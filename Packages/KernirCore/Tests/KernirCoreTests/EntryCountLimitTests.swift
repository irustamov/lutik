import CLibArchive
import Foundation
import Testing
@testable import KernirCore

/// The entry count is capped (`NestingLimits.maxEntries`, `.entryCount`): every cost the listing pays grows with it, and
/// a tiny archive could otherwise declare any count. A 763-byte 7z of 1 M one-unit names cost 384 MiB and 8 s before
/// its first header; 100 M would be about 40 GB. Swift counts each header as it is read, before its names. A 7z (files,
/// folders, streams) and a xar (files, extended attributes) are parsed whole inside libarchive first, so Kernir patch
/// 0016 holds them to the same count there, before it allocates them, with the limits `ReadSession` hands to
/// libarchive (`kernir_read_set_name_limits`). The name total and the m1 allowances grow with the count, so they too
/// stop at what `maxEntries` implies.
@Suite("Entry count limits", .serialized)
struct EntryCountLimitTests {
    static let sevenZipEntriesMessage = "7-Zip archive has more entries than the entry limit"
    static let sevenZipStreamsMessage = "7-Zip archive has more folders or streams than the entry limit"
    static let xarEntriesMessage = "xar archive has more entries than the entry limit"
    static let xarEAsPerFileMessage = "xar entry has more than 1024 extended attributes"
    static let xarEAsMessage = "xar archive has more extended attributes than the entry limit"

    static func limits(entries: Int = NestingLimits.standard.maxEntries, total: Int = 256 << 20,
                       perEntry: Int = 0) -> NestingLimits {
        var l = NestingLimits.standard
        l.maxEntries = entries
        l.maxTotalNameBytes = total
        l.nameBytesPerEntry = perEntry
        return l
    }

    /// The error libarchive gives for the first header of `url` read with `limits`, before the reader maps it.
    static func libarchiveError(_ url: URL, _ limits: NestingLimits) -> ArchiveError? {
        do {
            let session = try ReadSession(urls: [url], password: nil, limits: limits)
            _ = try session.nextHeader()
            return nil
        } catch {
            return error
        }
    }

    typealias Outcome = SevenZipNameLimitTests.Outcome

    static func open(_ url: URL, _ limits: NestingLimits, password: String? = nil) async -> Outcome {
        await SevenZipNameLimitTests.outcome {
            _ = try await LibArchiveReader.open(at: url, password: password, limits: limits)
        }
    }

    // MARK: - Values

    /// The compile-time defaults of patch 0016, and what a fresh libarchive reader holds, are `.standard`'s.
    @Test func standardEntryLimits() {
        let s = NestingLimits.standard
        #expect(s.maxEntries == 4_000_000)
        #expect(s.nameBytesPerEntry == 512)
        #expect(s.maxTotalNameBytes == 256 << 20)
        #expect(Int(KERNIR_READ_MAX_ENTRIES) == s.maxEntries)
        #expect(Int(KERNIR_READ_NAMES_BYTES) == s.maxTotalNameBytes)
        #expect(Int(KERNIR_READ_NAME_BYTES_PER_ENTRY) == s.nameBytesPerEntry)
        let a = archive_read_new()
        defer { archive_read_free(a) }
        var entries: UInt64 = 0, names: UInt64 = 0, perEntry: UInt64 = 0
        #expect(kernir_read_get_name_limits(a, &entries, &names, &perEntry) == ARCHIVE_OK)
        #expect(entries == UInt64(s.maxEntries))
        #expect(names == UInt64(s.maxTotalNameBytes))
        #expect(perEntry == UInt64(s.nameBytesPerEntry))
        // An honest wide tree stores at most 254 bytes of names per entry: it meets the entry cap first.
        #expect(254 * s.maxEntries < max(s.maxTotalNameBytes, s.nameBytesPerEntry * s.maxEntries))
    }

    /// `ReadSession` hands its limits to libarchive before it opens the file.
    @Test func readSessionSetsLibarchiveLimits() throws {
        let url = NestingLimitTests.written(["a"], as: "tar")
        let session = try ReadSession(urls: [url], password: nil, limits: Self.limits(entries: 7, total: 99,
                                                                                         perEntry: 3))
        var entries: UInt64 = 0, names: UInt64 = 0, perEntry: UInt64 = 0
        #expect(kernir_read_get_name_limits(session.handle, &entries, &names, &perEntry) == ARCHIVE_OK)
        #expect([entries, names, perEntry] == [7, 99, 3])
        // Too late once the file is open.
        #expect(kernir_read_set_name_limits(session.handle, 1, 1, 1) == ARCHIVE_FATAL)
    }

