import Foundation
import Testing
import CLibArchive
@testable import KernirCore

/// A crafted zip64 can declare any entry size up to Int64.max, and libarchive accepts it. Two such entries make every
/// sum of sizes pass Int64, so a plain `+` traps. Opening, previewing, extracting and repacking must not.
@Suite("Crafted sizes past Int64")
struct CraftedSizeTests {
    /// 268 bytes: stored entries `d/a` and `d/b`, each holding the byte "x" but declaring an uncompressed size of
    /// Int64.max (or `sizes`) in its zip64 extra field.
    static func zip(sizes: [Int64] = [.max, .max]) throws -> URL {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { le16(Int(v & 0xFFFF)) + le16(Int(v >> 16)) }
        func le64(_ v: UInt64) -> [UInt8] { le32(UInt32(v & 0xFFFF_FFFF)) + le32(UInt32(v >> 32)) }
        let data: [UInt8] = Array("x".utf8)
        let crc = SyntheticZip.crc32(data)
        var local: [UInt8] = [], central: [UInt8] = []
        for (name, size) in Swift.zip(["d/a", "d/b"].map({ Array($0.utf8) }), sizes) {
            let extra = le16(1) + le16(16) + le64(UInt64(size)) + le64(UInt64(data.count))
            let offset = UInt32(local.count)
            let sizes = le32(crc) + le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) + le16(name.count) + le16(extra.count)
            local += le32(0x0403_4B50) + le16(45) + le16(0) + le16(0) + le16(0) + le16(0) + sizes + name + extra + data
            central += le32(0x0201_4B50) + le16(45) + le16(45) + le16(0) + le16(0) + le16(0) + le16(0) + sizes
                + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name + extra
        }
        let end = le32(0x0605_4B50) + le16(0) + le16(0) + le16(2) + le16(2) + le32(UInt32(central.count))
            + le32(UInt32(local.count)) + le16(0)
        let bytes = local + central + end
        #expect(bytes.count == 268)
        let url = Fixtures.tempDir().appendingPathComponent("big.zip")
        try Data(bytes).write(to: url)
        return url
    }

    @Test func openKeepsSizesAndTreeTotalIsUnknown() async throws {
        let archive = try await Archive.open(at: try Self.zip())
        #expect(archive.entries.map(\.path) == ["d", "d/a", "d/b"])
        #expect(archive.entries.filter { !$0.isDirectory }.map(\.size) == [Int64.max, Int64.max])
        let tree = Archive.tree(from: archive.entries)
        #expect(tree.map(\.entry.path) == ["d"])
        #expect(tree.first?.totalSize == nil)
    }

    /// The Quick Look path: the total of visible file sizes is unknown, as the folder total is.
    @Test func previewListingFileSizeIsUnknown() async throws {
        let preview = try await Archive.previewListing(at: try Self.zip(), limit: 10)
        #expect(preview.format == .zip)
        #expect(preview.entries.map(\.path) == ["d/a", "d/b"])
        #expect(preview.visibleEntryCount == 3)
        #expect(preview.visibleFileSize == nil)
    }

    /// `d/a` declares 64 MiB + 1 and `d/b` Int64.max: the sum still passes Int64, and the first entry to fail is
    /// bounded. Were libarchive's "wrong size" check ever lost, a repack would zero-fill `d/a` to its declared size
    /// and go on to `d/b`; the tests below cancel as soon as `d/a` is done, so such a regression costs 64 MiB, never
    /// Int64.max bytes. (A file's progress report with a fraction above 0 comes after its data: entry counts are
    /// the measure when sizes pass Int64.)
    static let boundedSizes: [Int64] = [(64 << 20) + 1, .max]

    /// Extraction stops with libarchive's "wrong size" error after the first byte, and leaves nothing behind.
    @Test func extractFailsCleanly() async throws {
        let archive = try await Archive.open(at: try Self.zip(sizes: Self.boundedSizes))
        let out = Fixtures.tempDir().appendingPathComponent("out")
        let reports = Reports()
        let box = ExtractTests.TaskBox()
        let task = Task {
            try await archive.extract(nil, to: out, progress: { fraction, path in
                reports.add(fraction)
                if path == "d/a", fraction > 0 { box.cancel() }
            })
        }
        box.set(task)
        do {
            try await task.value
            Issue.record("extract succeeded")
        } catch let error as ArchiveError {
            guard case .corrupted = error else { Issue.record("\(error)"); return }
        }
        #expect(reports.all.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("d/a").path))
    }

    /// Repacking stops with the same error and leaves no output, into every writable format: the unfinished session
    /// is failed, so tar and 7z do not pad `d/a` to its declared size either.
    @Test(arguments: [ArchiveFormat.zip, .tar, .tarGzip, .tarBzip2, .tarXz, .sevenZip])
    func repackFailsCleanly(_ format: ArchiveFormat) async throws {
        let archive = try await Archive.open(at: try Self.zip(sizes: Self.boundedSizes))
        let out = Fixtures.tempDir().appendingPathComponent("out.\(format.fileExtension)")
        let reports = Reports()
        let box = ExtractTests.TaskBox()
        let task = Task {
            try await ArchiveWriter.write(source: archive, changes: ArchiveChangeSet(), format: format, to: out,
                                          options: nil, progress: { fraction, path in
                                              reports.add(fraction)
                                              if path == "d/a", fraction > 0 { box.cancel() }
                                          })
        }
        box.set(task)
        do {
            try await task.value
            Issue.record("repack succeeded")
        } catch let error as ArchiveError {
            guard case .corrupted = error else { Issue.record("\(format): \(error)"); return }
        }
        #expect(reports.all.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    /// A write session freed unfinished (after an error or a cancel) writes nothing more. Closing it instead would
    /// pad the current entry with zeros up to its declared size (tar, 7z), in C and past any cancellation: Int64.max
    /// bytes for a crafted size. 64 MiB declared here keeps a regression bounded and stored 7z keeps it visible.
    @Test(arguments: [ArchiveFormat.tar, .sevenZip, .zip])
    func unfinishedSessionDoesNotPadTheEntry(_ format: ArchiveFormat) throws {
        let url = Fixtures.tempDir().appendingPathComponent("out.\(format.fileExtension)")
        let options = try ResolvedWriteOptions.resolve(
            format.supportedMethods.isEmpty ? nil : ArchiveWriteOptions(method: .store), format: format,
            sourceEncryption: .none, sourceMethod: nil, sourcePassword: nil)
        let declared: Int64 = 64 << 20
        do {
            let session = try WriteSession(url: url, format: format, options: options)
            let entry = try #require(archive_entry_new())
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, "big")
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_perm(entry, 0o644)
            archive_entry_set_size(entry, declared)
            try session.writeHeader(entry)
            try [UInt8(ascii: "x")].withUnsafeBytes { try session.writeData($0) }
        }
        let size = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 1 << 20, "\(format): \(size) bytes after an unfinished session")
    }

    struct CompressorCase: CustomTestStringConvertible, Sendable {
        let name: String
        let format: ArchiveFormat
        let options: ArchiveWriteOptions
        /// Sessions per attempt: enough that a leak of the smallest codec state (256 KiB) clears `limit`.
        let sessions: Int
        var testDescription: String { name }
        /// Growth allowed per attempt: 64 KiB a session plus 4 MiB for the rest of the process.
        var limit: Int64 { Int64(sessions * (64 << 10) + (4 << 20)) }
    }

    static let compressorCases: [CompressorCase] = [
        .init(name: "tar.xz level 9", format: .tarXz, options: .init(compressionLevel: 9), sessions: 2),
        .init(name: "tar.xz", format: .tarXz, options: .init(), sessions: 4),
        .init(name: "tar.gz", format: .tarGzip, options: .init(), sessions: 128),
        .init(name: "tar.bz2", format: .tarBzip2, options: .init(), sessions: 16),
        .init(name: "zip deflate", format: .zip, options: .init(method: .deflate), sessions: 128),
        .init(name: "zip deflate AES-256", format: .zip,
              options: .init(method: .deflate, encryption: .aes256, password: "pw"), sessions: 128),
        .init(name: "7z lzma2", format: .sevenZip, options: .init(method: .lzma2), sessions: 16),
        .init(name: "7z AES-256", format: .sevenZip,
              options: .init(method: .lzma2, encryption: .aes256, password: "pw"), sessions: 4),
    ]

    /// Failing an unfinished session (above) skips libarchive's close, and close used to be the only place the gzip
    /// and xz filters and the zip writer ended their compressor (patch 0013 ends it in free). Without that every
    /// cancelled or failed save kept the codec state for the life of the process: 256 KiB for gzip and zip
    /// deflate, 93 MiB for xz at the default level, 673 MiB at level 9.
    @Test(.serialized, arguments: compressorCases)
    func unfinishedSessionFreesItsCompressor(_ c: CompressorCase) async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let options = try ResolvedWriteOptions.resolve(c.options, format: c.format, sourceEncryption: .none,
                                                       sourceMethod: nil, sourcePassword: nil)
        func unfinished(_ i: Int) throws {
            let session = try WriteSession(url: dir.appendingPathComponent("o\(i)"), format: c.format,
                                           options: options)
            let entry = try #require(archive_entry_new())
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname_utf8(entry, "f")
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_perm(entry, 0o644)
            archive_entry_set_size(entry, 2)
            try session.writeHeader(entry)
            try [UInt8(ascii: "x")].withUnsafeBytes { try session.writeData($0) }
        }
        try unfinished(-1)
        // malloc's in-use total is process-wide and other suites run in parallel (these cases do not), so it is
        // measured inside `MemoryQuiet.measure`, and one quiet attempt is enough: a leak grows it by sessions x leak
        // on every attempt.
        let growths = try await MemoryQuiet.measure {
            var growths: [Int64] = []
            for attempt in 0..<4 where growths.last.map({ $0 >= c.limit }) ?? true {
                let before = MemoryQuiet.mallocInUse()
                for i in 0..<c.sessions { try unfinished(attempt * c.sessions + i) }
                growths.append(MemoryQuiet.mallocInUse() - before)
            }
            return growths
        }
        #expect(try #require(growths.min()) < c.limit,
                "\(c.name): growth per attempt (KiB): \(growths.map { $0 >> 10 }), limit \(c.limit >> 10)")
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ value: Double) { lock.withLock { values.append(value) } }
    var all: [Double] { lock.withLock { values } }
}
