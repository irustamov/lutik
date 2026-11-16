import Testing
import Foundation
@testable import KernirCore

struct TemporaryFileTests {
    static func zipReader(_ files: [String: Data]) async throws -> LibArchiveReader {
        let url = try Fixtures.archive("t.zip", bsdtarArgs: ["--format", "zip"], files: files)
        return try await LibArchiveReader.open(at: url, password: nil)
    }

    @Test func tempFileHasContentAndName() async throws {
        let r = try await Self.zipReader(["a/b/c.txt": Data("content".utf8)])
        let url = try await r.extractToTemporaryFile("a/b/c.txt")
        #expect(url.lastPathComponent == "c.txt")
        #expect(try Data(contentsOf: url) == Data("content".utf8))
    }

    @Test func secondCallIsCached() async throws {
        let r = try await Self.zipReader(["c.txt": Data("content".utf8)])
        let u1 = try await r.extractToTemporaryFile("c.txt")
        // A fresh extraction would replace this file with the archive's bytes.
        try Data("sentinel".utf8).write(to: u1)
        let u2 = try await r.extractToTemporaryFile("c.txt")
        #expect(u1 == u2)
        #expect(try Data(contentsOf: u2) == Data("sentinel".utf8))
    }

    @Test func synthesizedDirectoryThrows() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a/c.txt": Data("x".utf8)], in: dir)
        try Fixtures.bsdtar(["-cf", "t.tar", "a/c.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        #expect(r.headerOrdinalByPath["a"] == nil)
        #expect(r.entries.contains { $0.path == "a" && $0.isDirectory })
        await #expect(throws: ArchiveError.entryNotFound("a")) { try await r.extractToTemporaryFile("a") }
    }

    static func symlinkReader(files: [String: Data], links: [String: String],
                              hardlinks: [String: String] = [:], fifos: [String] = []) async throws -> LibArchiveReader {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(files, in: dir)
        for f in fifos { try Fixtures.run("/usr/bin/mkfifo", [f], cwd: dir) }
        for (name, dest) in links {
            let u = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: u.path, withDestinationPath: dest)
        }
        // Hardlink name -> existing name; `ln -P` links the symlink itself, not its target.
        for (name, existing) in hardlinks { try Fixtures.run("/bin/ln", ["-P", existing, name], cwd: dir) }
        let top = Set((Array(files.keys) + Array(links.keys) + Array(hardlinks.keys) + fifos).map { String($0.split(separator: "/").first!) }).sorted()
        try Fixtures.bsdtar(["-cf", "t.tar"] + top, cwd: dir)
        return try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
    }

    static func expectRegular(_ url: URL, name: String, bytes: Data) throws {
        var st = stat()
        #expect(lstat(url.path, &st) == 0)
        #expect((st.st_mode & S_IFMT) == S_IFREG)
        #expect(url.lastPathComponent == name)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func symlinkSameDirReturnsTargetBytes() async throws {
        let r = try await Self.symlinkReader(files: ["file.txt": Data("target".utf8)], links: ["link": "file.txt"])
        try Self.expectRegular(try await r.extractToTemporaryFile("link"), name: "link", bytes: Data("target".utf8))
    }

    @Test func symlinkToSiblingDirReturnsTargetBytes() async throws {
        let r = try await Self.symlinkReader(files: ["x/file": Data("sib".utf8)], links: ["d/link": "../x/file"])
        try Self.expectRegular(try await r.extractToTemporaryFile("d/link"), name: "link", bytes: Data("sib".utf8))
    }

    @Test func symlinkChainResolves() async throws {
        let r = try await Self.symlinkReader(files: ["file.txt": Data("chain".utf8)],
                                             links: ["l1": "l2", "l2": "file.txt"])
        try Self.expectRegular(try await r.extractToTemporaryFile("l1"), name: "l1", bytes: Data("chain".utf8))
    }

    @Test func badSymlinksThrowEntryNotFound() async throws {
        let r = try await Self.symlinkReader(
            files: ["file.txt": Data("x".utf8), "dir/f": Data("y".utf8)],
            links: ["dangling": "nope", "abs": "/etc/hosts", "esc": "../../outside",
                    "loopA": "loopB", "loopB": "loopA", "todir": "dir", "up": "dir/../.."])
        for name in ["dangling", "abs", "esc", "loopA", "todir", "up"] {
            await #expect(throws: ArchiveError.entryNotFound(name)) { try await r.extractToTemporaryFile(name) }
        }
    }

