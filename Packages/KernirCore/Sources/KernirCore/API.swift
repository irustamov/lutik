// KernirCore public API: the contract between the engine and the apps.
// App, iOS and Quick Look code depend only on what is declared here.
// Changing a signature needs a note to the maintainers.

import Foundation

// MARK: - Formats

public enum ArchiveFormat: String, CaseIterable, Sendable, Codable {
    case zip, sevenZip, rar, tar, tarGzip, tarBzip2, tarXz, tarZstd
    case gzip, bzip2, xz, zstd, iso, cpio, xar, lha, cab

    /// Formats Kernir can create or repack.
    public static let writable: [ArchiveFormat] = [.zip, .sevenZip, .tar, .tarGzip, .tarBzip2, .tarXz]

    public var isWritable: Bool { Self.writable.contains(self) }

    /// Human-readable name, e.g. "ZIP", "7z", "TAR.GZ".
    public var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .sevenZip: "7z"
        case .rar: "RAR"
        case .tar: "TAR"
        case .tarGzip: "TAR.GZ"
        case .tarBzip2: "TAR.BZ2"
        case .tarXz: "TAR.XZ"
        case .tarZstd: "TAR.ZST"
        case .gzip: "GZ"
        case .bzip2: "BZ2"
        case .xz: "XZ"
        case .zstd: "ZST"
        case .iso: "ISO"
        case .cpio: "CPIO"
        case .xar: "XAR"
        case .lha: "LHA"
        case .cab: "CAB"
        }
    }

    /// Preferred file extension without a dot.
    public var fileExtension: String {
        switch self {
        case .sevenZip: "7z"
        case .tarGzip: "tar.gz"
        case .tarBzip2: "tar.bz2"
        case .tarXz: "tar.xz"
        case .tarZstd: "tar.zst"
        case .gzip: "gz"
        case .bzip2: "bz2"
        case .zstd: "zst"
        default: rawValue
        }
    }
}

// MARK: - Entries

/// One entry inside an archive. Paths use "/" separators and never start with "/".
/// Directories are always present as entries (synthesized when the archive omits them).
public struct ArchiveEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let isDirectory: Bool
    /// Uncompressed size in bytes; nil when unknown. For directories: nil.
    public let size: Int64?
    /// Compressed size in bytes when the format reports it.
    public let compressedSize: Int64?
    public let modificationDate: Date?
    public let isEncrypted: Bool
    /// POSIX permissions when known.
    public let permissions: UInt16?

    /// Last path component (the whole path when it has no "/"). Split on the scalar "/", never on Characters: a "/"
    /// followed by a combining mark or ZWJ, or preceded by a Prepend scalar, is still a separator (`a/\u{301}b` is
    /// named `\u{301}b`). For every path whose "/"s are Characters of their own, the same bytes as a Character split.
    public var name: String { EntryPath.lastComponent(of: path) }
    /// Parent directory path, "" for top level: everything before the last "/" scalar (see `name`).
    public var parentPath: String { EntryPath.parent(of: path) ?? "" }

    public init(path: String, isDirectory: Bool, size: Int64?, compressedSize: Int64?,
                modificationDate: Date?, isEncrypted: Bool = false, permissions: UInt16? = nil) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.compressedSize = compressedSize
        self.modificationDate = modificationDate
        self.isEncrypted = isEncrypted
        self.permissions = permissions
    }
}

extension ArchiveEntry {
    /// True for Finder metadata (a `__MACOSX` folder at any depth with everything beneath it, and AppleDouble
    /// `._` files); UI may hide these. A `__MACOSX` entry matches whether it is a folder or a file; only the whole
    /// component matches, case-sensitively (`__MACOSXfoo`, `__macosx` are content). The engine never
    /// drops them on its own: only a write with `ArchiveWriteOptions.excludesMacMetadata` set leaves them
    /// (and `.DS_Store`) out.
    public var isMacOSMetadata: Bool { Self.isMacOSMetadata(path: path) }

    /// `isMacOSMetadata` for a bare archive path, for callers that hold a path and no entry: true when a
    /// component at any depth is exactly `__MACOSX` (case-sensitive) or the last component starts with `._`.
    /// The path is split on the byte "/" (never on Characters, so a "/" next to a combining mark, ZWJ or Prepend
    /// scalar still separates) and names are compared as bytes. Trailing "/"s are ignored, so a directory path
    /// (`__MACOSX/`, `d/._x/`) answers like the same path without them. `.DS_Store` is NOT metadata here: only a
    /// write with `ArchiveWriteOptions.excludesMacMetadata` leaves it out. The path is taken as given (no
    /// normalization); an entry's `isMacOSMetadata` is exactly this for its `path`.
    public static func isMacOSMetadata(path: String) -> Bool { MacOSMetadata.isMetadata(path: path) }
}

/// Tree node for OutlineGroup / Table(children:) and Quick Look.
///
/// A crafted archive can nest folders tens of thousands deep, so nothing here recurses once per level: `==` and
/// `hash(into:)` walk with an explicit stack, and releasing a tree takes it apart level by level (`ChildList`),
/// where the synthesized versions and the default release of nested arrays would overflow the stack.
/// `dump` and other Mirror walks still recurse (debug only; nothing in the app uses them on a tree).
public struct ArchiveNode: Identifiable, Hashable, Sendable {
    public var id: String { entry.path }
    public let entry: ArchiveEntry
    /// nil for files, possibly empty for directories (OutlineGroup convention).
    public var children: [ArchiveNode]? {
        get { childList?.nodes }
        set { childList = newValue.map(ChildList.init) }
    }
    /// Sum of descendant file sizes for directories, entry size for files. nil when unknown: for a
    /// directory, when any descendant file's size is unknown (an empty directory is 0), or when the sum does not
    /// fit in Int64 (only crafted sizes get there).
    public var totalSize: Int64?
    private var childList: ChildList?

    public init(entry: ArchiveEntry, children: [ArchiveNode]?, totalSize: Int64?) {
        self.entry = entry
        self.childList = children.map(ChildList.init)
        self.totalSize = totalSize
    }

    public static func == (a: ArchiveNode, b: ArchiveNode) -> Bool {
        var pending = [(a, b)]
        while let (x, y) = pending.popLast() {
            guard x.entry == y.entry, x.totalSize == y.totalSize else { return false }
            switch (x.childList, y.childList) {
            case (nil, nil): continue
            case let (p?, q?):
                if p === q { continue }
                guard p.nodes.count == q.nodes.count else { return false }
                pending.append(contentsOf: zip(p.nodes, q.nodes))
            default: return false
            }
        }
        return true
    }

