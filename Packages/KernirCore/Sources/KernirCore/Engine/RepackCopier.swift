import Foundation
import CLibArchive

/// The repack copy step: which source headers survive a save and how each one is written, then the copy.
/// Kept headers go out in source order with their own metadata (`archive_entry_clone`) under their final
/// path (the normalized source path through `RenameMap`) as UTF-8, or under their stored name bytes when the
/// output keeps those (`storedName`; never for a renamed entry), and
/// their data streams block by block; nothing is extracted to disk and no entry is held in memory beyond one
/// libarchive block. A zip -> zip save keeps the archive comment (`zipArchiveComment`) and each kept header's
/// central-directory comment, verbatim (patch 0012).
struct RepackCopier {
    /// How a kept header is written.
    enum Action: Equatable {
        /// The header with its own data. A hardlink that carries data is written as a regular file.
        case copy
        /// A hardlink to an earlier kept header, by its normalized source path.
        case hardlink(String)
        /// A regular file holding the data of the header at `holder` (a hardlink whose target is gone or
        /// that the output format cannot hold, or an empty member of a cpio group).
        case borrow(holder: Int)
    }

    private struct Kept {
        /// The header's normalized path in the source, which removals, `LinkPlanner` and stored names go by.
        let sourcePath: String
        /// Its path in the output (`sourcePath` unless renamed), which additions replace and collisions go by.
        let path: String
        let isDirectory: Bool
        let action: Action
    }

    private let source: LibArchiveReader
    private let format: ArchiveFormat
    private let kept: [Int: Kept]
    private let renames: RenameMap
    /// Undeclared names may be written back as their stored bytes: zip -> zip (entry by entry), or tar family ->
    /// tar family when `tarKeepsStoredNames` allows it for the whole save.
    private let keepsStoredNames: Bool
    /// Tar family only: the paths hardlinks point at, whose stored bytes a raw-named link reuses.
    private let linkTargets: Set<String>
    /// Final paths of the kept headers. Additions get no extra parent entry for these.
    let keptPaths: Set<String>
    /// Data bytes the copy writes, for progress; nil when crafted sizes add up past Int64.
    let totalBytes: Int64?
    /// zip -> zip: the source's archive comment, verbatim, for the output's end record. Nil when there is none (or
    /// no end record whose comment reaches the end of the file) and for any other pair of formats.
    let zipArchiveComment: [UInt8]?
    /// zip -> zip: kept headers keep their central-directory comments.
    private let keepsZipComments: Bool
    var count: Int { kept.count }

    /// The copier for `source`, nil for a new archive. `changes.renamedPaths` is checked either way (`RenameMap`:
    /// with no source, any key is missing).
    static func make(source: LibArchiveReader?, changes: ArchiveChangeSet, additions: [AdditionItem],
                     format: ArchiveFormat, excludingMacMetadata: Bool) throws(ArchiveError) -> RepackCopier? {
        let renames = changes.renamedPaths.isEmpty ? RenameMap.none
            : try RenameMap(changes.renamedPaths, sourcePaths: Set(source?.entries.map(\.path) ?? []))
        guard let source else { return nil }
        return try RepackCopier(source: source, removedPaths: changes.removedPaths, renames: renames,
                                additions: additions, format: format, excludingMacMetadata: excludingMacMetadata)
    }

