import Foundation

/// One file system item to add, with its normalized path inside the archive.
struct AdditionItem: Sendable {
    enum Kind: Sendable { case file, directory, symlink(String) }
    let sourceURL: URL
    let archivePath: String
    let kind: Kind
    /// Byte count for files, 0 otherwise.
    let size: Int64
    let modificationDate: Date
    let permissions: UInt16
}

/// Turns `ArchiveChangeSet` additions into the items to write, each root under its `archiveName` or its own
/// name on disk, its contents under their own names. Folders recurse without following symlinks; Finder's
/// `.DS_Store` is skipped (by its name on disk); FIFOs, sockets and devices have no archive entry and are skipped.
/// With `excludingMacMetadata`, items named `__MACOSX`, `._*` or `.DS_Store` on disk are skipped at any
/// depth, a folder with its contents, and so is an addition whose archive path is Mac metadata
/// (`MacOSMetadata.isExcludedEntry`, e.g. one placed inside a `__MACOSX` folder of the archive, at any depth).
/// Note: on macOS, Foundation's directory enumerator never lists `._*` *files* inside a walked folder, even a
/// stray one with no data file beside it (folders named `._*` are listed). So whatever the flag, a nested `._*`
/// file is never written today; only a `._*` file added on its own reaches the flag. The name check still runs
/// on every enumerated child, for any file system or Foundation version that does list them (exFAT and SMB,
/// where AppleDouble files are real files, are untested).
enum AdditionWalker {
    /// Items in walk order (a folder before its contents). A later addition wins outright: an item at
    /// an existing path replaces it (keeping its position) and drops every earlier item beneath that
    /// path, and an earlier non-directory item at one of its ancestors is dropped, so that ancestor
    /// becomes a directory entry (via `missingParents`). The result never puts an entry under a file.
    static func items(for additions: [ArchiveChangeSet.Addition],
                      excludingMacMetadata: Bool) throws(ArchiveError) -> [AdditionItem] {
        var result: [AdditionItem?] = []
        var indexByPath: [String: Int] = [:]
        func drop(_ path: String) {
            if let i = indexByPath.removeValue(forKey: path) { result[i] = nil }
        }
        for addition in additions {
            for item in try walk(addition, excludingMacMetadata: excludingMacMetadata) {
                let path = item.archivePath
                for ancestor in EntryPath.ancestors(of: path) {
                    guard let i = indexByPath[ancestor], let a = result[i] else { continue }
                    if case .directory = a.kind { continue }
                    drop(ancestor)
                }
                if let i = indexByPath[path] {
                    let beneath = indexByPath.keys.filter { $0 != path && EntryPath.isSelected($0, by: [path]) }
                    beneath.forEach(drop)
                    result[i] = item
                } else {
                    indexByPath[path] = result.count
                    result.append(item)
                }
            }
        }
        return result.compactMap { $0 }
    }

    /// Directory paths to write before `items` so every item has an explicit parent entry, outermost
    /// first: each ancestor that is neither in `explicitPaths` (entries already in the output) nor an item.
    static func missingParents(of items: [AdditionItem], explicitPaths: Set<String>) -> [String] {
        var present = explicitPaths.union(items.map(\.archivePath))
        var result: [String] = []
        for item in items {
            for ancestor in EntryPath.ancestors(of: item.archivePath) where present.insert(ancestor).inserted {
                result.append(ancestor)
            }
        }
        return result
    }

    private static func walk(_ addition: ArchiveChangeSet.Addition,
                             excludingMacMetadata: Bool) throws(ArchiveError) -> [AdditionItem] {
        let root = addition.sourceURL
        let name = root.lastPathComponent
        if let given = addition.archiveName, !EntryPath.isValidComponent(given) {
            throw .io("“\(given)” is not a valid name")
        }
        let archiveName = addition.archiveName ?? name
        guard let base = EntryPath.normalize(addition.destinationDirectory + "/" + archiveName) else {
            throw .io("Cannot add \(root.path)")
        }
        guard !skips(name: name, excludingMacMetadata: excludingMacMetadata) else { return [] }
        if excludingMacMetadata, MacOSMetadata.isExcludedEntry(path: base) { return [] }
        guard let first = try item(at: root, archivePath: base) else { return [] }
        guard case .directory = first.kind else { return [first] }

        var result = [first]
        var walkError: (any Error)?
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [],
                                                    errorHandler: { _, error in walkError = error; return false })
        while let url = walker?.nextObject() as? URL {
            if skips(name: url.lastPathComponent, excludingMacMetadata: excludingMacMetadata) {
                // Without the flag a `.DS_Store` folder's contents are still walked, as without the option. With it, a
                // skipped folder goes with its contents. Only a real folder: `skipDescendants()` after anything
                // else (a `.DS_Store` or `._*` file, a symlink, which the enumerator never follows) makes the
                // enumerator skip the contents of the next folder it returns, silently losing real files.
                if excludingMacMetadata, isDirectory(url) { walker?.skipDescendants() }
                continue
            }
            // The last `level` components are the path below the root, whatever spelling the URL uses.
            let relative = url.pathComponents.suffix(walker?.level ?? 0).joined(separator: "/")
            guard let path = EntryPath.normalize(base + "/" + relative) else { continue }
            if let i = try item(at: url, archivePath: path) { result.append(i) }
        }
        if let walkError { throw .io("Could not read \(name): \(walkError.localizedDescription)") }
        return result
    }

    /// Whether an item with this name on disk is left out: `.DS_Store` always, and with the flag
    /// `__MACOSX` and `._*` too. Checked for every addition's root and every enumerated child.
    static func skips(name: String, excludingMacMetadata: Bool) -> Bool {
        name == ".DS_Store" || excludingMacMetadata && MacOSMetadata.isExcludedOnDisk(name: name)
    }

    /// Whether `url` is a folder itself (lstat: a symlink to a folder is not). False when it cannot be read.
    private static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// nil for file types an archive entry cannot hold.
    private static func item(at url: URL, archivePath: String) throws(ArchiveError) -> AdditionItem? {
        let fm = FileManager.default
        let attrs: [FileAttributeKey: Any]
        let kind: AdditionItem.Kind
        do {
            attrs = try fm.attributesOfItem(atPath: url.path)  // lstat: a symlink is not followed
            switch attrs[.type] as? FileAttributeType {
            case .typeRegular?: kind = .file
            case .typeDirectory?: kind = .directory
            case .typeSymbolicLink?: kind = .symlink(try fm.destinationOfSymbolicLink(atPath: url.path))
            default: return nil
            }
        } catch {
            throw .io("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let size: Int64
        if case .file = kind { size = (attrs[.size] as? NSNumber)?.int64Value ?? 0 } else { size = 0 }
        return AdditionItem(
            sourceURL: url, archivePath: archivePath, kind: kind, size: size,
            modificationDate: attrs[.modificationDate] as? Date ?? Date(),
            permissions: UInt16(truncatingIfNeeded: ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644) & 0o7777))
    }
}