    /// Pre-order, each node's entry and total followed by its child count (-1 for nil): equal trees feed equal input.
    public func hash(into hasher: inout Hasher) {
        var pending = [self]
        while let node = pending.popLast() {
            hasher.combine(node.entry)
            hasher.combine(node.totalSize)
            guard let list = node.childList else { hasher.combine(-1); continue }
            hasher.combine(list.nodes.count)
            pending.append(contentsOf: list.nodes.reversed())
        }
    }

    /// A folder's children. Releasing the last reference takes the subtree apart without recursion: every list
    /// nobody else holds is emptied into a work list before it goes, so no release reaches more than one level.
    /// `nodes` only changes in `deinit`, on lists no other reference can see, so sharing it across threads is safe.
    private final class ChildList: @unchecked Sendable {
        var nodes: [ArchiveNode]

        init(_ nodes: [ArchiveNode]) { self.nodes = nodes }

        deinit {
            guard !nodes.isEmpty else { return }
            var pending = nodes
            nodes = []
            while var node = pending.popLast() {
                if isKnownUniquelyReferenced(&node.childList), let list = node.childList, !list.nodes.isEmpty {
                    pending.append(contentsOf: list.nodes)
                    list.nodes = []
                }
                // `node` goes here: its list is empty or still held elsewhere, so this release stops at one level.
            }
        }
    }
}

// MARK: - Errors

public enum ArchiveError: Error, Sendable, Equatable {
    case unsupportedFormat
    /// The archive (or the entry being read) is encrypted and no password was given.
    case passwordRequired
    /// The given password does not decrypt the archive. Open checks it (zip: libarchive's check value; 7z:
    /// decoding the first encrypted entry), so after a successful open, data damage reads as `.corrupted`.
    /// A header-encrypted 7z whose encrypted header is damaged also answers `.wrongPassword` (the bytes
    /// cannot tell a wrong key from damage; 7-Zip itself says "Wrong password?").
    case wrongPassword
    /// Encrypted with a scheme the engine cannot decrypt (RAR, PKWARE strong-encrypted zip, 7z crypto other
    /// than 7zAES or AES folders past the supported coder layout). Asking for a password will not help.
    /// 7z AES-256 is decrypted: it answers `.passwordRequired` / `.wrongPassword` like zip.
    case unsupportedEncryption(ArchiveFormat)
    case readOnlyFormat(ArchiveFormat)
    case corrupted(String)
    case entryNotFound(String)
    case io(String)
    case cancelled
    case notImplemented
}

/// Thrown by `ArchiveReading.extract` when an item already exists where the extraction would write:
/// a file, symlink or other non-folder at an entry's destination, a folder where the archive has a file,
/// or a non-folder in the way of an entry's parent folder. Extract never replaces anything that existed
/// before the call. A separate type, not an `ArchiveError` case, so exhaustive switches over
/// `ArchiveError` keep compiling.
public struct ExtractionConflictError: Error, Sendable, Equatable {
    /// Archive entry paths, relative to the destination folder, "/"-separated and sorted, whose
    /// destination already exists.
    public let paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }
}

/// Thrown only by `ArchiveWriter.writeVolumes` when the archive needs more than `maximum` volumes
/// (`ArchiveWriteOptions.maximumVolumeCount`). Found while writing: the volumes written so far are deleted and
/// the folder is left as the caller made it. A separate type, not an `ArchiveError` case, so exhaustive
/// switches over `ArchiveError` keep compiling. It happens when the archive is larger than
/// `maximumVolumeCount` × `volumeSize`; a larger volume size fixes it.
public struct ArchiveVolumeLimitError: Error, Sendable, Equatable {
    /// Most volumes the split write allows: `ArchiveWriteOptions.maximumVolumeCount`.
    public let maximum: Int

    public init(maximum: Int) {
        self.maximum = maximum
    }
}

/// Thrown by `Archive.open` and `Archive.previewListing` for a multi-volume set that cannot be read whole.
/// A separate type, not an `ArchiveError` case, so exhaustive switches over `ArchiveError` keep compiling.
public struct ArchiveVolumeError: Error, Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case missing    // the part does not exist
        case noAccess   // the part exists but cannot be opened (sandbox: grant `folder`)
    }
    public let reason: Reason
    /// 1-based number of the first missing or unreadable part; nil when unknown (a spanned zip whose
    /// last part, the .zip, is missing).
    public let part: Int?
    /// The file name that part has, e.g. "Photos.part3.rar".
    public let fileName: String
    /// File name of part 1 (spanned zip: the .zip), for messages: "Part 3 of “Photos.part1.rar” is missing."
    public let setName: String
    /// The folder that holds the opened part; the one to grant for `.noAccess`.
    public let folder: URL
    /// 1-based number of the part that was opened. 0 when a spanned zip was opened at its `.zip`: that is
    /// its last part, and the part count is not known from the name.
    public let openedPart: Int

    public init(reason: Reason, part: Int?, fileName: String, setName: String, folder: URL, openedPart: Int) {
        self.reason = reason
        self.part = part
        self.fileName = fileName
        self.setName = setName
        self.folder = folder
        self.openedPart = openedPart
    }
}

/// Thrown by `Archive.open` and `Archive.previewListing` when the archive's entry names are longer, more numerous or
/// nest folders deeper than the reader accepts (see `Limit`), before any folder is synthesized. Each folder a path
/// implies holds that folder's whole path, so a crafted archive could otherwise cost memory and time that grow with the
/// square of its depth; names a few bytes of compressed data expand to could otherwise fill memory before the first
/// path is checked. A separate type, not an `ArchiveError` case, so exhaustive switches over `ArchiveError` keep
/// compiling.
public struct ArchiveNestingError: Error, Sendable, Equatable {
    public enum Limit: Sendable, Equatable {
        /// An entry path has more than 200 components.
        case depth
        /// A name or link target is too long: over 64 KiB as the header stores it (checked as the header is read,
        /// before any decoding), or, for an entry path or hardlink target, over 16 KiB of UTF-8 once normalized.
        /// A stored name may be much longer than its path ("./" padding normalizes away), so both are checked.
        case pathLength
        /// The folders all entry paths imply, counted once each, hold more than 64 MiB of path (plus 128 bytes each),
        /// or more than 512 bytes for each entry path so far once that is more.
        case folderBytes
        /// The folder paths of every entry path, summed over all entries, pass 1 GiB, or 8 KiB for each entry path so
        /// far once that is more.
        case ancestorWork
        /// The names and link targets of all headers, as stored, add up to more than 256 MiB, or 512 bytes for each
        /// header so far once that is more (checked as each header is read). Real trees store at most about 254 bytes
        /// per entry, even under a Time Machine-style prefix ("Backups.backupdb/<Mac>/<date>/Macintosh HD - Data/..."),
        /// so a very large honest listing meets `entryCount` first. A xar's extended attribute names count too, inside
        /// libarchive (one over 64 KiB is `pathLength`); so do an ISO 9660 image's Rockridge names and link targets, as
        /// each directory is read, before its first entry, and its continuation-area bytes (each record's pass over
        /// each area, beyond the bytes of the image read so far); and a zip's per-entry comments (central directory),
        /// added to its record names as the central directory is read, before the first entry.
        case totalPathBytes
        /// A name or link target has more than 30 combining marks in a row (the UAX #15 Stream-Safe limit). No real
        /// name comes close, and composing such a run costs time that grows with the square of its length.
        case combiningMarks
        /// The archive holds more than 4 million headers (files, folders and links, every one counted), checked as
        /// each header is read; a 7z (files, folders or streams), a xar (files, or extended attributes in all or
        /// more than 1,024 on one file), an ISO 9660 image (directory records, the root included) or a zip's central
        /// directory (records with a new local header offset, or twice as many in all) is held to the same count inside
        /// libarchive, before it allocates them.
        case entryCount
    }
    /// The first limit the archive passed, in archive order.
    public let limit: Limit