    /// Keeps a header when it is its path's winning header, is not removed (or beneath a removed path, both by
    /// source path, unless renamed out of it: `isRemoved`), no addition replaces it (by final path), and, with
    /// `excludingMacMetadata`, neither its source nor its final path is Mac metadata or beneath it
    /// (`MacOSMetadata.isExcludedEntry`). An addition replaces the kept entry at its own path, everything beneath a
    /// non-folder addition, and a kept non-folder at a path where an addition needs a folder. Throws `.io` when
    /// renames make two kept headers share a final path, put one beneath a kept non-folder, or move one onto a path
    /// a kept entry outside its key already holds (`checkFinalPaths`).
    init(source: LibArchiveReader, removedPaths: Set<String>, renames: RenameMap, additions: [AdditionItem],
         format: ArchiveFormat, excludingMacMetadata: Bool) throws(ArchiveError) {
        self.source = source
        self.format = format
        self.renames = renames
        let removed = Set(removedPaths.compactMap(EntryPath.normalize))
        let added = Set(additions.map(\.archivePath))
        var addedLeaves = Set<String>()
        var addedAncestors = Set<String>()
        for item in additions {
            if case .directory = item.kind {} else { addedLeaves.insert(item.archivePath) }
            addedAncestors.formUnion(EntryPath.ancestors(of: item.archivePath))
        }
        let entryByPath = Dictionary(source.entries.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })

        // Set lookups per ancestor: every path is NFC, so String equality is exact here.
        let removedFinals = renames.isEmpty ? removed : Set(removed.map(renames.finalPath))
        // Removals go by source path, except for an entry renamed out of a removed folder (`removedPaths`). Every
        // removed path at or above `path` lies on its ancestor chain, so the governing key lies strictly beneath all of
        // them exactly when it lies strictly beneath the deepest one. Such an entry is kept unless the key's final
        // path is at or beneath the final path of a removed path above it (moved within the folder it leaves), or
        // strictly beneath the final path of any removed path (moved into another removed folder); landing exactly on
        // another removed path's final path takes a freed name, as any rename may. The key decides, not the entry's
        // own final path, so a kept folder keeps its whole subtree (a removed final path at or beneath the key's final
        // path is one the moved folder now fills: its own entries are dropped).
        func isRemoved(_ path: String) -> Bool {
            guard !removed.isEmpty else { return false }
            let ancestors = EntryPath.ancestors(of: path)
            let selfRemoved = removed.contains(path)
            guard selfRemoved || ancestors.contains(where: removed.contains) else { return false }
            let above = (selfRemoved ? [path] : []) + ancestors.filter(removed.contains).reversed()
            guard let deepest = above.first else { return false }
            guard let key = renames.key(of: path), key != deepest, EntryPath.isSelected(key, by: [deepest]) else {
                return true
            }
            let keyFinal = renames.finalPath(of: key)
            return above.contains { renames.finalPath(of: $0) == keyFinal }
                || EntryPath.ancestors(of: keyFinal).contains(where: removedFinals.contains)
        }
        func isDropped(_ path: String, final: String) -> Bool {
            if isRemoved(path) { return true }
            if excludingMacMetadata, MacOSMetadata.isExcludedEntry(path: path)
                || final != path && MacOSMetadata.isExcludedEntry(path: final) {
                return true
            }
            if added.contains(final) || EntryPath.ancestors(of: final).contains(where: addedLeaves.contains) {
                return true
            }
            return addedAncestors.contains(final) && entryByPath[path]?.isDirectory != true
        }
        var keptPathByOrdinal: [Int: String] = [:]
        var finalPathByOrdinal: [Int: String] = [:]
        for (path, ordinal) in source.headerOrdinalByPath {
            let final = renames.finalPath(of: path)
            guard !isDropped(path, final: final) else { continue }
            keptPathByOrdinal[ordinal] = path
            finalPathByOrdinal[ordinal] = final
        }
        if !renames.isEmpty {
            try Self.checkFinalPaths(sources: keptPathByOrdinal, finals: finalPathByOrdinal, renames: renames,
                                     isDirectory: { entryByPath[$0]?.isDirectory == true })
        }