    // MARK: - Swift: every header counts, as it is read

    @Test(arguments: NestingLimitTests.kinds)
    func entryCapIsExact(kind: String) async throws {
        let five = (1...5).map { "f\($0).txt" }
        let reader = try await LibArchiveReader.open(at: NestingLimitTests.archive(five, as: kind), password: nil,
                                                     limits: Self.limits(entries: 5))
        #expect(reader.entries.count == 5)
        let listing = try await LibArchiveReader.previewListing(at: NestingLimitTests.archive(five, as: kind),
                                                                password: nil, limit: 10,
                                                                limits: Self.limits(entries: 5))
        #expect(listing.visibleEntryCount == 5)
        await NestingLimitTests.expectRefused(NestingLimitTests.archive(five + ["f6.txt"], as: kind), .entryCount,
                                              limits: Self.limits(entries: 5))
    }

    /// Duplicate headers and headers whose name normalizes to nothing count like any other.
    @Test func skippedAndDuplicateHeadersCount() async throws {
        let paths = ["a", "a", "./", "a", "b", "a"]
        let at = try await LibArchiveReader.open(at: NestingLimitTests.written(paths, as: "tar"), password: nil,
                                                 limits: Self.limits(entries: 6))
        #expect(at.entries.map(\.path) == ["a", "b"])
        await NestingLimitTests.expectRefused(NestingLimitTests.written(paths, as: "tar"), .entryCount,
                                              limits: Self.limits(entries: 5))
    }

    /// Header N+1 is refused before anything reads its names or the headers after it.
    @Test func capComesBeforeTheHeadersNamesAndTheRest() async throws {
        let long = String(repeating: "x", count: 65_537)
        let url = NestingLimitTests.written((1...5).map { "f\($0)" } + [long], as: "tar")
        await NestingLimitTests.expectRefused(url, .pathLength, limits: Self.limits(entries: 6))
        await NestingLimitTests.expectRefused(url, .entryCount, limits: Self.limits(entries: 5))
        // A cut seventh header: the cap answers first; with room for it, the damage shows.
        let full = try Data(contentsOf: NestingLimitTests.written((1...7).map { "f\($0)" }, as: "tar"))
        let cut = Fixtures.tempDir().appendingPathComponent("cut.tar")
        try full.prefix(6 * 512 + 100).write(to: cut)
        await NestingLimitTests.expectRefused(cut, .entryCount, limits: Self.limits(entries: 5))
        let damaged = await Self.open(cut, Self.limits(entries: 7))
        #expect(damaged != .opened && damaged != .limit(.entryCount), "\(damaged)")
    }

    // MARK: - Swift: the name total grows with the headers

    /// 100 bytes fixed, 30 more per header once that is more: each header of a 30-byte name fits exactly, one more
    /// byte does not; below the fixed part the first headers share 100.
    @Test func nameTotalGrowsWithTheHeaders() async throws {
        let limits = Self.limits(total: 100, perEntry: 30)
        func names(_ lengths: [Int]) -> [String] {
            lengths.enumerated().map { i, n in String(UnicodeScalar(UInt8(0x61 + i))) + String(repeating: "x", count: n - 1) }
        }
        let thirty = names(Array(repeating: 30, count: 8))
        let reader = try await LibArchiveReader.open(at: NestingLimitTests.written(thirty, as: "tar"), password: nil,
                                                     limits: limits)
        #expect(reader.entries.count == 8)
        await NestingLimitTests.expectRefused(NestingLimitTests.written(names(Array(repeating: 30, count: 7) + [31]),
                                                                        as: "tar"), .totalPathBytes, limits: limits)
        let fixed = try await LibArchiveReader.open(at: NestingLimitTests.written(names([50, 50]), as: "tar"),
                                                    password: nil, limits: limits)
        #expect(fixed.entries.count == 2)
        await NestingLimitTests.expectRefused(NestingLimitTests.written(names([50, 50, 1]), as: "tar"),
                                              .totalPathBytes, limits: limits)
        // Saturates instead of trapping.
        for perEntry in [Int.max, 1 << 62] {
            let huge = try await LibArchiveReader.open(at: NestingLimitTests.written(thirty, as: "tar"),
                                                       password: nil, limits: Self.limits(total: 1, perEntry: perEntry))
            #expect(huge.entries.count == 8)
        }
    }

    // MARK: - Swift: the m1 allowances stop at maxEntries

