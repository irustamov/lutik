import CLibArchive
import Foundation

/// How one reader decodes entry names, decided once by the listing pass and handed to every later session
/// (extraction, repack, link targets), so no pass detects again and every pass agrees with the listing.
struct NameDecoding: Sendable, Equatable {
    let requested: ArchiveNameEncoding
    /// The encoding of the undeclared non-ASCII names; nil when the archive has none.
    let legacy: String.Encoding?
    var hasLegacyNames: Bool { legacy != nil }

    init(requested: ArchiveNameEncoding, legacy: String.Encoding?) {
        self.requested = requested
        self.legacy = legacy
    }

    /// `undeclaredNames`: the raw bytes of every undeclared non-ASCII name of the archive (paths and link
    /// targets). The manual choice when there is one, else `NameEncodingDetector.detect` over all of them.
    init(requested: ArchiveNameEncoding, undeclaredNames: [[UInt8]]) {
        self.requested = requested
        if undeclaredNames.isEmpty {
            legacy = nil
        } else if case .specific(let encoding) = requested {
            legacy = encoding
        } else {
            legacy = NameEncodingDetector.detect(undeclaredNames)
        }
    }
}

/// Decodes entry names. A name is declared when the format stores it as Unicode (7z, RAR5, xar; zip with bit 11
/// or an Info-ZIP Unicode Path field libarchive used; a RAR4 name libarchive took as Unicode, FHD_UNICODE):
/// libarchive's UTF-8 reading is kept. Undeclared ASCII names pass through. Undeclared non-ASCII names decode with
/// the archive's one `NameDecoding.legacy`. Results are NFC (`EntryPath.nfc`).
enum EntryNameDecoder {
    /// A name read from a header, before or after the archive's legacy encoding is known.
    enum ListedName: Equatable {
        /// Declared, or undeclared ASCII: final already.
        case known(String)
        /// Undeclared and not all ASCII: the raw bytes, decoded with `NameDecoding.legacy`.
        case legacy([UInt8])

        var legacyBytes: [UInt8]? {
            if case .legacy(let bytes) = self { return bytes }
            return nil
        }

        func resolve(_ d: NameDecoding) -> String {
            switch self {
            case .known(let s): return s
            case .legacy(let bytes):
                // A listed archive always has `legacy` here; the one-name guess covers a header no listing saw.
                guard let encoding = d.legacy else { return EntryNameDecoder.decode(bytes) }
                return NameEncodingDetector.decode(bytes, as: encoding)
            }
        }
    }

    // MARK: Per archive

    /// The decoded (NFC) entry name, not normalized and with any trailing "/" kept: the caller applies
    /// `EntryPath.normalize` and uses the raw "/" to detect directories. Nil when the header has no name.
    static func pathname(of entry: OpaquePointer, in session: ReadSession, using d: NameDecoding) -> String? {
        listedPathname(of: entry, in: session)?.resolve(d)
    }

    /// The hardlink target name, decoded like `pathname`. Nil when the entry is not a hardlink.
    static func hardlinkTarget(of entry: OpaquePointer, in session: ReadSession, using d: NameDecoding) -> String? {
        listedHardlinkTarget(of: entry, in: session)?.resolve(d)
    }

    /// The hardlink target as an entry path (decoded, then `EntryPath.normalize`). The listing and every
    /// extraction pass use this one function, so a link resolves to the same key `open` recorded.
    static func normalizedHardlinkTarget(of entry: OpaquePointer, in session: ReadSession,
                                         using d: NameDecoding) -> String? {
        hardlinkTarget(of: entry, in: session, using: d).flatMap(EntryPath.normalize)
    }

    /// The symlink target, decoded like `pathname` but not normalized. Nil when the entry has none.
    static func symlinkTarget(of entry: OpaquePointer, in session: ReadSession, using d: NameDecoding) -> String? {
        listedSymlinkTarget(of: entry, in: session)?.resolve(d)
    }

    /// The symlink target to write to disk instead of the header's own bytes: the decoded target when it is
    /// stored in a legacy code page, nil when the header's target is already Unicode or ASCII.
    static func legacySymlinkTarget(of entry: OpaquePointer, in session: ReadSession,
                                    using d: NameDecoding) -> String? {
        guard let listed = listedSymlinkTarget(of: entry, in: session), listed.legacyBytes != nil else { return nil }
        return listed.resolve(d)
    }

    /// The repack guard: a header's stored name bytes may be written back only when its decoded name `decoded` is
    /// exactly its listed `path` (or `path` + "/" for a folder). A "./", "//", ".." or leading "/" spelling fails,
    /// so the save writes the normalized path instead. The listing and the repack copy both use this one rule.
    /// Compares bytes: both sides are NFC already (`EntryPath.nfc`), and String == would put marks in canonical
    /// order again, in time quadratic in a run of them.
    static func readsAsPath(_ decoded: String, path: String, isDirectory: Bool) -> Bool {
        let d = decoded.utf8
        let p = path.utf8
        if d.elementsEqual(p) { return true }
        return isDirectory && d.count == p.count + 1 && d.last == UInt8(ascii: "/") && d.dropLast().elementsEqual(p)
    }

