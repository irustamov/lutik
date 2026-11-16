import Foundation
import CLibArchive

/// Owns one libarchive read handle. Not thread-safe: use from one task at a time.
final class ReadSession {
    private let a: OpaquePointer
    let hasPassphrase: Bool
    /// The files read, in order: one, or every part of a multi-volume set.
    let urls: [URL]
    var handle: OpaquePointer { a }

    convenience init(url: URL, password: String?) throws(ArchiveError) {
        try self.init(urls: [url], password: password)
    }

    /// Reads `urls` as one stream, in order (the parts of a multi-volume set; libarchive switches files
    /// at each part's end and seeks across them). One URL opens that file alone. `limits` are the entry count and
    /// name total libarchive's 7z and xar readers hold a whole header or TOC to (patch 0016), and its seekable zip
    /// reader a central directory (patch 0022), the same ones the listing walk checks.
    init(urls: [URL], password: String?, limits: NestingLimits = .standard) throws(ArchiveError) {
        precondition(!urls.isEmpty, "ReadSession needs at least one file")
        guard let a = archive_read_new() else { throw .io("Could not allocate archive reader") }
        self.a = a
        self.urls = urls
        let pass = (password?.isEmpty == false) ? password : nil
        self.hasPassphrase = pass != nil

        // Patch 0016: the 7z and xar readers (and the seekable zip reader, patch 0022) parse every entry before the
        // first header; they hold the count and the names to the same limits as `walkHeaders`. It can only fail on a
        // handle that is not new.
        let limitsSet = kernir_read_set_name_limits(a, UInt64(clamping: limits.maxEntries),
                                                    UInt64(clamping: limits.maxTotalNameBytes),
                                                    UInt64(clamping: limits.nameBytesPerEntry))
        precondition(limitsSet == ARCHIVE_OK, "kernir_read_set_name_limits on a new reader")
        try Self.configure(a)
        if let pass {
            let pr = archive_read_add_passphrase(a, pass)
            if pr != ARCHIVE_OK { throw Self.mapError(a, code: pr) }
        }
        // C strings for libarchive, alive for the open call (libarchive copies each name).
        let names = urls.map { strdup($0.path) }
        defer { names.forEach { free($0) } }
        guard !names.contains(where: { $0 == nil }) else { throw .io("Could not copy the archive file names") }
        let r = withUTF8CType { Self.open(a, names: names) }
        if r != ARCHIVE_OK && r != ARCHIVE_WARN {
            // All stored properties are set, so deinit frees the handle when we throw.
            throw Self.mapError(a, code: r)
        }
    }

    deinit { archive_read_free(a) }

    /// The filters, in `archive_read_support_filter_all`'s order, minus the ones libarchive decodes only by spawning
    /// a program from PATH in this build: lrzip, grzip and lzop always (`lrzip -d -q`, `grzip -d`, `lzop -d`; no
    /// liblzo2), lz4 without liblz4 (`lz4 -d -q`). A crafted file with their magic would start that process; now it
    /// reaches the raw reader unfiltered and is `.unsupportedFormat`. Each kept one decodes in-process (zlib, bzip2,
    /// liblzma for lzip/lzma/xz, the vendored zstd; compress, uu and rpm need no library) and returns ARCHIVE_WARN
    /// when it would fall back to a program instead, so `configure` refuses the open if a build loses a library.
    static var filterSteps: [(String, (OpaquePointer) -> Int32)] {
        [
            ("bzip2", archive_read_support_filter_bzip2),
            ("compress", archive_read_support_filter_compress),
            ("gzip", archive_read_support_filter_gzip),
            ("lzip", archive_read_support_filter_lzip),
            ("lzma", archive_read_support_filter_lzma),
            ("xz", archive_read_support_filter_xz),
            ("uu", archive_read_support_filter_uu),
            ("rpm", archive_read_support_filter_rpm),
            ("zstd", archive_read_support_filter_zstd),
        ]
    }

