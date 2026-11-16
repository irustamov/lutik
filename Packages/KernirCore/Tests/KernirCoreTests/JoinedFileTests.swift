import Foundation
import Testing
@testable import KernirCore

/// `JoinedFile`, the byte source of the split-ZIP probes (SPLIT-ZIP-EOCD-STRADDLE): a set's parts read as one file.
/// Every read is exactly that range of the concatenated parts, or nil when the range leaves it; a read never comes
/// back short. Covers empty parts anywhere, totals shorter than an end record, a part that shrinks after the sizes
/// were taken, and parts over 4 GiB.
@Suite struct JoinedFileTests {
    /// `contents` as `p.001`, `p.002` ... in a new folder (an empty array makes an empty part).
    static func parts(_ contents: [[UInt8]]) throws -> [URL] {
        let dir = Fixtures.tempDir()
        return try contents.enumerated().map { i, bytes in
            let url = dir.appending(path: "p" + String(format: ".%03d", i + 1))
            try Data(bytes).write(to: url)
            return url
        }
    }

    /// One run of distinct-looking bytes cut into parts of `sizes`, so a read that takes the wrong part shows.
    static func contents(sizes: [Int]) -> [[UInt8]] {
        let joined = SplitEndRecordTests.pattern(sizes.reduce(0, +))
        var start = 0
        return sizes.map { size in
            defer { start += size }
            return Array(joined[start..<(start + size)])
        }
    }

    // MARK: - Empty parts