    public init(limit: Limit) {
        self.limit = limit
    }
}

/// The first entries of an archive plus exact totals, for previews that must stay fast on huge archives.
public struct ArchivePreviewListing: Sendable {
    public let format: ArchiveFormat
    /// The first `limit` header entries in archive order, without macOS metadata and without synthesized folders.
    /// A later header with the same path replaces the earlier one in place (as in `open`).
    public let entries: [ArchiveEntry]
    /// Exactly `open(at:).entries.filter { !$0.isMacOSMetadata }.count` (synthesized folders included).
    public let visibleEntryCount: Int
    /// Exactly the sum of `size ?? 0` over the non-directory entries counted in `visibleEntryCount`; nil when
    /// that sum does not fit in Int64 (only crafted sizes get there).
    public let visibleFileSize: Int64?
    public let isEncrypted: Bool
}

extension Archive {
    /// Lists like `open` but builds only the first `limit` visible entries (limit < 0 counts as 0). Same errors as `open`,
    /// `ArchiveNestingError` included.
    /// Any part of a multi-volume set lists the whole set, as in `open`.
    /// A preview runs where memory is short (the Quick Look extension is killed at about 1.3 GB), so it holds the
    /// archive to fixed totals well under `open`'s, and throws the same `ArchiveNestingError` limit past them: more
    /// than 400,000 headers (`.entryCount`), 64 MiB of stored names and link targets (`.totalPathBytes`), 32 MiB of
    /// folders (`.folderBytes`) or 1 GiB of ancestor work (`.ancestorWork`), none of them growing with the entry
    /// count. Per path and per name (`.pathLength`, `.depth`, `.combiningMarks`) it reads what `open` reads, so an
    /// archive `previewListing` refuses for a total may still `open`.
    public static func previewListing(at url: URL, password: String? = nil, limit: Int) async throws -> ArchivePreviewListing {
        try await LibArchiveReader.previewListing(at: url, password: password, limit: limit)
    }
}

// MARK: - Progress

/// Fraction 0...1 plus the entry currently processed. Called from a background thread.
public typealias ArchiveProgressHandler = @Sendable (_ fraction: Double, _ currentPath: String?) -> Void

// MARK: - Testing

/// What a test of an archive can vouch for.
public enum ArchiveIntegrityCoverage: Sendable, Equatable {
    /// The format stores per-entry data checksums, and they were verified.
    case dataChecksums
    /// Only structure/headers could be verified.
    case headersOnly
    /// Nothing verifiable.
    case none
}

/// One entry that could not be read to its end during a test.
public struct ArchiveTestFailure: Sendable, Equatable {
    public let path: String
    public let error: ArchiveError
    /// Paths of the other entries in the same solid block/compressed stream, which are unreadable because
    /// of this failure (folded into this failure rather than listed separately). May be empty when the
    /// engine cannot tell; those entries then appear as their own failures or in `notChecked`, never omitted.
    public let sameBlockPaths: [String]

    public init(path: String, error: ArchiveError, sameBlockPaths: [String]) {
        self.path = path
        self.error = error
        self.sameBlockPaths = sameBlockPaths
    }
}

/// The result of `ArchiveReading.test(progress:)`.
public struct ArchiveTestReport: Sendable, Equatable {
    /// Regular entries read to the end without error.
    public let checkedCount: Int
    public let failures: [ArchiveTestFailure]
    /// Regular entries never reached, after a fatal error (I/O, truncation, missing volume) once at least
    /// one entry had been read. A report with entries here is returned, not thrown.
    public let notChecked: [String]
    /// What the test could vouch for: the weakest coverage of any checked entry. Without a password,
    /// encrypted entries fail with `.passwordRequired`, which is not damage: UIs should not label them
    /// damaged.
    public let coverage: ArchiveIntegrityCoverage
    /// No failures and every entry reached.
    public var isClean: Bool { failures.isEmpty && notChecked.isEmpty }
    /// Every entry path that could not be verified as readable: the failing entries, the other entries in
    /// their solid blocks, and the entries never reached. Regular entries outside this set read to their end
    /// without error, verified only as far as `coverage` says. Directories and non-regular entries are never
    /// read. A caller that extracts the complement must pass only non-directory paths (plus empty folders),
    /// never a directory, because `extract` expands a directory to its whole contents.
    public var affectedPaths: Set<String> {
        var paths = Set(notChecked)
        for failure in failures {
            paths.insert(failure.path)
            paths.formUnion(failure.sameBlockPaths)
        }
        return paths
    }

    public init(checkedCount: Int, failures: [ArchiveTestFailure], notChecked: [String],
                coverage: ArchiveIntegrityCoverage) {
        self.checkedCount = checkedCount
        self.failures = failures
        self.notChecked = notChecked
        self.coverage = coverage
    }
}

// MARK: - Reading