    /// Charged directly, past `maxEntries`: the per-path allowances count at most `maxEntries` paths.
    @Test func allowancesStopGrowingAtMaxEntries() throws {
        // Ancestor work: 4 bytes per path, 0 fixed; 20 one-byte paths, then one of 25 bytes. 10 count: 45 > 40.
        var work = NestingBudget(NestingLimits(maxComponents: 200, maxPathBytes: 16 << 10, maxFolderBytes: .max,
                                               maxAncestorWork: 0, ancestorWorkPerPath: 4, maxEntries: 10))
        for _ in 0..<20 { try work.charge("x/y") }
        #expect(throws: ArchiveNestingError(limit: .ancestorWork)) {
            try work.charge(String(repeating: "a", count: 25) + "/z")
        }
        var roomy = NestingBudget(NestingLimits(maxComponents: 200, maxPathBytes: 16 << 10, maxFolderBytes: .max,
                                                maxAncestorWork: 0, ancestorWorkPerPath: 4, maxEntries: 21))
        for _ in 0..<20 { try roomy.charge("x/y") }
        try roomy.charge(String(repeating: "a", count: 25) + "/z")
        // Folders: 200 bytes per path, 0 fixed; "x" costs 129, a new 1,800-byte folder 1,928: 2,057 > 10 × 200.
        var folders = NestingBudget(NestingLimits(maxComponents: 200, maxPathBytes: 16 << 10, maxFolderBytes: 0,
                                                  folderBytesPerPath: 200, maxAncestorWork: .max, maxEntries: 10))
        for _ in 0..<20 { try folders.charge("x/y") }
        #expect(throws: ArchiveNestingError(limit: .folderBytes)) {
            try folders.charge(String(repeating: "b", count: 1_800) + "/z")
        }
        var roomyFolders = NestingBudget(NestingLimits(maxComponents: 200, maxPathBytes: 16 << 10, maxFolderBytes: 0,
                                                       folderBytesPerPath: 200, maxAncestorWork: .max, maxEntries: 11))
        for _ in 0..<20 { try roomyFolders.charge("x/y") }
        try roomyFolders.charge(String(repeating: "b", count: 1_800) + "/z")
    }

    // MARK: - 7z: patch 0016, before the allocations

    /// A plain 7z header of `body` (after kHeader) that declares `declared` more bytes than it holds, so the parse
    /// runs out right after `body`.
    static func sevenZipHeader(_ body: [UInt8], declared: Int = 1 << 20) throws -> URL {
        let header = [0x01] + body
        let url = Fixtures.tempDir().appendingPathComponent("streams.7z")
        try Data(SevenZipNameLimitTests.signatureHeader(offset: 0, size: header.count + declared, crc: 0) + header)
            .write(to: url)
        return url
    }

    static func number(_ v: Int) -> [UInt8] { SevenZipNameLimitTests.number(v) }

    /// PackInfo with `count` pack streams, cut after the count.
    static func packStreams(_ count: Int) throws -> URL { try sevenZipHeader([0x04, 0x06, 0x00] + number(count)) }
    /// UnPackInfo with `count` folders, cut after the count.
    static func folders(_ count: Int) throws -> URL { try sevenZipHeader([0x04, 0x07, 0x0B] + number(count)) }
    /// One pack stream, one Copy folder, and SubStreamsInfo giving it `count` unpack streams, cut at their sizes.
    static func unpackStreams(_ count: Int) throws -> URL {
        let packInfo: [UInt8] = [0x06, 0x00, 0x01, 0x09, 0x00, 0x00]
        let unpackInfo: [UInt8] = [0x07, 0x0B, 0x01, 0x00, 0x01, 0x01, 0x00, 0x0C, 0x00, 0x00]
        return try sevenZipHeader([0x04] + packInfo + unpackInfo + [0x08, 0x0D] + number(count) + [0x09])
    }
    /// PackInfo with `count` pack streams and kSize, cut there: libarchive callocs the sizes and positions first.
    static func sizedPackStreams(_ count: Int) throws -> URL {
        try sevenZipHeader([0x04, 0x06, 0x00] + number(count) + [0x09])
    }
    /// UnPackInfo with `count` inline folders (External 0), cut there: libarchive callocs the folders first.
    static func inlineFolders(_ count: Int) throws -> URL {
        try sevenZipHeader([0x04, 0x07, 0x0B] + number(count) + [0x00])
    }

    @Test func sevenZipEntryCapIsExact() async throws {
        let five = try SevenZipNameLimitTests.write(Array(repeating: 1, count: 5), encoded: false)
        #expect(Self.libarchiveError(five, Self.limits(entries: 5)) == nil)
        let six = try SevenZipNameLimitTests.write(Array(repeating: 1, count: 6), encoded: false)
        #expect(Self.libarchiveError(six, Self.limits(entries: 5)) == .corrupted(Self.sevenZipEntriesMessage))
        #expect(await Self.open(six, Self.limits(entries: 5)) == .limit(.entryCount))
        #expect(await Self.open(six, Self.limits(entries: 6)) == .opened)
    }

    /// Pack streams up to 4 × maxEntries, folders and unpack streams up to maxEntries; one more is refused.
    @Test func sevenZipStreamCapsAreExact() async throws {
        let limits = Self.limits(entries: 3)
        let damaged = ArchiveError.corrupted("Damaged 7-Zip archive")
        let refused = ArchiveError.corrupted(Self.sevenZipStreamsMessage)
        #expect(Self.libarchiveError(try Self.packStreams(12), limits) == damaged)
        #expect(Self.libarchiveError(try Self.packStreams(13), limits) == refused)
        #expect(Self.libarchiveError(try Self.folders(3), limits) == damaged)
        #expect(Self.libarchiveError(try Self.folders(4), limits) == refused)
        #expect(Self.libarchiveError(try Self.unpackStreams(3), limits) == damaged)
        #expect(Self.libarchiveError(try Self.unpackStreams(4), limits) == refused)
        for url in [try Self.packStreams(13), try Self.folders(4), try Self.unpackStreams(4)] {
            #expect(await Self.open(url, limits) == .limit(.entryCount))
        }
    }

    /// At the standard cap, numFiles = 4,000,001 is refused before libarchive allocates its entries (about 350 MB):
    /// the truncated header runs out at 4,000,000. Both the malloc growth and, through `AllocationWatch`, every block
    /// allocated during the open are checked, so a cap moved after the calloc fails even though the block is freed
    /// within microseconds.
    @Test func sevenZipStandardEntryCapIsCheckedBeforeTheAllocation() async throws {
        let cap = NestingLimits.standard.maxEntries
        let at = try SevenZipNameLimitTests.truncated(count: cap, namesBytes: 4 * cap + 2)
        let over = try SevenZipNameLimitTests.truncated(count: cap + 1, namesBytes: 4 * cap + 6)
        let (outcome, growth) = await SevenZipNameLimitTests.refusal(over, under: 16 << 20)
        #expect(outcome == .limit(.entryCount))
        #expect(growth < 16 << 20, "malloc growth \(growth >> 20) MiB")
        // A calloc freed at once escapes that 1 ms sampler, so malloc_logger watches every block. At the cap,
        // libarchive callocs its entries (cap × 80+ B), which shows the watch sees them; one over, no block sized by
        // the count may come before the refusal.
        let control = try await AllocationWatch.largestMultiple(of: cap) { await SevenZipNameLimitTests.open(at) }
        #expect(control.result == .corrupted("Damaged 7-Zip archive"))
        #expect(control.largest >= 32 * cap, "largest block of cap × n bytes: \(control.largest)")
        let refused = try await AllocationWatch.largestMultiple(of: cap + 1) {
            await SevenZipNameLimitTests.open(over)
        }
        #expect(refused.result == .limit(.entryCount))
        #expect(refused.largest == 0, "a block of \(refused.largest / (cap + 1)) B per entry came before the refusal")
    }

    /// The three stream caps the 7z reader checks before the calloc of the array each count sizes.
    enum StreamCap: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case packStreams = "pack streams", folders, unpackStreams = "unpack streams"
        var testDescription: String { rawValue }
    }

    /// The pack stream, folder and unpack stream caps come before their callocs too. Each header runs on to the calloc
    /// and is cut right after it: at the cap `AllocationWatch` sees the array sized by the count (the control), one
    /// over it sees no such block before the refusal, so a cap moved after its calloc fails. The old tests
    /// (`sevenZipStreamCapsAreExact`) already kill the pack stream and folder mutants, but not the unpack stream one;
    /// this pins all three. With maxEntries = 100,003 the counts (100,003, 100,004, 400,012, 400,013) are large, with
    /// no power-of-two factor beyond 4, so no other block in the process is a whole multiple of them, and the arrays
    /// are at most 13 MiB of untouched calloc pages.
    @Test(arguments: StreamCap.allCases)
    func sevenZipStreamCapsAreCheckedBeforeTheAllocations(cap: StreamCap) async throws {
        let entries = 100_003
        let limits = Self.limits(entries: entries)
        let kind = cap.rawValue
        // The count at the cap, a lower bound on the element size of its largest array, and the header.
        let (count, element, header): (Int, Int, (Int) throws -> URL) = switch cap {
        case .packStreams: (4 * entries, 8, Self.sizedPackStreams)      // int64_t sizes and positions
        case .folders: (entries, 64, Self.inlineFolders)                // struct _7z_folder: 128 B on 64-bit
        case .unpackStreams: (entries, 8, Self.unpackStreams)           // int64_t unpackSizes
        }
        let at = try header(count)
        let over = try header(count + 1)
        let control = try await AllocationWatch.largestMultiple(of: count) { Self.libarchiveError(at, limits) }
        #expect(control.result == .corrupted("Damaged 7-Zip archive"))
        #expect(control.largest >= element * count, "largest block of \(kind) × n bytes: \(control.largest)")
        let refused = try await AllocationWatch.largestMultiple(of: count + 1) { Self.libarchiveError(over, limits) }
        #expect(refused.result == .corrupted(Self.sevenZipStreamsMessage))
        #expect(refused.largest == 0,
                "a block of \(refused.largest / (count + 1)) B per \(kind) came before the refusal")
    }

    /// Behind an encrypted header: the right password gives the cap, not `.wrongPassword`.
    @Test func sevenZipEncryptedHeaderEntryCap() async throws {
        let url = try SevenZipNameLimitTests.write(Array(repeating: 1, count: 6), encoded: true, password: "pw")
        let limits = Self.limits(entries: 5)
        #expect(await Self.open(url, limits, password: "pw") == .limit(.entryCount))
        #expect(await Self.open(url, limits) == .other("\(ArchiveError.passwordRequired)"))
        #expect(await Self.open(url, limits, password: "wrong") == .other("\(ArchiveError.wrongPassword)"))
        #expect(await Self.open(url, Self.limits(entries: 6), password: "pw") == .opened)
    }

    /// The 7z names block does not grow with the CLAIMED numFiles (unlike the Swift and xar totals, which grow with
    /// the entries actually parsed): it stays 2 × the names limit + 2 × numFiles, 512 MiB + 2 B per entry at
    /// `.standard` (patch 0014's limit). Growing it with numFiles let a ~1 MB LZMA header of zeros claim a 4.1 GB block.
    @Test func sevenZipBlockLimitDoesNotGrowWithTheEntries() async throws {
        let count = 600_000
        let over = try SevenZipNameLimitTests.truncated(count: count,
                                                        namesBytes: SevenZipNameLimitTests.blockLimit(count) + 2)
        #expect(await SevenZipNameLimitTests.open(over) == .limit(.totalPathBytes))
        // With small limits through the setter: 2 × 100 + 6 = 206, whatever the per-entry figure (60 × 3 = 180).
        let small = Self.limits(total: 100, perEntry: 60)
        #expect(Self.libarchiveError(try SevenZipNameLimitTests.truncated(count: 3, namesBytes: 2 * 100 + 6), small)
                == .corrupted("Damaged 7-Zip archive"))
        #expect(Self.libarchiveError(try SevenZipNameLimitTests.truncated(count: 3, namesBytes: 2 * 100 + 8), small)
                == .corrupted(SevenZipNameLimitTests.blockMessage))
    }

    /// At the standard entry cap, a names block 2 bytes over 512 MiB + 2 B per entry, and the 4.1 GB block that
    /// 2 × 512 B × numFiles would allow, are refused before libarchive mallocs the block: `AllocationWatch` sees no
    /// block of that size. The control at the limit shows the watch sees the block (the truncated header runs out).
    @Test func sevenZipStandardBlockLimitIsCheckedBeforeTheAllocation() async throws {
        let cap = NestingLimits.standard.maxEntries
        let limit = SevenZipNameLimitTests.blockLimit(cap)
        #expect(limit == 544_870_912)
        let at = try SevenZipNameLimitTests.truncated(count: cap, namesBytes: limit)
        let control = try await AllocationWatch.largestMultiple(of: limit) { await SevenZipNameLimitTests.open(at) }
        #expect(control.result == .corrupted("Damaged 7-Zip archive"))
        #expect(control.largest == limit, "largest block of the names size: \(control.largest)")
        for size in [limit + 2, 2 * 512 * cap + 2 * cap] {
            let over = try SevenZipNameLimitTests.truncated(count: cap, namesBytes: size)
            let refused = try await AllocationWatch.largestMultiple(of: size) { await SevenZipNameLimitTests.open(over) }
            #expect(refused.result == .limit(.totalPathBytes), "\(size)")
            #expect(refused.largest == 0, "a \(refused.largest)-byte block came before the refusal of \(size)")
        }
    }

    /// The pack stream cap is 4 × maxEntries, saturated: past 2^62 the product would wrap (to 4 for 2^62 + 1) and
    /// refuse almost every pack stream count.
    @Test func sevenZipPackStreamCapSaturates() throws {
        let huge = Self.limits(entries: (1 << 62) + 1)
        #expect(Self.libarchiveError(try Self.packStreams(13), huge) == .corrupted("Damaged 7-Zip archive"))
        // libarchive's own bound on any 7z count (UMAX_ENTRY).
        #expect(Self.libarchiveError(try Self.packStreams(100_000_000), huge) == .corrupted("Damaged 7-Zip archive"))
    }

    // MARK: - xar: patch 0016, while the TOC is parsed

    /// `count` files, all in one folder of `folder` (its body: `XarTOCLimitTests.bare` or `.meta`) when given, then
    /// `bareFolders` empty top-level bare folders.
    static func xarFiles(_ count: Int, folder: String? = nil, bareFolders: Int = 0, eas: [Int] = []) throws -> URL {
        var toc = XarTOCLimitTests.TOC()
        if let folder { toc.open(1, 0x64, folder) }
        for i in 0..<count {
            toc.add("<file id=\"\(toc.id())\"><name>f\(i)</name><type>file</type><mode>0644</mode>")
            for e in 0..<(i < eas.count ? eas[i] : 0) { toc.add("<ea id=\"\(e)\"><name>e\(e)</name></ea>") }
            toc.add("</file>")
        }
        if folder != nil { toc.add("</file>") }
        for i in 0..<bareFolders {
            toc.add("<file id=\"\(toc.id())\"><name>b\(i)</name>\(XarTOCLimitTests.bare)</file>")
        }
        return try XarTOCLimitTests.write(toc)
    }

    @Test func xarEntryCapIsExact() async throws {
        let limits = Self.limits(entries: 5)
        #expect(Self.libarchiveError(try Self.xarFiles(5), limits) == nil)
        #expect(Self.libarchiveError(try Self.xarFiles(6), limits) == .corrupted(Self.xarEntriesMessage))
        #expect(await Self.open(try Self.xarFiles(6), limits) == .limit(.entryCount))
        #expect(await Self.open(try Self.xarFiles(5), limits) == .opened)
        // A bare folder (only a name and type directory) is never a header, so, as in Swift, which counts the headers,
        // it does not count (patch 0019): 5 files in one pass, 6 do not.
        let bare = XarTOCLimitTests.bare
        #expect(Self.libarchiveError(try Self.xarFiles(5, folder: bare), limits) == nil)
        #expect(await Self.open(try Self.xarFiles(5, folder: bare), limits) == .opened)
        #expect(Self.libarchiveError(try Self.xarFiles(6, folder: bare), limits) == .corrupted(Self.xarEntriesMessage))
        #expect(await Self.open(try Self.xarFiles(6, folder: bare), limits) == .limit(.entryCount))
        // A folder with metadata is a header and counts: it and 5 files make 6; it and 4 make 5.
        let meta = XarTOCLimitTests.meta
        #expect(Self.libarchiveError(try Self.xarFiles(4, folder: meta), limits) == nil)
        #expect(Self.libarchiveError(try Self.xarFiles(5, folder: meta), limits) == .corrupted(Self.xarEntriesMessage))
        #expect(await Self.open(try Self.xarFiles(5, folder: meta), limits) == .limit(.entryCount))
    }

    /// Bare folders do not count against the entry cap, but each is a <file> libarchive allocates: patch 0019 allows
    /// as many again, so a TOC holds at most 2 × maxEntries <file> elements, whatever they are.
    @Test func xarBareFoldersAreHeldToTheEntryCapAgain() async throws {
        let limits = Self.limits(entries: 5)
        #expect(Self.libarchiveError(try Self.xarFiles(5, bareFolders: 5), limits) == nil)
        #expect(await Self.open(try Self.xarFiles(5, bareFolders: 5), limits) == .opened)
        #expect(Self.libarchiveError(try Self.xarFiles(5, bareFolders: 6), limits)
                == .corrupted(Self.xarEntriesMessage))
        #expect(await Self.open(try Self.xarFiles(5, bareFolders: 6), limits) == .limit(.entryCount))
        // Nothing but bare folders: 10 pass (no header at all), 11 do not.
        #expect(Self.libarchiveError(try Self.xarFiles(0, bareFolders: 10), limits) == nil)
        #expect(Self.libarchiveError(try Self.xarFiles(0, bareFolders: 11), limits)
                == .corrupted(Self.xarEntriesMessage))
    }

    /// The headers libarchive returns for `url` with an entry limit of `maxEntries` (any UInt64), or its error.
    static func xarHeaders(_ url: URL, maxEntries: UInt64) -> Result<Int, ArchiveError> {
        guard let a = archive_read_new() else { return .failure(.io("archive_read_new")) }
        defer { archive_read_free(a) }
        _ = kernir_read_set_name_limits(a, maxEntries, 256 << 20, 512)
        archive_read_support_format_xar(a)
        guard archive_read_open_filename(a, url.path, 10_240) == ARCHIVE_OK else {
            return .failure(.corrupted(archive_error_string(a).map { String(cString: $0) } ?? "open failed"))
        }
        var count = 0
        var entry: OpaquePointer?
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { return .success(count) }
            guard r == ARCHIVE_OK else {
                return .failure(.corrupted(archive_error_string(a).map { String(cString: $0) } ?? "rc \(r)"))
            }
            count += 1
        }
    }

    /// A folder still bare when its child closes becomes a listed header once its <mode> follows: the count is made
    /// at its own </file>, so it is the headers Swift sees (the folder, 2 files; the bare folder inside is not one).
    @Test func xarFolderListedAfterItsChildClosesCountsAsAHeader() async throws {
        var toc = XarTOCLimitTests.TOC()
        toc.add("<file id=\"\(toc.id())\"><name>d</name><type>directory</type>")
        for i in 0..<2 {
            toc.add("<file id=\"\(toc.id())\"><name>f\(i)</name><type>file</type><mode>0644</mode></file>")
        }
        toc.add("<file id=\"\(toc.id())\"><name>b</name>\(XarTOCLimitTests.bare)</file>")
        toc.add("<mode>0755</mode></file>")
        let url = try XarTOCLimitTests.write(toc)
        #expect(Self.xarHeaders(url, maxEntries: 100) == .success(3))
        #expect(Self.xarHeaders(url, maxEntries: 3) == .success(3))
        #expect(Self.xarHeaders(url, maxEntries: 2) == .failure(.corrupted(Self.xarEntriesMessage)))
        #expect(await Self.open(url, Self.limits(entries: 3)) == .opened)
        #expect(await Self.open(url, Self.limits(entries: 2)) == .limit(.entryCount))
    }

    /// The <file> cap, 2 × the entry limit, saturates: an entry limit of 2^63 + 2 would wrap it to 4.
    @Test func xarFileElementCapSaturates() throws {
        let url = try Self.xarFiles(5, folder: XarTOCLimitTests.bare)
        #expect(Self.xarHeaders(url, maxEntries: (1 << 63) + 2) == .success(5))
        #expect(Self.xarHeaders(url, maxEntries: .max) == .success(5))
        #expect(Self.xarHeaders(url, maxEntries: 5) == .success(5))
        #expect(Self.xarHeaders(url, maxEntries: 4) == .failure(.corrupted(Self.xarEntriesMessage)))
    }

    /// At most 1,024 <ea> on one file: libarchive keeps them sorted by walking the file's list for each one, so their
    /// cost grows with the square of their count. At most maxEntries <ea> in all.
    @Test func xarExtendedAttributesAreCapped() async throws {
        let atCap = Self.libarchiveError(try Self.xarFiles(1, eas: [1_024]), .standard)
        #expect(atCap != .corrupted(Self.xarEAsPerFileMessage) && atCap != .corrupted(Self.xarEAsMessage),
                "\(String(describing: atCap))")
        #expect(Self.libarchiveError(try Self.xarFiles(1, eas: [1_025]), .standard)
                == .corrupted(Self.xarEAsPerFileMessage))
        // The attack: 50,000 on one file, about 4 s of list walks without the cap.
        let many = try Self.xarFiles(1, eas: [50_000])
        #expect(await Self.open(many, .standard) == .limit(.entryCount))
        // In all: 5 across 3 files pass a cap of 5, 6 do not.
        let limits = Self.limits(entries: 5)
        #expect(Self.libarchiveError(try Self.xarFiles(3, eas: [2, 2, 1]), limits)
                != .corrupted(Self.xarEAsMessage))
        #expect(Self.libarchiveError(try Self.xarFiles(3, eas: [2, 2, 2]), limits) == .corrupted(Self.xarEAsMessage))
        #expect(await Self.open(try Self.xarFiles(3, eas: [2, 2, 2]), limits) == .limit(.entryCount))
    }

    /// xar's names total: max(100, 30 × the <file> elements so far).
    @Test func xarNameTotalGrowsWithTheFiles() throws {
        func toc(_ lengths: [Int]) throws -> URL {
            var t = XarTOCLimitTests.TOC()
            for (i, n) in lengths.enumerated() { t.open(n, UInt8(0x61 + i), XarTOCLimitTests.meta); t.add("</file>") }
            return try XarTOCLimitTests.write(t)
        }
        let limits = Self.limits(total: 100, perEntry: 30)
        #expect(Self.libarchiveError(try toc(Array(repeating: 30, count: 6)), limits) == nil)
        #expect(Self.libarchiveError(try toc(Array(repeating: 30, count: 5) + [31]), limits)
                == .corrupted(XarTOCLimitTests.totalMessage))
        #expect(Self.libarchiveError(try toc([100]), limits) == nil)
        #expect(Self.libarchiveError(try toc([101]), limits) == .corrupted(XarTOCLimitTests.totalMessage))
        // Saturates: 2^62 bytes per file would wrap to 0 at the fourth file.
        #expect(Self.libarchiveError(try toc(Array(repeating: 30, count: 6)), Self.limits(total: 1, perEntry: 1 << 62))
                == nil)
    }

    /// The names total grows with every <file> element (bare folders too) but, as Swift's allowances, with at most
    /// maxEntries of them (patch 0019): 5 files of 30 bytes and a bare folder of 1 byte are 151 bytes over a total of
    /// max(100, 30 × min(6, 5)) = 150. Swift alone would accept this (its headers leave out the bare folder: 150
    /// bytes), but C's names total still charges the bare folder's name bytes, so it refuses slightly before Swift.
    /// Kept: only the entry count was moved to listed elements.
    @Test func xarNameTotalStopsGrowingAtTheEntryCap() throws {
        func toc(_ last: Int) throws -> URL {
            var t = XarTOCLimitTests.TOC()
            for (i, n) in [30, 30, 30, 30, last].enumerated() {
                t.open(n, UInt8(0x61 + i), "<type>file</type><mode>0644</mode>")
                t.add("</file>")
            }
            t.open(1, 0x7A, XarTOCLimitTests.bare)
            t.add("</file>")
            return try XarTOCLimitTests.write(t)
        }
        let limits = Self.limits(entries: 5, total: 100, perEntry: 30)
        #expect(Self.libarchiveError(try toc(29), limits) == nil)
        #expect(Self.libarchiveError(try toc(30), limits) == .corrupted(XarTOCLimitTests.totalMessage))
        // With a higher entry cap the sixth <file> grows the total to 180.
        #expect(Self.libarchiveError(try toc(30), Self.limits(entries: 6, total: 100, perEntry: 30)) == nil)
    }

    /// The hardlink copies are charged against the grown total: an original "o…" of 100 bytes and 9 hardlinks
    /// (names "h0"…"h7" and one of 4-5 bytes) store 100 + 20 + 9 × 100 = 1,020 bytes, 102 × 10 files.
    @Test func xarHardlinkCopiesUseTheGrownTotal() throws {
        func toc(_ last: String) throws -> URL {
            var t = XarTOCLimitTests.TOC()
            t.add("<file id=\"9999999\"><name>o" + String(repeating: "x", count: 99)
                  + "</name><type link=\"original\">hardlink</type><mode>0644</mode></file>")
            for name in (0..<8).map({ "h\($0)" }) + [last] {
                t.add("<file id=\"\(t.id())\"><name>\(name)</name><type link=\"9999999\">hardlink</type>"
                      + "<mode>0644</mode></file>")
            }
            return try XarTOCLimitTests.write(t)
        }
        let limits = Self.limits(total: 200, perEntry: 102)
        #expect(Self.libarchiveError(try toc("h8xx"), limits) == nil)
        #expect(Self.libarchiveError(try toc("h8xxx"), limits) == .corrupted(XarTOCLimitTests.hardlinkMessage))
    }

    // MARK: - Mapping

    @Test("Patch 0016's messages are the ones the reader maps to the entry cap")
    func refusalMessagesAreMapped() {
        for message in [Self.sevenZipEntriesMessage, Self.sevenZipStreamsMessage, Self.xarEntriesMessage,
                        Self.xarEAsPerFileMessage, Self.xarEAsMessage] {
            #expect(PatchedNameRefusal.refusal(for: .corrupted(message)) == ArchiveNestingError(limit: .entryCount),
                    "\(message)")
            #expect(PatchedNameRefusal.refusal(for: .corrupted(message + ".")) == nil)
        }
        for message in [SevenZipNameLimitTests.blockMessage, XarTOCLimitTests.totalMessage,
                        XarTOCLimitTests.hardlinkMessage] {
            #expect(PatchedNameRefusal.refusal(for: .corrupted(message)) == ArchiveNestingError(limit: .totalPathBytes),
                    "\(message)")
        }
    }
}