        let plan = LinkPlanner(source: source, entryByPath: entryByPath, keptPathByOrdinal: keptPathByOrdinal,
                               keepsHardlinks: Self.holdsHardlinks(format))
        var kept: [Int: Kept] = [:]
        var borrowed: [Int] = []
        var sizes: [Int64] = []
        for (ordinal, path) in keptPathByOrdinal {
            let action = try plan.action(for: path, ordinal: ordinal)
            kept[ordinal] = Kept(sourcePath: path, path: finalPathByOrdinal[ordinal] ?? path,
                                 isDirectory: entryByPath[path]?.isDirectory ?? false, action: action)
            switch action {
            case .copy: sizes.append(plan.size(path))
            case .borrow(let holder): borrowed.append(holder)
            case .hardlink: break
            }
        }
        if !borrowed.isEmpty {
            let pathByOrdinal = Dictionary(source.headerOrdinalByPath.map { ($0.value, $0.key) },
                                           uniquingKeysWith: { first, _ in first })
            for holder in borrowed { sizes.append(pathByOrdinal[holder].map(plan.size) ?? 0) }
        }
        self.kept = kept
        self.keptPaths = Set(finalPathByOrdinal.values)
        self.totalBytes = SizeSum.of(sizes)
        let sameFamily = Self.sameNameFamily(source.format, format)
        keepsStoredNames = sameFamily
            && (format == .zip
                || Self.tarKeepsStoredNames(source: source, kept: kept, renames: renames, additions: additions))
        linkTargets = keepsStoredNames && Self.holdsHardlinks(format) ? Set(source.hardlinkTargetByPath.values) : []
        keepsZipComments = source.format == .zip && format == .zip
        // The end record ends the set (a spanned set's .zip; in a byte split it may start in an earlier part), or the
        // file itself.
        let parts = source.volumeURLs.isEmpty ? [source.url] : source.volumeURLs
        if keepsZipComments, let comment = try VolumeProbe.zipComment(parts: parts),
           !comment.isEmpty {
            zipArchiveComment = comment
        } else {
            zipArchiveComment = nil
        }
    }

    /// Guard on the kept headers' final paths (the apps refuse these names first; this keeps a bad request from
    /// writing a broken archive). Throws `.io` when two headers share a final path, a renamed header lands beneath a
    /// kept non-folder, or a key's new path (or a path beneath it) is already held by a header from outside the
    /// key's subtree: an unrenamed one, or one renamed by another key whose own new path is not strictly inside it
    /// (a header that its own key moves into the renamed folder is fine). Only headers that are kept count, so two
    /// entries may trade names, and a name freed by a removal or a rename can be taken.
    private static func checkFinalPaths(sources: [Int: String], finals: [Int: String], renames: RenameMap,
                                        isDirectory: (String) -> Bool) throws(ArchiveError) {
        var sourceByFinal: [String: String] = [:]
        var files = Set<String>()
        for (ordinal, final) in finals {
            guard let source = sources[ordinal] else { continue }
            if sourceByFinal.updateValue(source, forKey: final) != nil { throw .io("\(final) already exists") }
            if !isDirectory(source) { files.insert(final) }
        }
        var headers: [(final: String, key: String?)] = []
        var usedKeys = Set<String>()
        for (final, source) in sourceByFinal {
            let key = renames.key(of: source)
            headers.append((final, key))
            guard let key else { continue }
            usedKeys.insert(key)
            if let file = EntryPath.ancestors(of: final).first(where: files.contains) {
                throw .io("\(file) is not a folder")
            }
        }
        for (key, target) in renames.targets where usedKeys.contains(key) {
            for header in headers where EntryPath.isSelected(header.final, by: [target]) {
                if let own = header.key {
                    if EntryPath.isSelected(own, by: [key]) { continue }
                    if let moved = renames.targets[own], moved != target, EntryPath.isSelected(moved, by: [target]) {
                        continue
                    }
                }
                throw .io("\(target) already exists")
            }
        }
    }

    /// Tar names are never declared, so a reopened tar decodes every name with one encoding: a save must not mix
    /// stored legacy bytes with UTF-8. Stored bytes are kept only when every name and link target the save writes
    /// is either a kept header's stored bytes (`keepsStoredName`) or ASCII; otherwise every name is UTF-8.
    /// Added names are never encoded into the legacy code page.
    private static func tarKeepsStoredNames(source: LibArchiveReader, kept: [Int: Kept], renames: RenameMap,
                                            additions: [AdditionItem]) -> Bool {
        func isASCII(_ s: String?) -> Bool { s?.utf8.allSatisfy { $0 < 0x80 } ?? true }
        for item in additions {
            // Ancestors added for an addition are prefixes of its path.
            guard isASCII(item.archivePath) else { return false }
            if case .symlink(let target) = item.kind, !isASCII(target) { return false }
        }
        // In copy order, as `copy` fills `storedTargets`.
        var stored = Set<String>()
        for ordinal in kept.keys.sorted() {
            guard let item = kept[ordinal] else { continue }
            // A renamed header never reads as its new path, so it is written as UTF-8 (`storedName`).
            let readsAsPath = item.path == item.sourcePath && !source.inexactStoredNames.contains(item.sourcePath)
            if keepsStoredName(readsAsPath: readsAsPath, action: item.action, targetIsStored: stored.contains) {
                stored.insert(item.sourcePath)
                continue
            }
            // Written under its UTF-8 path, link target included: only ASCII reads the same in any encoding.
            guard isASCII(item.path), isASCII(source.symlinkTargetByPath[item.sourcePath]) else { return false }
            if case .hardlink(let target) = item.action, !isASCII(renames.finalPath(of: target)) { return false }
        }
        return true
    }

    /// The one rule for whether a kept header (whose name is undeclared, in the output's family) keeps its stored
    /// bytes: its name reads as exactly its listed path, and a hardlink's target was itself written under its
    /// stored bytes, which the link then reuses (a raw-named link to a UTF-8 target would lose its target).
    private static func keepsStoredName(readsAsPath: Bool, action: Action, targetIsStored: (String) -> Bool)
        -> Bool {
        guard readsAsPath else { return false }
        if case .hardlink(let target) = action, !targetIsStored(target) { return false }
        return true
    }

    /// Only the tar family stores hardlinks; zip and 7z would write a data-less link as an empty file.
    private static func holdsHardlinks(_ format: ArchiveFormat) -> Bool {
        [.tar, .tarGzip, .tarBzip2, .tarXz].contains(format)
    }

    /// zip -> zip, or tar family -> tar family. The zip writer stores a raw name verbatim (patch 0009); the pax
    /// writer stores a name it cannot convert to UTF-8 as is, under hdrcharset=BINARY. Any other pair writes the
    /// names as the source displays them.
    private static func sameNameFamily(_ source: ArchiveFormat, _ format: ArchiveFormat) -> Bool {
        let tar: Set<ArchiveFormat> = [.tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd]
        return source == .zip && format == .zip || tar.contains(source) && tar.contains(format)
    }

    // MARK: - Copy

    /// Writes every kept header (and its data) into `session`, in source order.
    func copy(into session: WriteSession, tracker: inout ProgressTracker) throws {
        guard !kept.isEmpty else { return }
        let main = try source.makeSession()
        let cursor = SourceCursor(source: source)
        var remaining = kept.count
        var ordinal = 0
        var storedTargets: [String: [UInt8]] = [:]
        while remaining > 0 {
            if Task.isCancelled { throw ArchiveError.cancelled }
            guard let entry = try main.nextHeader() else { break }
            defer { ordinal += 1 }
            guard let item = kept[ordinal] else { continue }
            remaining -= 1
            try write(entry, item, ordinal: ordinal, from: main, cursor: cursor, storedTargets: &storedTargets,
                      into: session, tracker: &tracker)
            tracker.finishUnit(item.path)
        }
        if remaining > 0 { throw ArchiveError.corrupted("The archive ended before all of its entries were read") }
    }

    /// `storedTargets`: the stored bytes of each link target (by source path) written so far under its stored name.
    private func write(_ entry: OpaquePointer, _ item: Kept, ordinal: Int, from main: ReadSession,
                       cursor: SourceCursor, storedTargets: inout [String: [UInt8]],
                       into session: WriteSession, tracker: inout ProgressTracker) throws {
        var type = archive_entry_filetype(entry) & mode_t(S_IFMT)
        // A zip folder may be marked by its trailing "/" alone; a borrowed or linked entry is a file.
        if item.isDirectory {
            type = mode_t(S_IFDIR)
        } else if type == 0 || item.action != .copy && type != mode_t(S_IFLNK) {
            type = mode_t(S_IFREG)
        }
        // Zip and 7z hold files, folders and symlinks only; FIFOs, sockets and devices have no data and are
        // skipped there, as they are for additions.
        if !Self.holdsHardlinks(format), type != mode_t(S_IFREG), type != mode_t(S_IFDIR), type != mode_t(S_IFLNK) {
            return
        }

        guard let clone = archive_entry_clone(entry) else { throw ArchiveError.io("Out of memory") }
        defer { archive_entry_free(clone) }
        archive_entry_set_filetype(clone, UInt32(type))
        // The data is written densely; a sparse map would make tar skip the holes we fill.
        archive_entry_sparse_clear(clone)
        let stored = storedName(of: entry, item, in: main, storedTargets: storedTargets)
        if let stored, linkTargets.contains(item.sourcePath) { storedTargets[item.sourcePath] = stored }
        let symlinkTarget = type == mode_t(S_IFLNK)
            ? EntryNameDecoder.symlinkTarget(of: entry, in: main, using: source.nameDecoding) : nil
        let named: Bool = withUTF8CType {
            if let stored {
                // Byte setters only: the stored bytes are not UTF-8 text in general.
                Self.withCString(stored) { archive_entry_copy_pathname(clone, $0) }
                if symlinkTarget != nil {
                    archive_entry_copy_symlink(clone, archive_entry_symlink(entry))
                } else if case .hardlink(let target) = item.action, let bytes = storedTargets[target] {
                    Self.withCString(bytes) { archive_entry_copy_hardlink(clone, $0) }
                } else {
                    archive_entry_set_hardlink(clone, nil)
                }
                return true
            }
            guard archive_entry_update_pathname_utf8(clone, item.path) != 0 else { return false }
            if let symlinkTarget { return archive_entry_update_symlink_utf8(clone, symlinkTarget) != 0 }
            if case .hardlink(let target) = item.action {
                return archive_entry_update_hardlink_utf8(clone, renames.finalPath(of: target)) != 0
            }
            archive_entry_set_hardlink(clone, nil)
            return true
        }
        guard named else { throw ArchiveError.io("Cannot store the name \(item.path)") }
        // A zip keeps a stored name's bytes and its missing bit 11 (a declared name never gets here).
        let rawZip = stored != nil && format == .zip
        // Its comment goes with the header written next (the borrow and size passes below only read).
        if keepsZipComments, let comment = main.zipEntryComment, !comment.isEmpty {
            try session.setNextZipEntryComment(comment)
        }

        switch item.action {
        case .hardlink:
            archive_entry_set_size(clone, 0)
            try writeHeader(clone, rawZip: rawZip, into: session)
        case .borrow(let holder):
            let (holderEntry, read) = try cursor.header(at: holder)
            let size: Int64? = archive_entry_size_is_set(holderEntry) != 0 ? archive_entry_size(holderEntry) : nil
            if let size { archive_entry_set_size(clone, size) } else { archive_entry_unset_size(clone) }
            try writeHeaderAndData(clone, rawZip: rawZip, path: item.path, dataOf: holderEntry, from: read,
                                   cursor: cursor, ordinal: holder, into: session, tracker: &tracker)
        case .copy:
            guard type == mode_t(S_IFREG) else {
                archive_entry_set_size(clone, 0)
                try writeHeader(clone, rawZip: rawZip, into: session)
                return
            }
            try writeHeaderAndData(clone, rawZip: rawZip, path: item.path, dataOf: entry, from: main,
                                   cursor: cursor, ordinal: ordinal, into: session, tracker: &tracker)
        }
    }

    /// The stored name bytes to write the current header `entry` under, or nil for the listing's UTF-8 path.
    /// Kept when the save keeps stored names (`keepsStoredNames`), the name is undeclared (any bytes, ASCII too; a
    /// zip name with bit 11 or a used 0x7075 field is declared), and `keepsStoredName` holds: it reads as exactly
    /// the final path (`EntryNameDecoder.readsAsPath`), so a "./", "//" or ".." spelling still gets the
    /// normalized path and a renamed header gets its new one, and a hardlink's target was written under its stored
    /// bytes. A symlink's target is the
    /// source's stored target, which is exactly what the listing decoded and shows.
    private func storedName(of entry: OpaquePointer, _ item: Kept, in main: ReadSession,
                            storedTargets: [String: [UInt8]]) -> [UInt8]? {
        guard keepsStoredNames else { return nil }
        guard let raw = EntryNameDecoder.storableRawName(of: entry, in: main),
              let decoded = EntryNameDecoder.pathname(of: entry, in: main, using: source.nameDecoding),
              Self.keepsStoredName(readsAsPath: EntryNameDecoder.readsAsPath(decoded, path: item.path,
                                                                             isDirectory: item.isDirectory),
                                   action: item.action, targetIsStored: { storedTargets[$0] != nil })
        else { return nil }
        return raw
    }

    private static func withCString(_ bytes: [UInt8], _ body: (UnsafePointer<CChar>) -> Void) {
        (bytes + [0]).withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
    }

    /// `rawZip`: arm patch 0009's raw-name mode for exactly this header.
    private func writeHeader(_ clone: OpaquePointer, rawZip: Bool, into session: WriteSession) throws {
        if rawZip { try session.writeHeader(clone, rawZipName: false) } else { try session.writeHeader(clone) }
    }

    /// Writes the regular-file header `clone` and the data of `dataEntry`, the current header of `read`.
    /// Tar and 7z need the size up front: when the source does not say (raw streams), a cursor pass counts it.
    /// Counting may reopen the cursor; `read` is a session object of its own and stays where it is.
    private func writeHeaderAndData(_ clone: OpaquePointer, rawZip: Bool, path: String,
                                    dataOf dataEntry: OpaquePointer, from read: ReadSession, cursor: SourceCursor,
                                    ordinal: Int, into session: WriteSession,
                                    tracker: inout ProgressTracker) throws {
        if archive_entry_size_is_set(clone) == 0, format != .zip {
            archive_entry_set_size(clone, try cursor.dataSize(at: ordinal))
        }
        let declared: Int64? = archive_entry_size_is_set(clone) != 0 ? archive_entry_size(clone) : nil
        try writeHeader(clone, rawZip: rawZip, into: session)
        try streamData(of: dataEntry, from: read, path: path, declaredSize: declared, into: session, tracker: &tracker)
    }

    /// Streams the current entry's data blocks. A block that starts past the bytes written (a sparse hole)
    /// is preceded by zeros, and a short tail up to the declared size is zero-filled too.
    private func streamData(of entry: OpaquePointer, from read: ReadSession, path: String, declaredSize: Int64?,
                            into session: WriteSession, tracker: inout ProgressTracker) throws {
        let encrypted = try SourceCursor.checkDecryptable(entry, source: source, read: read)
        var written: Int64 = 0
        while let block = try SourceCursor.readBlock(read, encrypted: encrypted, source: source) {
            if Task.isCancelled { throw ArchiveError.cancelled }
            if block.offset < written { throw ArchiveError.corrupted("Out-of-order data in \(path)") }
            if block.offset > written {
                try writeZeros(block.offset - written, path: path, into: session, tracker: &tracker)
                written = block.offset
            }
            try session.writeData(block.buffer)
            written += Int64(block.buffer.count)
            tracker.addBytes(Int64(block.buffer.count), path: path)
        }
        if let declaredSize, written < declaredSize {
            try writeZeros(declaredSize - written, path: path, into: session, tracker: &tracker)
        }
    }

    private static let zeros = [UInt8](repeating: 0, count: 64 * 1024)

    private func writeZeros(_ count: Int64, path: String, into session: WriteSession,
                            tracker: inout ProgressTracker) throws {
        var left = count
        while left > 0 {
            if Task.isCancelled { throw ArchiveError.cancelled }
            let n = Int(min(left, Int64(Self.zeros.count)))
            try Self.zeros.withUnsafeBytes { try session.writeData(UnsafeRawBufferPointer(rebasing: $0[..<n])) }
            left -= Int64(n)
            tracker.addBytes(Int64(n), path: path)
        }
    }
}