/// An opened archive: listing plus on-demand extraction. Immutable snapshot of the file on disk.
public protocol ArchiveReading: Sendable {
    /// The file that was opened (for a multi-volume set: the part the user opened, any of them).
    var url: URL { get }
    /// Every file the archive is read from, in read order: `[url]` for a single file; for a
    /// multi-volume set all its parts (a spanned zip's `.zip` last). Listing, extraction and previews
    /// read all of them, and a change to any part after open fails them as "archive changed on disk".
    var volumeURLs: [URL] { get }
    var format: ArchiveFormat { get }
    var entries: [ArchiveEntry] { get }
    var isEncrypted: Bool { get }
    /// Encryption scheme of the archive's entries; `.none` when unencrypted. Encrypted 7z (and RAR)
    /// report `.aes256`.
    var encryption: ArchiveEncryption { get }
    /// Compression method of the archive's entries; nil when unknown or mixed.
    var compressionMethod: ArchiveCompressionMethod? { get }
    /// What the caller asked for.
    var nameEncoding: ArchiveNameEncoding { get }
    /// The encoding used for undeclared names; nil when there are no undeclared non-ASCII names (the picker is disabled then).
    var legacyNameEncoding: String.Encoding? { get }
    /// The archive-level comment; nil when the archive has none or its format has no comment Kernir reads.
    /// In 0.1.0 only ZIP comments are read (RAR and gzip later: nil for them, never an error). A multi-volume
    /// zip's comment comes from its last part, where the end record is. A zip whose end record is followed by
    /// other data (its comment does not reach the end of the file) reports none, and a save drops it.
    var comment: ArchiveComment? { get }

    /// Extracts the given entry paths (directories include their contents) into `directory`,
    /// recreating relative structure. `nil` extracts everything.
    /// Never replaces anything that existed before the call: when an item already exists at a destination
    /// (see `ExtractionConflictError`), it throws `ExtractionConflictError` before writing anything. An
    /// existing folder where the archive has a folder is merged. An item that appears during the run, at an
    /// entry's destination or in the way of its folder, throws the same error for that entry and is left as
    /// it is: the entry is not written (any part of it already written is removed), entries finished before
    /// it stay. Files, links and other non-folders are moved into place with an exclusive rename, so even an
    /// item that appears at that instant is not replaced; only a folder entry, or a volume without exclusive
    /// rename (not APFS or HFS+), leaves a brief window in which one could be. Two entries landing on one name
    /// (a case-insensitive volume) keep the archive's order: the later one replaces what this call wrote.
    /// Never applies setuid, setgid or sticky bits; only `mode & 0o777` is written.
    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws

    /// Extracts a single file entry into a unique temporary location and returns its URL
    /// (used for Quick Look previews and drag-out). Caller does not need to clean up. The returned URL
    /// stays valid only while the reader (some copy of it) is alive; the cache is deleted when the last copy is released.
    /// Symlink entries resolve inside the archive and return the target file's bytes as a regular file.
    /// Never applies setuid, setgid or sticky bits; only `mode & 0o777` is written.
    func extractToTemporaryFile(_ path: String) async throws -> URL

    /// Reads every regular entry to its end without writing anything, and reports what could not be read.
    /// Per-entry damage lands in `ArchiveTestReport.failures`. It throws only when no entry could be read
    /// (password required before any entry, I/O, unsupported format); cancellation always throws. Once any
    /// entry was read, a fatal error (I/O, truncation, missing volume) returns a report with the remaining
    /// regular entries in `ArchiveTestReport.notChecked`.
    func test(progress: ArchiveProgressHandler?) async throws -> ArchiveTestReport
}

public extension ArchiveReading {
    /// Defaults to throwing `.notImplemented`.
    func test(progress: ArchiveProgressHandler?) async throws -> ArchiveTestReport {
        throw ArchiveError.notImplemented
    }
    /// Defaults to the opened file alone.
    var volumeURLs: [URL] { [url] }
    /// Defaults to AES-256 for encrypted archives, since the real scheme is unknown.
    var encryption: ArchiveEncryption { isEncrypted ? .aes256 : .none }
    /// Defaults to nil (unknown).
    var compressionMethod: ArchiveCompressionMethod? { nil }
    /// Defaults to `.automatic`.
    var nameEncoding: ArchiveNameEncoding { .automatic }
    /// Defaults to nil (no undeclared names).
    var legacyNameEncoding: String.Encoding? { nil }
    /// Defaults to nil (no comment).
    var comment: ArchiveComment? { nil }
}

/// An archive-level comment (ZIP's end-of-central-directory comment), as `ArchiveReading.comment` reports it.
public struct ArchiveComment: Sendable, Equatable {
    /// Longest comment, in UTF-8 bytes, that a write accepts (`ArchiveChangeSet.CommentChange.set`). A ZIP
    /// comment field holds up to 65 535 bytes, and Kernir reads an archive behind a comment of any of those
    /// lengths; the cap keeps an edited comment to a size people read, well inside the field. Comments
    /// Kernir did not write (`.keep`) are kept at any length.
    /// A write also refuses text containing a ZIP end-record signature, "PK" followed by U+0005 U+0006,
    /// U+0006 U+0006 or U+0006 U+0007 (the bytes 50 4B 05 06, 50 4B 06 06, 50 4B 06 07): readers would take it
    /// for the archive's end and list the archive as empty. An app can check text before saving with these
    /// two rules, the length in `utf8.count` and the three sequences.
    public static let maximumWritableLength = 16_000

    /// The comment exactly as stored, with no decoding. A save that keeps the comment writes these bytes.
    public let bytes: [UInt8]
    /// `bytes` decoded for display: valid UTF-8 as UTF-8, as stored (a leading BOM removed, no normalization);
    /// anything else with the reader's `nameEncoding` when it is `.specific`, else its `legacyNameEncoding`, else
    /// code page 437, read like the names (NFC). Bytes invalid in the chosen encoding fall back to code page 437.
    public let text: String
    /// True when Kernir can change this comment: the archive's format has `ArchiveFormat.supportsComments`
    /// and the archive is a single file (not a multi-volume set).
    public let isWritable: Bool

    public init(bytes: [UInt8], text: String, isWritable: Bool) {
        self.bytes = bytes
        self.text = text
        self.isWritable = isWritable
    }
}

