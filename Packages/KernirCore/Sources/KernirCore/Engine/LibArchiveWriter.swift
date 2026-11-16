import Foundation
import CLibArchive

enum LibArchiveWriter {
    /// A new archive (`source` nil) or a repack of Kernir's own reader; other `ArchiveReading` types
    /// cannot be repacked.
    static func write(source: (any ArchiveReading)?, changes: ArchiveChangeSet, format: ArchiveFormat,
                      to destination: URL, options: ResolvedWriteOptions, progress: ArchiveProgressHandler?) async throws {
        var reader: LibArchiveReader?
        if let source {
            guard let r = source as? LibArchiveReader else { throw ArchiveError.notImplemented }
            reader = r
        }
        try writeArchive(source: reader, changes: changes, format: format, to: destination,
                         options: options, progress: progress)
    }

    /// Throws `.readOnlyFormat(source.format)` when `destination` is one of a multi-volume source's parts:
    /// a set is read-only, and writing over a part would destroy the archive being read. An existing
    /// destination is compared by file identity (device + inode, through symlinks and hard links, in any
    /// spelling); any destination also by its standardized, symlink-resolved path, which covers a part
    /// that is gone. A single-file source is not checked: saving it in place is a normal save.
    static func refuseVolumePart(_ destination: URL, of source: (any ArchiveReading)?) throws(ArchiveError) {
        guard let source, source.volumeURLs.count > 1 else { return }
        let id = FileID(followingLinksAt: destination.path)
        let path = canonicalPath(destination)
        for part in source.volumeURLs {
            if let id, id == FileID(followingLinksAt: part.path) { throw .readOnlyFormat(source.format) }
            if canonicalPath(part) == path { throw .readOnlyFormat(source.format) }
        }
    }

