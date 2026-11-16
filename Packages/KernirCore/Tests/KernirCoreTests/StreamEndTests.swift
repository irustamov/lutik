import Foundation
import Testing
import CLibArchive
@testable import KernirCore

/// What may follow the end of a compressed tar's data, and what follows a plain tar's end blocks.
/// Kernir patch 0006 makes tar read a compressed stream to its end (so the filter checks its trailer); valid
/// streams that the standard tools accept must still open: concatenated streams (gzip -t, bzip2 -t, xz -t,
/// zstd -t accept them), tape-style zero padding after the stream (bzip2 -t, xz -t; GNU gzip ignores
/// trailing zeros and bsdtar accepts it), xz stream padding, zstd skippable frames. A plain tar is not read
/// past its end blocks at all, so a long (or endless) tail costs nothing.
struct StreamEndTests {
    typealias D = DamagedChecksumTests

    // MARK: - Streams

    /// A zstd frame of raw (stored) blocks, built by hand so no zstd encoder is needed: magic, a frame
    /// header with only a 128 KiB window descriptor (no content size, no checksum), then blocks of at most
    /// 128 KiB, each with a 3-byte header (last flag, type 0 = raw, size).
    static func zstdRaw(_ data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        var out: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x38]
        var start = 0
        repeat {
            let n = min(128 * 1024, bytes.count - start)
            let last = start + n == bytes.count
            let h = UInt32(n) << 3 | (last ? 1 : 0)
            out += [UInt8(h & 0xff), UInt8(h >> 8 & 0xff), UInt8(h >> 16 & 0xff)] + bytes[start..<start + n]
            start += n
        } while start < bytes.count
        return out
    }

    /// A zstd skippable frame (magic 0x184D2A50, little-endian length, payload), which decoders pass over.
    static func zstdSkippable(_ count: Int) -> [UInt8] {
        [0x50, 0x2A, 0x4D, 0x18] + D.le32(UInt32(count)) + [UInt8](repeating: 0x5A, count: count)
    }

    static func stream(_ kind: String, _ data: Data) throws -> [UInt8] {
        switch kind {
        case "zst": return zstdRaw(data)
        case "Z":
            let dir = Fixtures.tempDir()
            Fixtures.makeFiles(["m": data], in: dir)
            try Fixtures.run("/usr/bin/compress", ["-f", "m"], cwd: dir)
            return [UInt8](try Data(contentsOf: dir.appendingPathComponent("m.Z")))
        default: return try D.compress(kind, data)
        }
    }

    /// Zeros after `bytes` up to the next multiple of 10240 (a tape record; a full one if already aligned).
    static func tapePadded(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: 10240 - bytes.count % 10240)
    }

    static let formats: [String: (ext: String, format: ArchiveFormat)] = [
        "gz": ("tar.gz", .tarGzip), "bz2": ("tar.bz2", .tarBzip2), "xz": ("tar.xz", .tarXz),
        "zst": ("tar.zst", .tarZstd),
    ]

    /// A tar of a.txt and b.bin: "small" (the whole stream is decoded while the format is picked) or "large"
    /// (a 300 KB incompressible b.bin, so tar's end blocks and the stream's end lie past the read-ahead).
    static func tar(_ shape: String) throws -> (bytes: Data, files: [String: Data]) {
        let files = ["a.txt": D.small, "b.bin": shape == "large" ? D.large : D.small]
        let tar = try Fixtures.archive("t.tar", bsdtarArgs: ["--no-mac-metadata"], files: files)
        return (try Data(contentsOf: tar), files)
    }

    /// The tar compressed as `variant`: "concatenated" (two streams, split mid-tar, so the second one holds
    /// tar's end blocks), "tape-padded", "stream-padded" (xz: 4 null bytes after the stream),
    /// "concatenated-padded" (xz: stream padding between and after two streams), "skippable" (zstd: a
    /// skippable frame between and after two frames).
    static func variant(_ kind: String, _ variant: String, _ tar: Data) throws -> [UInt8] {
        let cut = tar.startIndex + tar.count / 3
        let halves = { (sep: [UInt8], end: [UInt8]) throws -> [UInt8] in
            try stream(kind, tar[..<cut]) + sep + stream(kind, tar[cut...]) + end
        }
        switch variant {
        case "concatenated": return try halves([], [])
        case "tape-padded": return tapePadded(try stream(kind, tar))
        case "stream-padded": return try stream(kind, tar) + [0, 0, 0, 0]
        case "concatenated-padded": return try halves([0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0])
        case "skippable": return try halves(zstdSkippable(20), zstdSkippable(300))
        default: fatalError(variant)
        }
    }

    static let validEnds: [(String, String)] = [
        ("gz", "concatenated"), ("gz", "tape-padded"),
        ("bz2", "concatenated"), ("bz2", "tape-padded"),
        ("xz", "concatenated"), ("xz", "tape-padded"), ("xz", "stream-padded"), ("xz", "concatenated-padded"),
        ("zst", "concatenated"), ("zst", "skippable"),
    ]

    @Test(arguments: validEnds, ["small", "large"])
    func validStreamEndOpens(end: (kind: String, variant: String), shape: String) async throws {
        let (tar, files) = try Self.tar(shape)
        let bytes = try Self.variant(end.kind, end.variant, tar)
        let f = Self.formats[end.kind]!
        let url = D.write(bytes, "t.\(f.ext)")
        let reader = try await Archive.open(at: url)
        #expect(reader.format == f.format)
        try await D.expectIntact(url, files: files, repackAs: f.format == .tarZstd ? .tar : f.format)
    }

    /// The hand-built zstd frames are well formed: a damaged block header or a cut frame fails.
    @Test(arguments: ["small", "large"])
    func zstdRawFrameDamageIsCorrupted(shape: String) async throws {
        let (tar, _) = try Self.tar(shape)
        let z = Self.zstdRaw(tar)
        let url = D.write(Array(z.dropLast(100)), "t.tar.zst")
        let open = await D.error { _ = try await Archive.open(at: url) }
        #expect(D.isCorrupted(open), "open: \(String(describing: open))")
    }

    // MARK: - Filter chains

    /// A tar.gz inside a uuencode wrapper, or inside a bzip2 stream: the drain reads the gzip stream (the
    /// top filter) to its trailer either way, so a damaged trailer fails and an intact one opens.
    static func chained(_ outer: String, damaged: Bool) throws -> (bytes: [UInt8], files: [String: Data]) {
        let (tar, files) = try tar("large")
        var gz = try D.gzip(tar)
        if damaged { gz = D.flip(gz, at: gz.count - 8) }
        switch outer {
        case "uu":
            let dir = Fixtures.tempDir()
            Fixtures.makeFiles(["t.tar.gz": Data(gz)], in: dir)
            let out = dir.appendingPathComponent("t.uu")
            try Fixtures.run("/usr/bin/uuencode", ["-o", out.path, "t.tar.gz", "t.tar.gz"], cwd: dir)
            return ([UInt8](try Data(contentsOf: out)), files)
        default: return (try D.compress(outer, Data(gz)), files)
        }
    }

    @Test(arguments: ["uu", "bz2"])
    func chainedTarGzIntactOpens(outer: String) async throws {
        let (bytes, files) = try Self.chained(outer, damaged: false)
        let url = D.write(bytes, "t.tar.gz.\(outer)")
        try await D.expectIntact(url, files: files, repackAs: .tarGzip)
    }

    @Test(arguments: ["uu", "bz2"])
    func chainedTarGzBadTrailerIsCorrupted(outer: String) async throws {
        let (bytes, _) = try Self.chained(outer, damaged: true)
        let url = D.write(bytes, "t.tar.gz.\(outer)")
        let open = await D.error { _ = try await Archive.open(at: url) }
        #expect(D.isCorrupted(open), "open: \(String(describing: open))")
    }

    /// .tar.Z (compress): Kernir does not list it as a format, but libarchive reads it, and `compress -d`
    /// accepts tape padding after the stream (it decodes the zeros as more output, past tar's end blocks).
    @Test(arguments: ["small", "large"])
    func tapePaddedTarZStillWalks(shape: String) throws {
        let (tar, files) = try Self.tar(shape)
        let url = D.write(Self.tapePadded(try Self.stream("Z", tar)), "t.tar.Z")
        let walk = try Self.walk(url)
        #expect(walk.result == ARCHIVE_EOF, "\(walk.error)")
        #expect(walk.names == files.keys.sorted())
    }

    // MARK: - Plain tar

    /// A plain tar followed by a large payload (64 MiB of zeros, or of incompressible bytes) lists and
    /// extracts; nothing reads past the end blocks.
    @Test(arguments: [false, true])
    func plainTarWithLargeTailStillReads(noise: Bool) async throws {
        let (tar, files) = try Self.tar("large")
        let url = Fixtures.tempDir().appendingPathComponent("tail.tar")
        FileManager.default.createFile(atPath: url.path, contents: tar)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        let chunk = noise ? D.noise(1 << 20, seed: 0xC0FFEE) : Data(count: 1 << 20)
        for _ in 0..<64 { try h.write(contentsOf: chunk) }
        try h.close()
        try await D.expectIntact(url, files: files, repackAs: .tar)
    }

    /// Serves `head`, then zeros without end (capped, so a regression ends instead of hanging), counting what
    /// libarchive asked for.
    final class EndlessSource {
        let head: UnsafeMutableRawBufferPointer
        let zeros = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 1)
        let cap: Int
        var served = 0

        init(_ head: Data, cap: Int) {
            self.head = .allocate(byteCount: head.count, alignment: 1)
            self.head.copyBytes(from: head)
            zeros.initializeMemory(as: UInt8.self, repeating: 0)
            self.cap = cap
        }

        deinit { head.deallocate(); zeros.deallocate() }

        func next(_ buf: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int {
            if served < head.count {
                buf.pointee = UnsafeRawPointer(head.baseAddress! + served)
                let n = head.count - served
                served += n
                return n
            }
            guard served < cap else { return 0 }
            buf.pointee = UnsafeRawPointer(zeros.baseAddress!)
            served += zeros.count
            return zeros.count
        }
    }

    /// A plain tar on a non-seekable input that never ends: reading every header reaches EOF after the end
    /// blocks and pulls only the read-ahead, not the endless tail.
    @Test func plainTarOnEndlessInputEnds() throws {
        let (tar, files) = try Self.tar("large")
        let source = EndlessSource(tar, cap: 256 << 20)
        let a = try #require(archive_read_new())
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        let ctx = Unmanaged.passUnretained(source).toOpaque()
        let r = archive_read_open(a, ctx, nil, { _, ctx, buf in
            Unmanaged<EndlessSource>.fromOpaque(ctx!).takeUnretainedValue().next(buf!)
        }, nil)
        #expect(r == ARCHIVE_OK)
        var names: [String] = []
        var entry: OpaquePointer?
        var status = archive_read_next_header(a, &entry)
        while status == ARCHIVE_OK {
            names.append(String(cString: archive_entry_pathname(entry)))
            status = archive_read_next_header(a, &entry)
        }
        #expect(status == ARCHIVE_EOF, "\(String(cString: archive_error_string(a)))")
        #expect(names.sorted() == files.keys.sorted())
        #expect(source.served < tar.count + (1 << 20), "read \(source.served) bytes of a \(tar.count)-byte tar")
    }

    // MARK: - libarchive walk

    /// Every header of `url`, from an independent libarchive read (filter_all, format_all, raw last).
    /// This is not the production setup (ReadSession.configure registers an explicit in-process filter
    /// list), so it is only for trusted, test-built fixtures.
    static func walk(_ url: URL) throws -> (names: [String], result: Int32, error: String) {
        let a = try #require(archive_read_new())
        defer { archive_read_free(a) }
        archive_read_support_filter_all(a)
        archive_read_support_format_all(a)
        archive_read_support_format_raw(a)
        var r = archive_read_open_filename(a, url.path, 64 * 1024)
        var names: [String] = []
        if r == ARCHIVE_OK {
            var entry: OpaquePointer?
            r = archive_read_next_header(a, &entry)
            while r == ARCHIVE_OK || r == ARCHIVE_WARN {
                names.append(String(cString: archive_entry_pathname(entry)))
                r = archive_read_next_header(a, &entry)
            }
        }
        let e = archive_error_string(a).map { String(cString: $0) } ?? ""
        return (names.sorted(), r, e)
    }
}