    /// The stored byte counts of the current header's name, hardlink target and symlink target (0 when absent), the
    /// longer of the raw and UTF-8 readings: what the listing would hold. Read before any decoding or NFC, so the
    /// walk can refuse a name past `NestingLimits.maxRawNameBytes` before it costs more than its own bytes.
    static func storedLengths(of entry: OpaquePointer) -> (name: Int, hardlink: Int, symlink: Int) {
        func length(_ utf8: UnsafePointer<CChar>?, _ raw: UnsafePointer<CChar>?) -> Int {
            max(utf8.map { strlen($0) } ?? 0, raw.map { strlen($0) } ?? 0)
        }
        return withUTF8CType {
            (length(archive_entry_pathname_utf8(entry), archive_entry_pathname(entry)),
             length(archive_entry_hardlink_utf8(entry), archive_entry_hardlink(entry)),
             length(archive_entry_symlink_utf8(entry), archive_entry_symlink(entry)))
        }
    }

    /// Raw stored bytes and whether they were declared Unicode, for the listing pass and RepackCopier.
    static func rawName(of entry: OpaquePointer, in session: ReadSession) -> (bytes: [UInt8], declared: Bool) {
        withUTF8CType {
            let raw = bytes(archive_entry_pathname(entry))
            return (raw ?? [], isDeclared(session))
        }
    }

    /// The raw name bytes a save may write verbatim: undeclared and non-empty. The one definition shared by the
    /// listing (`inexactStoredNames`) and RepackCopier, so both agree on which names can be stored.
    static func storableRawName(of entry: OpaquePointer, in session: ReadSession) -> [UInt8]? {
        let raw = rawName(of: entry, in: session)
        return !raw.declared && !raw.bytes.isEmpty ? raw.bytes : nil
    }

    /// The current header's name before the legacy encoding is known. Nil when the header has none.
    static func listedPathname(of entry: OpaquePointer, in session: ReadSession) -> ListedName? {
        withUTF8CType {
            listed(utf8: archive_entry_pathname_utf8(entry), raw: archive_entry_pathname(entry), in: session)
        }
    }

    static func listedHardlinkTarget(of entry: OpaquePointer, in session: ReadSession) -> ListedName? {
        withUTF8CType {
            listed(utf8: archive_entry_hardlink_utf8(entry), raw: archive_entry_hardlink(entry), in: session)
        }
    }

    static func listedSymlinkTarget(of entry: OpaquePointer, in session: ReadSession) -> ListedName? {
        withUTF8CType {
            listed(utf8: archive_entry_symlink_utf8(entry), raw: archive_entry_symlink(entry), in: session)
        }
    }

    /// 7z, RAR5 and xar store Unicode names; zip declares them per entry (patch 0009), and so does RAR4
    /// (FHD_UNICODE), which patch 0010 reports: `ReadSession.rarNameDeclared` holds the reader's word, taken right
    /// after the header read. Only that word declares a RAR4 name; an OEM name whose bytes happen to be valid
    /// UTF-8 stays undeclared. Valid for the session's current header only.
    private static func isDeclared(_ session: ReadSession) -> Bool {
        switch session.formatCode & Int32(ARCHIVE_FORMAT_BASE_MASK) {
        case Int32(ARCHIVE_FORMAT_7ZIP), Int32(ARCHIVE_FORMAT_RAR_V5), Int32(ARCHIVE_FORMAT_XAR): return true
        case Int32(ARCHIVE_FORMAT_ZIP): return kernir_read_zip_entry_name_declared(session.handle) == 1
        case Int32(ARCHIVE_FORMAT_RAR): return session.rarNameDeclared
        default: return false
        }
    }

    /// A declared name keeps libarchive's UTF-8 reading; one libarchive could not convert (not valid UTF-8 despite
    /// the declaration) is treated like an undeclared one.
    private static func listed(utf8: UnsafePointer<CChar>?, raw: UnsafePointer<CChar>?,
                               in session: ReadSession) -> ListedName? {
        let rawBytes = bytes(raw)
        if isDeclared(session), let utf8 {
            return .known(EntryPath.nfc(String(cString: utf8)))
        }
        guard let bytes = rawBytes else {
            return utf8.map { .known(EntryPath.nfc(String(cString: $0))) }
        }
        if bytes.allSatisfy({ $0 < 0x80 }) { return .known(String(decoding: bytes, as: UTF8.self)) }
        return .legacy(bytes)
    }

    private static func bytes(_ p: UnsafePointer<CChar>?) -> [UInt8]? {
        guard let p else { return nil }
        return Array(UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self),
                                         count: strlen(p)))
    }

    // MARK: One name at a time (no archive context)

    /// `archive_entry_pathname_utf8` when available, otherwise the raw bytes run through `decode`.
    static func pathname(of entry: OpaquePointer) -> String? {
        withUTF8CType { decodeName(utf8: archive_entry_pathname_utf8(entry), raw: archive_entry_pathname(entry)) }
    }

    /// The hardlink target, decoded like `pathname(of:)`, then `EntryPath.normalize`.
    static func normalizedHardlinkTarget(of entry: OpaquePointer) -> String? {
        withUTF8CType { decodeName(utf8: archive_entry_hardlink_utf8(entry), raw: archive_entry_hardlink(entry)) }
            .flatMap(EntryPath.normalize)
    }

    private static func decodeName(utf8: UnsafePointer<CChar>?, raw: UnsafePointer<CChar>?) -> String? {
        if let utf8 { return EntryPath.nfc(String(cString: utf8)) }
        return bytes(raw).map(decode)
    }

    /// One name as a one-name archive: `NameEncodingDetector.detect([bytes])`, then decoded with it. NFC.
    static func decode(_ bytes: [UInt8]) -> String {
        NameEncodingDetector.decode(bytes, as: NameEncodingDetector.detect([bytes]))
    }
}
