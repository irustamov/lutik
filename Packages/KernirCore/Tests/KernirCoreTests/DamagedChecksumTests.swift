import Foundation
import Testing
@testable import KernirCore

/// Archives whose stored data checksum does not match their bytes must fail `.corrupted`: extract keeps
/// no file for the failing entry, and a repack writes nothing, so it never launders the bad bytes into a
/// new archive with a fresh checksum. Intact archives of the same shape still read.
/// Every damaged archive is built here: 7z by the engine's writer (Store, so the data sits raw in the file),
/// LHA level-0 by hand, gzip and tar.gz by /usr/bin/gzip and bsdtar, then one byte is flipped.
struct DamagedChecksumTests {
    // MARK: - Helpers

    static func error(_ body: () async throws -> Void) async -> ArchiveError? {
        do { try await body(); return nil } catch let e as ArchiveError { return e } catch {
            Issue.record("non-ArchiveError \(error)")
            return .notImplemented
        }
    }

    static func isCorrupted(_ e: ArchiveError?) -> Bool {
        if case .corrupted = e { return true }
        return false
    }

    /// Text that differs per tag and line (compressible).
    static func text(_ tag: String, lines: Int) -> Data {
        Data((0..<lines).map { "\(tag) line \($0) of the Kernir checksum payload\n" }.joined().utf8)
    }

    /// Deterministic incompressible bytes (xorshift), so a gzip stream spans many filter reads.
    static func noise(_ count: Int, seed: UInt64) -> Data {
        var x = seed | 1
        return Data((0..<count).map { _ in
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            return UInt8(truncatingIfNeeded: x)
        })
    }

    static func write(_ bytes: [UInt8], _ name: String) -> URL {
        let url = Fixtures.tempDir().appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
        return url
    }

    static func flip(_ bytes: [UInt8], at i: Int) -> [UInt8] {
        var b = bytes
        b[i] ^= 0x5A
        return b
    }

    /// With `failsAtOpen`, checks that open throws `.corrupted`. Otherwise opens `url` and checks that
    /// extract-all, a temporary file of `failing` and a repack to `repackAs` all throw `.corrupted`, that
    /// extract leaves no file at `failing`, and that the repack writes nothing.
    static func expectRejected(_ url: URL, failing: String, repackAs: ArchiveFormat, failsAtOpen: Bool = false,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        if failsAtOpen {
            let open = await error { _ = try await Archive.open(at: url) }
            #expect(isCorrupted(open), "open: \(String(describing: open))", sourceLocation: sourceLocation)
            return
        }
        let reader = try await Archive.open(at: url)
        let dest = Fixtures.tempDir()
        let extract = await error { try await reader.extract(nil, to: dest, progress: nil) }
        #expect(isCorrupted(extract), "extract: \(String(describing: extract))", sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent(failing).path),
                "extract left \(failing) behind", sourceLocation: sourceLocation)

        let temp = await error { _ = try await reader.extractToTemporaryFile(failing) }
        #expect(isCorrupted(temp), "temporary file: \(String(describing: temp))", sourceLocation: sourceLocation)

