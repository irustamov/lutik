import Testing
import Foundation
import CLibArchive
@testable import KernirCore

/// Triage of the reader against the early fixture run.
struct TriageTests {
    static func dest() -> URL { Fixtures.tempDir().appendingPathComponent("out", isDirectory: true) }

    static func regularBytes(_ url: URL) -> Data? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - NFD raw names, selections in either spelling

    static let nfc = "\u{E9}.txt"
    static let nfd = "e\u{0301}.txt"

    struct Fmt: Sendable, CustomTestStringConvertible {
        let name: String
        let args: [String]
        var testDescription: String { name }
    }
    static let nfdFormats = [Fmt(name: "t.zip", args: ["--format", "zip"]),
                             Fmt(name: "t.tar", args: ["--format", "pax"])]

    static func nfdReader(_ f: Fmt) async throws -> LibArchiveReader {
        let dir = Fixtures.tempDir()
        let file = dir.appendingPathComponent("d").appendingPathComponent(nfd)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("accent".utf8).write(to: file)
        try Fixtures.bsdtar(["-cf", f.name] + f.args + ["d"], cwd: dir)
        let url = dir.appendingPathComponent(f.name)
        // The raw header name must really be NFD, or the cases below would only test NFC.
        let bytes = try Data(contentsOf: url)
        #expect(bytes.range(of: Data(nfd.utf8)) != nil, "\(f.name): NFD name bytes missing")
        #expect(bytes.range(of: Data(nfc.utf8)) == nil, "\(f.name): archive holds an NFC name")
        return try await LibArchiveReader.open(at: url, password: nil)
    }

    @Test(arguments: nfdFormats)
    func nfdRawNameIsListedNFC(_ f: Fmt) async throws {
        let r = try await Self.nfdReader(f)
        let paths = r.entries.map { Array($0.path.unicodeScalars) }
        #expect(paths.contains(Array("d/\(Self.nfc)".unicodeScalars)))
        #expect(!paths.contains(Array("d/\(Self.nfd)".unicodeScalars)))
    }