    @Test func ws7LinksTarSymlinks() async throws {
        let r = try await LibArchiveReader.open(at: ReaderListingTests.fixture("tar/links.tar"), password: nil)
        let hello = try await r.extractToTemporaryFile("hello.txt")
        let link = try await r.extractToTemporaryFile("link-to-hello")
        try Self.expectRegular(link, name: "link-to-hello", bytes: Data("Hello, Kernir!\n".utf8))
        #expect(try Data(contentsOf: hello) == Data("Hello, Kernir!\n".utf8))
        await #expect(throws: ArchiveError.entryNotFound("dangling")) { try await r.extractToTemporaryFile("dangling") }
    }

    @Test func directoryThrows() async throws {
        let r = try await Self.zipReader(["a/c.txt": Data("x".utf8)])
        await #expect(throws: ArchiveError.entryNotFound("a")) { try await r.extractToTemporaryFile("a") }
        await #expect(throws: ArchiveError.entryNotFound("a/")) { try await r.extractToTemporaryFile("a/") }
        await #expect(throws: ArchiveError.entryNotFound("nope.txt")) { try await r.extractToTemporaryFile("nope.txt") }
    }

    @Test func twoReadersDontShareCache() async throws {
        let url = try Fixtures.archive("t.zip", bsdtarArgs: ["--format", "zip"], files: ["c.txt": Data("x".utf8)])
        let r1 = try await LibArchiveReader.open(at: url, password: nil)
        let r2 = try await LibArchiveReader.open(at: url, password: nil)
        #expect(r1.cache.root != r2.cache.root)
        let u1 = try await r1.extractToTemporaryFile("c.txt")
        let u2 = try await r2.extractToTemporaryFile("c.txt")
        #expect(u1 != u2)
    }