// MARK: - Hardlinks

/// Decides how each kept header is written, from the maps the reader recorded at open (no source pass).
private struct LinkPlanner {
    let source: LibArchiveReader
    let entryByPath: [String: ArchiveEntry]
    let keptPathByOrdinal: [Int: String]
    let keepsHardlinks: Bool
    /// cpio only: the data holder of each hardlink group (by root path), the last member with data.
    private let cpioHolders: [String: (ordinal: Int, path: String)]
    private let cpioRoots: Set<String>

    init(source: LibArchiveReader, entryByPath: [String: ArchiveEntry], keptPathByOrdinal: [Int: String],
         keepsHardlinks: Bool) {
        self.source = source
        self.entryByPath = entryByPath
        self.keptPathByOrdinal = keptPathByOrdinal
        self.keepsHardlinks = keepsHardlinks
        var holders: [String: (ordinal: Int, path: String)] = [:]
        var roots = Set<String>()
        if source.format == .cpio, source.hasHardlinks {
            // libarchive names a group's first header as every later member's target.
            roots = Set(source.hardlinkTargetByPath.values)
            func consider(_ path: String, of root: String) {
                guard (entryByPath[path]?.size ?? 0) > 0, let o = source.headerOrdinalByPath[path],
                      o > holders[root]?.ordinal ?? -1 else { return }
                holders[root] = (o, path)
            }
            for (link, root) in source.hardlinkTargetByPath { consider(link, of: root) }
            for root in roots where source.hardlinkTargetByPath[root] == nil { consider(root, of: root) }
        }
        cpioHolders = holders
        cpioRoots = roots
    }