    @Test(arguments: nfdFormats)
    func extractByListedPathMatchesNFDHeader(_ f: Fmt) async throws {
        let r = try await Self.nfdReader(f)
        for spelling in [Self.nfc, Self.nfd] {
            let out = Self.dest()
            try await r.extract(["d/\(spelling)"], to: out, progress: nil)
            #expect(Self.regularBytes(out.appendingPathComponent("d/\(Self.nfc)")) == Data("accent".utf8),
                    "extract \(spelling.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    @Test(arguments: nfdFormats)
    func tempFileByListedPathMatchesNFDHeader(_ f: Fmt) async throws {
        for spelling in [Self.nfc, Self.nfd] {
            let r = try await Self.nfdReader(f)
            let url = try await r.extractToTemporaryFile("d/\(spelling)")
            #expect(Self.regularBytes(url) == Data("accent".utf8))
        }
    }

    @Test func nfdAndNFCSpellingsShareOneCacheEntry() async throws {
        let r = try await Self.nfdReader(Self.nfdFormats[0])
        let a = try await r.extractToTemporaryFile("d/\(Self.nfc)")
        let b = try await r.extractToTemporaryFile("d/\(Self.nfd)")
        #expect(a == b)
    }

    @Test func nulBetweenBaseAndCombiningMarkStillComposes() async throws {
        // NUL goes before NFC: "e\0\u{301}" must become "\u{E9}", not "e" + U+0301.
        #expect(EntryPath.normalize("d/e\u{0}\u{0301}.txt").map { Array($0.unicodeScalars) }
                == Array("d/\(Self.nfc)".unicodeScalars))
        let r = try await Self.nfdReader(Self.nfdFormats[0])
        let out = Self.dest()
        try await r.extract(["d/e\u{0}\u{0301}.txt"], to: out, progress: nil)
        #expect(Self.regularBytes(out.appendingPathComponent("d/\(Self.nfc)")) == Data("accent".utf8))
    }

    @Test func normalizeComposesToNFC() {
        #expect(EntryPath.normalize("./d/\(Self.nfd)").map { Array($0.unicodeScalars) }
                == Array("d/\(Self.nfc)".unicodeScalars))
        // A lone combining mark after "/" stays its own component; "/" and ".." are never absorbed.
        #expect(EntryPath.normalize("a/\u{0301}b").map { Array($0.unicodeScalars) }
                == Array("a/\u{0301}b".unicodeScalars))
        #expect(EntryPath.normalize("../\u{0301}/..") == "\u{0301}")
    }

    @Test func rar4UnicodeByListedAndDecomposedPath() async throws {
        let url = ReaderListingTests.fixture("third-party/rar/rar4-unicode.rar")
        try #require(FileManager.default.fileExists(atPath: url.path), "corpus missing")
        let r = try await LibArchiveReader.open(at: url, password: nil)
        // The manifest spells the names decomposed (た + U+3099); the listing is NFC (だ).
        let decomposed = "\u{8868}\u{305F}\u{3099}\u{3088}/\u{6F22}\u{5B57}\u{9577}\u{3044}\u{30D5}\u{30A1}\u{30A4}\u{30EB}\u{540D}long-filename-in-\u{6F22}\u{5B57}.txt"
        let composed = decomposed.precomposedStringWithCanonicalMapping
        #expect(r.entries.contains { Array($0.path.unicodeScalars) == Array(composed.unicodeScalars) })
        for spelling in [composed, decomposed] {
            // A fresh reader per spelling, kept alive: the cache directory goes away with its reader.
            let fresh = try await LibArchiveReader.open(at: url, password: nil)
            let t = try await fresh.extractToTemporaryFile(spelling)
            #expect(Self.regularBytes(t)?.count == 5)
            let out = Self.dest()
            try await r.extract([spelling], to: out, progress: nil)
            #expect(Self.regularBytes(out.appending(path: composed))?.count == 5)
        }
    }

    // MARK: - No data reads for symlink, directory or data-less hardlink entries

    static func symlinkTarget(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    @Test func rar5SymlinkExtractsAll() async throws {
        let url = ReaderListingTests.fixture("third-party/rar/rar5-symlink.rar")
        try #require(FileManager.default.fileExists(atPath: url.path), "corpus missing")
        let r = try await LibArchiveReader.open(at: url, password: nil)
        let out = Self.dest()
        try await r.extract(nil, to: out, progress: nil)
        #expect(Self.symlinkTarget(out.appendingPathComponent("dirlink")) == "dir")
        #expect(Self.symlinkTarget(out.appendingPathComponent("symlink.txt")) == "file.txt")
        #expect(Self.regularBytes(out.appendingPathComponent("file.txt"))?.count == 5)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("dir").path, isDirectory: &isDir)
                && isDir.boolValue)
        // Selected alone, and through the temp-file path.
        let one = Self.dest()
        try await r.extract(["dirlink"], to: one, progress: nil)
        #expect(Self.symlinkTarget(one.appendingPathComponent("dirlink")) == "dir")
        #expect(Self.regularBytes(try await r.extractToTemporaryFile("symlink.txt"))?.count == 5)
        await #expect(throws: ArchiveError.entryNotFound("dirlink")) { try await r.extractToTemporaryFile("dirlink") }
    }

    @Test func tarSymlinkToDirectoryExtractsAsSymlink() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["dir/f.txt": Data("in-dir".utf8), "top.txt": Data("top".utf8)], in: dir)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("dirlink").path,
                                                   withDestinationPath: "dir")
        try Fixtures.bsdtar(["-cf", "t.tar", "dir", "dirlink", "top.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        let out = Self.dest()
        try await r.extract(nil, to: out, progress: nil)
        #expect(Self.symlinkTarget(out.appendingPathComponent("dirlink")) == "dir")
        #expect(Self.regularBytes(out.appendingPathComponent("dir/f.txt")) == Data("in-dir".utf8))
        #expect(Self.regularBytes(out.appendingPathComponent("top.txt")) == Data("top".utf8))
        let one = Self.dest()
        try await r.extract(["dirlink"], to: one, progress: nil)
        #expect(Self.symlinkTarget(one.appendingPathComponent("dirlink")) == "dir")
    }

    // MARK: - AppleDouble "._" files extract raw

    /// A real AppleDouble file (ditto --sequesterRsrc of a file with one xattr), 188 bytes.
    static let appleDouble: Data = {
        let hex = "00051607000200004d6163204f53205820202020202020200002000000090000"
            + "00320000008a00000002000000bc000000000000000000000000000000000000"
            + "00000000000000000000000000000000000000004154545200000000000000bc"
            + "000000b00000000c00000000000000000000000000000002000000b00000000b"
            + "000015636f6d2e6170706c652e70726f76656e616e636500000000bb00000001"
            + "00000d636f6d2e6b65726e69722e74000102003ca8b2088745f67931"
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return Data(bytes)
    }()

    @Test func appleDoubleFilesExtractRaw() async throws {
        #expect(Self.appleDouble.count == 188)
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a": Data("data-a".utf8), "._a": Self.appleDouble,
                            "__MACOSX/._a": Self.appleDouble], in: dir)
        try Fixtures.bsdtar(["--no-mac-metadata", "--format", "zip", "-cf", "t.zip", "a", "._a", "__MACOSX"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.zip"), password: nil)
        #expect(Set(r.entries.map(\.path)) == ["a", "._a", "__MACOSX", "__MACOSX/._a"])
        let out = Self.dest()
        try await r.extract(nil, to: out, progress: nil)
        #expect(Self.regularBytes(out.appendingPathComponent("._a")) == Self.appleDouble)
        #expect(Self.regularBytes(out.appendingPathComponent("__MACOSX/._a")) == Self.appleDouble)
        #expect(Self.regularBytes(out.appendingPathComponent("a")) == Data("data-a".utf8))
        // The AppleDouble was not applied to "a" either.
        #expect(getxattr(out.appendingPathComponent("a").path, "com.kernir.t", nil, 0, 0, XATTR_NOFOLLOW) < 0,
                "a gained the AppleDouble's xattr")
        // The temp-file path writes the same raw bytes.
        #expect(Self.regularBytes(try await r.extractToTemporaryFile("._a")) == Self.appleDouble)
    }

    // MARK: - Truncated tar.gz / tar.xz are detected, then fail as corrupted

    struct Cut: Sendable, CustomTestStringConvertible {
        let name: String
        let flag: String
        let bytes: Int
        let expected: ArchiveFormat
        var testDescription: String { "\(name) \(bytes / 1024) KiB" }
    }
    // Small: the whole decompressed stream is under the filters' 64 KiB output block, so libarchive
    // fails before bidding any format. Large: the first block decodes, the failure comes later.
    static let cuts = [Cut(name: "t.tar.gz", flag: "-z", bytes: 20_000, expected: .tarGzip),
                       Cut(name: "t.tar.xz", flag: "-J", bytes: 20_000, expected: .tarXz),
                       Cut(name: "t.tar.gz", flag: "-z", bytes: 400_000, expected: .tarGzip),
                       Cut(name: "t.tar.xz", flag: "-J", bytes: 400_000, expected: .tarXz)]

    static func truncatedTar(_ c: Cut) throws -> URL {
        let dir = Fixtures.tempDir()
        let random = Data((0..<c.bytes).map { _ in UInt8.random(in: 0...255) })
        Fixtures.makeFiles(["big.bin": random, "small.txt": Data("small".utf8)], in: dir)
        try Fixtures.bsdtar(["-cf", c.name, "--format", "pax", c.flag, "small.txt", "big.bin"], cwd: dir)
        let url = dir.appendingPathComponent(c.name)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: UInt64(size.doubleValue * 0.6))
        try h.close()
        return url
    }

    @Test(arguments: cuts)
    func truncatedCompressedTarIsDetectedThenCorrupted(_ c: Cut) async throws {
        let url = try Self.truncatedTar(c)
        #expect(LibArchiveReader.detectFormat(at: url) == c.expected)
        #expect(Archive.detectFormat(at: url) == c.expected)
        // open is where the engine fails: listing needs every header, and the stream ends early.
        await #expect {
            _ = try await LibArchiveReader.open(at: url, password: nil)
        } throws: { error in
            if case .corrupted = error as? ArchiveError { return true }
            return false
        }
    }

    @Test func truncatedGzipWithNameFieldIsDetected() throws {
        // /usr/bin/gzip writes FNAME, so the deflate data starts after a NUL-terminated name.
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["big.bin": Data((0..<20_000).map { _ in UInt8.random(in: 0...255) })], in: dir)
        try Fixtures.bsdtar(["-cf", "named.tar", "big.bin"], cwd: dir)
        try Fixtures.run("/usr/bin/gzip", ["named.tar"], cwd: dir)
        let url = dir.appendingPathComponent("named.tar.gz")
        let bytes = try Data(contentsOf: url)
        #expect(bytes[3] & 0x08 != 0, "gzip wrote no FNAME")
        try bytes.prefix(bytes.count * 6 / 10).write(to: url)
        #expect(LibArchiveReader.detectFormat(at: url) == .tarGzip)
    }

    @Test func truncatedFixturesAreDetected() throws {
        for (f, expected) in [("corrupt/truncated.tar.gz", ArchiveFormat.tarGzip),
                              ("corrupt/truncated.tar.xz", .tarXz)] {
            let url = ReaderListingTests.fixture(f)
            try #require(FileManager.default.fileExists(atPath: url.path), "corpus missing")
            #expect(LibArchiveReader.detectFormat(at: url) == expected, "\(f)")
        }
    }

    @Test func gzipOrXzMagicWithoutTarHeaderStaysNil() throws {
        let dir = Fixtures.tempDir()
        let junk = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
        let gz = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]) + junk
        let xz = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0x00, 0x04]) + junk
        Fixtures.makeFiles(["j.gz": gz, "j.xz": xz, "m.gz": Data([0x1F, 0x8B])], in: dir)
        for n in ["j.gz", "j.xz", "m.gz"] {
            #expect(LibArchiveReader.detectFormat(at: dir.appendingPathComponent(n)) == nil, "\(n)")
        }
    }

    // MARK: - Hardlink chains (temp-file resolver and selected-alone extraction)

    enum Node { case file(String), symlink(String), hardlink(String), directory, fifo }

    /// Writes a pax tar with entries in the given order; bsdtar cannot write hardlink chains.
    static func craftedTar(_ nodes: [(String, Node)]) throws -> URL {
        let url = Fixtures.tempDir().appendingPathComponent("chain.tar")
        let a = try #require(archive_write_new())
        defer { archive_write_free(a) }
        #expect(archive_write_set_format_pax_restricted(a) == ARCHIVE_OK)
        #expect(archive_write_open_filename(a, url.path) == ARCHIVE_OK)
        for (path, node) in nodes {
            let e = try #require(archive_entry_new())
            defer { archive_entry_free(e) }
            archive_entry_set_pathname(e, path)
            archive_entry_set_perm(e, 0o644)
            archive_entry_set_mtime(e, 981_158_400, 0)
            var data = Data()
            switch node {
            case .file(let s):
                data = Data(s.utf8)
                archive_entry_set_filetype(e, UInt32(S_IFREG))
                archive_entry_set_size(e, Int64(data.count))
            case .symlink(let t):
                archive_entry_set_filetype(e, UInt32(S_IFLNK))
                archive_entry_set_symlink(e, t)
            case .fifo:
                archive_entry_set_filetype(e, UInt32(S_IFIFO))
            case .directory:
                archive_entry_set_filetype(e, UInt32(S_IFDIR))
                archive_entry_set_perm(e, 0o755)
            case .hardlink(let t):
                archive_entry_set_filetype(e, UInt32(S_IFREG))
                archive_entry_set_hardlink(e, t)
                archive_entry_set_size(e, 0)
            }
            #expect(archive_write_header(a, e) == ARCHIVE_OK, "\(path)")
            if !data.isEmpty {
                _ = data.withUnsafeBytes { archive_write_data(a, $0.baseAddress, $0.count) }
            }
        }
        #expect(archive_write_close(a) == ARCHIVE_OK)
        return url
    }

    static func chainReader(_ nodes: [(String, Node)]) async throws -> LibArchiveReader {
        try await LibArchiveReader.open(at: try craftedTar(nodes), password: nil)
    }

    @Test func tempFileFollowsHardlinkChainOntoSymlink() async throws {
        // h -> g -> s (hardlink, hardlink, symlink), s -> f.
        let r = try await Self.chainReader([("f", .file("data-f")), ("s", .symlink("f")),
                                            ("g", .hardlink("s")), ("h", .hardlink("g"))])
        #expect(Self.regularBytes(try await r.extractToTemporaryFile("h")) == Data("data-f".utf8))
        #expect(Self.regularBytes(try await r.extractToTemporaryFile("g")) == Data("data-f".utf8))
    }

    @Test func tempFileHardlinkChainOntoAbsoluteSymlinkIsNotFound() async throws {
        let r = try await Self.chainReader([("s", .symlink("/etc/hosts")),
                                            ("g", .hardlink("s")), ("h", .hardlink("g"))])
        await #expect(throws: ArchiveError.entryNotFound("h")) { try await r.extractToTemporaryFile("h") }
    }

    @Test func tempFileSymlinkOntoHardlinkChainReturnsData() async throws {
        // s -> h, h -> g -> f (hardlinks); the data sits on f.
        let r = try await Self.chainReader([("f", .file("data-f")), ("g", .hardlink("f")),
                                            ("h", .hardlink("g")), ("s", .symlink("h"))])
        #expect(Self.regularBytes(try await r.extractToTemporaryFile("s")) == Data("data-f".utf8))
        #expect(Self.regularBytes(try await r.extractToTemporaryFile("h")) == Data("data-f".utf8))
    }

    @Test func tempFileMissingHardlinkTargetIsNotFound() async throws {
        let r = try await Self.chainReader([("f", .file("data-f")), ("h", .hardlink("missing"))])
        await #expect(throws: ArchiveError.entryNotFound("h")) { try await r.extractToTemporaryFile("h") }
        let s = try await Self.chainReader([("f", .file("data-f")), ("h", .hardlink("missing")), ("s", .symlink("h"))])
        await #expect(throws: ArchiveError.entryNotFound("s")) { try await s.extractToTemporaryFile("s") }
    }

    @Test func hardlinkJumpsCountTowardTheHopBound() async throws {
        // h1 -> h2 -> ... -> h9 -> f: nine hardlink jumps from h1, eight from h2.
        var nodes: [(String, Node)] = [("f", .file("data-f")), ("h9", .hardlink("f"))]
        for i in stride(from: 8, through: 1, by: -1) { nodes.append(("h\(i)", .hardlink("h\(i + 1)"))) }
        let r = try await Self.chainReader(nodes)
        #expect(Self.regularBytes(try await r.extractToTemporaryFile("h2")) == Data("data-f".utf8))
        await #expect(throws: ArchiveError.entryNotFound("h1")) { try await r.extractToTemporaryFile("h1") }
    }

    static func longChain() -> [(String, Node)] {
        var nodes: [(String, Node)] = [("f", .file("data-f")), ("h9", .hardlink("f"))]
        for i in stride(from: 8, through: 1, by: -1) { nodes.append(("h\(i)", .hardlink("h\(i + 1)"))) }
        return nodes
    }

    @Test func extractHopBoundMatchesTempFile() async throws {
        // h1 -> ... -> h9 -> f: eight hops from h2 work, nine from h1 do not, on both paths.
        let r = try await Self.chainReader(Self.longChain())
        let ok = Self.dest()
        try await r.extract(["h2"], to: ok, progress: nil)
        #expect(Self.regularBytes(ok.appendingPathComponent("h2")) == Data("data-f".utf8))
        await #expect {
            try await r.extract(["h1"], to: Self.dest(), progress: nil)
        } throws: { error in
            if case .corrupted = error as? ArchiveError { return true }
            return false
        }
        await #expect(throws: ArchiveError.entryNotFound("h1")) { try await r.extractToTemporaryFile("h1") }
    }

    @Test func hardlinkChainEndingOnNonRegularEntryIsCorrupted() async throws {
        // h -> g -> s (symlink), hd -> d (directory), hp -> p (FIFO): extract must not write a copy of
        // a non-regular entry at the link's path.
        let r = try await Self.chainReader([("f", .file("data-f")), ("s", .symlink("f")),
                                            ("g", .hardlink("s")), ("h", .hardlink("g")),
                                            ("d", .directory), ("hd", .hardlink("d")),
                                            ("p", .fifo), ("hp", .hardlink("p"))])
        for link in ["h", "g", "hd", "hp"] {
            let out = Self.dest()
            await #expect {
                try await r.extract([link], to: out, progress: nil)
            } throws: { error in
                if case .corrupted = error as? ArchiveError { return true }
                return false
            }
            var st = stat()
            #expect(lstat(out.appendingPathComponent(link).path, &st) != 0, "\(link) was written")
        }
        // The temp-file path is unchanged: h resolves through s to f; hd hits a directory.
        #expect(Self.regularBytes(try await r.extractToTemporaryFile("h")) == Data("data-f".utf8))
        await #expect(throws: ArchiveError.entryNotFound("hd")) { try await r.extractToTemporaryFile("hd") }
    }

    @Test func extractHardlinkChainSelectedAloneGetsTargetBytes() async throws {
        let r = try await Self.chainReader([("f", .file("data-f")), ("g", .hardlink("f")), ("h", .hardlink("g"))])
        let out = Self.dest()
        try await r.extract(["h"], to: out, progress: nil)
        #expect(Self.regularBytes(out.appendingPathComponent("h")) == Data("data-f".utf8))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("f").path))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("g").path))
        // h and g selected together, f not: both get the bytes.
        let both = Self.dest()
        try await r.extract(["h", "g"], to: both, progress: nil)
        #expect(Self.regularBytes(both.appendingPathComponent("h")) == Data("data-f".utf8))
        #expect(Self.regularBytes(both.appendingPathComponent("g")) == Data("data-f".utf8))
        // Everything: still a correct tree.
        let all = Self.dest()
        try await r.extract(nil, to: all, progress: nil)
        for n in ["f", "g", "h"] {
            #expect(Self.regularBytes(all.appendingPathComponent(n)) == Data("data-f".utf8), "\(n)")
        }
    }

    static let linkFormats = [Fmt(name: "t.iso", args: ["--format", "iso9660"]),
                              Fmt(name: "t.xar", args: ["--format", "xar"])]

    /// f, h (hardlink to f), s -> h, made by bsdtar, which writes ISO and XAR hardlinks.
    static func bsdtarLinkReader(_ f: Fmt) async throws -> LibArchiveReader {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["f": Data("data-f".utf8)], in: dir)
        try Fixtures.run("/bin/ln", ["f", "h"], cwd: dir)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("s").path, withDestinationPath: "h")
        try Fixtures.bsdtar(["-cf", f.name] + f.args + ["f", "h", "s"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent(f.name), password: nil)
        try #require(r.hasHardlinks, "\(f.name) has no hardlink entry")
        return r
    }

    @Test(arguments: linkFormats)
    func hardlinkSelectedAloneInISOAndXAR(_ f: Fmt) async throws {
        let r = try await Self.bsdtarLinkReader(f)
        let link = try #require(r.hardlinkTargetByPath.first?.key)
        let out = Self.dest()
        try await r.extract([link], to: out, progress: nil)
        #expect(Self.regularBytes(out.appendingPathComponent(link)) == Data("data-f".utf8))
        #expect(Self.regularBytes(try await r.extractToTemporaryFile(link)) == Data("data-f".utf8))
        #expect(Self.regularBytes(try await r.extractToTemporaryFile("s")) == Data("data-f".utf8))
        let all = Self.dest()
        try await r.extract(nil, to: all, progress: nil)
        for n in ["f", "h"] { #expect(Self.regularBytes(all.appendingPathComponent(n)) == Data("data-f".utf8), "\(n)") }
    }

    // MARK: - Tar "._" companions are listed and extracted raw

    /// Entry names in a ustar/pax tar, skipping pax and GNU extension headers.
    static func rawTarNames(_ data: Data) -> [String] {
        let b = [UInt8](data)
        var names: [String] = []
        var off = 0
        while off + 512 <= b.count {
            let h = b[off..<off + 512]
            if h.allSatisfy({ $0 == 0 }) { break }
            let nameBytes = h.prefix(100).prefix { $0 != 0 }
            let sizeField = String(decoding: b[off + 124..<off + 136].prefix { $0 != 0 && $0 != 0x20 }, as: UTF8.self)
            let size = Int(sizeField, radix: 8) ?? 0
            let type = b[off + 156]
            if ![UInt8(ascii: "x"), UInt8(ascii: "g"), UInt8(ascii: "L"), UInt8(ascii: "K")].contains(type) {
                names.append(String(decoding: nameBytes, as: UTF8.self))
            }
            off += 512 + (size + 511) / 512 * 512
        }
        return names
    }

    @Test func appleBsdtarMacMetadataCompanionIsListedAndExtractedRaw() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["f": Data("data-f".utf8)], in: dir)
        try Fixtures.run("/usr/bin/xattr", ["-w", "com.kernir.test", "1", "f"], cwd: dir)
        // Apple bsdtar WITHOUT --no-mac-metadata writes an AppleDouble companion before f.
        try Fixtures.bsdtar(["-cf", "t.tar", "f"], cwd: dir)
        let url = dir.appendingPathComponent("t.tar")
        let raw = Self.rawTarNames(try Data(contentsOf: url))
        try #require(raw == ["._f", "f"], "bsdtar emitted \(raw)")

        let r = try await LibArchiveReader.open(at: url, password: nil)
        #expect(r.entries.map(\.path) == ["._f", "f"])
        let out = Self.dest()
        try await r.extract(nil, to: out, progress: nil)
        let companion = try #require(Self.regularBytes(out.appendingPathComponent("._f")))
        #expect(companion.prefix(8) == Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]), "AppleDouble header")
        #expect(Self.regularBytes(out.appendingPathComponent("f")) == Data("data-f".utf8))
        #expect(getxattr(out.appendingPathComponent("f").path, "com.kernir.test", nil, 0, 0, XATTR_NOFOLLOW) < 0)
        #expect(Self.regularBytes(try await r.extractToTemporaryFile("._f")) == companion)
    }
}