public enum Archive {
    /// Opens and lists an archive. Throws `.passwordRequired` when headers are encrypted
    /// and no password was given (a 7z with encrypted data but plain headers lists without one; its
    /// entries are `isEncrypted` and extracting them throws `.passwordRequired`. The exception is a 7z
    /// that stores a symlink in an encrypted folder: listing reads the link's target from that folder,
    /// so it throws `.passwordRequired` too).
    /// With a password and encrypted entries, open verifies it and throws `.wrongPassword` when it is
    /// wrong: zip checks libarchive's per-entry check value. A 7z with an encrypted header (7-Zip's
    /// "Encrypt file names", and every 7z Kernir writes with `.aes256`) is verified by that header, which
    /// decrypts, decodes and passes its CRC only with the right password; open reads no data, so data
    /// damage surfaces at extract as `.corrupted` (except in a folder holding a symlink: listing decodes
    /// it, so damage there throws `.corrupted` from open). A damaged encrypted header answers `.wrongPassword`
    /// too: its bytes cannot tell damage from a wrong password. A 7z with plain headers and encrypted data
    /// has no check value, so open decodes its first encrypted non-empty entry to its end or 1 MiB of
    /// output, and a CRC or decompression failure in that decode is `.wrongPassword`. The decode includes
    /// the decoder's read-ahead past the entry's end: in a solid LZMA/LZMA2 folder, damage in roughly the
    /// next 64 KiB of packed data after it is `.wrongPassword` as well. A wrong password is caught only by
    /// that decode: past 1 MiB of a stored entry it can go unnoticed; extracting then fails `.corrupted` at
    /// the entry's CRC and keeps no output. After open succeeds, data failures are `.corrupted`.
    ///
    /// Multi-volume sets (`x.part1.rar` ..., old-style `x.rar` + `x.r00` ..., `x.7z.001` ..., `x.zip.001` ...,
    /// spanned `x.z01` ... `x.zip`): opening any part reads the whole set. `url` stays the opened part,
    /// `volumeURLs` lists every part in read order, and listing, extraction and previews read them all.
    /// A part that is missing or cannot be opened when the set is resolved throws `ArchiveVolumeError`
    /// before anything is read (one that vanishes or turns unreadable after that, during open, throws
    /// `ArchiveError`, usually `.io`); a part changed after open fails extraction with
    /// `.io("archive changed on disk")`. A set is read-only: `ArchiveWriter` refuses to write over any of
    /// its parts, and Save As to another file works. A file only named
    /// like a part (a plain RAR without the volume flag, a one-disk `x.zip`) opens on its own.
    ///
    /// An archive whose entry names are too long or nest folders too deeply throws `ArchiveNestingError` (see
    /// `ArchiveNestingError.Limit`) before any folder is synthesized. As each header is read, before its names are
    /// decoded, header number 4,000,001, a stored name or link target over 64 KiB, or over 256 MiB of them in all (512
    /// bytes per header once that is more), stops the read (a 7z, whose header holds every entry at once, is held to
    /// the same limits inside libarchive, an encrypted header included, except that its names may take 512 MiB of
    /// UTF-16 at most, whatever count it claims; so is a xar, whose TOC holds every entry and also may not nest more
    /// than 200 deep, and so is a zip's central directory, which the seekable reader reads whole, with the same
    /// errors).
    /// Once every header is read: a name or link target with more than 30 combining marks in a row, a normalized path
    /// or hardlink target over 16 KiB, a path of more than 200 components, or too many folder path bytes in all.
    public static func open(at url: URL, password: String? = nil) async throws -> any ArchiveReading {
        try await open(at: url, password: password, nameEncoding: .automatic)
    }

    /// Like `open(at:password:)`, decoding names stored without a declared encoding (e.g. legacy zip, tar, RAR4 OEM) as
    /// `nameEncoding` asks: `.automatic` picks one encoding from all of them, `.specific` uses that one (one of `choices`;
    /// other encodings are not supported). Declared
    /// names (7z, RAR5, xar, RAR4 names flagged Unicode, zip with the UTF-8 flag or a Unicode Path field) are never reinterpreted.
    /// Extraction and saves from the returned reader use the same decoding.
    public static func open(at url: URL, password: String? = nil,
                            nameEncoding: ArchiveNameEncoding) async throws -> any ArchiveReading {
        try await LibArchiveReader.open(at: url, password: password, nameEncoding: nameEncoding)
    }

    /// Detects the format from content (not just extension). nil when not an archive. Any part of a
    /// multi-volume set detects as the set's format (the whole set is read, as in `open`); with a part
    /// missing, the given file is read alone, and a later part alone usually detects as nil.
    public static func detectFormat(at url: URL) -> ArchiveFormat? {
        LibArchiveReader.detectFormat(at: url)
    }

    /// Builds the folder tree from a flat entry list, folders first, then by name (Finder order).
    /// A folder's `totalSize` is nil when a size below it is unknown or when the sizes below it add up past Int64.
    public static func tree(from entries: [ArchiveEntry]) -> [ArchiveNode] {
        ArchiveTreeBuilder.build(entries)
    }

    /// Finder metadata entries that belong to `paths`: for a path `d/n`, `__MACOSX/d/n` (with everything
    /// beneath it), `d/._n` and `__MACOSX/d/._n`. Only paths present in `entries` are returned. Only the root
    /// `__MACOSX` holds companions; a nested `__MACOSX` is metadata but pairs with nothing. The writer
    /// never removes companions on its own; pass them along with the removed paths.
    public static func macOSCompanions(of paths: [String], in entries: [ArchiveEntry]) -> Set<String> {
        MacOSMetadata.companions(of: paths, in: entries)
    }
}

// MARK: - Writing

/// Pending edits applied on save.
public struct ArchiveChangeSet: Sendable, Equatable {
    public struct Addition: Sendable, Equatable {
        /// File or folder on disk (folders are added recursively).
        public var sourceURL: URL
        /// Directory inside the archive to place it in, "" for top level. A final path: it already
        /// reflects `renamedPaths`.
        public var destinationDirectory: String
        /// Name of the added item inside the archive; nil uses `sourceURL.lastPathComponent`. Lets a
        /// pending addition (a staged empty folder from New Folder, say) be renamed without copying files.
        /// A folder's contents keep their own names beneath it. An empty name, one containing `/` or NUL, `.`
        /// or `..` makes the write throw `.io` and write nothing (the same rules as a `renamedPaths` value).
        /// The `.DS_Store` skip and `excludesMacMetadata`'s on-disk name check go by the name on disk; with
        /// `excludesMacMetadata`, a name that makes the item Mac metadata (`._x`, say) drops it as well.
        public var archiveName: String?

        public init(sourceURL: URL, destinationDirectory: String, archiveName: String? = nil) {
            self.sourceURL = sourceURL
            self.destinationDirectory = destinationDirectory
            self.archiveName = archiveName
        }
    }

    /// A change to the archive-level comment (see `ArchiveComment`).
    public enum CommentChange: Sendable, Equatable {
        /// Leaves the comment alone: a save keeps the source's comment bytes where the output format can
        /// hold one (`ArchiveFormat.supportsComments`), and a new archive has none. A ZIP save also keeps every
        /// kept entry's own comment, whatever this is.
        case keep
        /// Replaces the comment with this text, written as UTF-8 (no BOM, no normalization). Empty text removes
        /// the comment, exactly like `.remove`. Other text longer than `ArchiveComment.maximumWritableLength`
        /// UTF-8 bytes, text holding a ZIP end-record signature (see `maximumWritableLength`), or text on a format
        /// without `supportsComments`, makes the write throw `.io` and write nothing. The `.io` message is
        /// short and can be shown as is ("The comment contains bytes a ZIP archive cannot hold").
        case set(String)
        /// Removes the comment. On a format without `supportsComments` it changes nothing.
        case remove
    }