    func size(_ path: String) -> Int64 { entryByPath[path]?.size ?? 0 }

    private func isRegularFile(_ path: String) -> Bool {
        entryByPath[path]?.isDirectory == false && source.symlinkTargetByPath[path] == nil
    }

    /// The ordinal of `target`'s header when it is kept and comes before `ordinal` (tar needs a link's
    /// target earlier in the stream).
    private func keptEarlier(_ target: String, than ordinal: Int) -> Bool {
        guard let t = source.headerOrdinalByPath[target] else { return false }
        return t < ordinal && keptPathByOrdinal[t] != nil
    }

    private func notRegular(_ path: String) -> ArchiveError {
        .corrupted("Hardlink \(path) does not lead to a regular file")
    }

    func action(for path: String, ordinal: Int) throws(ArchiveError) -> RepackCopier.Action {
        if source.format == .cpio { return try cpioAction(for: path, ordinal: ordinal) }
        guard let target = source.hardlinkTargetByPath[path], size(path) == 0 else { return .copy }
        if keepsHardlinks, keptEarlier(target, than: ordinal) { return .hardlink(target) }
        // Follow the chain (h -> g -> f) to the header that holds the bytes.
        var holder = target
        for _ in 0..<8 {
            guard size(holder) == 0, let next = source.hardlinkTargetByPath[holder] else { break }
            holder = next
        }
        if size(holder) == 0, source.hardlinkTargetByPath[holder] != nil {
            throw .corrupted("Hardlink chain longer than 8 hops: \(path)")
        }
        guard let holderOrdinal = source.headerOrdinalByPath[holder] else {
            throw .corrupted("Hardlink target missing from archive: \(path)")
        }
        guard isRegularFile(holder) else { throw notRegular(path) }
        return .borrow(holder: holderOrdinal)
    }

