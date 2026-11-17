import Testing
import Foundation
@testable import KernirCore

struct ExtractTests {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        private var lastPath: String?
        func add(_ v: Double, _ path: String? = nil) { lock.lock(); values.append(v); lastPath = path; lock.unlock() }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
        var last: String? { lock.lock(); defer { lock.unlock() }; return lastPath }
    }

    final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Error>?
        func set(_ t: Task<Void, Error>) { lock.lock(); task = t; lock.unlock() }
        func cancel() {
            while true {
                lock.lock(); let t = task; lock.unlock()
                if let t { t.cancel(); return }
                usleep(100)
            }
        }
    }

    static let mtime = Date(timeIntervalSince1970: 981_158_400) // 2001-02-03

    static func dest() -> URL { Fixtures.tempDir().appendingPathComponent("out", isDirectory: true) }

    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    struct Fmt: Sendable, CustomTestStringConvertible {
        let name: String
        let args: [String]
        var testDescription: String { name }
    }

    @Test(arguments: [Fmt(name: "t.tar.gz", args: ["--format", "pax", "-z"]),
                      Fmt(name: "t.zip", args: ["--format", "zip"])])
    func extractAllRecreatesTreeWithDatesAndPermissions(_ f: Fmt) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["d/f.bin": Data("payload".utf8), "top.txt": Data("top".utf8)], in: dir)
        for p in ["d/f.bin", "top.txt"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o751, .modificationDate: Self.mtime],
                                                  ofItemAtPath: dir.appendingPathComponent(p).path)
        }
        try Fixtures.bsdtar(["-cf", f.name] + f.args + ["d", "top.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent(f.name), password: nil)
        let out = Self.dest()
        try await r.extract(nil, to: out, progress: nil)
        for p in ["d/f.bin", "top.txt"] {
            let u = out.appendingPathComponent(p)
            let attrs = try FileManager.default.attributesOfItem(atPath: u.path)
            #expect(try Data(contentsOf: u) == Data(contentsOf: dir.appendingPathComponent(p)))
            #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o751, "\(p)")
            let m = try #require(attrs[.modificationDate] as? Date)
            #expect(abs(m.timeIntervalSince(Self.mtime)) <= 2, "\(p) \(m)")
        }
    }

    @Test func extractSelectionOnlyWritesSelected() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a/b/c.txt": Data("hello".utf8), "top.txt": Data("x".utf8)], in: dir)
        try Fixtures.bsdtar(["-cf", "t.tar", "a", "top.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        let out = Self.dest()
        try await r.extract(["a"], to: out, progress: nil)
        #expect(try Data(contentsOf: out.appendingPathComponent("a/b/c.txt")) == Data("hello".utf8))
        #expect(!Self.exists(out.appendingPathComponent("top.txt")))
    }

    @Test func extractUnknownPathThrows() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data("x".utf8)], in: dir)
        try Fixtures.bsdtar(["-cf", "t.tar", "a.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        let out = Self.dest()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        await #expect(throws: ArchiveError.entryNotFound("nope")) {
            try await r.extract(["nope"], to: out, progress: nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func pathTraversalStaysInside() async throws {
        let root = Fixtures.tempDir()
        let src = root.appendingPathComponent("src")
        Fixtures.makeFiles(["evil.txt": Data("evil".utf8)], in: src)
        try Fixtures.bsdtar(["-cf", "t.tar", "-P", "-s", ",^,../../,", "evil.txt"], cwd: src)
        let r = try await LibArchiveReader.open(at: src.appendingPathComponent("t.tar"), password: nil)
        let out = root.appendingPathComponent("d1/d2/out")
        try await r.extract(nil, to: out, progress: nil)
        #expect(Self.exists(out.appendingPathComponent("evil.txt")))
        #expect(!Self.exists(out.appendingPathComponent("../../evil.txt")))
        #expect(!Self.exists(root.appendingPathComponent("evil.txt")))
    }

    @Test func symlinkEscapeIsRefused() async throws {
        let root = Fixtures.tempDir()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let one = root.appendingPathComponent("one")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: one.appendingPathComponent("link").path,
                                                   withDestinationPath: outside.path)
        try Fixtures.bsdtar(["-cf", "../t.tar", "link"], cwd: one)
        let two = root.appendingPathComponent("two")
        Fixtures.makeFiles(["link/pwn.txt": Data("pwn".utf8)], in: two)
        try Fixtures.bsdtar(["-rf", "../t.tar", "link/pwn.txt"], cwd: two)
        let r = try await LibArchiveReader.open(at: root.appendingPathComponent("t.tar"), password: nil)
        do {
            try await r.extract(nil, to: Self.dest(), progress: nil)
            Issue.record("expected throw")
        } catch let e as ArchiveError {
            guard case .io = e else { Issue.record("unexpected \(e)"); return }
        }
        #expect(!Self.exists(outside.appendingPathComponent("pwn.txt")))
    }

    @Test func progressReachesOneAndIsMonotonic() async throws {
        let dir = Fixtures.tempDir()
        var files: [String: Data] = [:]
        for i in 0..<5 { files["f\(i).bin"] = Data((0..<(300_000 + i * 50_000)).map { UInt8(truncatingIfNeeded: $0 &* 31) }) }
        files["empty.txt"] = Data()
        Fixtures.makeFiles(files, in: dir)
        try Fixtures.bsdtar(["-czf", "t.tar.gz"] + files.keys.sorted(), cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar.gz"), password: nil)
        let c = Collector()
        try await r.extract(nil, to: Self.dest()) { f, p in c.add(f, p) }
        let v = c.all
        #expect(v.count > 2)
        #expect(v.last == 1.0)
        #expect(c.last != nil)
        #expect(v.dropLast().allSatisfy { $0 < 1.0 })
        #expect(zip(v, v.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(v.allSatisfy { (0...1).contains($0) })
    }

    @Test func cancellationThrowsCancelled() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["big.bin": Data(count: 50_000_000)], in: dir)
        try Fixtures.bsdtar(["-cf", "t.tar", "big.bin"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        let out = Self.dest()
        let box = TaskBox()
        let task = Task { try await r.extract(nil, to: out) { _, _ in box.cancel() } }
        box.set(task)
        do {
            try await task.value
            Issue.record("expected throw")
        } catch {
            #expect(error as? ArchiveError == .cancelled)
        }
        #expect(!Self.exists(out.appendingPathComponent("big.bin")))
    }

    @Test func changedArchiveOnDiskThrows() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data("one".utf8)], in: dir)
        try Fixtures.bsdtar(["-cf", "t.tar", "a.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        Fixtures.makeFiles(["b.txt": Data(count: 4096), "c.txt": Data(count: 4096)], in: dir)
        try Fixtures.bsdtar(["-cf", "t.tar", "a.txt", "b.txt", "c.txt"], cwd: dir)
        await #expect(throws: ArchiveError.io("archive changed on disk")) {
            try await r.extract(nil, to: Self.dest(), progress: nil)
        }
    }

    @Test(arguments: ["aes", "zipcrypto"])
    func encryptedZipExtract(_ kind: String) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data("secret".utf8), "d/b.txt": Data("more".utf8)], in: dir)
        if kind == "aes" {
            try Fixtures.bsdtar(["-cf", "e.zip", "--format", "zip", "--options", "zip:encryption=aes256",
                                 "--passphrase", "pw", "a.txt", "d/b.txt"], cwd: dir)
        } else {
            try Fixtures.run("/usr/bin/zip", ["-q", "-P", "pw", "e.zip", "a.txt", "d/b.txt"], cwd: dir)
        }
        let url = dir.appendingPathComponent("e.zip")
        let plain = try await LibArchiveReader.open(at: url, password: nil)
        let out1 = Self.dest()
        await #expect(throws: ArchiveError.passwordRequired) {
            try await plain.extract(nil, to: out1, progress: nil)
        }
        #expect(!Self.exists(out1.appendingPathComponent("a.txt")))
        #expect(!Self.exists(out1.appendingPathComponent("d/b.txt")))
        let ok = try await LibArchiveReader.open(at: url, password: "pw")
        let out2 = Self.dest()
        try await ok.extract(nil, to: out2, progress: nil)
        #expect(try Data(contentsOf: out2.appendingPathComponent("a.txt")) == Data("secret".utf8))
        #expect(try Data(contentsOf: out2.appendingPathComponent("d/b.txt")) == Data("more".utf8))
    }

    @Test func hardlinkAloneGetsTargetBytes() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["hello.txt": Data("hello bytes".utf8)], in: dir)
        try FileManager.default.linkItem(at: dir.appendingPathComponent("hello.txt"),
                                         to: dir.appendingPathComponent("link.txt"))
        try Fixtures.bsdtar(["-cf", "t.tar", "hello.txt", "link.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        let out = Self.dest()
        try await r.extract(["link.txt"], to: out, progress: nil)
        #expect(try Data(contentsOf: out.appendingPathComponent("link.txt")) == Data("hello bytes".utf8))
        #expect(!Self.exists(out.appendingPathComponent("hello.txt")))

        // Both selected: a real hardlink is created.
        let both = Self.dest()
        try await r.extract(nil, to: both, progress: nil)
        let ids = try ["hello.txt", "link.txt"].map {
            try FileManager.default.attributesOfItem(atPath: both.appendingPathComponent($0).path)[.systemFileNumber] as? NSNumber
        }
        #expect(ids[0] == ids[1])
        #expect(try Data(contentsOf: both.appendingPathComponent("link.txt")) == Data("hello bytes".utf8))
    }

    @Test func linksTarHardlinkAloneGetsTargetBytes() async throws {
        let r = try await LibArchiveReader.open(at: ReaderListingTests.fixture("tar/links.tar"), password: nil)
        let out = Self.dest()
        try await r.extract(["hardlink-to-hello"], to: out, progress: nil)
        let data = try Data(contentsOf: out.appendingPathComponent("hardlink-to-hello"))
        #expect(data.count == 15)
        #expect(!Self.exists(out.appendingPathComponent("hello.txt")))
    }

    @Test func encrypted7zDataNeedsPassword() async throws {
        let r = try await LibArchiveReader.open(at: ReaderListingTests.fixture("7z/encrypted-data.7z"), password: nil)
        let out = Self.dest()
        await #expect(throws: ArchiveError.passwordRequired) {
            try await r.extract(nil, to: out, progress: nil)
        }
        let unlocked = try await LibArchiveReader.open(at: ReaderListingTests.fixture("7z/encrypted-data.7z"),
                                                       password: "kernir")
        let out2 = Self.dest()
        try await unlocked.extract(nil, to: out2, progress: nil)
        #expect(try Data(contentsOf: out2.appendingPathComponent("docs/nested/deep/data.bin")).count == 70000)
    }

    @Test func unknownPathCarriesCallersOriginalSpelling() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data("x".utf8)], in: dir)
        try Fixtures.bsdtar(["-cf", "t.tar", "a.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        await #expect(throws: ArchiveError.entryNotFound("./nope")) {
            try await r.extract(["./nope"], to: Self.dest(), progress: nil)
        }
    }

    @Test func existingDirectoryModeIsPreserved() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a/b/c.txt": Data("x".utf8)], in: dir)
        try Fixtures.bsdtar(["-cf", "t.tar", "a/b/c.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        #expect(r.headerOrdinalByPath["a"] == nil)
        let out = Self.dest()
        let existing = out.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: existing.path)
        try await r.extract(nil, to: out, progress: nil)
        let mode = try FileManager.default.attributesOfItem(atPath: existing.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        #expect(Self.exists(out.appendingPathComponent("a/b/c.txt")))
    }

    @Test func cpioHardlinkDataLivesOnLastLink() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["hello.txt": Data("hello bytes".utf8)], in: dir)
        try FileManager.default.linkItem(at: dir.appendingPathComponent("hello.txt"),
                                         to: dir.appendingPathComponent("link.txt"))
        try Fixtures.bsdtar(["-cf", "t.cpio", "--format", "newc", "hello.txt", "link.txt"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.cpio"), password: nil)
        let alone = Self.dest()
        try await r.extract(["link.txt"], to: alone, progress: nil)
        #expect(try Data(contentsOf: alone.appendingPathComponent("link.txt")) == Data("hello bytes".utf8))
        let both = Self.dest()
        try await r.extract(nil, to: both, progress: nil)
        for n in ["hello.txt", "link.txt"] {
            #expect(try Data(contentsOf: both.appendingPathComponent(n)) == Data("hello bytes".utf8), "\(n)")
        }
    }

    // MARK: - cpio hardlink groups

    static let groupBytes = Data("cpio-group-bytes".utf8)

    /// A hardlink group made with `ln f g; ln f h` (the first name is the original), archived by bsdtar
    /// in `format` together with any `plain` files, which are not part of the group.
    static func cpioGroupReader(_ format: String, members: [String] = ["f", "g", "h"],
                                plain: [String: Data] = [:]) async throws -> LibArchiveReader {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(plain.merging([members[0]: groupBytes]) { $1 }, in: dir)
        for m in members.dropFirst() { try Fixtures.run("/bin/ln", [members[0], m], cwd: dir) }
        try Fixtures.bsdtar(["-cf", "t.cpio", "--format", format] + members + plain.keys.sorted(), cwd: dir)
        return try await LibArchiveReader.open(at: dir.appendingPathComponent("t.cpio"), password: nil)
    }

    /// Selected members hold the group's bytes as regular files; unselected members do not exist.
    static func expectGroup(_ r: LibArchiveReader, selection: [String]?, members: [String]) async throws {
        let out = Self.dest()
        try await r.extract(selection, to: out, progress: nil)
        for n in members {
            let url = out.appendingPathComponent(n)
            if selection?.contains(n) ?? true {
                #expect(TriageTests.regularBytes(url) == Self.groupBytes, "\(n) of \(selection ?? ["<all>"])")
            } else {
                #expect(!Self.exists(url), "\(n) was written for \(selection ?? ["<all>"])")
            }
        }
    }

    @Test(arguments: [["f"], ["g"], ["h"], ["f", "g"], ["g", "h"], nil] as [[String]?])
    func newcHardlinkGroupGivesEverySelectedMemberTheBytes(_ selection: [String]?) async throws {
        let r = try await Self.cpioGroupReader("newc")
        // The layout this pins: f is plain and empty, g -> f is empty, h -> f carries the data.
        try #require(r.format == .cpio)
        try #require(r.hardlinkTargetByPath == ["g": "f", "h": "f"])
        try #require(r.entries.map(\.path) == ["f", "g", "h"])
        try #require(r.entries.map(\.size) == [0, 0, Int64(Self.groupBytes.count)])
        try await Self.expectGroup(r, selection: selection, members: ["f", "g", "h"])
    }

    @Test(arguments: [["f"], ["g"], nil] as [[String]?])
    func newcTwoMemberGroupGivesEverySelectedMemberTheBytes(_ selection: [String]?) async throws {
        let r = try await Self.cpioGroupReader("newc", members: ["f", "g"])
        try #require(r.entries.map(\.size) == [0, Int64(Self.groupBytes.count)])
        try await Self.expectGroup(r, selection: selection, members: ["f", "g"])
    }

    @Test(arguments: [["f"], ["g"], ["h"], nil] as [[String]?])
    func odcHardlinkGroupGivesEverySelectedMemberTheBytes(_ selection: [String]?) async throws {
        let r = try await Self.cpioGroupReader("odc")
        try #require(r.format == .cpio)
        try #require(r.hardlinkTargetByPath == ["g": "f", "h": "f"])
        try await Self.expectGroup(r, selection: selection, members: ["f", "g", "h"])
    }

    @Test func newcLinkToFifoSelectedAloneIsCorrupted() async throws {
        // p is a FIFO, q its second name: q must not become a copy of a FIFO entry.
        let dir = Fixtures.tempDir()
        try Fixtures.run("/usr/bin/mkfifo", ["p"], cwd: dir)
        try Fixtures.run("/bin/ln", ["p", "q"], cwd: dir)
        try Fixtures.bsdtar(["-cf", "t.cpio", "--format", "newc", "p", "q"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.cpio"), password: nil)
        try #require(r.hardlinkTargetByPath == ["q": "p"])
        let out = Self.dest()
        await #expect {
            try await r.extract(["q"], to: out, progress: nil)
        } throws: { error in
            if case .corrupted = error as? ArchiveError { return true }
            return false
        }
        var st = stat()
        #expect(lstat(out.appendingPathComponent("q").path, &st) != 0)
    }

    @Test func newcPlainFileBesideAGroupExtractsAlone() async throws {
        // No seam observes whether the plan runs a second pass; this pins the visible result.
        let r = try await Self.cpioGroupReader("newc", plain: ["p": Data("plain".utf8)])
        let out = Self.dest()
        try await r.extract(["p"], to: out, progress: nil)
        #expect(TriageTests.regularBytes(out.appendingPathComponent("p")) == Data("plain".utf8))
        for n in ["f", "g", "h"] { #expect(!Self.exists(out.appendingPathComponent(n)), "\(n)") }
        #expect(TriageTests.regularBytes(try await r.extractToTemporaryFile("p")) == Data("plain".utf8))
    }
}