    @Test func cacheRootRemovedOnDeinit() async throws {
        var r: LibArchiveReader? = try await Self.zipReader(["c.txt": Data("x".utf8)])
        let url = try await r!.extractToTemporaryFile("c.txt")
        let root = r!.cache.root
        #expect(FileManager.default.fileExists(atPath: url.path))
        r = nil
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func noStagingLeftBehind() async throws {
        let r = try await Self.zipReader(["c.txt": Data("x".utf8)])
        _ = try await r.extractToTemporaryFile("c.txt")
        let names = try FileManager.default.contentsOfDirectory(atPath: r.cache.root.path)
        #expect(!names.contains { $0.hasPrefix(".staging-") })
    }

    @Test func concurrentCallsReturnCompleteFiles() async throws {
        let big = Data((0..<2_000_000).map { UInt8($0 & 0xff) })
        let r = try await Self.zipReader(["d/big.bin": big])
        let urls = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<8 { group.addTask { try await r.extractToTemporaryFile("d/big.bin") } }
            var out: [URL] = []
            for try await u in group { out.append(u); #expect(try Data(contentsOf: u) == big) }
            return out
        }
        #expect(Set(urls).count == 1)
        #expect(try Data(contentsOf: urls[0]) == big)
    }

    @Test func hardlinkAloneGetsTargetBytesViaTempFile() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["hello.txt": Data("hello bytes".utf8)], in: dir)
        try FileManager.default.linkItem(at: dir.appendingPathComponent("hello.txt"),
                                         to: dir.appendingPathComponent("link.txt"))
        try Fixtures.bsdtar(["-cf", "t.tar", "hello.txt", "link.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        let url = try await r.extractToTemporaryFile("link.txt")
        #expect(url.lastPathComponent == "link.txt")
        #expect(try Data(contentsOf: url) == Data("hello bytes".utf8))
    }

    @Test func ws7LinksTarHardlinkViaTempFile() async throws {
        let r = try await LibArchiveReader.open(at: ReaderListingTests.fixture("tar/links.tar"), password: nil)
        let link = try await r.extractToTemporaryFile("hardlink-to-hello")
        let target = try await r.extractToTemporaryFile("hello.txt")
        let data = try Data(contentsOf: link)
        #expect(data.count == 15)
        #expect(data == (try Data(contentsOf: target)))
    }

    // Names sort so the symlink ("a_sym") is archived before its hardlink ("b_hard").
    @Test func hardlinkToSymlinkOutsideArchiveThrows() async throws {
        let r = try await Self.symlinkReader(files: [:], links: ["a_sym": "/etc/hosts"], hardlinks: ["b_hard": "a_sym"])
        await #expect(throws: ArchiveError.entryNotFound("b_hard")) { try await r.extractToTemporaryFile("b_hard") }
        await #expect(throws: ArchiveError.entryNotFound("a_sym")) { try await r.extractToTemporaryFile("a_sym") }
    }

    @Test func hardlinkToSymlinkInArchiveReturnsTargetBytes() async throws {
        let r = try await Self.symlinkReader(files: ["file.txt": Data("hl".utf8)], links: ["a_sym": "file.txt"],
                                             hardlinks: ["b_hard": "a_sym"])
        try Self.expectRegular(try await r.extractToTemporaryFile("b_hard"), name: "b_hard", bytes: Data("hl".utf8))
    }

    @Test func symlinkChainThroughHardlinkToSymlink() async throws {
        let r = try await Self.symlinkReader(files: ["file.txt": Data("hc".utf8)],
                                             links: ["a_sym": "file.txt", "c_link": "b_hard"],
                                             hardlinks: ["b_hard": "a_sym"])
        try Self.expectRegular(try await r.extractToTemporaryFile("c_link"), name: "c_link", bytes: Data("hc".utf8))
    }

    @Test func fifoEntryThrows() async throws {
        let r = try await Self.symlinkReader(files: ["file.txt": Data("x".utf8)], links: [:], fifos: ["pipe"])
        await #expect(throws: ArchiveError.entryNotFound("pipe")) { try await r.extractToTemporaryFile("pipe") }
        let cached = r.cache.cachedURL(for: "pipe")
        #expect(cached == nil)
    }

    @Test func combiningMarkAfterDotDotIsAnEscape() async throws {
        // A file named "\u{0301}x" is what the buggy Character split would resolve to after dropping "..".
        let r = try await Self.symlinkReader(files: ["\u{0301}x": Data("x".utf8)], links: ["link": "../\u{0301}x"])
        await #expect(throws: ArchiveError.entryNotFound("link")) { try await r.extractToTemporaryFile("link") }
    }

    @Test func hopLimitIsEight() async throws {
        func chain(_ n: Int) -> [String: String] {
            var l: [String: String] = [:]
            for i in 1..<n { l["l\(i)"] = "l\(i + 1)" }
            l["l\(n)"] = "file.txt"
            return l
        }
        let ok = try await Self.symlinkReader(files: ["file.txt": Data("hop".utf8)], links: chain(8))
        try Self.expectRegular(try await ok.extractToTemporaryFile("l1"), name: "l1", bytes: Data("hop".utf8))
        let tooLong = try await Self.symlinkReader(files: ["file.txt": Data("hop".utf8)], links: chain(9))
        await #expect(throws: ArchiveError.entryNotFound("l1")) { try await tooLong.extractToTemporaryFile("l1") }
    }

    @Test func symlinkToHardlinkGroupMemberReturnsDataInNewc() async throws {
        // In cpio newc the data sits on the LAST link of a hardlink group (g), not on f.
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["f": Data("newc-data".utf8)], in: dir)
        try Fixtures.run("/bin/ln", ["f", "g"], cwd: dir)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("s").path, withDestinationPath: "g")
        try Fixtures.bsdtar(["-cf", "t.cpio", "--format", "newc", "f", "g", "s"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.cpio"), password: nil)
        try Self.expectRegular(try await r.extractToTemporaryFile("s"), name: "s", bytes: Data("newc-data".utf8))
    }

    @Test(arguments: ["f", "g", "h"])
    func newcHardlinkGroupMemberViaTempFile(_ member: String) async throws {
        // f (plain, empty), g -> f (empty), h -> f (the data): every member returns the bytes.
        let r = try await ExtractTests.cpioGroupReader("newc")
        try Self.expectRegular(try await r.extractToTemporaryFile(member), name: member, bytes: ExtractTests.groupBytes)
    }

    @Test func combiningMarkInLinkParentPathIsNotMergedWithSlash() async throws {
        // "a/\u{0301}b" must split into a, \u{0301}b so that ".." lands in "a", not at the root.
        let r = try await Self.symlinkReader(files: ["y": Data("root".utf8), "a/y": Data("inA".utf8)],
                                             links: ["a/\u{0301}b/l": "../y"])
        try Self.expectRegular(try await r.extractToTemporaryFile("a/\u{0301}b/l"), name: "l", bytes: Data("inA".utf8))
    }
}
