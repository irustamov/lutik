import Foundation

/// The rule for every export that hands file URLs to another app (Copy's files, Share, Open With, Quick Look,
/// drag-out): no symbolic link in it may lead out of the item it is in, so a crafted archive's
/// "photo.jpg" -> ~/.ssh/id_rsa never sends the user's own file along. `sanitize` runs once the items are
/// extracted, before anyone gets their URLs:
/// - an item that is itself a symlink is removed (it has nothing inside to lead to);
/// - inside a folder item, a symlink stays only when its target is relative, stays inside the item when
///   normalized from the link's folder ("..", "." and empty parts, on bytes), and resolves on disk to
///   something that exists inside the item, every step of the way (followed part by part, and realpath).
///   `d` -> "." with `x` -> "d/../secret" passes the first check and leaves through the second. Bundles keep their links (`Versions/Current` -> "A");
/// - a symlink that resolves to the item itself or to a folder the link is in (`s` -> ".", `up` -> "..") is
///   removed too: a receiver that follows links would find an endless tree below it. Links to a sibling or a
///   child stay (`Versions/Current` -> "A", `Headers` -> "Versions/Current/Headers"). Two sibling folders
///   linking to each other aren't caught;
/// - a file hard-linked from outside the export (more links than its items hold) is removed.
/// lstat only: nothing is followed while walking. A removal can leave another link dangling, so passes repeat
/// until one removes nothing. A folder the archive made unreadable or read-only is opened up (owner rwx) while
/// it is swept, then gets its mode back. Fails closed: anything that keeps the sweep from finishing throws, and
/// the caller drops the export. Only the folders being walked are opened up, so a link into a sibling the
/// archive made 0000 (or without search permission) can't be followed when it is checked, and is removed
/// although it stays inside.
enum ExportLinkSweep {
    /// Sanitizes `items` (extracted top-level items of one export, each its own root) in place. Returns the
    /// items kept, in order: all but those that were symlinks themselves or files hard-linked from outside.
    nonisolated static func sanitize(_ items: [URL]) throws -> [URL] {
        var kept: [(url: URL, root: [UInt8]?)] = []
        for item in items {
            let path = item.path
            var status = stat()
            guard lstat(path, &status) == 0 else { throw posixError(errno) }
            switch status.st_mode & S_IFMT {
            case S_IFLNK:
                guard unlink(path) == 0 else { throw posixError(errno) }
            case S_IFDIR:
                guard let resolved = realpath(path, nil) else { throw posixError(errno) }
                kept.append((item, Array(String(cString: resolved).utf8)))
                free(resolved)
            default:
                kept.append((item, nil))
            }
        }
        var gone = Set<String>()
        while true {
            let removed = try pass(kept.filter { !gone.contains(standardized($0.url)) })
            if removed.isEmpty { break }
            gone.formUnion(removed)
        }
        return kept.map(\.url).filter { !gone.contains(standardized($0)) }
    }

    private struct FileID: Hashable {
        var dev: dev_t
        var ino: ino_t
    }

    /// `url`'s path with "." and ".." parts resolved (no symlink followed): the one spelling of a path the sweep
    /// counts and removes by.
    private nonisolated static func standardized(_ url: URL) -> String { url.standardizedFileURL.path }

