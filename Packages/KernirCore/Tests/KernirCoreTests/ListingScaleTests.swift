import Foundation
import Testing
@testable import KernirCore

/// The listing walk at sizes past its internal chunking (headers are held in chunks of 65,536) and around the preview's
/// limits (`NestingLimits.preview`). Each archive is generated into the run's temporary folder and removed after; the
/// largest is a 139 MB zip.
@Suite("Listing at scale", .serialized)
struct ListingScaleTests {
    /// A stored zip of empty files, written as it is generated (no whole-file buffer): one local header per name, then
    /// the central directory, then the end records (zip64 ones too past 65,534 entries).
    static func zip(count: Int, name: (Int) -> [UInt8]) throws -> URL {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }
        func le64(_ v: Int) -> [UInt8] { le32(v & 0xFFFF_FFFF) + le32(v >> 32) }
        let url = Fixtures.tempDir().appendingPathComponent("scale.zip")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var buffer: [UInt8] = []
        func flush(_ force: Bool = false) throws {
            guard force || buffer.count >= 4 << 20 else { return }
            try handle.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }
        // Version 2.0, UTF-8 names, stored, 1980-01-01 00:00, CRC 0, sizes 0.
        let fixed = le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21) + le32(0) + le32(0) + le32(0)
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        var offset = 0
        for i in 0..<count {
            let n = name(i)
            offsets.append(offset)
            let header = le32(0x0403_4B50) + fixed + le16(n.count) + le16(0)
            buffer += header
            buffer += n
            offset += header.count + n.count
            try flush()
        }
        let centralStart = offset
        for i in 0..<count {
            let n = name(i)
            let header = le32(0x0201_4B50) + le16(20) + fixed + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0)
                + le32(0) + le32(offsets[i])
            buffer += header
            buffer += n
            offset += header.count + n.count
            try flush()
        }
        let centralSize = offset - centralStart
        if count > 0xFFFE {
            buffer += le32(0x0606_4B50) + le64(44) + le16(45) + le16(45) + le32(0) + le32(0) + le64(count) + le64(count)
                + le64(centralSize) + le64(centralStart)
            buffer += le32(0x0706_4B50) + le32(0) + le64(offset) + le32(1)
            buffer += le32(0x0605_4B50) + le16(0) + le16(0) + le16(0xFFFF) + le16(0xFFFF) + le32(0xFFFF_FFFF)
                + le32(0xFFFF_FFFF) + le16(0)
        } else {
            buffer += le32(0x0605_4B50) + le16(0) + le16(0) + le16(count) + le16(count) + le32(centralSize)
                + le32(centralStart) + le16(0)
        }
        try flush(true)
        return url
    }

    /// Visible count and file-size total, as `ArchivePreviewListing` reports them.
    static func totals(_ entries: [ArchiveEntry]) -> (count: Int, fileSize: Int64) {
        (entries.count, entries.filter { !$0.isDirectory }.reduce(0) { $0 + ($1.size ?? 0) })
    }

    /// 2 × 65,536 + 1 headers, so the walk's third chunk holds one. Two paths repeat across chunk boundaries:
    /// header 65,535 (the first chunk's last) again as header 65,536 (the second chunk's first), and header 0 again as
    /// the last header, alone in the third chunk. As before chunking: a repeated path keeps its first place and takes
    /// its last header's facts (size, header ordinal); `open` lists the synthesized folder `d` first, the preview
    /// counts it.
    @Test(.memoryHeavy) func duplicatesAcrossWalkChunks() async throws {
        let chunk = 1 << 16
        func path(_ i: Int) -> String { String(format: "d/%06d", i) }
        var items: [NameLimitTests.Item] = []
        items.reserveCapacity(2 * chunk + 1)
        for i in 0..<(2 * chunk + 1) {
            switch i {
            case 0, chunk - 1: items.append(.file(path(i), size: 1))
            case chunk: items.append(.file(path(chunk - 1), size: 2))
            case 2 * chunk: items.append(.file(path(0), size: 3))
            default: items.append(.file(path(i)))
            }
        }
        let url = NameLimitTests.tar(items, as: "tar.gz")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        items = []

        let expected = ["d"] + (0..<(2 * chunk)).filter { $0 != chunk }.map(path)
        let reader = try await LibArchiveReader.open(at: url, password: nil)
        #expect(reader.entries.map(\.path) == expected)
        let sizes = Dictionary(uniqueKeysWithValues: reader.entries.map { ($0.path, $0.size) })
        #expect(sizes[path(0)] == 3)
        #expect(sizes[path(chunk - 1)] == 2)
        #expect(sizes[path(1)] == 0)
        #expect(reader.headerOrdinalByPath[path(0)] == 2 * chunk)
        #expect(reader.headerOrdinalByPath[path(chunk - 1)] == chunk)
        #expect(reader.headerOrdinalByPath[path(chunk + 1)] == chunk + 1)
        let totals = Self.totals(reader.entries)
        #expect(totals.count == 2 * chunk)
        #expect(totals.fileSize == 5)

        let archive = try await Archive.open(at: url)
        #expect(archive.entries.map(\.path) == expected)
        let preview = try await Archive.previewListing(at: url, limit: 5_000)
        #expect(preview.visibleEntryCount == totals.count)
        #expect(preview.visibleFileSize == totals.fileSize)
        // The preview builds header entries only; the synthesized folder counts in its totals.
        #expect(preview.entries.map(\.path) == Array(expected.dropFirst().prefix(5_000)))
        #expect(preview.entries.first { $0.path == path(0) }?.size == 3)
    }

    /// 61,100 flat 1,100-byte names: 67.2 MB of names, over the preview's fixed 64 MiB total but far under its 400,000
    /// entries. Patch 0022 refuses the central directory inside libarchive with the preview limits, before it allocates
    /// the entries; the app's limits (256 MiB, or 512 bytes per entry) list it.
    @Test(.memoryHeavy) func previewRefusesNamesOverItsTotal() async throws {
        let count = 61_100, length = 1_100
        #expect(count * length > NestingLimits.preview.maxTotalNameBytes)
        #expect(count < NestingLimits.preview.maxEntries)
        let pad = [UInt8](repeating: UInt8(ascii: "n"), count: length - 6)
        let url = try Self.zip(count: count) { Array(String(format: "%06d", $0).utf8) + pad }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(EntryCountLimitTests.libarchiveError(url, .preview) != nil)
        #expect(EntryCountLimitTests.libarchiveError(url, .standard) == nil)
        await #expect(throws: ArchiveNestingError(limit: .totalPathBytes)) {
            _ = try await Archive.previewListing(at: url, limit: 5_000)
        }
        let archive = try await Archive.open(at: url)
        #expect(archive.entries.count == count)
        let last = String(format: "%06d", count - 1) + String(repeating: "n", count: length - 6)
        #expect(archive.entries.last?.path == last)
    }

    /// One header past the preview's 400,000 entries is still well inside the app's: `Archive.open` lists it whole.
    @Test(.memoryHeavy) func openListsPastThePreviewEntryLimit() async throws {
        let count = NestingLimits.preview.maxEntries + 1
        let url = try Self.zip(count: count) { Array(String(format: "%06d", $0).utf8) }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let archive = try await Archive.open(at: url)
        #expect(archive.entries.count == count)
        #expect(archive.entries.first?.path == "000000")
        #expect(archive.entries.last?.path == "400000")
        await #expect(throws: ArchiveNestingError(limit: .entryCount)) {
            _ = try await Archive.previewListing(at: url, limit: 5_000)
        }
    }
}