    /// Entry paths to drop (directories drop their contents). Source paths, matched against each entry's
    /// source path, with one exception for entries renamed out of a removed folder: an entry beneath a
    /// removed path P is kept when the `renamedPaths` key that governs it (the longest key at or above the
    /// entry) lies strictly beneath P and the key's own final path is not at or beneath P's final path
    /// (renames applied); P's own entry and the rest of its subtree are still dropped. So a file moved out of
    /// a folder survives the folder's removal, while a removed entry that is also renamed (its key at or
    /// above P) is dropped. With several removed paths at or above an entry, the key must lie strictly
    /// beneath each of them and its final path must not be at or beneath any of their final paths; a key
    /// whose final path lies strictly beneath the final path of any other removed path (moved into a removed
    /// folder) drops its entries as well. Landing exactly on a removed path's final path takes a freed name.
    /// The key's final path decides for its whole subtree, so a folder kept this way keeps everything
    /// beneath it, even where that lands beneath a removed path's final path (a folder moved onto a freed
    /// removed name, or onto an ancestor of one); the removed path's own entries are dropped. This is
    /// asymmetric: a plain rename from outside any removed path into a removed folder's final path keeps its
    /// entries, while an escaping key whose final path lies strictly beneath a removed final path is dropped
    /// with its subtree. Entries kept
    /// this way go through the same final-path checks as every kept entry (see `renamedPaths`).
    public var removedPaths: Set<String> = []
    public var additions: [Addition] = []
    /// Source entry path → its new full path in the output. Applied as a prefix map: an entry whose path,
    /// or nearest ancestor, is a key goes out under the new prefix, so renaming a folder moves everything
    /// beneath it, including entries under a folder the archive never stored as its own entry (a deeper key
    /// wins for its own subtree). Kept entries keep their data, dates, permissions, encryption and zip entry
    /// comments (the data is decoded and re-encoded, as on every save); a renamed name is stored as UTF-8
    /// (zip: with the UTF-8 flag, untouched legacy names keep their bytes; tar: a new name that is not ASCII
    /// writes every name of that save as UTF-8). Symlink targets are text and are not rewritten.
    /// Final paths are compared exactly, after NFC normalization like every entry path: names that differ
    /// only in case (`Readme` and `README`) are different paths and both allowed, while NFC and NFD spellings
    /// of one name are the same path. Only kept entries count, so two entries may trade names. The write
    /// throws `.io` and writes nothing when two kept entries would land on one final path, when a key's new
    /// path (or a path beneath it) is already held by a kept entry outside the key (a folder renamed onto
    /// another folder, even one the archive stores only implicitly), when an entry would land beneath a kept
    /// file, or when a value lies inside its own key. An addition at a kept entry's final path replaces it,
    /// as it replaces an entry at its own path. A value that is empty or has an empty, `.` or `..` component
    /// (a leading or trailing `/` included), or contains NUL, makes the write throw `.io` and write nothing.
    /// A key that names no entry of the source (as listed, implicit folders included; any key when there is
    /// no source) makes the write throw `.entryNotFound(key)` and write nothing. A key mapped to itself
    /// changes nothing. With `ArchiveWriteOptions.excludesMacMetadata`, an entry whose source or final path is
    /// Mac metadata is dropped.
    public var renamedPaths: [String: String] = [:]
    /// What happens to the archive comment; `.keep` by default.
    public var comment: CommentChange = .keep

    public init(removedPaths: Set<String> = [], additions: [Addition] = [],
                renamedPaths: [String: String] = [:], comment: CommentChange = .keep) {
        self.removedPaths = removedPaths
        self.additions = additions
        self.renamedPaths = renamedPaths
        self.comment = comment
    }

    /// True when the set changes nothing: no removals, additions or renames, and the comment is kept.
    public var isEmpty: Bool {
        removedPaths.isEmpty && additions.isEmpty && renamedPaths.isEmpty && comment == .keep
    }
}

public enum ArchiveWriter {
    /// Writes a new archive to `destination`: kept entries of `source` (if any) streamed
    /// as-is, minus removals, plus additions. The temporary output is created in FileManager's
    /// `itemReplacementDirectory` for the destination's volume and moved into place with
    /// `replaceItemAt`, so a failure never damages an existing file.
    /// A multi-volume set is read-only: a `destination` that is one of the source's `volumeURLs` (the
    /// same file through any symlink, hard link or spelling, or a part's path after the part is gone)
    /// throws `.readOnlyFormat(source.format)` before anything is written. Saving the set to another
    /// file (Save As) works like any other source.
    /// A non-nil `password` encrypts with AES-256; use the `options` overload for other schemes.
    public static func write(
        source: (any ArchiveReading)?,
        changes: ArchiveChangeSet,
        format: ArchiveFormat,
        to destination: URL,
        password: String? = nil,
        progress: ArchiveProgressHandler? = nil
    ) async throws {
        let options = password.map { ArchiveWriteOptions(encryption: .aes256, password: $0) }
        try await write(source: source, changes: changes, format: format, to: destination,
                        options: options, progress: progress)
    }

    /// Like the password overload, with explicit settings; nil `options` keeps the source's
    /// method and encryption (a plain save). Throws on explicit settings the format cannot honor.
    /// With nil `options`, an encrypted source converted to a format that cannot carry its scheme
    /// is upgraded to AES-256 when that format offers it (a ZipCrypto or AES-128 zip converted to 7z
    /// becomes a 7z `.aes256`), and is written unencrypted only when the format has no encryption
    /// (tar, for example); pass explicit options to be told instead. An encrypted result uses the
    /// source's password: a source opened without one throws `.passwordRequired` and writes nothing.
    /// A same-format save never drops encryption: if the format cannot carry the source's encryption
    /// (no writable format today; 7z keeps AES-256), it throws `unsupportedEncryption(format)` and
    /// writes nothing. A 7z written with `.aes256` always has an encrypted header (see
    /// `ArchiveFormat.supportedEncryptions`), so a plain save of a 7z whose names were readable without
    /// the password (encrypted data, plain headers) hides them.
    /// A non-nil `options.volumeSize` throws `.notImplemented`: one file cannot hold volumes, use
    /// `writeVolumes`.
    public static func write(
        source: (any ArchiveReading)?,
        changes: ArchiveChangeSet,
        format: ArchiveFormat,
        to destination: URL,
        options: ArchiveWriteOptions?,
        progress: ArchiveProgressHandler? = nil
    ) async throws {
        if options?.volumeSize != nil { throw ArchiveError.notImplemented }
        try LibArchiveWriter.refuseVolumePart(destination, of: source)
        // The password stays off the protocol: only Kernir's own reader carries it.
        let resolved = try ResolvedWriteOptions.resolve(
            options, format: format, sourceFormat: source?.format,
            sourceEncryption: source?.encryption ?? .none,
            sourceMethod: source?.compressionMethod, sourcePassword: (source as? LibArchiveReader)?.password)
        try await LibArchiveWriter.write(source: source, changes: changes, format: format,
                                         to: destination, options: resolved, progress: progress)
    }

