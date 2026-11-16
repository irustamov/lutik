import Foundation
import CLibArchive

/// Size and modification time of the archive file, used to detect changes after open.
struct FileStamp: Sendable, Equatable {
    let size: Int64
    let modificationDate: Date
    let inode: UInt64
    let device: UInt64

    init(url: URL) throws(ArchiveError) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            self.size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            self.modificationDate = (attrs[.modificationDate] as? Date) ?? .distantPast
            self.inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            self.device = (attrs[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        } catch {
            throw .io("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

struct LibArchiveReader: ArchiveReading {
    let url: URL
    let format: ArchiveFormat
    let entries: [ArchiveEntry]
    let isEncrypted: Bool
    /// Exact encryption method; for zip from the central directory, AES-256 for encrypted 7z/RAR.
    let encryption: ArchiveEncryption
    /// Zip method: deflate if any non-empty file is deflated, else store if any is stored, else nil;
    /// with no non-empty file, the first non-directory entry's method. Nil for other formats.
    let compressionMethod: ArchiveCompressionMethod?
    /// True when an encrypted zip entry uses PKWARE strong encryption (central-directory flag bit 6),
    /// which libarchive cannot decrypt: its data reads as `.unsupportedEncryption(.zip)`.
    let zipStrongEncryption: Bool
    let password: String?
    /// 0-based header index of the winning header; absent for synthesized directories.
    let headerOrdinalByPath: [String: Int]
    /// True when any header is a hardlink; lets extraction skip its hardlink pre-scan.
    let hasHardlinks: Bool
    /// The name encoding chosen at open; every later session (extraction, repack) decodes with it.
    let nameDecoding: NameDecoding
    var nameEncoding: ArchiveNameEncoding { nameDecoding.requested }
    var legacyNameEncoding: String.Encoding? { nameDecoding.legacy }
    /// Raw (decoded, unnormalized) link targets of the winning symlink entries, by normalized path.
    let symlinkTargetByPath: [String: String]
    /// Normalized hardlink targets of the winning hardlink headers, by normalized path.
    let hardlinkTargetByPath: [String: String]
    /// Paths whose winning header has no stored bytes a save may keep: a declared or empty name
    /// (`EntryNameDecoder.storableRawName`), or a name that does not decode to exactly the path (or path + "/" for
    /// a folder), such as a "./", "//", ".." or leading "/" spelling. A repack never writes these under their
    /// stored bytes. Every declared name is in the set, not only odd spellings.
    let inexactStoredNames: Set<String>
    /// The archive comment, read once at open (`ArchiveCommentDecoder.comment`) and decoded with `nameDecoding`.
    let comment: ArchiveComment?
    /// Every file read, in read order: `[url]`, or all parts of the multi-volume set `url` belongs to.
    let volumeURLs: [URL]
    /// One stamp per `volumeURLs` entry, taken before the listing read.
    let stamps: [FileStamp]
    let cache: TemporaryExtractionCache

    /// One normalized header, as `walkHeaders` hands it out once the archive's name encoding is chosen.
    struct Header {
        let path: String
        let isDirectory: Bool
        let isEncrypted: Bool
        let size: Int64?
        /// 0-based index of the header in the archive, counting skipped (unnamed or unusable) ones.
        let ordinal: Int
        let isRaw: Bool
        let modificationDate: Date?
        let permissions: UInt16?
        /// The normalized hardlink target; nil when the header is not a hardlink.
        let hardlinkTarget: String?
        /// The decoded, unnormalized symlink target; nil when the header is not a symlink.
        let symlinkTarget: String?
        /// The header's name decodes to exactly `path` (`EntryNameDecoder.readsAsPath`) and has storable raw bytes.
        let nameReadsAsPath: Bool

        func makeEntry() -> ArchiveEntry {
            ArchiveEntry(path: path, isDirectory: isDirectory, size: size, compressedSize: nil,
                         modificationDate: modificationDate, isEncrypted: isEncrypted, permissions: permissions)
        }
    }

    /// Headers per chunk of the walk's header list (`walkHeaders`).
    private static let listedChunk = 1 << 16

    /// A header's facts as the walk reads them, before its names can be decoded.
    private struct ListedHeader {
        let name: EntryNameDecoder.ListedName
        let fileType: mode_t
        let encryptedFlag: Bool
        let size: Int64?
        let ordinal: Int
        let isRaw: Bool
        let modificationDate: Date?
        let permissions: UInt16?
        let hardlink: EntryNameDecoder.ListedName?
        let symlink: EntryNameDecoder.ListedName?
        /// The name has storable raw bytes (`EntryNameDecoder.storableRawName`).
        let storable: Bool

        /// The usable entry path of the decoded name `n` (`name` resolved), whether the header is a directory, and
        /// whether `n` is exactly that path (`EntryNameDecoder.readsAsPath`); nil for a name that normalizes to nothing.
        func pathAndKind(_ n: String, format: ArchiveFormat)
            -> (path: String, isDirectory: Bool, readsAsPath: Bool)? {
            // libarchive stops converting CAB "\" separators at the first one that could be a CP932 trail
            // byte (表 = 0x95 0x5C), so finish the job on the decoded name. CAB has no links to convert.
            let rawName = format == .cab && !isRaw ? n.replacingOccurrences(of: "\\", with: "/") : n
            guard let path = EntryPath.normalize(rawName) else { return nil }
            // The byte "/", never a Character `hasSuffix`: after a Prepend scalar (`d\u{600}/`) the last Character
            // is `\u{600}/`, which is not "/".
            let isDirectory = fileType == mode_t(S_IFDIR) || rawName.utf8.last == UInt8(ascii: "/")
            return (path, isDirectory, EntryNameDecoder.readsAsPath(n, path: path, isDirectory: isDirectory))
        }
    }

    /// Reads every header, then chooses the archive's one name encoding from all of its undeclared non-ASCII
    /// names (paths and link targets; `nameEncoding` when the caller chose one), then calls `visit` for each
    /// usable header, in archive order. Shared by `open` and `previewListing`, so both see the same entries,
    /// the same cancellation points and the same errors. As each header is read, before anything decodes its names,
    /// the header count is held to `maxEntries`, each stored name and link target to `maxRawNameBytes` and their
    /// running total to `maxTotalNameBytes`, or `nameBytesPerEntry` for each header so far once that is more.
    /// Then every decoded name and link target is scanned for runs of combining marks, and every usable path (and
    /// hardlink target) is charged against `limits`, all before the first `visit`, so an archive that nests too
    /// deeply throws `ArchiveNestingError` before any folder is built.
    /// `afterListing` runs once every header is read, before any name is decoded or charged (a test seam).
    /// `willVisit` gets the number of `visit` calls to come, before the first (to reserve capacity).
    static func walkHeaders(session: ReadSession, url: URL, password: String?, nameEncoding: ArchiveNameEncoding,
                            limits: NestingLimits = .standard, afterListing: () -> Void = {},
                            willVisit: (Int) -> Void = { _ in },
                            visit: (Header) throws -> Void) throws
        -> (format: ArchiveFormat, anyHardlink: Bool, nameDecoding: NameDecoding) {
        var ordinal = 0
        var format: ArchiveFormat?
        var anyHardlink = false
        // The first encrypted non-empty header so far: what a failed 7z header read is arbitrated with.
        var firstEncrypted: Int?
        // In chunks, each freed once its paths are charged, so the headers and the usable paths are never both
        // held whole (they were the walk's two largest buffers).
        var listed: [[ListedHeader]] = []
        var listedCount = 0
        var undeclared: [[UInt8]] = []
        // Stored bytes of every name and link target so far (`maxTotalNameBytes`).
        var nameBytes = 0

        while true {
            if Task.isCancelled { throw ArchiveError.cancelled }
            let entry: OpaquePointer?
            do {
                entry = try session.nextHeader()
            } catch {
                throw headerFailure(error, session: session, url: url, password: password, ordinal: ordinal,
                                    firstEncrypted: firstEncrypted)
            }
            guard let entry else {
                // A valid archive with zero entries (e.g. an empty zip) still reports its format at EOF.
                if ordinal == 0 {
                    format = mapArchiveFormat(formatCode: session.formatCode, filterCodes: session.filterCodes)
                }
                break
            }
            if ordinal == 0 {
                format = mapArchiveFormat(formatCode: session.formatCode, filterCodes: session.filterCodes)
                if format == nil { throw ArchiveError.unsupportedFormat }
            }
            // Every header counts, before anything reads its names: header maxEntries + 1 is refused.
            guard ordinal < limits.maxEntries else { throw ArchiveNestingError(limit: .entryCount) }
            defer { ordinal += 1 }
            // Before any decoding or NFC: the header costs its stored names and no more.
            let stored = EntryNameDecoder.storedLengths(of: entry)
            guard max(stored.name, stored.hardlink, stored.symlink) <= limits.maxRawNameBytes else {
                throw ArchiveNestingError(limit: .pathLength)
            }
            nameBytes += stored.name + stored.hardlink + stored.symlink
            guard nameBytes <= NestingBudget.allowance(limits.maxTotalNameBytes, limits.nameBytesPerEntry, ordinal + 1,
                                                       cap: limits.maxEntries) else {
                throw ArchiveNestingError(limit: .totalPathBytes)
            }
            if archive_entry_hardlink(entry) != nil { anyHardlink = true }

            let isRaw = (session.formatCode & Int32(ARCHIVE_FORMAT_BASE_MASK)) == Int32(ARCHIVE_FORMAT_RAW)
            let name: EntryNameDecoder.ListedName
            if isRaw {
                name = .known(url.deletingPathExtension().lastPathComponent)
            } else {
                guard let n = EntryNameDecoder.listedPathname(of: entry, in: session) else { continue }
                name = n
            }
            let fileType = archive_entry_filetype(entry) & mode_t(S_IFMT)
            let hardlink = EntryNameDecoder.listedHardlinkTarget(of: entry, in: session)
            let symlink = fileType == mode_t(S_IFLNK) ? EntryNameDecoder.listedSymlinkTarget(of: entry, in: session)
                : nil
            let mtime: Date? = archive_entry_mtime_is_set(entry) != 0
                ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry))
                       + TimeInterval(archive_entry_mtime_nsec(entry)) / 1e9)
                : nil
            let perm: UInt16? = (isRaw || archive_entry_perm_is_set(entry) == 0)
                ? nil : UInt16(truncatingIfNeeded: archive_entry_perm(entry))
            let header = ListedHeader(
                name: name, fileType: fileType, encryptedFlag: archive_entry_is_encrypted(entry) != 0,
                size: archive_entry_size_is_set(entry) == 0 ? nil : archive_entry_size(entry), ordinal: ordinal,
                isRaw: isRaw, modificationDate: mtime, permissions: perm, hardlink: hardlink, symlink: symlink,
                storable: EntryNameDecoder.storableRawName(of: entry, in: session) != nil)
            for n in [name, hardlink, symlink] { if let bytes = n?.legacyBytes { undeclared.append(bytes) } }
            // Only 7z reads this, and 7z names are declared, so final here; a legacy name counts as usable.
            if firstEncrypted == nil, header.encryptedFlag, header.isRaw || header.size != 0, let format {
                let known = NameDecoding(requested: nameEncoding, legacy: nil)
                let isDir = name.legacyBytes.map { fileType == mode_t(S_IFDIR) || $0.last == 0x2F }
                    ?? header.pathAndKind(name.resolve(known), format: format)?.isDirectory
                if isDir == false { firstEncrypted = ordinal }
            }
            if listedCount % listedChunk == 0 {
                listed.append([])
                listed[listed.count - 1].reserveCapacity(listedChunk)
            }
            listed[listed.count - 1].append(header)
            listedCount += 1
        }
        guard let format else { throw ArchiveError.unsupportedFormat }

        afterListing()
        let nameDecoding = NameDecoding(requested: nameEncoding, undeclaredNames: undeclared)
        undeclared = []
        // Every path is charged before the first visit: the visitors build folder paths, which is what the limits
        // bound. Each name and link target is scanned for marks before anything normalizes or compares it.
        var budget = NestingBudget(limits)
        var usable: [Header] = []
        usable.reserveCapacity(listedCount)
        listed.reverse()
        while let chunk = listed.popLast() {
            for h in chunk {
                if Task.isCancelled { throw ArchiveError.cancelled }
                let name = h.name.resolve(nameDecoding)
                let hardlink = h.hardlink?.resolve(nameDecoding)
                let symlink = h.symlink?.resolve(nameDecoding)
                try NestingBudget.checkMarks(name)
                if let hardlink { try NestingBudget.checkMarks(hardlink) }
                if let symlink { try NestingBudget.checkMarks(symlink) }
                guard let (path, isDir, exact) = h.pathAndKind(name, format: format) else { continue }
                try budget.charge(path)
                // The target is a path the extraction resolves: held to the same length as one.
                let target = hardlink.flatMap(EntryPath.normalize)
                if let target { try budget.checkLength(target) }
                usable.append(Header(path: path, isDirectory: isDir, isEncrypted: !isDir && h.encryptedFlag,
                                     size: isDir || h.isRaw ? nil : h.size, ordinal: h.ordinal, isRaw: h.isRaw,
                                     modificationDate: h.modificationDate, permissions: h.permissions,
                                     hardlinkTarget: target, symlinkTarget: symlink,
                                     nameReadsAsPath: exact && h.storable))
            }
        }
        willVisit(usable.count)
        for h in usable {
            if Task.isCancelled { throw ArchiveError.cancelled }
            try visit(h)
        }
        return (format, anyHardlink, nameDecoding)
    }

    /// The checks that follow every walk: encryption and compression facts, then the password check.
    /// `encryptedOrdinals` are the header ordinals of the winning encrypted, non-empty entries. `parts` are
    /// the files the walk read (`volumes(of:)`).
    private static func postWalk(parts: [URL], password: String?, format: ArchiveFormat, anyEncrypted: Bool,
                                 encryptedOrdinals: [Int]) throws
        -> (ArchiveEncryption, ArchiveCompressionMethod?, Bool) {
        let facts = try zipFacts(format: format, parts: parts, anyEncrypted: anyEncrypted)
        // RAR and strong-encrypted zip cannot be decrypted, so there is no password to check.
        if let pw = password, !pw.isEmpty, let first = encryptedOrdinals.min(),
           undecryptableError(format: format, zipStrongEncryption: facts.2) == nil {
            if format == .sevenZip {
                // The walk decoded an encrypted header with this password, which proves it. A data
                // verify would only turn early data damage into a false `.wrongPassword`.
                if !sevenZipHeaderIsEncrypted(parts: parts) {
                    try verifySevenZipPassword(parts: parts, password: pw, ordinal: first)
                }
            } else {
                try verifyPassword(parts: parts, password: pw, format: format,
                                   ordinals: Set(encryptedOrdinals.sorted().prefix(4)))
            }
        }
        return facts
    }

    /// The files to read for the opened `url`, each stamped before any read: every part of the
    /// multi-volume set `url` belongs to (`VolumeSetResolver`), else `url` alone. The one place that turns
    /// the opened file into parts; every later read takes them from here (`makeSession`, `session.urls`).
    /// A missing `url` throws `.io` from its stamp, as for a single file.
    private static func volumes(of url: URL) throws -> (parts: [URL], stamps: [FileStamp]) {
        let stamp = try FileStamp(url: url)
        guard let parts = try VolumeSetResolver.resolve(url) else { return ([url], [stamp]) }
        return (parts, try parts.map { part throws(ArchiveError) in try FileStamp(url: part) })
    }

    static func open(at url: URL, password: String?, nameEncoding: ArchiveNameEncoding = .automatic,
                     limits: NestingLimits = .standard) async throws -> LibArchiveReader {
        let (parts, stamps) = try volumes(of: url)

        var list: [ArchiveEntry] = []
        var indexByPath: [String: Int] = [:]
        var ordinalByPath: [String: Int] = [:]
        var symlinks: [String: String] = [:]
        var hardlinks: [String: String] = [:]
        var inexact = Set<String>()
        var anyEncrypted = false

        let walked: (format: ArchiveFormat, anyHardlink: Bool, nameDecoding: NameDecoding)
        // Scoped to the walk: the session's reader holds what libarchive read (a zip's whole central directory),
        // and postWalk's probes and password check open their own.
        do {
            let session = try ReadSession(urls: parts, password: password, limits: limits)
            walked = try walkHeaders(session: session, url: url, password: password, nameEncoding: nameEncoding,
                                     limits: limits) { h in
                let e = h.makeEntry()
                let path = h.path
                if let i = indexByPath[path] {
                    list[i] = e
                } else {
                    indexByPath[path] = list.count
                    list.append(e)
                }
                ordinalByPath[path] = h.ordinal
                hardlinks[path] = h.hardlinkTarget
                symlinks[path] = h.symlinkTarget
                if h.nameReadsAsPath { inexact.remove(path) } else { inexact.insert(path) }
            }
        }
        let (format, anyHardlink, decoding) = walked

        // Recompute encryption facts from the winning entries.
        var encryptedOrdinals: [Int] = []
        for e in list where e.isEncrypted {
            anyEncrypted = true
            if let o = ordinalByPath[e.path], e.size != 0 { encryptedOrdinals.append(o) }
        }

        // Synthesize missing ancestors before their first descendant.
        var result: [ArchiveEntry] = []
        result.reserveCapacity(list.count)
        var emitted = Set<String>()
        var previousParent: Substring.UTF8View?
        for e in list {
            // Parent = bytes before the last "/" (like EntryPath, not Character-based `parentPath`).
            // Same parent as the previous entry: its ancestors were handled one entry earlier.
            let u = e.path.utf8
            let parent = u.lastIndex(of: 0x2F).map { Substring(e.path[..<$0]).utf8 } ?? Substring("").utf8
            if let prev = previousParent, prev.elementsEqual(parent) {
                result.append(e)
                continue
            }
            previousParent = parent
            for a in EntryPath.ancestors(of: e.path) where indexByPath[a] == nil && !emitted.contains(a) {
                emitted.insert(a)
                result.append(ArchiveEntry(path: a, isDirectory: true, size: nil, compressedSize: nil,
                                           modificationDate: nil))
            }
            result.append(e)
        }

        let (encryption, method, strong) = try postWalk(parts: parts, password: password, format: format,
                                                        anyEncrypted: anyEncrypted,
                                                        encryptedOrdinals: encryptedOrdinals)
        let comment = try ArchiveCommentDecoder.comment(format: format, parts: parts, decoding: decoding)

        return LibArchiveReader(url: url, format: format, entries: result, isEncrypted: anyEncrypted,
                                encryption: encryption, compressionMethod: method, zipStrongEncryption: strong,
                                password: password, headerOrdinalByPath: ordinalByPath,
                                hasHardlinks: anyHardlink, nameDecoding: decoding,
                                symlinkTargetByPath: symlinks, hardlinkTargetByPath: hardlinks,
                                inexactStoredNames: inexact, comment: comment, volumeURLs: parts, stamps: stamps,
                                cache: TemporaryExtractionCache())
    }

    /// Walks like `open` but keeps only a path -> facts dictionary and a set of ancestor candidates, and builds
    /// `ArchiveEntry` values for the first `limit` visible paths. Totals equal `open`'s by construction. Held to
    /// `NestingLimits.preview` by default, tighter than `open`'s: previews run where memory is short (Quick Look).
    static func previewListing(at url: URL, password: String?, limit: Int,
                               limits: NestingLimits = .preview) async throws -> ArchivePreviewListing {
        let (parts, _) = try volumes(of: url)
        let limit = max(limit, 0)

        struct Slot {
            var isDirectory: Bool
            var size: Int64?
            var isEncrypted: Bool
            var ordinal: Int
            let isMetadata: Bool
            /// Index into `entries` while the path is among the first `limit` visible ones.
            let entryIndex: Int?
        }
        var slots: [String: Slot] = [:]
        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(min(limit, 1 << 16))
        var ancestorCandidates = Set<String>()
        var previousParent: Substring.UTF8View?

        let format: ArchiveFormat
        // Scoped to the walk, as in `open`: postWalk opens its own sessions.
        do {
            let session = try ReadSession(urls: parts, password: password, limits: limits)
            format = try walkHeaders(session: session, url: url, password: password, nameEncoding: .automatic,
                                     limits: limits, willVisit: { slots.reserveCapacity($0) }) { h in
                if var slot = slots[h.path] {
                    slot.isDirectory = h.isDirectory
                    slot.size = h.size
                    slot.isEncrypted = h.isEncrypted
                    slot.ordinal = h.ordinal
                    slots[h.path] = slot
                    if let i = slot.entryIndex { entries[i] = h.makeEntry() }
                    return
                }
                let meta = MacOSMetadata.isMetadata(path: h.path)
                var index: Int?
                if !meta && entries.count < limit {
                    index = entries.count
                    entries.append(h.makeEntry())
                }
                slots[h.path] = Slot(isDirectory: h.isDirectory, size: h.size, isEncrypted: h.isEncrypted,
                                     ordinal: h.ordinal, isMetadata: meta, entryIndex: index)

                // Same byte-based parent and parent cache as `open`'s ancestor synthesis.
                let u = h.path.utf8
                let parent = u.lastIndex(of: 0x2F).map { Substring(h.path[..<$0]).utf8 } ?? Substring("").utf8
                if let prev = previousParent, prev.elementsEqual(parent) { return }
                previousParent = parent
                for a in EntryPath.ancestors(of: h.path) { ancestorCandidates.insert(a) }
            }.format
        }

        var count = 0
        var fileSizes: [Int64] = []
        var anyEncrypted = false
        var encrypted: [Int] = []
        for slot in slots.values {
            if slot.isEncrypted {
                anyEncrypted = true
                if slot.size != 0 { encrypted.append(slot.ordinal) }
            }
            guard !slot.isMetadata else { continue }
            count += 1
            if !slot.isDirectory { fileSizes.append(slot.size ?? 0) }
        }
        for a in ancestorCandidates where slots[a] == nil && !MacOSMetadata.isMetadata(path: a) { count += 1 }
        let fileSize = SizeSum.of(fileSizes)
        // The probes and the password check that follow need none of the path tables.
        slots = [:]
        ancestorCandidates = []
        fileSizes = []

        _ = try postWalk(parts: parts, password: password, format: format, anyEncrypted: anyEncrypted,
                         encryptedOrdinals: Array(encrypted))
        return ArchivePreviewListing(format: format, entries: entries, visibleEntryCount: count,
                                     visibleFileSize: fileSize, isEncrypted: anyEncrypted)
    }

    /// Any part of a multi-volume set reads the whole set, as in `open` (a later part alone, such as a
    /// spanned zip's `.zip` or a `.7z.002`, has no recognizable start). When the set cannot be resolved
    /// (a part is missing or unreadable), `url` is read alone.
    static func detectFormat(at url: URL) -> ArchiveFormat? {
        let parts = (try? VolumeSetResolver.resolve(url)).flatMap { $0 } ?? [url]
        // A gzip/xz stream that ends inside the filter's first output block fails before any format
        // bids (in open or in the first nextHeader); the probe still finds the tar header at the front.
        guard let session = try? ReadSession(urls: parts, password: nil) else {
            return CompressedTarProbe.format(at: url)
        }
        // The format code is set before headers parse, so encrypted-header 7z/RAR still map.
        _ = try? session.nextHeader()
        return mapArchiveFormat(formatCode: session.formatCode, filterCodes: session.filterCodes)
            ?? CompressedTarProbe.format(at: url)
    }

    /// A fresh session over every part. Any part whose stamp changed since open fails it.
    func makeSession() throws(ArchiveError) -> ReadSession {
        for (part, stamp) in zip(volumeURLs, stamps) {
            guard try FileStamp(url: part) == stamp else { throw .io("archive changed on disk") }
        }
        return try ReadSession(urls: volumeURLs, password: password)
    }

    // MARK: - Helpers

    /// Encryption method and compression method. Zip comes from the central-directory probe; if that
    /// directory is unusable (libarchive streamed the local headers), fall back to the header flag.
    /// The fallback assumes AES-256 so a plain save never downgrades AES to ZipCrypto, and an
    /// encrypted entry libarchive saw is never reported (and so never saved) as unencrypted.
    /// The third value is the probe's strong-encryption flag (false when the probe cannot run).
    private static func zipFacts(format: ArchiveFormat, parts: [URL], anyEncrypted: Bool) throws
        -> (ArchiveEncryption, ArchiveCompressionMethod?, Bool) {
        let unknown: ArchiveEncryption = anyEncrypted ? .aes256 : .none
        guard format == .zip else { return (unknown, nil, false) }
        let found: (encryption: ArchiveEncryption, method: ArchiveCompressionMethod?, strongEncryption: Bool)
        do {
            found = try probeZip(parts)
        } catch ArchiveError.corrupted {
            return (unknown, nil, false)
        }
        return (found.encryption == .none ? unknown : found.encryption, found.method, found.strongEncryption)
    }

    /// `ZipEncryptionProbe` on a zip's parts: joined for a byte split, else the last file (`isByteSplit`).
    private static func probeZip(_ parts: [URL]) throws
        -> (encryption: ArchiveEncryption, method: ArchiveCompressionMethod?, strongEncryption: Bool) {
        try isByteSplit(parts) ? ZipEncryptionProbe.detect(parts: parts)
                               : ZipEncryptionProbe.detect(at: parts[parts.count - 1])
    }

    /// Whether the probe reads a zip's parts as one file: a byte split (`x.zip.001` ...) is one disk-0 zip cut
    /// anywhere, so its central directory and end records may lie in any parts and its offsets are positions in the
    /// joined bytes. A spanned set (end record disk above 0: its offsets are per disk) and a single file are probed at
    /// the last file alone, which refuses a directory that starts on another disk (`.corrupted`) and falls back to
    /// the header flag.
    private static func isByteSplit(_ parts: [URL]) throws -> Bool {
        guard parts.count > 1 else { return false }
        let end = try VolumeProbe.zipEOCD(parts: parts)
        return end.found && end.diskNumber == 0
    }

    /// Maps a failed header read of the listing walk. `ordinal` is the header being read, `firstEncrypted`
    /// the first encrypted non-empty header the walk has returned (7z arbitration). `url` is the
    /// opened file; the follow-up reads take every part from `session.urls`.
    private static func headerFailure(_ error: Error, session: ReadSession, url: URL, password: String?,
                                      ordinal: Int, firstEncrypted: Int?) -> Error {
        let format = mapArchiveFormat(formatCode: session.formatCode, filterCodes: session.filterCodes)
        guard let format else { return ArchiveError.unsupportedFormat }
        guard let ae = error as? ArchiveError else { return error }
        if case .io = ae { return ae }
        // A patch refused the names inside libarchive (7z: patch 0014, xar: 0015, zip: 0022): the limit, before any password
        // rule, since an encrypted header that decoded far enough to reach its names was decrypted with the right
        // password.
        if let refusal = PatchedNameRefusal.refusal(for: ae) { return refusal }
        if format == .sevenZip {
            let msg = archive_error_string(session.handle).map { String(cString: $0) } ?? ""
            let hasEncrypted = archive_read_has_encrypted_entries(session.handle) > 0
            let failed = session.failedEntry
            let reached = failed.map { archive_entry_size_is_set($0) != 0 } ?? false
            if let mapped = sevenZipHeaderFailure(ae, message: msg,
                                                  isEncryptedHeaderDecode: isSevenZipEncryptedHeaderDecode(
                                                      session: session, ordinal: ordinal),
                                                  hasEncryptedEntries: hasEncrypted,
                                                  hasPassphrase: session.hasPassphrase) {
                return mapped
            }
            // Arbitrate with the open-time check. Its target is the first encrypted non-empty entry: one
            // already listed, else the entry whose header read failed (an encrypted symlink, whose target
            // libarchive decodes in the header read). It decodes: the failure is damage. It fails: the
            // password is wrong. Password-independent failures (.io, .cancelled, codec checks) pass through.
            let target = firstEncrypted
                ?? failed.flatMap { reached && archive_entry_is_encrypted($0) != 0 ? ordinal : nil }
            guard let password, !password.isEmpty, let target else {
                return readFailure(ae, format: format, encrypted: true, hasPassphrase: session.hasPassphrase,
                                   zipStrongEncryption: false)
            }
            // This read came after an encrypted header that the password decoded, so it is damage.
            if sevenZipHeaderIsEncrypted(parts: session.urls) { return ae }
            do {
                try verifySevenZipPassword(parts: session.urls, password: password, ordinal: target)
            } catch {
                return error
            }
            return ae
        }
        if format == .rar {
            let msg = archive_error_string(session.handle).map { String(cString: $0).lowercased() } ?? ""
            if archive_read_has_encrypted_entries(session.handle) > 0
                || msg.contains("encrypt") || msg.contains("passphrase") {
                return encryptionError(format: format, hasPassphrase: session.hasPassphrase)
            }
            return ae
        }
        // Zip and the rest: a password error only when libarchive names the passphrase. The central
        // directory may still say the entries use strong encryption, which no password decrypts.
        let strong = format == .zip
            && ((try? probeZip(session.urls))?.strongEncryption ?? false)
        return readFailure(ae, format: format,
                           encrypted: strong || archive_read_has_encrypted_entries(session.handle) == 1,
                           hasPassphrase: session.hasPassphrase, zipStrongEncryption: strong)
    }

    /// Reads the first block of each encrypted entry at `ordinals` (up to four) with the password. Each
    /// read runs libarchive's own check (ZipCrypto check byte, AES verifier), so a wrong password passes
    /// all of them only with probability 1/256 per entry. Only a password error (or another non-corruption
    /// failure) fails open: corruption in a verified entry's data block is ignored here, and that entry
    /// fails on extract. A password error from any entry still wins, since a wrong password that slipped
    /// past one check decrypts garbage. libarchive's deflate error is fatal for the session, so after an
    /// ignored corruption the walk continues in a fresh session (at most four, damaged archives only).
    /// With a single ZipCrypto entry, a wrong password that passes the check byte (1/256) now opens and
    /// then fails on extract as `.corrupted` (before: open failed `.corrupted`); neither is a password loop.
    private static func verifyPassword(parts: [URL], password: String, format: ArchiveFormat, ordinals: Set<Int>) throws {
        func mapped(_ error: ArchiveError) -> ArchiveError {
            readFailure(error, format: format, encrypted: true, hasPassphrase: true, zipStrongEncryption: false)
        }
        var s = try ReadSession(urls: parts, password: password)
        var remaining = ordinals
        var i = 0
        while !remaining.isEmpty {
            let entry: OpaquePointer?
            do { entry = try s.nextHeader() } catch { throw mapped(error) }
            guard entry != nil else { break }
            defer { i += 1 }
            guard remaining.remove(i) != nil else { continue }
            do { _ = try s.readBlock() } catch {
                let e = mapped(error)
                guard case .corrupted = e else { throw e }
                // The session may be dead (fatal error): carry on from the start in a fresh one. The
                // ordinals left in `remaining` are all after this entry.
                if !remaining.isEmpty {
                    s = try ReadSession(urls: parts, password: password)
                    i = -1  // the deferred increment makes the next header ordinal 0
                }
            }
        }
    }

    /// Whether a failed 7z header read was the decode of an encrypted (`-mhe`) header. libarchive decodes a
    /// 7z header inside the first header read, while it reads the central directory, before it fills any
    /// entry (it always sets the size of an entry it reached). During that read only a header folder with
    /// 7zAES coders marks the archive encrypted (patch 0004). So the -mhe header decode is: first read, no
    /// entry reached, encrypted. Everything else (a symlink's target decoded while listing, or a folder skip
    /// after one) comes after the header. Valid only right after `session.nextHeader()` threw.
    private static func isSevenZipEncryptedHeaderDecode(session: ReadSession, ordinal: Int) -> Bool {
        let reached = session.failedEntry.map { archive_entry_size_is_set($0) != 0 } ?? false
        return ordinal == 0 && !reached && archive_read_has_encrypted_entries(session.handle) > 0
    }

    /// Whether the 7z in `parts` has an encrypted header (`-mhe=on`; every Kernir-written encrypted 7z).
    /// Without a passphrase such a header cannot be decoded: the first header read fails as the encrypted
    /// header decode (`isSevenZipEncryptedHeaderDecode`) asking for the passphrase. A plain header parses
    /// (no data is decoded) and the read succeeds, or fails later. Called only after a walk with the
    /// password listed the archive, so an encrypted header here was decrypted, decoded and CRC-checked with
    /// that password: a wrong one passes that with probability about 2^-32, and 7z uses one password per
    /// archive. The password is proven, and the open-time data verify is skipped.
    private static func sevenZipHeaderIsEncrypted(parts: [URL]) -> Bool {
        guard let s = try? ReadSession(urls: parts, password: nil) else { return false }
        do {
            _ = try s.nextHeader()
            return false
        } catch {
            guard isSevenZipEncryptedHeaderDecode(session: s, ordinal: 0) else { return false }
            let msg = archive_error_string(s.handle).map { String(cString: $0) } ?? ""
            return sevenZipHeaderFailure(error, message: msg, isEncryptedHeaderDecode: true,
                                         hasEncryptedEntries: true, hasPassphrase: false) == .passwordRequired
        }
    }

    /// 7z has no password check value: a wrong key shows up only as a decompression or CRC failure, possibly
    /// only at the end of the entry. So decode the first encrypted non-empty entry (header `ordinal`) to its
    /// end or 1 MiB of output. A failure `readFailure` would leave as `.corrupted` (CRC, LZMA/PPMd/... data
    /// errors) is `.wrongPassword` here; password-independent failures pass through: `.unsupportedEncryption`
    /// (codec checks), damaged 7zAES properties (`.corrupted`, `sevenZipCoderFailure`), and `.io`. Header
    /// failures before the target map like `readFailure`. The target's own header read decodes it when it
    /// is a symlink (libarchive reads the target while listing), so a failure there counts as a decode
    /// failure. Once open succeeds, later data failures under that password are `.corrupted`, never
    /// `.wrongPassword`. The listing walk also calls this to arbitrate a failed header read. Neither
    /// calls it for a header-encrypted 7z, whose decoded header already proved the password.
    private static func verifySevenZipPassword(parts: [URL], password: String, ordinal: Int) throws {
        func plain(_ error: ArchiveError) -> ArchiveError {
            readFailure(error, format: .sevenZip, encrypted: true, hasPassphrase: true, zipStrongEncryption: false)
        }
        func decodeFailure(_ error: ArchiveError) -> ArchiveError {
            let mapped = plain(error)
            if case .corrupted(let message) = mapped, sevenZipCoderFailure(mapped, message: message) == nil {
                return .wrongPassword
            }
            return mapped
        }
        let s = try ReadSession(urls: parts, password: password)
        var i = 0
        while true {
            let entry: OpaquePointer?
            do { entry = try s.nextHeader() } catch { throw i == ordinal ? decodeFailure(error) : plain(error) }
            guard entry != nil else { return }
            if i < ordinal { i += 1; continue }
            var produced = 0
            while produced < 1 << 20 {
                if Task.isCancelled { throw ArchiveError.cancelled }
                let block: (buffer: UnsafeRawBufferPointer, offset: Int64)?
                do throws(ArchiveError) { block = try s.readBlock() } catch {
                    throw decodeFailure(error)
                }
                guard let block else { return }
                produced += block.buffer.count
            }
            return
        }
    }

    // MARK: - Temporary extraction

    /// Follows symlinks and hardlinks inside the archive to the regular-file entry path whose header
    /// holds the data. Nil for an absolute target, an escape above the archive root, a dangling, missing
    /// or directory target, or more than 8 hops (each hardlink jump and symlink jump counts).
    private func resolveLinks(_ link: String) -> String? {
        var current = link
        for _ in 0...8 {
            if let target = hardlinkTargetByPath[current] {
                // A hardlink must name an entry that has a header.
                guard headerOrdinalByPath[target] != nil else { return nil }
                // Jump onto the target, where every format but cpio keeps the data. cpio newc keeps it on
                // the last link of a group, so there a hardlink to a regular file stops here and
                // extractEntries finds the data; a hardlink to a symlink is jumped in every format.
                if format != .cpio || symlinkTargetByPath[target] != nil {
                    current = target; continue
                }
            }
            guard let raw = symlinkTargetByPath[current] else {
                guard let e = entries.first(where: { $0.path == current }), !e.isDirectory else { return nil }
                return current
            }
            // Scalar-exact components, like EntryPath: a "/" or ".." hidden behind a combining mark must
            // not survive as one grapheme.
            let scalars = raw.unicodeScalars.filter { $0.value != 0 }
            if scalars.first == "/" { return nil }
            var parts = current.unicodeScalars.split(separator: "/", omittingEmptySubsequences: true).dropLast()
                .map { String(String.UnicodeScalarView($0)) }
            for c in scalars.split(separator: "/", omittingEmptySubsequences: true) {
                if c.count == 1 && c.first == "." { continue }
                if c.count == 2 && c.allSatisfy({ $0 == "." }) {
                    if parts.isEmpty { return nil }
                    parts.removeLast()
                } else { parts.append(String(String.UnicodeScalarView(c))) }
            }
            guard let next = EntryPath.normalize(parts.joined(separator: "/")) else { return nil }
            current = next
        }
        return nil
    }

    /// The POSIX reason for a Foundation file error (its own message names the paths involved); the error code
    /// when there is none.
    static func posixReason(_ error: Error) -> String {
        let ns = error as NSError
        let posix = ns.domain == NSPOSIXErrorDomain ? ns : ns.userInfo[NSUnderlyingErrorKey] as? NSError
        if let posix, posix.domain == NSPOSIXErrorDomain { return String(cString: strerror(Int32(posix.code))) }
        return "error \(ns.code)"
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        // Errors carry the caller's spelling; a missing path or a directory fails before any extraction.
        guard let n = EntryPath.normalize(path),
              let entry = entries.first(where: { $0.path == n }), !entry.isDirectory
        else { throw ArchiveError.entryNotFound(path) }
        if let cached = cache.cachedURL(for: n) { return cached }
        // Never return a symlink: serve the bytes of the regular file it resolves to, under the link's name.
        var source = n
        if symlinkTargetByPath[n] != nil || hardlinkTargetByPath[n] != nil {
            guard let resolved = resolveLinks(n) else { throw ArchiveError.entryNotFound(path) }
            // A cpio hardlink to a regular file resolves to itself; extractEntries finds its data.
            source = resolved
        }

        // Extract into a private staging dir, then rename(2) into place, so concurrent calls for the
        // same path never expose a partially written file.
        let fm = FileManager.default
        let staging = cache.root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try extractEntries(selection: [source], to: staging, progress: nil)

        let destination = cache.destination(for: n)
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            // Named by the entry: the folder is a 64-hex hash, and Foundation's own message names it too.
            throw ArchiveError.io("Could not create a temporary folder for \(path): \(Self.posixReason(error))")
        }
        let rc = rename(staging.appending(path: source).path, destination.path)
        guard rc == 0 else {
            throw ArchiveError.io("Could not move extracted file into place: \(String(cString: strerror(errno)))")
        }
        // Final guard: only a regular file may be returned or cached (no symlink, FIFO or device).
        var st = stat()
        guard lstat(destination.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            try? fm.removeItem(at: destination)
            throw ArchiveError.entryNotFound(path)
        }
        cache.store(destination, for: n)
        return destination
    }
}
