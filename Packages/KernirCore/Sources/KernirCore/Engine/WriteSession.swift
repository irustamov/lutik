import Foundation
import CLibArchive

/// Owns one libarchive write handle, configured for a writable format and resolved options.
/// Not thread-safe: use from one task at a time. Every name-converting call runs in `withUTF8CType`.
final class WriteSession {
    private let a: OpaquePointer
    /// The split writer's byte sink, kept alive for libarchive's write callback until the handle is freed.
    private let output: VolumeSink?
    /// The file `init(url:)` writes, opened here (not by libarchive) so `deinit` can close it without closing the
    /// handle; -1 for a sink, and once `finish` closed it.
    private var fd: Int32 = -1
    /// Set once `finish` closed the archive cleanly.
    private var finished = false

    init(url: URL, format: ArchiveFormat, options: ResolvedWriteOptions) throws(ArchiveError) {
        guard let a = archive_write_new() else { throw .io("Could not allocate archive writer") }
        self.a = a
        output = nil
        // All stored properties are set, so deinit frees the handle when a step below throws.
        try configure(format: format, options: options)
        // The same file and flags as archive_write_open_filename, which also leaves a regular file's last block
        // unpadded.
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw .io("Failed to open '\(url.path)'") }
        let r = archive_write_open_fd(a, fd)
        if r != ARCHIVE_OK { throw error() }
    }

    /// Writes the archive's bytes to `output` instead of a file (`archive_write_open2`), unpadded: a file opened
    /// by name gets no padding either, so the bytes are the same as `init(url:)` writes.
    init(output: VolumeSink, format: ArchiveFormat, options: ResolvedWriteOptions) throws(ArchiveError) {
        guard let a = archive_write_new() else { throw .io("Could not allocate archive writer") }
        self.a = a
        self.output = output
        try configure(format: format, options: options)
        try check(archive_write_set_bytes_in_last_block(a, 1))
        let r = archive_write_open2(a, Unmanaged.passUnretained(output).toOpaque(), nil, { _, context, buffer, length in
            guard let context, let buffer else { return -1 }
            let sink = Unmanaged<VolumeSink>.fromOpaque(context).takeUnretainedValue()
            return sink.write(UnsafeRawBufferPointer(start: buffer, count: length)) ? length : -1
        }, nil, nil)
        if r != ARCHIVE_OK { throw error() }
    }

    /// An unfinished handle is marked failed before it is freed, so freeing it writes nothing. Freeing would
    /// otherwise close it, and that close writes the rest of the archive after the error that left it unfinished:
    /// all of a 7z, and the rest of the current entry's declared size in zeros for tar (Int64.max bytes for a
    /// crafted size, in C, past any cancellation). A split writer's sink is abandoned as well, so not one more
    /// byte reaches it. Freeing a failed handle still ends its compressors (patch 0013; upstream ended the gzip
    /// and xz filters' and the zip writer's only in close).
    deinit {
        if !finished {
            output?.abandon()
            archive_write_fail(a)
        }
        withUTF8CType { _ = archive_write_free(a) }
        if fd >= 0 { close(fd) }
    }

    /// ARCHIVE_WARN (e.g. a metadata field the format cannot hold) is tolerated.
    func writeHeader(_ entry: OpaquePointer) throws(ArchiveError) {
        let r = withUTF8CType { archive_write_header(a, entry) }
        if r < ARCHIVE_WARN { throw error() }
    }

    /// Zip only: writes `entry` with its MBS pathname and symlink bytes stored verbatim (no conversion) and bit 11
    /// set iff `utf8Flag` (patch 0009). The raw request covers this one header, whether it succeeds or fails.
    func writeHeader(_ entry: OpaquePointer, rawZipName utf8Flag: Bool) throws(ArchiveError) {
        try check(kernir_write_zip_next_name_raw(a, utf8Flag ? 1 : 0))
        try writeHeader(entry)
    }

    /// Zip only (patch 0012): the next `writeHeader`'s entry gets `comment` as its central-directory comment,
    /// verbatim. Taken by that header, whether it succeeds or fails; an empty comment writes none.
    func setNextZipEntryComment(_ comment: [UInt8]) throws(ArchiveError) {
        try check(comment.withUnsafeBytes { kernir_write_zip_next_comment(a, $0.baseAddress, $0.count) })
    }

    /// Zip only (patch 0012): the archive comment `finish` writes after the end-of-central-directory record,
    /// verbatim (at most 65 535 bytes).
    func setZipArchiveComment(_ comment: [UInt8]) throws(ArchiveError) {
        try check(comment.withUnsafeBytes { kernir_write_zip_archive_comment(a, $0.baseAddress, $0.count) })
    }

    /// Writes all of `buffer` to the current entry.
    func writeData(_ buffer: UnsafeRawBufferPointer) throws(ArchiveError) {
        var offset = 0
        while offset < buffer.count {
            let n = archive_write_data(a, buffer.baseAddress! + offset, buffer.count - offset)
            if n <= 0 { throw error() }
            offset += n
        }
    }

    /// Flushes the last entry and the archive trailer (7z writes its whole header here); errors surface here.
    func finish() throws(ArchiveError) {
        let r = withUTF8CType { archive_write_close(a) }
        if r < ARCHIVE_WARN { throw error() }
        finished = true
        if fd >= 0 { close(fd) }  // as archive_write_open_filename's close
        fd = -1
    }

    // MARK: - Setup

    private func configure(format: ArchiveFormat, options: ResolvedWriteOptions) throws(ArchiveError) {
        switch format {
        case .zip:
            try check(archive_write_set_format_zip(a))
            try set("zip", "compression", options.method == .store ? "store" : "deflate")
            if let level = options.compressionLevel { try set("zip", "compression-level", String(level)) }
            try set("zip", "hdrcharset", "UTF-8")
            switch options.encryption {
            case .none: break
            case .zipCrypto: try encrypt(format, "zip", "zipcrypt", options.password)
            case .aes128: try encrypt(format, "zip", "aes128", options.password)
            case .aes256: try encrypt(format, "zip", "aes256", options.password)
            }
        case .sevenZip:
            try check(archive_write_set_format_7zip(a))
            try set("7zip", "compression", Self.sevenZipMethod(options.method ?? .lzma2))
            if let level = options.compressionLevel { try set("7zip", "compression-level", String(level)) }
            // Patch 0005: 7zAES on every folder, the header included (names hidden, like 7-Zip's -mhe=on).
            switch options.encryption {
            case .none: break
            case .aes256: try encrypt(format, "7zip", "aes256", options.password)
            case .aes128, .zipCrypto: throw .unsupportedEncryption(format)
            }
        case .tar:
            try check(archive_write_set_format_pax_restricted(a))
        case .tarGzip:
            try check(archive_write_set_format_pax_restricted(a))
            try check(archive_write_add_filter_gzip(a))
            if let level = options.compressionLevel { try set("gzip", "compression-level", String(level)) }
        case .tarBzip2:
            try check(archive_write_set_format_pax_restricted(a))
            try check(archive_write_add_filter_bzip2(a))
            if let level = options.compressionLevel { try set("bzip2", "compression-level", String(level)) }
        case .tarXz:
            try check(archive_write_set_format_pax_restricted(a))
            try check(archive_write_add_filter_xz(a))
            if let level = options.compressionLevel { try set("xz", "compression-level", String(level)) }
        default:
            throw .readOnlyFormat(format)
        }
    }

    private static func sevenZipMethod(_ method: ArchiveCompressionMethod) -> String {
        switch method {
        case .store: "copy"
        case .deflate: "deflate"
        case .bzip2: "bzip2"
        case .lzma: "lzma1"
        case .lzma2: "lzma2"
        case .ppmd: "ppmd"
        }
    }

    /// Zip encryption comes from libarchive's own zip writer, 7z's from patch 0005 (both CommonCrypto).
    private func encrypt(_ format: ArchiveFormat, _ module: String, _ scheme: String,
                         _ password: String?) throws(ArchiveError) {
        guard let password, !password.isEmpty else { throw .passwordRequired }
        guard archive_write_set_option(a, module, "encryption", scheme) == ARCHIVE_OK,
              archive_write_set_passphrase(a, password) == ARCHIVE_OK else {
            throw .unsupportedEncryption(format)
        }
    }

    private func set(_ module: String, _ key: String, _ value: String) throws(ArchiveError) {
        let r = withUTF8CType { archive_write_set_option(a, module, key, value) }
        if r != ARCHIVE_OK { throw error() }
    }

    private func check(_ r: Int32) throws(ArchiveError) {
        if r != ARCHIVE_OK { throw error() }
    }

    /// libarchive's message. When the split writer's sink refused bytes, `VolumeWriter` throws the sink's own reason.
    private func error() -> ArchiveError {
        .io(archive_error_string(a).map { String(cString: $0) } ?? "Could not write archive")
    }
}