    /// cpio newc keeps a group's bytes on its last member only (earlier members have size 0); odc keeps
    /// them on every member. Every member is written as a regular file with the group's bytes, so any
    /// subset of a group survives a save with its data.
    private func cpioAction(for path: String, ordinal: Int) throws(ArchiveError) -> RepackCopier.Action {
        let root = source.hardlinkTargetByPath[path] ?? (cpioRoots.contains(path) ? path : nil)
        guard let root, size(path) == 0 else { return .copy }
        if let holder = cpioHolders[root] {
            guard isRegularFile(holder.path) else { throw notRegular(path) }
            return .borrow(holder: holder.ordinal)
        }
        // No member has data: empty files, or links to a symlink or folder (the root itself copies as is).
        if path == root || isRegularFile(root) { return .copy }
        if keepsHardlinks, keptEarlier(root, than: ordinal) { return .hardlink(root) }
        throw notRegular(path)
    }
}

// MARK: - Second source pass

/// A second read of the source, for data that is not where the main pass is: a hardlink's data holder
/// (tar keeps it earlier, cpio newc later) or an entry whose size must be counted before its header.
/// Moves forward; going back reopens the source.
final class SourceCursor {
    private let source: LibArchiveReader
    private var session: ReadSession?
    private var next = 0

    init(source: LibArchiveReader) { self.source = source }