    /// The in-process filters (`filterSteps`), the formats `mapArchiveFormat` maps, and the read options. Every step
    /// must return ARCHIVE_OK (each fails only on a handle that is not new, or out of memory; xar warns when built
    /// without an XML parser, a filter when it would run a program):
    /// a reader missing a format would take its archives for another one (a tar.gz for one gzip file), and one
    /// missing the options would fold `._*` entries into their owners, so a failed step refuses the open.
    ///
    /// Formats: the mapped ones plus empty (a zero-byte file stays `.unsupportedFormat`) and raw (single compressed
    /// files; anything else reaching raw unfiltered is `.unsupportedFormat`). Not `archive_read_support_format_all`:
    /// its ar, mtree and warc readers are unmapped, so they were refused only after libarchive parsed a first header,
    /// and mtree reads and parses its whole text manifest there (its entries name host paths, not archive members,
    /// and its `checkfs` option reads those host files). Bidders register in format_all's order, cheap ones first;
    /// cpio covers every variant.
    ///
    /// Options: Finder `__MACOSX/._*` entries and Apple bsdtar's `._*` companions must be listed raw, never
    /// folded into their owners (the Apple build turns mac-ext on by default for zip and tar).
    /// (Kernir patch 0006 makes tar read a compressed stream to its end at its end-of-archive blocks, so
    /// the filter's trailer check fails the walk; a plain tar stops there. tar:read_concatenated_archives
    /// is not used: it would refuse tars with junk after those blocks, which bsdtar and GNU tar accept.)
    static func configure(_ a: OpaquePointer) throws(ArchiveError) {
        let steps: [(String, (OpaquePointer) -> Int32)] = filterSteps + [
            ("cpio", archive_read_support_format_cpio),
            ("empty", archive_read_support_format_empty),
            ("lha", archive_read_support_format_lha),
            ("tar", archive_read_support_format_tar),
            ("xar", archive_read_support_format_xar),
            ("7zip", archive_read_support_format_7zip),
            ("cab", archive_read_support_format_cab),
            ("rar", archive_read_support_format_rar),
            ("rar5", archive_read_support_format_rar5),
            ("iso9660", archive_read_support_format_iso9660),
            ("zip", archive_read_support_format_zip),
            ("raw", archive_read_support_format_raw),
            ("options", { a in withUTF8CType { archive_read_set_options(a, "zip:!mac-ext,tar:!mac-ext") } }),
        ]
        for (name, step) in steps {
            let r = step(a)
            guard r == ARCHIVE_OK else {
                let message = archive_error_string(a).map { String(cString: $0) } ?? "libarchive error \(r)"
                throw .io("Could not set up the archive reader (\(name)): \(message)")
            }
        }
    }

    /// One file: `archive_read_open_filename`. Several: `archive_read_open_filenames` with a
    /// NULL-terminated array; both read the files through the same callbacks.
    private static func open(_ a: OpaquePointer, names: [UnsafeMutablePointer<CChar>?]) -> Int32 {
        if names.count == 1 { return archive_read_open_filename(a, names[0], 64 * 1024) }
        var list: [UnsafePointer<CChar>?] = names.map { UnsafePointer($0) } + [nil]
        return list.withUnsafeMutableBufferPointer { archive_read_open_filenames(a, $0.baseAddress, 64 * 1024) }
    }

    /// After `nextHeader` throws: libarchive's entry as the failed read left it (nil after any other call).
    /// libarchive clears the entry before each header read, so a format reader that failed before filling
    /// it (a 7z failing while it reads its central directory, before the first entry) leaves it empty.
    /// Valid until the next `nextHeader` call.
    private(set) var failedEntry: OpaquePointer?