    /// One pass over the items: removes the links the rule refuses, and the files hard-linked from outside the
    /// export (every link to one inode counts once, in any of its items: overlapping items, `a` and `a/x`, meet
    /// `a/x` twice). Returns the (standardized) paths it removed.
    private nonisolated static func pass(_ items: [(url: URL, root: [UInt8]?)]) throws -> [String] {
        var removed: [String] = []
        // Non-folders with more than one link: where they are, and how many links the system counts.
        var linked: [FileID: (paths: Set<String>, count: Int)] = [:]
        func note(_ path: String, _ status: stat) {
            guard status.st_nlink > 1 else { return }
            linked[FileID(dev: status.st_dev, ino: status.st_ino), default: ([], Int(status.st_nlink))]
                .paths.insert(path)
        }
        func walk(_ folder: String, parts: [[UInt8]], rootBytes: [UInt8]) throws {
            try withOwnerAccess(folder) {
                let names = try FileManager.default.contentsOfDirectory(atPath: folder)
                for name in names {
                    let path = folder + "/" + name
                    var status = stat()
                    guard lstat(path, &status) == 0 else { throw posixError(errno) }
                    switch status.st_mode & S_IFMT {
                    case S_IFDIR:
                        try walk(path, parts: parts + [Array(name.utf8)], rootBytes: rootBytes)
                    case S_IFLNK where !isContained(link: path, in: parts, rootBytes: rootBytes):
                        guard unlink(path) == 0 else { throw posixError(errno) }
                        removed.append(path)
                    default:
                        note(path, status)
                    }
                }
            }
        }
        for item in items {
            let path = standardized(item.url)
            if let rootBytes = item.root {
                try walk(path, parts: [], rootBytes: rootBytes)
            } else {
                var status = stat()
                guard lstat(path, &status) == 0 else { throw posixError(errno) }
                note(path, status)
            }
        }
        // A link the walk didn't meet is outside the export: every link of that file inside goes.
        for (paths, count) in linked.values where paths.count < count {
            for path in paths.sorted() {
                try withOwnerAccess((path as NSString).deletingLastPathComponent) {
                    guard unlink(path) == 0 else { throw posixError(errno) }
                }
                removed.append(path)
            }
        }
        return removed
    }

    /// Whether the symlink at `link`, in the folder `parts` below the root, stays inside it: a relative target
    /// that normalizes inside (`isLexicallyInside`), a resolution on disk that exists inside (`rootBytes`, the
    /// root's realpath), and every step of that resolution inside too (`resolve`), so a target that passes
    /// through the root's parent (`d` -> "." with `x` -> "d/../<root's name>/f") goes as well. A link that
    /// resolves to the root or to a folder it is in isn't kept either (`isAncestor`): it would loop. A link
    /// into a folder that isn't open yet (0000, no search permission) can't be resolved and isn't kept.
    private nonisolated static func isContained(link: String, in parts: [[UInt8]], rootBytes: [UInt8]) -> Bool {
        guard let target = readTarget(Array(link.utf8)), target.first != slash,
              isLexicallyInside(target, depth: parts.count) else { return false }
        var hops = 0
        guard resolve(target, from: parts, rootBytes: rootBytes, hops: &hops) != nil,
              let resolved = realpath(link, nil) else { return false }
        defer { free(resolved) }
        let bytes = Array(String(cString: resolved).utf8)
        guard bytes == rootBytes || bytes.starts(with: rootBytes + [slash]) else { return false }
        return !isAncestor(of: link, in: parts, rootBytes: rootBytes)
    }

    /// Whether the symlink at `link` resolves to the root or to one of the folders `parts` it is in. Compared
    /// by file identity (stat, the link followed), so another case or normalization of a name is the same folder.
    private nonisolated static func isAncestor(of link: String, in parts: [[UInt8]], rootBytes: [UInt8]) -> Bool {
        var target = stat()
        // Unresolvable now counts as a loop: fail closed.
        guard stat(link, &target) == 0 else { return true }
        guard target.st_mode & S_IFMT == S_IFDIR else { return false }
        for depth in 0...parts.count {
            let folder = parts[..<depth].reduce(rootBytes) { $0 + [slash] + $1 }
            var status = stat()
            let rc = (folder + [0]).withUnsafeBufferPointer { b in
                b.withMemoryRebound(to: CChar.self) { lstat($0.baseAddress!, &status) }
            }
            guard rc == 0 else { return true }
            if status.st_dev == target.st_dev, status.st_ino == target.st_ino { return true }
        }
        return false
    }

    private nonisolated static let slash = UInt8(ascii: "/")
    private nonisolated static let dot = [UInt8(ascii: ".")]
    private nonisolated static let dotDot = [UInt8(ascii: "."), UInt8(ascii: ".")]

    /// Whether `target`, normalized from a folder `depth` levels below the root ("..", "." and empty parts, on
    /// bytes), stays inside the root.
    private nonisolated static func isLexicallyInside(_ target: [UInt8], depth: Int) -> Bool {
        var level = depth
        for part in target.split(separator: slash) {
            if part.elementsEqual(dot) { continue }
            if part.elementsEqual(dotDot) {
                level -= 1
                if level < 0 { return false }
            } else {
                level += 1
            }
        }
        return true
    }