    /// `url` standardized (`.` and `..` removed), then symlink-resolved: the whole path when it exists,
    /// else its folder plus the last component, else the standardized path as it is.
    static func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        func resolved(_ path: String) -> String? {
            guard let buffer = realpath(path, nil) else { return nil }
            defer { free(buffer) }
            return String(cString: buffer)
        }
        if let path = resolved(standardized.path) { return path }
        if let folder = resolved(standardized.deletingLastPathComponent().path) {
            return URL(fileURLWithPath: folder).appendingPathComponent(standardized.lastPathComponent).path
        }
        return standardized.path
    }

    private static let chunkSize = 1 << 20

    /// Synchronous core with no suspension points, so `Task.isCancelled` reads the calling task's state.
    /// The archive is built in the destination volume's item-replacement directory and moved into place only
    /// when complete; on any failure or cancellation that directory is removed and nothing remains. An in-place
    /// save reads the source until the final replace.
    private static func writeArchive(source: LibArchiveReader?, changes: ArchiveChangeSet, format: ArchiveFormat,
                                     to destination: URL, options: ResolvedWriteOptions,
                                     progress: ArchiveProgressHandler?) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        // replaceItemAt would delete the folder's contents.
        if exists, isDirectory.boolValue {
            throw ArchiveError.io("\(destination.lastPathComponent) is a folder")
        }
        // The refusals (a missing addition, a broken hard-link chain) come before the temporary folder exists.
        let entries = try planEntries(source: source, changes: changes, format: format,
                                      excludingMacMetadata: options.excludesMacMetadata)

        let tempDir: URL
        do {
            tempDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: exists ? destination : destination.deletingLastPathComponent(),
                                 create: true)
        } catch {
            throw ArchiveError.io("Could not create a temporary folder: \(error.localizedDescription)")
        }
        defer { try? fm.removeItem(at: tempDir) }
        let output = tempDir.appendingPathComponent(destination.lastPathComponent)

        let tracker = try writeEntries(entries, keepsArchiveComment: true,
                                       progress: progress) { () throws(ArchiveError) in
            try WriteSession(url: output, format: format, options: options)
        }

        do {
            if exists {
                _ = try fm.replaceItemAt(destination, withItemAt: output)
            } else {
                try fm.moveItem(at: output, to: destination)
            }
        } catch {
            throw ArchiveError.io("Could not save \(destination.lastPathComponent): \(error.localizedDescription)")
        }
        tracker.finish()
    }

    /// What an archive's entries will be, worked out before any output exists, so its refusals (a missing
    /// addition, a broken hard-link chain in the source) are thrown first.
    struct EntryPlan {
        let items: [AdditionItem]
        let copier: RepackCopier?
        let parents: [String]
        /// The output's archive comment (`changes.comment`): the source's bytes for `.keep` (zip -> zip), the UTF-8
        /// text for `.set`, nil for none.
        let archiveComment: [UInt8]?
    }

    /// `excludingMacMetadata` (`ResolvedWriteOptions.excludesMacMetadata`; no default, so neither the single-file
    /// save nor the split writer can forget it) leaves Mac metadata out of both the additions and the kept entries.
    static func planEntries(source: LibArchiveReader?, changes: ArchiveChangeSet, format: ArchiveFormat,
                            excludingMacMetadata: Bool) throws -> EntryPlan {
        let setComment = try commentBytes(changes.comment, format: format)
        let items = try AdditionWalker.items(for: changes.additions, excludingMacMetadata: excludingMacMetadata)
        let copier = try RepackCopier.make(source: source, changes: changes, additions: items, format: format,
                                           excludingMacMetadata: excludingMacMetadata)
        let parents = AdditionWalker.missingParents(of: items, explicitPaths: copier?.keptPaths ?? [])
        return EntryPlan(items: items, copier: copier, parents: parents,
                         archiveComment: changes.comment == .keep ? copier?.zipArchiveComment : setComment)
    }

    /// The bytes `.set(text)` writes: the text as UTF-8, checked before anything is written. Nil for `.keep`,
    /// `.remove` and empty text (no comment). Throws `.io` for a format without `supportsComments`, text longer
    /// than `ArchiveComment.maximumWritableLength` UTF-8 bytes, or text holding a ZIP end-record signature
    /// (`zipEndSignatures`).
    static func commentBytes(_ change: ArchiveChangeSet.CommentChange,
                             format: ArchiveFormat) throws(ArchiveError) -> [UInt8]? {
        guard case .set(let text) = change, !text.isEmpty else { return nil }
        guard format.supportsComments else { throw .io("\(format.displayName) archives cannot have a comment") }
        let bytes = Array(text.utf8)
        guard bytes.count <= ArchiveComment.maximumWritableLength else {
            throw .io("The comment is too long: \(bytes.count) bytes, at most \(ArchiveComment.maximumWritableLength)")
        }
        guard !bytes.indices.contains(where: { i in zipEndSignatures.contains { bytes[i...].starts(with: $0) } }) else {
            throw .io("The comment contains bytes a ZIP archive cannot hold")
        }
        return bytes
    }

    /// The comment is the file's last field, and readers find the end of central directory by scanning back from
    /// EOF for its signature: "PK\u{5}\u{6}" and 18 more bytes in a comment would be taken for the archive's end
    /// record (every reader then lists the archive as empty), and the signature alone in its last 21 bytes makes
    /// Python's zipfile reject the file. The Zip64 end record and locator signatures matter only next to such a
    /// fake end record; they are refused too, as no comment text needs them.
    static let zipEndSignatures: [[UInt8]] = [
        [0x50, 0x4B, 0x05, 0x06], [0x50, 0x4B, 0x06, 0x06], [0x50, 0x4B, 0x06, 0x07],
    ]

    /// The planned entries, written into the session `open` makes, which is then finished: the kept source
    /// entries (the copy step), then the additions' missing parents and the additions. `keepsArchiveComment`: the
    /// output gets the plan's `archiveComment` (a split set gets none). The session is freed before
    /// this returns or throws. Returns the progress, for the caller to finish once the output is in place.
    /// Shared by the single-file save and the split writer (`VolumeWriter`).
    static func writeEntries(_ plan: EntryPlan, keepsArchiveComment: Bool, progress: ArchiveProgressHandler?,
                             open: () throws(ArchiveError) -> WriteSession) throws -> ProgressTracker {
        let (items, copier, parents) = (plan.items, plan.copier, plan.parents)
        // Unknown (crafted sizes past Int64) counts entries instead, as no bytes do.
        let copied: Int64? = if let copier { copier.totalBytes } else { 0 }
        let totalBytes = copied.flatMap { SizeSum.of([$0] + items.map(\.size)) } ?? 0
        var tracker = ProgressTracker(totalBytes: totalBytes,
                                      totalUnits: (copier?.count ?? 0) + parents.count + items.count,
                                      handler: progress)
        let session = try open()
        if keepsArchiveComment, let comment = plan.archiveComment { try session.setZipArchiveComment(comment) }
        try copier?.copy(into: session, tracker: &tracker)
        let now = Date()
        for path in parents {
            if Task.isCancelled { throw ArchiveError.cancelled }
            try writeEntry(session, path: path, kind: .directory, size: 0, modificationDate: now, permissions: 0o755)
            tracker.finishUnit(path)
        }
        for item in items {
            if Task.isCancelled { throw ArchiveError.cancelled }
            try writeEntry(session, path: item.archivePath, kind: item.kind, size: item.size,
                           modificationDate: item.modificationDate, permissions: item.permissions)
            if case .file = item.kind {
                try copyData(of: item, into: session, tracker: &tracker)
            }
            tracker.finishUnit(item.archivePath)
        }
        try session.finish()
        return tracker
    }

    private static func writeEntry(_ session: WriteSession, path: String, kind: AdditionItem.Kind, size: Int64,
                                   modificationDate: Date, permissions: UInt16) throws {
        guard let entry = archive_entry_new() else { throw ArchiveError.io("Out of memory") }
        defer { archive_entry_free(entry) }
        let converted: Bool = withUTF8CType {
            guard archive_entry_update_pathname_utf8(entry, path) != 0 else { return false }
            if case .symlink(let target) = kind {
                return archive_entry_update_symlink_utf8(entry, target) != 0
            }
            return true
        }
        guard converted else { throw ArchiveError.io("Cannot store the name \(path)") }
        switch kind {
        case .file:
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_size(entry, size)
        case .directory:
            archive_entry_set_filetype(entry, UInt32(S_IFDIR))
            archive_entry_set_size(entry, 0)
        case .symlink:
            archive_entry_set_filetype(entry, UInt32(S_IFLNK))
            archive_entry_set_size(entry, 0)
        }
        archive_entry_set_perm(entry, mode_t(permissions))
        let time = modificationDate.timeIntervalSince1970
        let seconds = time.rounded(.down)
        archive_entry_set_mtime(entry, time_t(seconds), Int((time - seconds) * 1e9))
        try session.writeHeader(entry)
    }

    /// Streams exactly `item.size` bytes in 1 MiB chunks. A file that shrank since the walk is an error,
    /// never zero padding; bytes it gained are not read.
    private static func copyData(of item: AdditionItem, into session: WriteSession,
                                 tracker: inout ProgressTracker) throws {
        let name = item.sourceURL.lastPathComponent
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: item.sourceURL)
        } catch {
            throw ArchiveError.io("Could not read \(name): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var remaining = item.size
        while remaining > 0 {
            if Task.isCancelled { throw ArchiveError.cancelled }
            // The pool frees each chunk now, not when the thread's outer pool next drains.
            let count: Int = try autoreleasepool {
                let data: Data?
                do {
                    data = try handle.read(upToCount: Int(min(Int64(chunkSize), remaining)))
                } catch {
                    throw ArchiveError.io("Could not read \(name): \(error.localizedDescription)")
                }
                guard let data, !data.isEmpty else {
                    throw ArchiveError.io("\(name) changed while it was being added")
                }
                try data.withUnsafeBytes { try session.writeData($0) }
                return data.count
            }
            remaining -= Int64(count)
            tracker.addBytes(Int64(count), path: item.archivePath)
        }
    }
}

/// Byte-based progress (entry count only when there are no bytes). Reports below 1.0 move by at
/// least 0.01; 1.0 is sent exactly once, after the archive is in place.
struct ProgressTracker {
    let totalBytes: Int64
    let totalUnits: Int
    let handler: ArchiveProgressHandler?
    private var doneBytes: Int64 = 0
    private var doneUnits = 0
    private var lastReported = -1.0
    private var lastPath: String?

    init(totalBytes: Int64, totalUnits: Int, handler: ArchiveProgressHandler?) {
        self.totalBytes = totalBytes
        self.totalUnits = max(totalUnits, 1)
        self.handler = handler
    }

    mutating func addBytes(_ n: Int64, path: String) {
        doneBytes += n
        report(path)
    }

    mutating func finishUnit(_ path: String) {
        doneUnits += 1
        report(path)
    }

    func finish() { handler?(1, lastPath) }

    private mutating func report(_ path: String) {
        guard let handler else { return }
        lastPath = path
        let raw = totalBytes > 0 ? Double(doneBytes) / Double(totalBytes) : Double(doneUnits) / Double(totalUnits)
        let f = min(max(raw, 0), 0.99)
        guard f - lastReported >= 0.01 else { return }
        lastReported = f
        handler(f, path)
    }
}
