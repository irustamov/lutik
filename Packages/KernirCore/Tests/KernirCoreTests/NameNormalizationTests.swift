import Testing
import Foundation
import CLibArchive
@testable import KernirCore

/// Entry names must reach the archive and come back as the NFC the source had, not the NFD that libarchive's
/// Apple-only normalization produced (Kernir patch 0003). Ground truth is the archive file's own bytes
/// (7z: the names `7zz l -slt` prints, because 7z headers are compressed).
struct NameNormalizationTests {
    /// Names built from explicit scalars: an editor may normalize source literals.
    static let cafe = "caf\u{E9}"
    static let resume = "r\u{E9}sum\u{E9}.txt"
    static let ga = "\u{30AC}\u{30A4}.txt"

    static func nfd(_ s: String) -> String { s.decomposedStringWithCanonicalMapping }
    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    static func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        haystack.range(of: Data(needle)) != nil
    }

    /// The path of every entry as 7zz prints it, or nil when 7zz is not installed.
    static func sevenZipNames(_ url: URL) throws -> Data? {
        let tool = ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let tool else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["l", "-slt", url.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    /// The bytes that carry entry names: the file itself, or 7zz's listing for 7z.
    static func nameBytes(_ url: URL, format: ArchiveFormat) throws -> Data? {
        format == .sevenZip ? try sevenZipNames(url) : try Data(contentsOf: url)
    }

    // MARK: - Writer

    static func scratchTree() throws -> (root: URL, additions: [ArchiveChangeSet.Addition]) {
        let dir = Fixtures.tempDir()
        let folder = dir.appending(path: cafe, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appending(path: resume))
        try Data("b".utf8).write(to: dir.appending(path: ga))
        return (dir, [.init(sourceURL: folder, destinationDirectory: ""), .init(sourceURL: dir.appending(path: ga), destinationDirectory: "")])
    }

    @Test(arguments: [ArchiveFormat.tar, .zip, .sevenZip])
    func addedNamesAreStoredNFC(_ format: ArchiveFormat) async throws {
        let (_, additions) = try Self.scratchTree()
        let out = Fixtures.tempDir().appending(path: "out.\(format.fileExtension)")
        let options = format == .zip ? ArchiveWriteOptions(method: .store) : nil
        try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(additions: additions),
                                      format: format, to: out, options: options)
        guard let data = try Self.nameBytes(out, format: format) else {
            print("NOTE: 7zz not installed, skipping the 7z byte check")
            return
        }
        for name in [Self.cafe, Self.resume, Self.ga] {
            #expect(Self.contains(data, Self.bytes(name)), "NFC \(name.unicodeScalars.map { String($0.value, radix: 16) }) missing")
            #expect(!Self.contains(data, Self.bytes(Self.nfd(name))), "NFD \(name.unicodeScalars.map { String($0.value, radix: 16) }) found")
        }
    }

    // MARK: - Repack

    static let fixtureFiles: [(path: String, format: ArchiveFormat)] = [
        ("tar/unicode.tar", .tar), ("zip/unicode-utf8-flag.zip", .zip), ("7z/unicode.7z", .sevenZip)]

    /// Non-ASCII names in the three fixtures whose NFD form differs from the NFC one.
    static let fixtureNames = ["caf\u{E9}.txt"]

    @Test(arguments: fixtureFiles)
    func repackKeepsNFCNames(_ fixture: (path: String, format: ArchiveFormat)) async throws {
        let source = Corpus.root.appending(path: fixture.path)
        guard let before = try Self.nameBytes(source, format: fixture.format) else {
            print("NOTE: 7zz not installed, skipping the 7z byte check")
            return
        }
        for name in Self.fixtureNames {
            try #require(Self.contains(before, Self.bytes(name)), "fixture \(fixture.path) lacks NFC bytes")
        }
        let reader = try await Archive.open(at: source)
        let out = Fixtures.tempDir().appending(path: "out.\(fixture.format.fileExtension)")
        try await ArchiveWriter.write(source: reader, changes: ArchiveChangeSet(), format: fixture.format, to: out, options: nil)
        let after = try #require(try Self.nameBytes(out, format: fixture.format))
        for name in Self.fixtureNames {
            #expect(Self.contains(after, Self.bytes(name)), "NFC bytes missing after repack of \(fixture.path)")
            #expect(!Self.contains(after, Self.bytes(Self.nfd(name))), "NFD bytes after repack of \(fixture.path)")
        }
    }

    // MARK: - Reader

    @Test func readerReturnsStoredNFC() throws {
        let a = archive_read_new()
        defer { archive_read_free(a) }
        archive_read_support_format_all(a)
        let path = Corpus.root.appending(path: "tar/unicode.tar").path
        try #require(archive_read_open_filename(a, path, 10240) == ARCHIVE_OK)
        var names: [[Unicode.Scalar]] = []
        withUTF8CType {
            var entry: OpaquePointer?
            while archive_read_next_header(a, &entry) == ARCHIVE_OK {
                if let p = archive_entry_pathname_utf8(entry) { names.append(Array(String(cString: p).unicodeScalars)) }
            }
        }
        #expect(names.contains(Array(("caf\u{E9}.txt").unicodeScalars)))
        #expect(!names.contains(Array(Self.nfd("caf\u{E9}.txt").unicodeScalars)))
    }
}