    /// Follows the relative `target` from the folder `parts` below the root the way the system does, step by
    /// step, and returns where it ends (parts below the root): nil as soon as a step would leave the root, a
    /// part is missing or isn't a folder where one is needed, a link met on the way is absolute, or more than
    /// 32 links were followed (`MAXSYMLINKS`).
    private nonisolated static func resolve(_ target: [UInt8], from parts: [[UInt8]], rootBytes: [UInt8],
                                            hops: inout Int) -> [[UInt8]]? {
        func path(_ parts: [[UInt8]]) -> [UInt8] { parts.reduce(rootBytes) { $0 + [slash] + $1 } }
        hops += 1
        guard hops <= 32, target.first != slash else { return nil }
        var at = parts
        for part in target.split(separator: slash) {
            // Every step starts from a folder ("f/..", "f/." and "f/x" fail on a file, as they do on disk).
            guard let mode = lstatMode(path(at)), mode == S_IFDIR else { return nil }
            if part.elementsEqual(dot) { continue }
            if part.elementsEqual(dotDot) {
                guard !at.isEmpty else { return nil }
                at.removeLast()
                continue
            }
            at.append(Array(part))
            guard let mode = lstatMode(path(at)) else { return nil }
            if mode == S_IFLNK {
                guard let next = readTarget(path(at)) else { return nil }
                at.removeLast()
                guard let resolved = resolve(next, from: at, rootBytes: rootBytes, hops: &hops) else { return nil }
                at = resolved
            }
        }
        return at
    }

    /// The file type bits of the item at `path` (lstat: links aren't followed); nil when it can't be read.
    private nonisolated static func lstatMode(_ path: [UInt8]) -> mode_t? {
        var status = stat()
        let rc = (path + [0]).withUnsafeBufferPointer { b in
            b.withMemoryRebound(to: CChar.self) { lstat($0.baseAddress!, &status) }
        }
        return rc == 0 ? status.st_mode & S_IFMT : nil
    }

    /// The target bytes of the symlink at `path`; nil when it can't be read or is empty.
    private nonisolated static func readTarget(_ path: [UInt8]) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let length = (path + [0]).withUnsafeBufferPointer { p in
            p.withMemoryRebound(to: CChar.self) { cPath in
                buffer.withUnsafeMutableBufferPointer { b in
                    b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: b.count) {
                        readlink(cPath.baseAddress!, $0, b.count - 1)
                    }
                }
            }
        }
        return length > 0 ? Array(buffer[..<length]) : nil
    }

    /// Runs `body` with the owner's read, write and search permission on `folder` (an archive's 0555 or 0000
    /// folder can't be listed or swept otherwise), then puts its mode back.
    private nonisolated static func withOwnerAccess(_ folder: String, _ body: () throws -> Void) throws {
        var status = stat()
        guard lstat(folder, &status) == 0 else { throw posixError(errno) }
        let mode = status.st_mode & 0o7777
        let opened = mode & S_IRWXU != S_IRWXU
        if opened {
            guard chmod(folder, mode | S_IRWXU) == 0 else { throw posixError(errno) }
        }
        defer { if opened { chmod(folder, mode) } }
        try body()
    }

    private nonisolated static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

/// Every item an export was asked for was a link (symbolic, or a file hard-linked from outside), and none is
/// handed to another app (`ExportLinkSweep`): the export fails as one that couldn't be made.
struct ExportedLinksError: LocalizedError, Equatable {
    /// The items' names, in order.
    var names: [String]

    var errorDescription: String? {
        if names.count == 1 {
            String(localized: "“\(names[0])” is a link and can’t be copied out of the archive.", table: "Shared",
                   comment: "Alert message when the only item exported is a link (a symbolic link, or a file hard-linked to one outside the archive's copy), which Lutik never hands to other apps. Shown for Edit > Copy and Cut, Share, Open With, preview, a drag-out to Finder, a drag to another archive window, and Share on iOS. %@ = the item's name.")
        } else {
            String(localized: "The selected items are links and can’t be copied out of the archive.", table: "Shared",
                   comment: "Alert message when every item exported is a link (a symbolic link, or a file hard-linked to one outside the archive's copy), which Lutik never hands to other apps. Shown for Edit > Copy and Cut, Share, Open With, preview, a drag-out to Finder, a drag to another archive window, and Share on iOS.")
        }
    }
}