    /// Patch 0010: true when the RAR4 reader took the current header's name as Unicode (FHD_UNICODE); false for
    /// an OEM name, any other format, at end of archive and after a failed header read. Read right after
    /// `archive_read_next_header` (a RAR4 multivolume continuation read during the data recomputes libarchive's
    /// value), and kept for a header that returned ARCHIVE_WARN: a WARN never makes a name undeclared.
    /// Valid until the next `nextHeader` call.
    private(set) var rarNameDeclared = false

    /// Nil at end of archive. The entry pointer is valid until the next call.
    func nextHeader() throws(ArchiveError) -> OpaquePointer? {
        var entry: OpaquePointer?
        failedEntry = nil
        let r = withUTF8CType { archive_read_next_header(a, &entry) }
        rarNameDeclared = (r == ARCHIVE_OK || r == ARCHIVE_WARN) && kernir_read_rar_entry_name_declared(a) == 1
        switch r {
        case ARCHIVE_OK, ARCHIVE_WARN: return entry
        case ARCHIVE_EOF: return nil
        default:
            failedEntry = entry
            throw Self.mapError(a, code: r)
        }
    }

    /// Patch 0012: the current zip entry's central-directory comment, verbatim (empty: none). Nil when the entry has
    /// no central-directory record here: not zip, or libarchive's streaming zip reader (it takes that when the
    /// seekable reader finds no end record: none in the last 16 KiB, and none further back whose comment reaches EOF,
    /// e.g. a zip followed by more than 16 KiB of other data). Read before the next `nextHeader`.
    var zipEntryComment: [UInt8]? {
        var bytes: UnsafeRawPointer?
        var length = 0
        guard kernir_read_zip_entry_comment(a, &bytes, &length) == 1 else { return nil }
        guard let bytes, length > 0 else { return [] }
        return [UInt8](UnsafeRawBufferPointer(start: bytes, count: length))
    }

    /// Nil at end of the current entry's data. The buffer is valid only until the next
    /// `readBlock`/`nextHeader` call or deinit. A zip AES authentication-code mismatch, which libarchive
    /// reports only as a warning, is `.corrupted`: AE-2 entries carry no CRC, so nothing else catches
    /// tampered or wrongly decrypted data. Other warnings pass, as before; a data CRC mismatch is never one
    /// (7z and LHA report it as ARCHIVE_FAILED under Kernir patch 0007, gzip's trailer as ARCHIVE_FATAL under 0006).
    func readBlock() throws(ArchiveError) -> (buffer: UnsafeRawBufferPointer, offset: Int64)? {
        var buf: UnsafeRawPointer?
        var size = 0
        var offset: Int64 = 0
        let r = withUTF8CType { archive_read_data_block(a, &buf, &size, &offset) }
        switch r {
        case ARCHIVE_WARN:
            if let message = archive_error_string(a).map({ String(cString: $0) }),
               message.contains("Authentication code") {
                throw .corrupted(message)
            }
            return (UnsafeRawBufferPointer(start: buf, count: size), offset)
        case ARCHIVE_OK:
            return (UnsafeRawBufferPointer(start: buf, count: size), offset)
        case ARCHIVE_EOF: return nil
        default: throw Self.mapError(a, code: r)
        }
    }

    var formatCode: Int32 { archive_format(a) }

    var filterCodes: [Int32] {
        let n = archive_filter_count(a)
        guard n > 0 else { return [] }
        return (0..<n).map { archive_filter_code(a, $0) }.filter { $0 != ARCHIVE_FILTER_NONE }
    }

    private static func mapError(_ a: OpaquePointer, code: Int32) -> ArchiveError {
        // libarchive sets no message when the data simply runs out (a truncated file).
        let message = archive_error_string(a).map { String(cString: $0) }
            ?? (code == ARCHIVE_FATAL ? "The archive ends unexpectedly" : "Unknown archive error (\(code))")
        switch archive_errno(a) {
        case ENOENT, EACCES, EPERM: return .io(message)
        default: return .corrupted(message)
        }
    }
}