        let out = Fixtures.tempDir().appendingPathComponent("repacked.\(repackAs.fileExtension)")
        let repack = await error {
            try await ArchiveWriter.write(source: reader, changes: ArchiveChangeSet(), format: repackAs, to: out,
                                          options: nil)
        }
        #expect(isCorrupted(repack), "repack: \(String(describing: repack))", sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: out.path), "repack wrote \(out.lastPathComponent)",
                sourceLocation: sourceLocation)
    }

    /// Opens `url`, extracts everything and compares the files; then repacks to `repackAs` and reads it back.
    static func expectIntact(_ url: URL, files: [String: Data], repackAs: ArchiveFormat,
                             sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let reader = try await Archive.open(at: url)
        let dest = Fixtures.tempDir()
        try await reader.extract(nil, to: dest, progress: nil)
        for (name, data) in files {
            #expect(FileManager.default.contents(atPath: dest.appendingPathComponent(name).path) == data,
                    "extracted \(name)", sourceLocation: sourceLocation)
        }
        let out = Fixtures.tempDir().appendingPathComponent("repacked.\(repackAs.fileExtension)")
        try await ArchiveWriter.write(source: reader, changes: ArchiveChangeSet(), format: repackAs, to: out,
                                      options: nil)
        let back = try await Archive.open(at: out)
        let backDest = Fixtures.tempDir()
        try await back.extract(nil, to: backDest, progress: nil)
        for (name, data) in files {
            #expect(FileManager.default.contents(atPath: backDest.appendingPathComponent(name).path) == data,
                    "repacked \(name)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - 7z

    static let a7 = text("a", lines: 40)
    static let b7 = text("b", lines: 60)

    /// An engine-written unencrypted Store 7z of a.txt then b.txt, and the offset of b.txt's data.
    static func sevenZip() async throws -> (bytes: [UInt8], bOffset: Int) {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": a7, "b.txt": b7], in: dir)
        let dest = Fixtures.tempDir().appendingPathComponent("s.7z")
        let changes = ArchiveChangeSet(additions: ["a.txt", "b.txt"].map {
            .init(sourceURL: dir.appendingPathComponent($0), destinationDirectory: "")
        })
        try await ArchiveWriter.write(source: nil, changes: changes, format: .sevenZip, to: dest,
                                      options: ArchiveWriteOptions(method: .store))
        let data = try Data(contentsOf: dest)
        let range = try #require(data.range(of: b7), "b.txt is not stored raw")
        return ([UInt8](data), range.lowerBound - data.startIndex)
    }

    @Test func sevenZipIntactStillReads() async throws {
        let (z, _) = try await Self.sevenZip()
        try await Self.expectIntact(Self.write(z, "s.7z"), files: ["a.txt": Self.a7, "b.txt": Self.b7],
                                    repackAs: .sevenZip)
    }

    @Test func sevenZipBadCRCIsCorrupted() async throws {
        let (z, b) = try await Self.sevenZip()
        let url = Self.write(Self.flip(z, at: b + 100), "s.7z")
        try await Self.expectRejected(url, failing: "b.txt", repackAs: .sevenZip)
    }

    // MARK: - LHA

    /// CRC-16/ARC, the data CRC of LHA.
    static func crc16(_ d: [UInt8]) -> UInt16 {
        var c: UInt16 = 0
        for b in d {
            c ^= UInt16(b)
            for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
        }
        return c
    }

    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    /// A level-0 LHA archive of stored (-lh0-) files; `badCRC` names the entry whose CRC field is off by one.
    static func lha(_ files: [(String, Data)], badCRC: String? = nil) -> [UInt8] {
        var out: [UInt8] = []
        for (name, data) in files {
            let n = Array(name.utf8)
            var crc = crc16([UInt8](data))
            if name == badCRC { crc &+= 1 }
            var h: [UInt8] = [0, 0] + Array("-lh0-".utf8) + le32(UInt32(data.count)) + le32(UInt32(data.count))
            h += le32(0x4D83_A429) + [0x20, 0, UInt8(n.count)] + n + [UInt8(crc & 0xff), UInt8(crc >> 8)]
            h[0] = UInt8(h.count - 2)
            h[1] = h[2...].reduce(0) { $0 &+ $1 }
            out += h + [UInt8](data)
        }
        return out + [0]
    }

    static let aL = text("lha a", lines: 20)
    static let bL = text("lha b", lines: 30)

    @Test func lhaIntactStillReads() async throws {
        let url = Self.write(Self.lha([("a.txt", Self.aL), ("b.txt", Self.bL)]), "l.lzh")
        try await Self.expectIntact(url, files: ["a.txt": Self.aL, "b.txt": Self.bL], repackAs: .zip)
    }

    @Test func lhaBadCRCIsCorrupted() async throws {
        let url = Self.write(Self.lha([("a.txt", Self.aL), ("b.txt", Self.bL)], badCRC: "b.txt"), "l.lzh")
        try await Self.expectRejected(url, failing: "b.txt", repackAs: .zip)
    }

    // MARK: - gzip

    static func gzip(_ data: Data) throws -> [UInt8] {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["m": data], in: dir)
        try Fixtures.run("/usr/bin/gzip", ["-n", "m"], cwd: dir)
        return [UInt8](try Data(contentsOf: dir.appendingPathComponent("m.gz")))
    }

    static let small = text("gz", lines: 50)
    static let large = noise(300_000, seed: 0x9E37_79B9_7F4A_7C15)

    @Test(arguments: [false, true])
    func gzipIntactStillReads(large: Bool) async throws {
        let data = large ? Self.large : Self.small
        let url = Self.write(try Self.gzip(data), "f.txt.gz")
        try await Self.expectIntact(url, files: ["f.txt": data], repackAs: .zip)
    }

    /// The trailer is CRC32 (4 bytes) then ISIZE (4 bytes); damaging either is caught. A small stream is
    /// decoded whole while libarchive picks the format (the uu bidder reads up to 128 KiB ahead), so open
    /// fails; a large one (300 KB, incompressible) opens and fails at its last data block.
    @Test(arguments: [(false, 8), (false, 4), (true, 8), (true, 4)])
    func gzipBadTrailerIsCorrupted(large: Bool, fromEnd: Int) async throws {
        let g = try Self.gzip(large ? Self.large : Self.small)
        let url = Self.write(Self.flip(g, at: g.count - fromEnd), "f.txt.gz")
        try await Self.expectRejected(url, failing: "f.txt", repackAs: .zip, failsAtOpen: !large)
    }

    static func members(large: Bool) -> [Data] {
        large ? [noise(200_000, seed: 11), noise(200_000, seed: 12)]
              : [text("member one", lines: 30), text("member two", lines: 40)]
    }

    @Test(arguments: [false, true])
    func multiMemberGzipIntactStillReads(large: Bool) async throws {
        let m = Self.members(large: large)
        let url = Self.write(try Self.gzip(m[0]) + Self.gzip(m[1]), "m.txt.gz")
        try await Self.expectIntact(url, files: ["m.txt": m[0] + m[1]], repackAs: .zip)
    }

    /// Each member's trailer is checked, not only the last one (the CRC restarts per member).
    @Test(arguments: [(false, 0), (false, 1), (true, 0), (true, 1)])
    func multiMemberGzipBadTrailerIsCorrupted(large: Bool, damaged: Int) async throws {
        var members = try Self.members(large: large).map(Self.gzip)
        members[damaged] = Self.flip(members[damaged], at: members[damaged].count - 8)
        let url = Self.write(members[0] + members[1], "m.txt.gz")
        try await Self.expectRejected(url, failing: "m.txt", repackAs: .zip, failsAtOpen: !large)
    }

    // MARK: - Compressed tar

    /// The extension and the Kernir format of each compressed tar.
    static let tarKinds: [String: (ext: String, format: ArchiveFormat)] = [
        "gz": ("tar.gz", .tarGzip), "bz2": ("tar.bz2", .tarBzip2), "xz": ("tar.xz", .tarXz),
    ]

    /// gzip and bzip2 by their command-line tools; xz by the Compression framework (an .xz stream with
    /// check type None, but the usual 12-byte stream footer and its CRC32).
    static func compress(_ kind: String, _ data: Data) throws -> [UInt8] {
        switch kind {
        case "gz": return try gzip(data)
        case "bz2":
            let dir = Fixtures.tempDir()
            Fixtures.makeFiles(["m": data], in: dir)
            try Fixtures.run("/usr/bin/bzip2", ["m"], cwd: dir)
            return [UInt8](try Data(contentsOf: dir.appendingPathComponent("m.bz2")))
        default: return [UInt8](try (data as NSData).compressed(using: .lzma) as Data)
        }
    }

    /// Shapes of a compressed tar: "small" (decoded whole at open), "large" (a 300 KB incompressible
    /// member), "padded" (small members in 1 MiB tar records, so about 1 MiB of zeros follows the end blocks).
    static func compressedTar(_ kind: String, shape: String) throws -> (bytes: [UInt8], files: [String: Data]) {
        let files = ["a.txt": small, "b.bin": shape == "large" ? large : small]
        let args = ["--no-mac-metadata"] + (shape == "padded" ? ["-b", "2048"] : [])
        let tar = try Fixtures.archive("t.tar", bsdtarArgs: args, files: files)
        return (try compress(kind, try Data(contentsOf: tar)), files)
    }

    @Test(arguments: ["gz", "bz2", "xz"], ["small", "large", "padded"])
    func compressedTarIntactStillReads(kind: String, shape: String) async throws {
        let (t, files) = try Self.compressedTar(kind, shape: shape)
        let k = Self.tarKinds[kind]!
        try await Self.expectIntact(Self.write(t, "t.\(k.ext)"), files: files, repackAs: k.format)
    }

    /// The stream's check sits after tar's end-of-archive blocks: gzip's CRC32 and ISIZE (8 and 4 bytes from
    /// the end), bzip2's combined CRC (bit-aligned in the last bytes), xz's stream footer (12 bytes, with its
    /// own CRC32). A small stream is decoded whole at open (the format bidders read up to 128 KiB ahead).
    /// Larger ones are not, and upstream tar stops at the null blocks (and turns a filter error while reading
    /// the second into EOF), never reaching the check when more than a filter read of output follows them
    /// (gzip: the trailer is read only after the last output; "padded": a megabyte of record padding).
    /// Kernir patch 0006 reads on to the end of the stream, so listing, which reads every header, reaches
    /// the check. Either way a damaged end fails open, before anything is extracted or repacked.
    @Test(arguments: [("gz", 8), ("gz", 4), ("bz2", 3), ("xz", 10)], ["small", "large", "padded"])
    func compressedTarBadEndIsCorrupted(damage: (kind: String, fromEnd: Int), shape: String) async throws {
        let (t, _) = try Self.compressedTar(damage.kind, shape: shape)
        let url = Self.write(Self.flip(t, at: t.count - damage.fromEnd), "t.\(Self.tarKinds[damage.kind]!.ext)")
        let open = await Self.error { _ = try await Archive.open(at: url) }
        #expect(Self.isCorrupted(open), "open: \(String(describing: open))")
    }

    /// A gzip stream cut right after tar's end-of-archive blocks (no trailer) is damaged too.
    @Test func tarGzWithoutTrailerIsCorrupted() async throws {
        let (t, _) = try Self.compressedTar("gz", shape: "large")
        let url = Self.write(Array(t.dropLast(8)), "t.tar.gz")
        let open = await Self.error { _ = try await Archive.open(at: url) }
        #expect(Self.isCorrupted(open), "open: \(String(describing: open))")
    }

    /// Bytes after tar's end-of-archive blocks are read past, not parsed: a tar with junk there still opens
    /// and extracts (bsdtar and GNU tar accept it), plain or inside an intact gzip stream.
    @Test(arguments: [false, true])
    func junkAfterTarEndStillReads(gzipped: Bool) async throws {
        let files = ["a.txt": Self.small, "b.bin": Self.large]
        let tar = try Fixtures.archive("t.tar", bsdtarArgs: ["--no-mac-metadata"], files: files)
        let junked = try Data(contentsOf: tar) + Data("junk after the end of the archive".utf8)
            + Data(repeating: 0x41, count: 1024)
        let bytes = gzipped ? try Self.gzip(junked) : [UInt8](junked)
        try await Self.expectIntact(Self.write(bytes, gzipped ? "j.tar.gz" : "j.tar"), files: files,
                                    repackAs: gzipped ? .tarGzip : .tar)
    }
}