    /// Empty parts at the start, in the middle (one and several in a row), right before the tail and at the end:
    /// every (offset, count) inside the set reads as the same slice of the concatenation, so a read crosses an
    /// empty part as if it were not there; one byte more than is left gives nil.
    @Test(arguments: [[0, 37, 0, 0, 5, 0], [37, 0, 5], [0, 0, 42], [42, 0, 0], [1, 0, 1, 0, 1]])
    func emptyPartsReadAsJoined(_ sizes: [Int]) throws {
        let contents = Self.contents(sizes: sizes)
        let joined = contents.flatMap { $0 }
        let file = try JoinedFile(try Self.parts(contents))
        let label = "parts of \(sizes) B"
        #expect(file.size == UInt64(joined.count), "\(label)")
        for offset in 0...joined.count {
            for count in 0...(joined.count - offset) {
                #expect(try file.read(at: UInt64(offset), count: UInt64(count)) == Array(joined[offset..<(offset + count)]),
                        "\(label): \(count) B at \(offset)")
            }
            #expect(try file.read(at: UInt64(offset), count: UInt64(joined.count - offset + 1)) == nil,
                    "\(label): past the end from \(offset)")
        }
        #expect(try file.read(at: UInt64(joined.count + 1), count: 0) == nil, "\(label)")
        #expect(try file.read(at: 1, count: .max) == nil, "\(label)")
    }

    // MARK: - Totals shorter than an end record

    /// 21 bytes in parts of 10 and 11 that hold an end record's signature: too short for the 22-byte record, so no
    /// record is found and there is no comment. A set of empty parts is an empty file: 0 bytes read as nothing, one
    /// byte is past the end.
    @Test func totalsUnderOneEndRecord() throws {
        let signed = [0x50, 0x4B, 5, 6] + [UInt8](repeating: 0, count: 17)
        let short = try Self.parts([Array(signed[..<10]), Array(signed[10...])])
        #expect(try !VolumeProbe.zipEOCD(parts: short).found)
        #expect(try VolumeProbe.zipComment(parts: short) == nil)

        let empty = try Self.parts([[], [], []])
        let file = try JoinedFile(empty)
        #expect(file.size == 0)
        #expect(try file.read(at: 0, count: 0) == [])
        #expect(try file.read(at: 0, count: 1) == nil)
        #expect(try !VolumeProbe.zipEOCD(parts: empty).found)
        #expect(try VolumeProbe.zipComment(parts: empty) == nil)
    }

    /// No parts at all is a read error, not a trap.
    @Test func noPartsIsAnIOError() throws {
        do {
            _ = try JoinedFile([])
            Issue.record("a set of no parts opened")
        } catch ArchiveError.io {
        }
    }

    // MARK: - A part that changes after the sizes were taken

    /// The sizes are taken when the file is made. Part 1 then shrinks from 100 to 50 bytes: a read that reaches the
    /// lost bytes is nil, never fewer bytes than asked; reads within what is still there (in part 1, and wholly in
    /// part 2) still work.
    @Test func partShrinksAfterInit() throws {
        let contents = Self.contents(sizes: [100, 60])
        let urls = try Self.parts(contents)
        let file = try JoinedFile(urls)
        #expect(file.size == 160)
        let handle = try FileHandle(forWritingTo: urls[0])
        try handle.truncate(atOffset: 50)
        try handle.close()

        #expect(try file.read(at: 40, count: 80) == nil, "across the boundary")
        #expect(try file.read(at: 60, count: 10) == nil, "wholly in the lost bytes")
        #expect(try file.read(at: 0, count: 50) == Array(contents[0][..<50]))
        #expect(try file.read(at: 100, count: 60) == contents[1])
    }

    // MARK: - Parts over 4 GiB

    /// Whether the temporary folder keeps holes in a file (APFS does): a 64 MiB file made by truncation takes
    /// under 1 MiB on disk. Without that, the sparse parts below would really take 8 GiB, so the test is skipped.
    static func sparseFilesWork() -> Bool {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "sparse")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.truncate(atOffset: 64 << 20)) != nil else { return false }
        let allocated = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
        return (allocated ?? .max) < 1 << 20
    }

    /// Two sparse parts of 4 294 967 295 bytes (the FAT32 file limit) and a 3-byte tail, with marker bytes at each
    /// part's ends: reads across both boundaries return the markers in order (offsets past 32 bits map to the right
    /// part and position), and a read one byte past the end is nil. Only the markers take disk space.
    @Test(.enabled(if: JoinedFileTests.sparseFilesWork(), "needs sparse files in the temporary folder"))
    func partsOver4GiB() throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big: UInt64 = 0xFFFF_FFFF
        let urls = (1...3).map { dir.appending(path: "big.zip" + String(format: ".%03d", $0)) }
        let markers: [(part: Int, at: UInt64, bytes: [UInt8])] = [
            (0, 0, [1, 2]), (0, big - 2, [3, 4]), (1, 0, [5, 6]), (1, big - 2, [7, 8]), (2, 0, [9, 10, 11]),
        ]
        for (i, url) in urls.enumerated() {
            try #require(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            if i < 2 { try handle.truncate(atOffset: big) }
            for m in markers where m.part == i {
                try handle.seek(toOffset: m.at)
                try handle.write(contentsOf: Data(m.bytes))
            }
            try handle.close()
        }

        let file = try JoinedFile(urls)
        #expect(file.size == 2 * big + 3)
        #expect(try file.read(at: 0, count: 2) == [1, 2])
        #expect(try file.read(at: big - 2, count: 4) == [3, 4, 5, 6], "across the first boundary")
        #expect(try file.read(at: big - 1, count: 3) == [4, 5, 6])
        #expect(try file.read(at: 2 * big - 2, count: 5) == [7, 8, 9, 10, 11], "across the second boundary")
        #expect(try file.read(at: 2 * big + 1, count: 2) == [10, 11])
        #expect(try file.read(at: 2 * big + 1, count: 3) == nil, "one byte past the end")
    }
    // MARK: - Memory

    /// Reads release their buffers as they return: `ZipEncryptionProbe` walks a whole central directory in 64 KiB
    /// windows on one thread, inside one job, and a read that left each chunk to the thread's autorelease pool kept
    /// the whole directory resident (2.2 GB for a 4-million-entry zip, on top of the listing). 4,096 reads of
    /// 64 KiB (256 MiB in all) must grow malloc's in-use total by much less than that.
    @Test func readsDoNotAccumulateChunks() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "chunk.bin")
        try Data(repeating: 0x5A, count: 64 << 10).write(to: url)
        let file = try JoinedFile([url])
        let limit: Int64 = 32 << 20
        let growths = try await MemoryQuiet.measure {
            var growths: [Int64] = []
            for _ in 0..<3 where growths.last.map({ $0 >= limit }) ?? true {
                let before = MemoryQuiet.mallocInUse()
                for _ in 0..<4096 { _ = try file.read(at: 0, count: 64 << 10) }
                growths.append(MemoryQuiet.mallocInUse() - before)
            }
            return growths
        }
        #expect(try #require(growths.min()) < limit, "growth per 256 MiB of reads (KiB): \(growths.map { $0 >> 10 })")
    }
}
