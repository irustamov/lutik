import Foundation
import CLibArchive

/// A file's identity, device + inode: two paths name the same file exactly when these match.
struct FileID: Hashable {
    let dev: dev_t
    let ino: ino_t

    init(dev: dev_t, ino: ino_t) {
        self.dev = dev
        self.ino = ino
    }

    /// The file `path` names, following symlinks; nil when nothing can be stat'ed there.
    init?(followingLinksAt path: String) {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        self.init(dev: st.st_dev, ino: st.st_ino)
    }
}

extension LibArchiveReader {
    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        var selection: Set<String>?
        if let paths {
            var set = Set<String>()
            let known = Set(entries.map(\.path))
            for p in paths {
                // Errors carry the caller's spelling, not the normalized one.
                guard let n = EntryPath.normalize(p), known.contains(n) else { throw ArchiveError.entryNotFound(p) }
                set.insert(n)
            }
            selection = set
        }
        try extractEntries(selection: selection, to: directory, progress: progress)
    }

    /// Synchronous core, shared with the temporary-file cache. `selection` holds normalized paths; nil
    /// extracts everything. The whole loop runs inside one `withUTF8CType` with no suspension points,
    /// so `Task.isCancelled` reads the calling task's state. `afterClaim` (tests only) runs once a
    /// destination has passed its write-time check, before anything is created there.
    func extractEntries(selection: Set<String>?, to directory: URL, progress: ArchiveProgressHandler?,
                        afterClaim: ((String) -> Void)? = nil) throws {
        let entryByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        if let selection {
            for p in selection.sorted() where entryByPath[p] == nil { throw ArchiveError.entryNotFound(p) }
        }
        let selected = entries.filter { e in selection.map { EntryPath.isSelected(e.path, by: $0) } ?? true }

        // Header ordinal -> destination entry path, plus directories that have no header.
        var wanted: [Int: String] = [:]
        var synthesizedDirs: [String] = []
        for e in selected {
            if let o = headerOrdinalByPath[e.path] { wanted[o] = e.path }
            else if e.isDirectory { synthesizedDirs.append(e.path) }
        }

        let session = try makeSession()
        let hardlinks = format == .cpio
            ? try cpioHardlinkPlan(wanted: wanted, entryByPath: entryByPath)
            : try hardlinkPlan(wanted: wanted, selection: selection, entryByPath: entryByPath)

        // Progress totals: known bytes of selected files plus unselected hardlink targets; else entry count
        // (also when crafted sizes add up past Int64).
        let totalBytes = SizeSum.of(selected.filter { !$0.isDirectory }.map { $0.size ?? 0 }
            + hardlinks.targetPath.values.map { entryByPath[$0]?.size ?? 0 }) ?? 0
        let totalUnits = max(wanted.count, 1)
        var doneBytes: Int64 = 0
        var doneUnits = 0
        var lastReported = -1.0
        var lastPath: String?
        // 1.0 is sent exactly once, at the real end; earlier reports stay below it.
        func report(_ path: String?, final: Bool = false) {
            guard let progress else { return }
            if let path { lastPath = path }
            if final { progress(1, lastPath); return }
            var f = totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : Double(doneUnits) / Double(totalUnits)
            f = min(max(f, 0), 0.99)
            guard f - lastReported >= 0.01 else { return }
            lastReported = f
            progress(f, path)
        }

        let root = try Self.prepareDestination(directory)
        func absolute(_ p: String) -> String { root + "/" + p }

        // Nothing that exists before the call is ever replaced: refuse before the first write.
        let conflicts = Self.conflicts(of: selected, under: root)
        if !conflicts.isEmpty { throw ExtractionConflictError(paths: conflicts) }

        // Re-checked at every write, against items that appear during the run. Only the exact object
        // this extraction created (device + inode, recorded once it is in place) may be written again, so
        // two entries landing on one name keep the archive's later-wins order; a path that resolves
        // through a symlink to anything else is a conflict, never unlinked. An item that appears after
        // this check is caught when the entry is moved into place (see `moveIntoPlace`).
        var createdFiles = Set<FileID>()
        func claim(_ p: String, isDirectory: Bool) throws {
            var st = stat()
            guard lstat(absolute(p), &st) == 0 else { return }
            let existingIsDirectory = (st.st_mode & S_IFMT) == S_IFDIR
            if existingIsDirectory && isDirectory { return }   // A folder is merged.
            guard !existingIsDirectory, createdFiles.contains(FileID(dev: st.st_dev, ino: st.st_ino)) else {
                throw ExtractionConflictError(paths: [p])
            }
            guard unlink(absolute(p)) == 0 else {
                throw ArchiveError.io("Could not replace \(p): \(String(cString: strerror(errno)))")
            }
        }
        func recordCreated(_ p: String) {
            var st = stat()
            if lstat(absolute(p), &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR {
                createdFiles.insert(FileID(dev: st.st_dev, ino: st.st_ino))
            }
        }
        // The topmost item this call did not create that stands in the way of `p`: a non-folder at one
        // of its parent folders, or at `p` itself (a folder too, when `p` is a non-folder). The same form
        // as the pre-check. Used when a write fails, to tell an item that appeared from other failures.
        func foreignItem(inTheWayOf p: String, isDirectory: Bool) -> String? {
            let parts = EntryPath.split(p)   // On scalars: a "/" can hide in a Character.
            var prefix = ""
            for (k, part) in parts.enumerated() {
                prefix += (prefix.isEmpty ? "" : "/") + part
                var st = stat()
                guard lstat(absolute(prefix), &st) == 0 else { return nil }
                if (st.st_mode & S_IFMT) == S_IFDIR, k < parts.count - 1 || isDirectory { continue }
                return createdFiles.contains(FileID(dev: st.st_dev, ino: st.st_ino)) ? nil : prefix
            }
            return nil
        }

        try withUTF8CType {
            guard let writer = Self.makeDiskWriter() else { throw ArchiveError.io("Could not allocate archive writer") }
            var main: OpaquePointer? = writer
            defer { if let m = main { archive_write_free(m) } }

            // Directories without a header go through write_disk too, so SECURE_SYMLINKS applies.
            // An existing directory is left alone: PERM would chmod it to 0755.
            for dir in synthesizedDirs {
                var st = stat()
                let exists = lstat(absolute(dir), &st) == 0
                try claim(dir, isDirectory: true)
                if exists { continue }
                guard let e = archive_entry_new() else { throw ArchiveError.io("Out of memory") }
                defer { archive_entry_free(e) }
                archive_entry_set_pathname_utf8(e, absolute(dir))
                archive_entry_set_filetype(e, UInt32(S_IFDIR))
                archive_entry_set_perm(e, 0o755)
                Self.setOptions(main, isDirectory: true)
                try Self.check(Self.writeHeader(main, e), main)
                try Self.check(archive_write_finish_entry(main), main)
            }

            var remaining = Set(wanted.keys).union(hardlinks.targetPath.keys)
            var ordinal = 0
            while !remaining.isEmpty {
                if Task.isCancelled { throw ArchiveError.cancelled }
                guard let entry = try session.nextHeader() else { break }
                defer { ordinal += 1 }
                guard remaining.remove(ordinal) != nil else { continue }

                // Where this header's content lands: its own path, plus any links that borrow its data.
                var destinations: [String] = []
                let ownPath = hardlinks.skippedLinks.contains(ordinal) ? nil : wanted[ordinal]
                if let ownPath { destinations.append(ownPath) }
                destinations += hardlinks.linkDestinations[ordinal] ?? []
                destinations += hardlinks.extraDestinations[ordinal] ?? []
                guard let currentPath = destinations.first else { continue }

                let isRegular = (archive_entry_filetype(entry) & mode_t(S_IFMT)) == mode_t(S_IFREG)
                let isDirectory = (archive_entry_filetype(entry) & mode_t(S_IFMT)) == mode_t(S_IFDIR)
                // A hardlink selected alone gets a regular file's bytes, never a copy of a FIFO or device.
                if !isRegular, hardlinks.linkDestinations[ordinal] != nil {
                    throw ArchiveError.corrupted("Hardlink to \(hardlinks.targetPath[ordinal] ?? currentPath) does not lead to a regular file")
                }
                let dataEncrypted = archive_entry_is_data_encrypted(entry) != 0
                // RAR and strong-encrypted zip cannot be decrypted; libarchive would report garbage
                // or a misleading error instead of saying so. Refuse before any read, with or without a password.
                if isRegular, dataEncrypted,
                   let unsupported = undecryptableError(format: format, zipStrongEncryption: zipStrongEncryption) {
                    throw unsupported
                }
                let encrypted = dataEncrypted || archive_entry_is_encrypted(entry) != 0

                // Retarget the entry under the destination. A hardlink whose target is also selected stays
                // a hardlink, with its target path rewritten the same way.
                // A link that carries its own data (cpio puts it on the last link) is written as a regular file.
                let carriesData = archive_entry_size_is_set(entry) != 0 && archive_entry_size(entry) > 0
                let linkName = (ownPath == nil || carriesData) ? nil
                    : EntryNameDecoder.normalizedHardlinkTarget(of: entry, in: session, using: nameDecoding)
                // A symlink target stored in a legacy code page is written as the listing decoded it.
                if archive_entry_filetype(entry) & mode_t(S_IFMT) == mode_t(S_IFLNK),
                   let target = EntryNameDecoder.legacySymlinkTarget(of: entry, in: session, using: nameDecoding) {
                    archive_entry_set_symlink_utf8(entry, target)
                }
                var extras: [OpaquePointer] = []
                defer { for w in extras { archive_write_free(w) } }
                var writers: [OpaquePointer] = []
                // Non-folders are written under a private name next to their destination (`staging`) and
                // moved into place once complete. libarchive's NO_OVERWRITE cannot guard the destination
                // itself: on an item that appeared after `claim` it skips the entry yet reports success,
                // then applies the entry's mode and date to that item, and fails the first data write (the
                // partial-entry cleanup would then remove the item).
                var written: [(dest: String, staging: String?)] = []
                var moved = 0   // written[..<moved] are in place
                func cleanupPartial() {
                    for w in extras { archive_write_free(w) }
                    extras = []
                    if let m = main { archive_write_free(m) }
                    main = nil
                    for (k, item) in written.enumerated() {
                        if k >= moved, let staging = item.staging { unlink(staging) }   // Always this call's own.
                        else if isRegular { try? FileManager.default.removeItem(atPath: absolute(item.dest)) }
                    }
                }
                func failure(_ error: Error, at dest: String) -> Error {
                    guard error is ArchiveError,
                          let p = foreignItem(inTheWayOf: dest, isDirectory: isDirectory) else { return error }
                    return ExtractionConflictError(paths: [p])
                }
                for (i, dest) in destinations.enumerated() {
                    let w: OpaquePointer
                    if i == 0 {
                        w = main!
                    } else {
                        guard let x = Self.makeDiskWriter() else {
                            cleanupPartial()
                            throw ArchiveError.io("Could not allocate archive writer")
                        }
                        extras.append(x)
                        w = x
                    }
                    let staging = isDirectory ? nil : Self.stagingPath(for: absolute(dest))
                    archive_entry_set_pathname_utf8(entry, staging ?? absolute(dest))
                    if i == 0, let linkName {
                        archive_entry_set_hardlink_utf8(entry, absolute(linkName))
                    } else {
                        archive_entry_set_hardlink(entry, nil)
                    }
                    Self.setOptions(w, isDirectory: isDirectory)
                    do {
                        try claim(dest, isDirectory: isDirectory)
                        afterClaim?(dest)
                        try Self.check(Self.writeHeader(w, entry), w)
                    } catch {
                        // A failed header created nothing: written holds only this header's earlier destinations.
                        let e = failure(error, at: dest)
                        cleanupPartial()
                        throw e
                    }
                    written.append((dest, staging))
                    writers.append(w)
                }

                // Only a regular file that is not written as a hardlink has data to stream. Symlinks,
                // directories, devices and data-less hardlinks are complete after write_header; asking
                // libarchive for their data fails in some readers (RAR5 directory symlinks), and
                // nextHeader skips whatever is left.
                let readsData = isRegular && linkName == nil
                while readsData {
                    if Task.isCancelled {
                        cleanupPartial()
                        throw ArchiveError.cancelled
                    }
                    let block: (buffer: UnsafeRawBufferPointer, offset: Int64)?
                    do throws(ArchiveError) {
                        block = try session.readBlock()
                    } catch {
                        cleanupPartial()
                        throw readFailure(error, format: format, encrypted: encrypted,
                                          hasPassphrase: session.hasPassphrase, zipStrongEncryption: zipStrongEncryption)
                    }
                    guard let block else { break }
                    for w in writers {
                        if archive_write_data_block(w, block.buffer.baseAddress, block.buffer.count, block.offset) < 0 {
                            let err = Self.writeError(w)
                            cleanupPartial()
                            throw err
                        }
                    }
                    doneBytes += Int64(block.buffer.count)
                    report(currentPath)
                }
                for w in writers {
                    do { try Self.check(archive_write_finish_entry(w), w) } catch { cleanupPartial(); throw error }
                }
                for item in written {
                    if let staging = item.staging {
                        let e = Self.moveIntoPlace(staging, absolute(item.dest))
                        if e != 0 {
                            let conflict = foreignItem(inTheWayOf: item.dest, isDirectory: false)
                                ?? (e == EEXIST ? item.dest : nil)
                            cleanupPartial()
                            if let conflict { throw ExtractionConflictError(paths: [conflict]) }
                            throw ArchiveError.io("Could not move \(item.dest) into place: \(String(cString: strerror(e)))")
                        }
                        recordCreated(item.dest)
                    }
                    moved += 1
                }
                doneUnits += destinations.count
                report(currentPath)
            }

            // Closing applies the deferred directory times and permissions.
            let m = main!
            let closeResult = archive_write_close(m)
            let closeError = closeResult < ARCHIVE_WARN ? Self.writeError(m) : nil
            archive_write_free(m)
            main = nil
            if let closeError { throw closeError }
        }
        report(nil, final: true)
    }

    // MARK: - Hardlinks

    /// Hardlinks among the wanted headers whose target is not itself selected. Every format but cpio
    /// keeps the data on the target (tar stores the link with size 0), so the data holder's bytes are
    /// written at the link's path while the holder streams past; a chain h -> g -> f is followed to f.
    /// A link that carries its own data (pax may) also supplies a selected empty target. cpio groups
    /// are planned by `cpioHardlinkPlan`.
    private struct HardlinkPlan {
        var skippedLinks: Set<Int> = []
        var linkDestinations: [Int: [String]] = [:]   // data-holder ordinal -> link paths to write
        var targetPath: [Int: String] = [:]           // data-holder ordinal -> its entry path (cpio: unwanted holders only)
        var extraDestinations: [Int: [String]] = [:]  // link ordinal -> selected empty targets that need its data
    }

    private func hardlinkPlan(wanted: [Int: String], selection: Set<String>?,
                              entryByPath: [String: ArchiveEntry]) throws -> HardlinkPlan {
        var plan = HardlinkPlan()
        // Only a wanted hardlink whose target may be unselected needs a plan (an in-memory check, so
        // Quick Look of a plain file skips the second pass).
        guard hasHardlinks, selection != nil, let last = wanted.keys.max(),
              wanted.values.contains(where: { hardlinkTargetByPath[$0] != nil }) else { return plan }
        let session = try makeSession()
        var ordinal = 0
        while ordinal <= last, let entry = try session.nextHeader() {
            defer { ordinal += 1 }
            // hardlinkTargetByPath holds the winning header's normalized target, recorded by open.
            guard let path = wanted[ordinal], hardlinkTargetByPath[path] != nil else { continue }
            guard let target = EntryNameDecoder.normalizedHardlinkTarget(of: entry, in: session, using: nameDecoding),
                  headerOrdinalByPath[target] != nil else {
                throw ArchiveError.corrupted("Hardlink target missing from archive: \(path)")
            }
            let carriesData = archive_entry_size_is_set(entry) != 0 && archive_entry_size(entry) > 0
            let targetSelected = selection.map { EntryPath.isSelected(target, by: $0) } ?? true
            if carriesData {
                if targetSelected, (entryByPath[target]?.size ?? 0) == 0 {
                    plan.extraDestinations[ordinal, default: []].append(target)
                }
                continue
            }
            if targetSelected { continue }
            let holder = try dataHolder(ofLink: path, target: target)
            // The bytes written at the link's path must come from a regular file, never a copy of a
            // symlink or directory entry. Other non-regular holders are caught when their header streams.
            guard let holderOrdinal = headerOrdinalByPath[holder],
                  symlinkTargetByPath[holder] == nil,
                  entryByPath[holder]?.isDirectory == false else {
                throw ArchiveError.corrupted("Hardlink \(path) does not lead to a regular file")
            }
            plan.skippedLinks.insert(ordinal)
            plan.linkDestinations[holderOrdinal, default: []].append(path)
            plan.targetPath[holderOrdinal] = holder
        }
        return plan
    }

    /// cpio hardlink groups, planned from the maps recorded at open (no second pass). libarchive names
    /// a group's first header as every later member's target, so a group is a root (a plain entry that
    /// hardlinks name) plus the hardlinks to it. newc stores the bytes on one member only (the last)
    /// and the others have size 0; odc stores them on every member. Each selected empty member is
    /// written as a regular file from the data holder's header (the member with size > 0) and skips its
    /// own header, so every subset of a group gets the bytes; the main pass reads on to the holder.
    private func cpioHardlinkPlan(wanted: [Int: String], entryByPath: [String: ArchiveEntry]) throws -> HardlinkPlan {
        var plan = HardlinkPlan()
        guard hasHardlinks else { return plan }
        func isEmpty(_ path: String) -> Bool { (entryByPath[path]?.size ?? 0) == 0 }

        // Wanted members by group root. Paths are the normalized map keys, compared as such.
        let roots = Set(hardlinkTargetByPath.values)
        var wantedByRoot: [String: [Int]] = [:]
        for (ordinal, path) in wanted {
            if let root = hardlinkTargetByPath[path] { wantedByRoot[root, default: []].append(ordinal) }
            else if roots.contains(path) { wantedByRoot[path, default: []].append(ordinal) }
        }
        guard !wantedByRoot.isEmpty else { return plan }

        // The data holder of each such group: its last member with size > 0.
        var holderByRoot: [String: (ordinal: Int, path: String)] = [:]
        func consider(_ path: String, of root: String) {
            guard !isEmpty(path), let o = headerOrdinalByPath[path], o > holderByRoot[root]?.ordinal ?? -1 else { return }
            holderByRoot[root] = (o, path)
        }
        for (link, root) in hardlinkTargetByPath where wantedByRoot[root] != nil { consider(link, of: root) }
        for root in wantedByRoot.keys where hardlinkTargetByPath[root] == nil { consider(root, of: root) }

        for (root, members) in wantedByRoot {
            let emptyLinks = members.filter { hardlinkTargetByPath[wanted[$0]!] != nil && isEmpty(wanted[$0]!) }.sorted()
            func notRegular() -> ArchiveError {
                .corrupted("Hardlink \(wanted[emptyLinks.first ?? members[0]]!) does not lead to a regular file")
            }
            guard let rootOrdinal = headerOrdinalByPath[root] else {
                throw ArchiveError.corrupted("Hardlink target missing from archive: \(wanted[members[0]]!)")
            }
            let rootWanted = wanted[rootOrdinal] != nil
            // A link to a symlink or directory is no data group: with the root selected it stays a
            // hardlink, otherwise it is refused.
            if symlinkTargetByPath[root] != nil || entryByPath[root]?.isDirectory != false {
                if !rootWanted, !emptyLinks.isEmpty { throw notRegular() }
                continue
            }
            let holder: (ordinal: Int, path: String)
            let needy: [Int]
            if let h = holderByRoot[root] {
                guard symlinkTargetByPath[h.path] == nil, entryByPath[h.path]?.isDirectory == false else {
                    throw notRegular()
                }
                holder = h
                needy = members.filter { $0 != h.ordinal && isEmpty(wanted[$0]!) }.sorted()
            } else {
                // No member has data: the members are empty files. Links to a selected root stay
                // hardlinks; otherwise the root's empty header supplies them (and refuses a FIFO or device).
                if rootWanted { continue }
                holder = (rootOrdinal, root)
                needy = emptyLinks
            }
            guard !needy.isEmpty else { continue }
            for o in needy {
                plan.skippedLinks.insert(o)
                plan.linkDestinations[holder.ordinal, default: []].append(wanted[o]!)
            }
            if wanted[holder.ordinal] == nil { plan.targetPath[holder.ordinal] = holder.path }
        }
        return plan
    }

    /// Follows a hardlink chain from the link itself (h -> g -> f) to the entry that is not a
    /// hardlink. At most 8 hops in total, the same bound as the temporary-file resolver.
    private func dataHolder(ofLink link: String, target: String) throws -> String {
        var current = target
        for _ in 1..<8 {
            guard let next = hardlinkTargetByPath[current] else { return current }
            guard headerOrdinalByPath[next] != nil else {
                throw ArchiveError.corrupted("Hardlink target missing from archive: \(link)")
            }
            current = next
        }
        if hardlinkTargetByPath[current] == nil { return current }
        throw ArchiveError.corrupted("Hardlink chain longer than 8 hops: \(link)")
    }

    // MARK: - write_disk helpers

    private static func makeDiskWriter() -> OpaquePointer? {
        guard let w = archive_write_disk_new() else { return nil }
        setOptions(w, isDirectory: false)
        return w
    }

    /// The only call that hands an entry to write_disk. Only the nine permission bits are ever applied:
    /// setuid, setgid and sticky are cleared here, for every kind of item, so the mode libarchive records
    /// for the deferred folder fix-up at close is clean too. With EXTRACT_PERM libarchive itself would keep
    /// setuid/setgid whenever the entry's owner and group match the created item, and always keep sticky.
    private static func writeHeader(_ w: OpaquePointer?, _ entry: OpaquePointer?) -> Int32 {
        archive_entry_set_perm(entry, archive_entry_perm(entry) & 0o777)
        return archive_write_header(w, entry)
    }

    /// Set before each header. NO_OVERWRITE makes libarchive create non-folders (at their fresh staging
    /// name) with O_EXCL and never unlink; it is not set for folders: on an existing folder it would also
    /// skip the archive's folder date and permissions when the folder's header comes after its files
    /// (tar -n, or any writer that lists folders last).
    private static func setOptions(_ w: OpaquePointer?, isDirectory: Bool) {
        var flags = ARCHIVE_EXTRACT_TIME | ARCHIVE_EXTRACT_PERM
            | ARCHIVE_EXTRACT_SECURE_SYMLINKS | ARCHIVE_EXTRACT_SECURE_NODOTDOT
        if !isDirectory { flags |= ARCHIVE_EXTRACT_NO_OVERWRITE }
        archive_write_disk_set_options(w, Int32(flags))
    }

    /// Selected entries, and the parent folders a partial selection implies, whose destination under
    /// `root` already holds something: any non-folder, or a folder where the archive has a file. A
    /// folder on a folder is merged. Only the topmost conflict of a subtree is listed. Sorted.
    static func conflicts(of selected: [ArchiveEntry], under root: String) -> [String] {
        // On scalars: the implied parent `d` of `d/\u{301}x` ("/" + a combining mark is one Character) is checked too.
        func parent(_ p: String) -> String { EntryPath.parent(of: p) ?? "" }
        var isDirectoryByPath: [String: Bool] = [:]
        for e in selected { isDirectoryByPath[e.path] = e.isDirectory }
        for e in selected {
            var p = parent(e.path)
            while !p.isEmpty, isDirectoryByPath[p] == nil {
                isDirectoryByPath[p] = true
                p = parent(p)
            }
        }
        var result: [String] = []
        var conflicting = Set<String>()
        // Parents sort before their children by depth, so a child under a conflict is skipped.
        let ordered = isDirectoryByPath.keys.map { (depth: $0.utf8.count(where: { $0 == UInt8(ascii: "/") }), path: $0) }
            .sorted { $0.depth != $1.depth ? $0.depth < $1.depth : $0.path < $1.path }
        for (_, path) in ordered {
            var ancestor = parent(path)
            while !ancestor.isEmpty, !conflicting.contains(ancestor) { ancestor = parent(ancestor) }
            if !ancestor.isEmpty { continue }
            var st = stat()
            guard lstat(root + "/" + path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFDIR, isDirectoryByPath[path] == true { continue }
            conflicting.insert(path)
            result.append(path)
        }
        return result.sorted()
    }

    /// A fresh name in the destination's folder, short enough for any destination name. The folder is found on
    /// scalars: with a Character split, `…/link/\u{301}x` staged in the folder above `link`, past libarchive's
    /// symlink check, and the final rename then followed `link` out of the destination.
    static func stagingPath(for destination: String) -> String {
        let folder = EntryPath.parent(of: destination) ?? "."
        return folder + "/.kernir-" + String(UInt64.random(in: .min ... .max), radix: 16)
    }

    /// Renames a staged item to its destination without ever replacing what is there: RENAME_EXCL fails
    /// with EEXIST instead, atomically. A volume without it (some non-APFS ones) gets a check right
    /// before a plain rename, which leaves only that instant open. Returns 0 or the errno.
    private static func moveIntoPlace(_ staging: String, _ destination: String) -> Int32 {
        if renamex_np(staging, destination, UInt32(RENAME_EXCL)) == 0 { return 0 }
        let e = errno
        guard lacksExclusiveRename(e) else { return e }
        var st = stat()
        if lstat(destination, &st) == 0 { return EEXIST }
        return rename(staging, destination) == 0 ? 0 : errno
    }

    /// renamex_np's error when the volume has no RENAME_EXCL: ENOTSUP (45) or EOPNOTSUPP (102), separate
    /// numbers on Darwin that a volume may give either of, or EINVAL. Internal for tests.
    static func lacksExclusiveRename(_ e: Int32) -> Bool {
        e == ENOTSUP || e == EOPNOTSUPP || e == EINVAL
    }

    private static func writeError(_ w: OpaquePointer?) -> ArchiveError {
        .io(w.flatMap { archive_error_string($0) }.map { String(cString: $0) } ?? "Could not write extracted file")
    }

    /// ARCHIVE_WARN (e.g. a metadata attribute that could not be applied) is tolerated.
    private static func check(_ r: Int32, _ w: OpaquePointer?) throws {
        if r < ARCHIVE_WARN { throw writeError(w) }
    }

    /// Creates the destination if needed and resolves it with realpath(3), which keeps `/private` on
    /// macOS (unlike URL.resolvingSymlinksInPath). SECURE_SYMLINKS refuses absolute paths that pass
    /// through any symlink, and the temp dirs are symlinks. Never chdirs: that is process-global.
    private static func prepareDestination(_ directory: URL) throws -> String {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.io("Could not create \(directory.lastPathComponent): \(error.localizedDescription)")
        }
        guard let resolved = realpath(directory.path, nil) else {
            throw ArchiveError.io("Could not resolve \(directory.path)")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