    /// Writes the archive `write(options:)` would write, split into volumes of `options.volumeSize` bytes,
    /// directly into `directory`, and returns the volume URLs in order. The volumes are named
    /// `<baseName>.<format.fileExtension>.001`, `.002` … (a byte split, as 7-Zip's `-v` writes it; Kernir's
    /// reader opens the set); every volume but the last is exactly `volumeSize` bytes. A result that fits
    /// in one volume, or a nil `volumeSize`, is a single plain `<baseName>.<format.fileExtension>`.
    ///
    /// `directory` is an existing, empty folder the caller created (typically a temporary folder in the
    /// item-replacement directory for the save destination's volume). The engine writes only the volume
    /// files into it, in place; it never creates, moves or replaces `directory` or anything at the save
    /// destination: moving the finished folder into place is the caller's job. On any failure or
    /// cancellation the engine deletes the volume files it wrote and leaves `directory` itself in place.
    ///
    /// Refusals, all before anything is written unless noted. `ArchiveError` has no dedicated cases for them
    /// (the app validates against the constants first and shows its own text); the volume limit, which the app
    /// cannot check ahead because the archive's size is known only while writing, throws its own
    /// `ArchiveVolumeLimitError` instead:
    /// - `.unsupportedFormat`: the format lacks `ArchiveFormat.supportsVolumes` (only ZIP and 7z have it).
    ///   Apps gate on `supportsVolumes`, so a user never sees this case.
    /// - `.io`: `directory` does not exist, is not a folder, or is not empty (hidden items count).
    /// - `.io`: a file of the source (any of its `volumeURLs`) is inside `directory`.
    /// - `.io`: `volumeSize` is below `ArchiveWriteOptions.minimumVolumeSize`.
    /// - `.io`: `baseName` is empty or holds a `/` or a NUL.
    /// - `ArchiveVolumeLimitError` (not an `ArchiveError`), with `maximum` =
    ///   `ArchiveWriteOptions.maximumVolumeCount`: the archive needs more volumes than that. Found while
    ///   writing; the volumes written so far are deleted and `directory` is left in place, empty.
    ///
    /// A ZIP split this way opens in 7-Zip, Keka and Kernir, not in Archive Utility or Windows Explorer until
    /// joined. A split set gets no archive comment: `changes.comment` `.keep` drops the source's (kept entries
    /// keep their own comments), and any other value throws `.io`. Source, changes and the other options behave
    /// as `write` does with these explicit options; unlike `write`, there is no nil-options mode that keeps or
    /// upgrades the source's encryption and method on a conversion. Progress is reported as `write` reports it,
    /// 1.0 once the volumes are complete.
    ///
    /// `options.excludesMacMetadata` leaves Mac metadata out of the set exactly as it does in `write`.
    @discardableResult
    public static func writeVolumes(
        source: (any ArchiveReading)?,
        changes: ArchiveChangeSet,
        format: ArchiveFormat,
        into directory: URL,
        baseName: String,
        options: ArchiveWriteOptions,
        progress: ArchiveProgressHandler? = nil
    ) async throws -> [URL] {
        try VolumeFolderChecks.refuse(source: source, format: format, directory: directory, options: options)
        // The password stays off the protocol: only Kernir's own reader carries it.
        let resolved = try ResolvedWriteOptions.resolve(
            options, format: format, sourceFormat: source?.format,
            sourceEncryption: source?.encryption ?? .none,
            sourceMethod: source?.compressionMethod, sourcePassword: (source as? LibArchiveReader)?.password)
        return try VolumeWriter.write(source: source, changes: changes, format: format, into: directory,
                                      baseName: baseName, options: resolved, volumeSize: options.volumeSize,
                                      progress: progress)
    }
}

// MARK: - Write options

/// Compression method inside an archive.
public enum ArchiveCompressionMethod: String, CaseIterable, Sendable, Codable {
    case store, deflate, bzip2, lzma, lzma2, ppmd

    /// Human-readable name, e.g. "Deflate", "LZMA2".
    public var displayName: String {
        switch self {
        case .store: "Store"
        case .deflate: "Deflate"
        case .bzip2: "BZip2"
        case .lzma: "LZMA"
        case .lzma2: "LZMA2"
        case .ppmd: "PPMd"
        }
    }
}

/// Encryption scheme applied to archive entries.
public enum ArchiveEncryption: String, CaseIterable, Sendable, Codable {
    /// No encryption.
    case none
    /// Legacy ZIP encryption; weak, offered for compatibility only.
    case zipCrypto
    /// AES with a 128-bit key.
    case aes128
    /// AES with a 256-bit key.
    case aes256

    /// Human-readable name, e.g. "AES-256".
    public var displayName: String {
        switch self {
        case .none: "None"
        case .zipCrypto: "ZipCrypto"
        case .aes128: "AES-128"
        case .aes256: "AES-256"
        }
    }

    /// True for schemes that are cryptographically weak (only ZipCrypto).
    public var isWeak: Bool { self == .zipCrypto }
}

extension ArchiveFormat {
    /// Compression methods the writer offers, default first; empty when the format has no choice.
    public var supportedMethods: [ArchiveCompressionMethod] {
        switch self {
        case .zip: [.deflate, .store]
        case .sevenZip: [.lzma2, .lzma, .bzip2, .deflate, .ppmd, .store]
        default: []
        }
    }

    /// Method used when none is chosen; nil when the format has no method choice.
    public var defaultMethod: ArchiveCompressionMethod? { supportedMethods.first }

    /// Valid compression levels; nil when the format has no level control.
    public var compressionLevelRange: ClosedRange<Int>? {
        switch self {
        case .zip, .sevenZip, .tarXz: 0...9
        case .tarGzip, .tarBzip2: 1...9
        default: nil
        }
    }

    /// Level used when none is chosen; nil when the format has no level control.
    public var defaultCompressionLevel: Int? {
        switch self {
        case .zip, .sevenZip, .tarGzip, .tarXz: 6
        case .tarBzip2: 9
        default: nil
        }
    }

