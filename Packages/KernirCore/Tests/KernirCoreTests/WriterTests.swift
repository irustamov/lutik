import Testing
import Foundation
@testable import KernirCore

struct WriterTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let format: ArchiveFormat
        let method: ArchiveCompressionMethod?
        let encryption: ArchiveEncryption
        var testDescription: String { "\(format.rawValue) \(method?.rawValue ?? "-") \(encryption.rawValue)" }
    }

    /// Every writable format x supported method (nil when none) x supported encryption.
    static let allCases: [Case] = ArchiveFormat.writable.flatMap { format in
        let methods: [ArchiveCompressionMethod?] = format.supportedMethods.isEmpty ? [nil] : format.supportedMethods
        return methods.flatMap { method in
            format.supportedEncryptions.map { Case(format: format, method: method, encryption: $0) }
        }
    }

    static let password = "пароль-pw"

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        private var peak: Int64 = 0
        func sample(_ v: Int64) { lock.lock(); peak = max(peak, v); lock.unlock() }
        func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
        var highest: Int64 { lock.lock(); defer { lock.unlock() }; return peak }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// `proj/` with a nested file, an empty folder, a Cyrillic name, Finder's .DS_Store and an empty file.
    static func makeProject() -> URL {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles([
            "proj/src/main.swift": Data("print(\"hi\")\n".utf8),
            "proj/empty/": Data(),
            "proj/Привет.txt": Data("мир".utf8),
            "proj/.DS_Store": Data("finder".utf8),
            "proj/zero": Data(),
        ], in: dir)
        return dir.appendingPathComponent("proj")
    }

    static func adding(_ urls: URL..., into directory: String = "") -> ArchiveChangeSet {
        ArchiveChangeSet(additions: urls.map { .init(sourceURL: $0, destinationDirectory: directory) })
    }

    /// A path in a new, empty folder.
    static func destination(_ name: String) -> URL {
        let folder = Fixtures.tempDir().appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    static func contents(of dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    static func size(_ url: URL) throws -> Int64 {
        try #require((FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value)
    }

    static func repetitiveText(bytes: Int) -> Data {
        let line = Data("The quick brown fox jumps over the lazy dog. 0123456789\n".utf8)
        var d = Data()
        while d.count < bytes { d.append(line) }
        return d.prefix(bytes)
    }

    /// Standard output of a tool; throws when it exits non-zero.
    static func output(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Fixtures.ToolFailure(description: "\(tool) exited \(p.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func physFootprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    static func expectThrows(_ expected: ArchiveError, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected \(expected)")
        } catch {
            #expect(error as? ArchiveError == expected)
        }
    }

    static func expectIOError(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected .io")
        } catch ArchiveError.io {
        } catch {
            Issue.record("expected .io, got \(error)")
        }
    }

    // MARK: - Round trip

    @Test(arguments: allCases)
    func roundTripEveryFormatMethodAndEncryption(_ c: Case) async throws {
        let proj = Self.makeProject()
        let dest = Self.destination("out.\(c.format.fileExtension)")
        let encrypted = c.encryption != .none
        let options = ArchiveWriteOptions(method: c.method, encryption: c.encryption,
                                          password: encrypted ? Self.password : nil)
        try await ArchiveWriter.write(source: nil, changes: Self.adding(proj), format: c.format,
                                      to: dest, options: options)

        let r = try await LibArchiveReader.open(at: dest, password: encrypted ? Self.password : nil)
        #expect(r.format == c.format)
        let paths = r.entries.map(\.path)
        #expect(Set(paths) == ["proj", "proj/src", "proj/src/main.swift", "proj/empty", "proj/Привет.txt", "proj/zero"])
        #expect(paths.count == 6)
        #expect(r.isEncrypted == encrypted)
        #expect(r.encryption == c.encryption)

        let out = Fixtures.tempDir()
        try await r.extract(nil, to: out, progress: nil)
        for p in ["src/main.swift", "Привет.txt", "zero"] {
            #expect(try Data(contentsOf: out.appendingPathComponent("proj/\(p)"))
                    == Data(contentsOf: proj.appendingPathComponent(p)), "\(p)")
        }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("proj/empty").path, isDirectory: &isDir)
                && isDir.boolValue)
    }

    @Test func zipCryptoIsReadableByUnzip() async throws {
        let proj = Self.makeProject()
        let dest = Self.destination("out.zip")
        try await ArchiveWriter.write(source: nil, changes: Self.adding(proj), format: .zip, to: dest,
                                      options: ArchiveWriteOptions(encryption: .zipCrypto, password: "pw"))
        try Fixtures.run("/usr/bin/unzip", ["-P", "pw", "-t", dest.path], cwd: dest.deletingLastPathComponent())
    }

    @Test func levelChangesOutput() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["text.txt": Self.repetitiveText(bytes: 1_000_000)], in: dir)
        var sizes: [Int: Int64] = [:]
        for level in [0, 9] {
            let dest = Self.destination("l\(level).zip")
            try await ArchiveWriter.write(source: nil, changes: Self.adding(dir.appendingPathComponent("text.txt")),
                                          format: .zip, to: dest,
                                          options: ArchiveWriteOptions(method: .deflate, compressionLevel: level))
            sizes[level] = try Self.size(dest)
        }
        #expect(try #require(sizes[0]) > #require(sizes[9]))
    }

    @Test func storeMethodStoresUncompressed() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["text.txt": Self.repetitiveText(bytes: 1_000_000)], in: dir)
        let dest = Self.destination("s.zip")
        try await ArchiveWriter.write(source: nil, changes: Self.adding(dir.appendingPathComponent("text.txt")),
                                      format: .zip, to: dest, options: ArchiveWriteOptions(method: .store))
        #expect(try Self.size(dest) >= 1_000_000)
    }

    @Test func bigFileStreamsWithoutLoadingIntoMemory() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.bin")
        let block = Data((0..<4096).map { _ in UInt8.random(in: .min ... .max) })
        var mib = Data()
        for _ in 0..<256 { mib.append(block) }
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let h = try FileHandle(forWritingTo: big)
        for _ in 0..<256 { try h.write(contentsOf: mib) }
        try h.close()

        let dest = dir.appendingPathComponent("out.tar.gz")
        let limit: Int64 = 64 << 20
        // phys_footprint is process-wide and other suites run in parallel, so it is measured inside
        // `MemoryQuiet.measure`, and one quiet attempt is enough: a writer that loads the file grows by the full
        // 256 MiB on every attempt.
        let growths = try await MemoryQuiet.measure {
            var growths: [Int64] = []
            for _ in 0..<5 where growths.last.map({ $0 >= limit }) ?? true {
                let rec = Recorder()
                let baseline = Self.physFootprint()
                try await ArchiveWriter.write(source: nil, changes: Self.adding(big), format: .tarGzip, to: dest,
                                              options: nil) { _, _ in rec.sample(Self.physFootprint()) }
                rec.sample(Self.physFootprint())
                growths.append(rec.highest - baseline)
            }
            return growths
        }
        #expect(try #require(growths.min()) < limit, "growth per attempt (MiB): \(growths.map { $0 >> 20 })")

        let r = try await LibArchiveReader.open(at: dest, password: nil)
        #expect(r.entries.map(\.path) == ["big.bin"])
        #expect(r.entries.first?.size == 268_435_456)
    }

    // MARK: - Failures leave nothing behind

    @Test func missingAdditionThrowsIOAndCreatesNothing() async throws {
        let dest = Self.destination("out.zip")
        let missing = Fixtures.tempDir().appendingPathComponent("nope.txt")
        await Self.expectIOError {
            try await ArchiveWriter.write(source: nil, changes: Self.adding(missing), format: .zip, to: dest)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(Self.contents(of: dest.deletingLastPathComponent()) == [])
    }

    @Test func cancelledWriteLeavesNothing() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Fixtures.makeFiles(["big.bin": Data(count: 50_000_000)], in: dir)
        let dest = Self.destination("out.tar")
        let box = ExtractTests.TaskBox()
        let task = Task {
            try await ArchiveWriter.write(source: nil, changes: Self.adding(dir.appendingPathComponent("big.bin")),
                                          format: .tar, to: dest) { _, _ in box.cancel() }
        }
        box.set(task)
        await Self.expectThrows(.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(Self.contents(of: dest.deletingLastPathComponent()) == [])
    }

    @Test func unwritableFolderThrowsIOAndLeavesNothing() async throws {
        let proj = Self.makeProject()
        let dest = Self.destination("out.zip")
        let folder = dest.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        await Self.expectIOError {
            try await ArchiveWriter.write(source: nil, changes: Self.adding(proj), format: .zip, to: dest)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(Self.contents(of: folder) == [])
    }

    // MARK: - Paths and options

    @Test func duplicateAdditionPathsLastWins() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a/same.txt": Data("first".utf8), "b/same.txt": Data("second".utf8)], in: dir)
        let dest = Self.destination("out.zip")
        try await ArchiveWriter.write(source: nil,
                                      changes: Self.adding(dir.appendingPathComponent("a/same.txt"),
                                                           dir.appendingPathComponent("b/same.txt")),
                                      format: .zip, to: dest)
        let r = try await LibArchiveReader.open(at: dest, password: nil)
        #expect(r.entries.map(\.path) == ["same.txt"])
        let out = Fixtures.tempDir()
        try await r.extract(nil, to: out, progress: nil)
        #expect(try Data(contentsOf: out.appendingPathComponent("same.txt")) == Data("second".utf8))
    }

    @Test func laterFileReplacesEarlierFolderAndItsContents() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a/x/child.txt": Data("child".utf8), "b/x": Data("file".utf8)], in: dir)
        let dest = Self.destination("out.zip")
        try await ArchiveWriter.write(source: nil,
                                      changes: Self.adding(dir.appendingPathComponent("a/x"),
                                                           dir.appendingPathComponent("b/x")),
                                      format: .zip, to: dest)
        #expect(try Self.output("/usr/bin/bsdtar", ["-tf", dest.path]) == "x\n")
        let r = try await LibArchiveReader.open(at: dest, password: nil)
        #expect(r.entries.map(\.path) == ["x"])
        let out = Fixtures.tempDir()
        try await r.extract(nil, to: out, progress: nil)
        #expect(try Data(contentsOf: out.appendingPathComponent("x")) == Data("file".utf8))
    }

    @Test func laterAdditionIntoEarlierFileTurnsItIntoAFolder() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a/x": Data("file".utf8), "f.txt": Data("f".utf8)], in: dir)
        let dest = Self.destination("out.zip")
        let changes = ArchiveChangeSet(additions: [
            .init(sourceURL: dir.appendingPathComponent("a/x"), destinationDirectory: ""),
            .init(sourceURL: dir.appendingPathComponent("f.txt"), destinationDirectory: "x"),
        ])
        try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: dest)
        let headers = try Self.output("/usr/bin/bsdtar", ["-tf", dest.path]).split(separator: "\n").map(String.init)
        #expect(headers == ["x/", "x/f.txt"])
        let r = try await LibArchiveReader.open(at: dest, password: nil)
        #expect(r.entries.first { $0.path == "x" }?.isDirectory == true)
    }

    @Test func existingFolderAtDestinationThrowsIOAndIsUntouched() async throws {
        let proj = Self.makeProject()
        let dest = Self.destination("out.zip")
        Fixtures.makeFiles(["keep.txt": Data("keep".utf8)], in: dest)
        await Self.expectIOError {
            try await ArchiveWriter.write(source: nil, changes: Self.adding(proj), format: .zip, to: dest)
        }
        #expect(Self.contents(of: dest) == ["keep.txt"])
        #expect(try Data(contentsOf: dest.appendingPathComponent("keep.txt")) == Data("keep".utf8))
    }

    @Test func existingDestinationIsReplaced() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["new.txt": Data("new".utf8)], in: dir)
        let dest = Self.destination("out.zip")
        try Data("old archive".utf8).write(to: dest)
        try await ArchiveWriter.write(source: nil, changes: Self.adding(dir.appendingPathComponent("new.txt")),
                                      format: .zip, to: dest)
        let r = try await LibArchiveReader.open(at: dest, password: nil)
        #expect(r.entries.map(\.path) == ["new.txt"])
        #expect(Self.contents(of: dest.deletingLastPathComponent()) == ["out.zip"])
    }

    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .tar])
    func symlinkIsStoredAsLinkNotFollowed(_ format: ArchiveFormat) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["outside/secret.txt": Data("s".utf8), "proj/f.txt": Data("f".utf8)], in: dir)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("proj/link").path,
                                                   withDestinationPath: "../outside")
        let dest = Self.destination("out.\(format.fileExtension)")
        try await ArchiveWriter.write(source: nil, changes: Self.adding(dir.appendingPathComponent("proj")),
                                      format: format, to: dest)
        let r = try await LibArchiveReader.open(at: dest, password: nil)
        #expect(Set(r.entries.map(\.path)) == ["proj", "proj/f.txt", "proj/link"])
        #expect(r.symlinkTargetByPath["proj/link"] == "../outside")
    }

    @Test func legacyPasswordOverloadWritesAES256() async throws {
        let proj = Self.makeProject()
        let dest = Self.destination("out.zip")
        try await ArchiveWriter.write(source: nil, changes: Self.adding(proj), format: .zip, to: dest, password: "pw")
        let r = try await LibArchiveReader.open(at: dest, password: "pw")
        #expect(r.encryption == .aes256)
    }

    @Test(arguments: [ArchiveFormat.zip, .tar])
    func additionIntoMissingFolderCreatesParentEntries(_ format: ArchiveFormat) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["f.txt": Data("f".utf8)], in: dir)
        let dest = Self.destination("out.\(format.fileExtension)")
        try await ArchiveWriter.write(source: nil, changes: Self.adding(dir.appendingPathComponent("f.txt"), into: "x/y"),
                                      format: format, to: dest)
        let headers = try Self.output("/usr/bin/bsdtar", ["-tf", dest.path]).split(separator: "\n").map(String.init)
        #expect(headers == ["x/", "x/y/", "x/y/f.txt"])
    }

    @Test func progressIsByBytesAndEndsAtOne() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["small.bin": Data(count: 10), "large.bin": Data(count: 8 << 20)], in: dir)
        let dest = Self.destination("out.tar")
        let rec = Recorder()
        try await ArchiveWriter.write(source: nil, changes: Self.adding(dir.appendingPathComponent("small.bin"),
                                                                       dir.appendingPathComponent("large.bin")),
                                      format: .tar, to: dest) { f, _ in rec.add(f) }
        let v = rec.all
        // Per-entry progress would report at most three values; by bytes every 1 MiB chunk moves it.
        #expect(v.count > 4)
        #expect(v.last == 1.0)
        #expect(v.dropLast().allSatisfy { $0 < 1.0 })
        #expect(zip(v, v.dropFirst()).allSatisfy { $0 <= $1 })
    }
}