    /// The header at `ordinal` and the session positioned on it (its data not yet read).
    func header(at ordinal: Int) throws -> (OpaquePointer, ReadSession) {
        if session == nil || ordinal < next {
            session = try source.makeSession()
            next = 0
        }
        let s = session!
        while let entry = try s.nextHeader() {
            let o = next
            next += 1
            if o == ordinal { return (entry, s) }
        }
        session = nil
        throw ArchiveError.corrupted("An entry is missing from the archive")
    }

    /// The data length of the header at `ordinal`, counted by reading it.
    func dataSize(at ordinal: Int) throws -> Int64 {
        let (entry, s) = try header(at: ordinal)
        let encrypted = try Self.checkDecryptable(entry, source: source, read: s)
        var end: Int64 = 0
        while let block = try Self.readBlock(s, encrypted: encrypted, source: source) {
            if Task.isCancelled { throw ArchiveError.cancelled }
            end = max(end, block.offset + Int64(block.buffer.count))
        }
        return end
    }

    /// Throws when the entry's data cannot be decrypted: RAR or strong zip encryption (whatever the
    /// password), or no password. Returns whether the entry is encrypted.
    static func checkDecryptable(_ entry: OpaquePointer, source: LibArchiveReader, read: ReadSession) throws -> Bool {
        let dataEncrypted = archive_entry_is_data_encrypted(entry) != 0
        if dataEncrypted {
            if let unsupported = undecryptableError(format: source.format,
                                                    zipStrongEncryption: source.zipStrongEncryption) {
                throw unsupported
            }
            if !read.hasPassphrase { throw encryptionError(format: source.format, hasPassphrase: false) }
        }
        return dataEncrypted || archive_entry_is_encrypted(entry) != 0
    }

    /// One data block; a failure maps through `readFailure`, like extraction.
    static func readBlock(_ read: ReadSession, encrypted: Bool, source: LibArchiveReader) throws
        -> (buffer: UnsafeRawBufferPointer, offset: Int64)? {
        do throws(ArchiveError) {
            return try read.readBlock()
        } catch {
            throw readFailure(error, format: source.format, encrypted: encrypted, hasPassphrase: read.hasPassphrase,
                              zipStrongEncryption: source.zipStrongEncryption)
        }
    }
}