    /// Encryption schemes the writer offers; empty for read-only formats. 7z `.aes256` always encrypts
    /// the header as well (7-Zip's "Encrypt file names"; there is no switch), so entry names are hidden:
    /// a 7z Kernir writes encrypted needs the password just to list (`Archive.open` and
    /// `Archive.previewListing` throw `.passwordRequired` without it). That includes a nil-options save
    /// of a 7z with encrypted data but plain headers, which comes out header-encrypted.
    public var supportedEncryptions: [ArchiveEncryption] {
        switch self {
        case .zip: [.none, .aes256, .aes128, .zipCrypto]
        case .sevenZip: [.none, .aes256]
        case .tar, .tarGzip, .tarBzip2, .tarXz: [.none]
        default: []
        }
    }

    /// The encryption a nil-options write into this format gives a source encrypted with `source`:
    /// `source` when the format carries it, else AES-256 when the format offers that (a ZipCrypto or
    /// AES-128 zip converted to 7z); nil when it can carry neither, where a nil-options write refuses
    /// (same format) or drops the encryption (another format; tar, say). An app that passes explicit
    /// options for a plain save uses this to convert as nil options would.
    public func encryption(carrying source: ArchiveEncryption) -> ArchiveEncryption? {
        if supportedEncryptions.contains(source) { return source }
        if source != .none, supportedEncryptions.contains(.aes256) { return .aes256 }
        return nil
    }

    /// Whether the writer offers a solid-archive switch (none does yet).
    public var supportsSolid: Bool { false }

    /// Whether the writer can split this format into volumes (`ArchiveWriter.writeVolumes`): ZIP and 7z.
    public var supportsVolumes: Bool {
        switch self {
        case .zip, .sevenZip: true
        default: false
        }
    }

    /// Whether the format has an archive comment Kernir can write (`ArchiveChangeSet.comment`): ZIP only.
    public var supportsComments: Bool { self == .zip }
}

/// Settings for writing an archive; nil fields mean the format's default.
public struct ArchiveWriteOptions: Sendable, Equatable {
    /// nil uses the format default; an unsupported method falls back to the default.
    public var method: ArchiveCompressionMethod?
    /// nil uses the default; clamped to `compressionLevelRange`.
    public var compressionLevel: Int?
    /// Encryption scheme; must be in the format's `supportedEncryptions`. For 7z, `.aes256` encrypts the
    /// header too, hiding entry names (see `ArchiveFormat.supportedEncryptions`).
    public var encryption: ArchiveEncryption
    /// Required unless `encryption` is `.none`; ignored in that case.
    public var password: String?
    /// nil uses the default; ignored when the format does not support solid archives.
    public var solid: Bool?
    /// When true, the write leaves out Finder metadata: additions skip `._*` files and `__MACOSX` folders
    /// (with their contents) as well as `.DS_Store` (always skipped), matched by their names on disk at any
    /// depth, and kept source entries that are `ArchiveEntry.isMacOSMetadata` or named `.DS_Store` are dropped,
    /// together with anything stored beneath such an entry. An addition that would land at such a path (inside
    /// a `__MACOSX` folder of the archive, at any depth, say) is left out too. A `__MACOSX` folder nested inside a
    /// source archive is metadata like the root one, with everything in it. Folders are never generated for
    /// what is left: a folder the source only implied, holding nothing but dropped entries, is gone. False (the
    /// default) keeps today's behavior: source metadata entries are copied as they are, and a nil-options plain
    /// save never drops them. Nothing is ever generated: no AppleDouble files, resource forks or extended
    /// attributes. `write` and `writeVolumes` apply it the same way. On macOS, Foundation never lists `._*` files
    /// inside an added folder, so those are left out whatever the flag; only a `._*` file added on its own needs it.
    /// The flag takes effect only through explicit options: a write with nil options resolves its settings from the
    /// source and never strips, so an app that has the toggle on must pass explicit options (carrying the source's
    /// method, encryption and password) for a plain save too.
    public var excludesMacMetadata: Bool
    /// Bytes per volume for a split write (`ArchiveWriter.writeVolumes`, formats with
    /// `ArchiveFormat.supportsVolumes`); nil (the default) writes one file. The single-file
    /// `ArchiveWriter.write` throws when it is set. At least `minimumVolumeSize`; a smaller value, zero or
    /// a negative one makes `writeVolumes` throw `.io`.
    public var volumeSize: Int64?

    /// Smallest `volumeSize` a split write accepts: 1 MB in decimal units (1 000 000 bytes), so a size the
    /// app shows as "1 MB" is accepted whether it counts in decimal (Finder) or binary units.
    public static let minimumVolumeSize: Int64 = 1_000_000
    /// Most volumes a split write produces (three-digit `.001` … `.999` names); more throws
    /// `ArchiveVolumeLimitError` from `ArchiveWriter.writeVolumes`.
    public static let maximumVolumeCount = 999

    /// Creates options; every parameter is optional and defaults to "format default".
    public init(method: ArchiveCompressionMethod? = nil, compressionLevel: Int? = nil,
                encryption: ArchiveEncryption = .none, password: String? = nil, solid: Bool? = nil,
                excludesMacMetadata: Bool = false, volumeSize: Int64? = nil) {
        self.method = method
        self.compressionLevel = compressionLevel
        self.encryption = encryption
        self.password = password
        self.solid = solid
        self.excludesMacMetadata = excludesMacMetadata
        self.volumeSize = volumeSize
    }
}

// MARK: - Preview data

/// Static sample for SwiftUI previews and UI work before the engine lands.
public struct SampleArchive: ArchiveReading {
    public let url = URL(fileURLWithPath: "/tmp/project.zip")
    public let format: ArchiveFormat = .zip
    public let isEncrypted = false
    public let entries: [ArchiveEntry]

    public init() {
        let d = Date(timeIntervalSince1970: 1_794_000_000)
        entries = [
            .init(path: "src", isDirectory: true, size: nil, compressedSize: nil, modificationDate: d),
            .init(path: "src/main.swift", isDirectory: false, size: 4_096, compressedSize: 1_500, modificationDate: d),
            .init(path: "src/utils.swift", isDirectory: false, size: 2_048, compressedSize: 800, modificationDate: d),
            .init(path: "assets", isDirectory: true, size: nil, compressedSize: nil, modificationDate: d),
            .init(path: "assets/cover.png", isDirectory: false, size: 1_200_000, compressedSize: 1_150_000, modificationDate: d),
            .init(path: "brief.pdf", isDirectory: false, size: 340_000, compressedSize: 300_000, modificationDate: d),
            .init(path: "README.md", isDirectory: false, size: 1_024, compressedSize: 500, modificationDate: d),
        ]
    }

    public func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        throw ArchiveError.notImplemented
    }

    public func extractToTemporaryFile(_ path: String) async throws -> URL {
        throw ArchiveError.notImplemented
    }
}
