import CLibArchive
import Foundation
import Testing
@testable import KernirCore

/// libarchive's ISO 9660 reader reads a whole directory, and every Rockridge continuation area (CE) its records point
/// at, before it returns the directory's first entry, so no Swift-side limit comes in time. Kernir patch 0021 makes that
/// work follow the image's real bytes and Kernir's limits: a directory extent is read one logical block at a time (its
/// size was read ahead whole: a 296 KiB image claiming a 4 GiB directory had libarchive malloc 4.3 GB), every record is
/// counted against the entry limit before it is allocated, and each record's name and link target are charged to the
/// names total after the record and after each continuation area (many records can share one CE chain, which then
/// grows every one of their names: N records × k blocks of names from k blocks of file; each record's pass over each
/// area is charged by the area's size too, so a chain that grows no name costs no more). The reader turns each refusal
/// into the `ArchiveNestingError` the Swift-side limit for the same thing throws (`PatchedNameRefusal`).
@Suite("ISO 9660 reader limits", .serialized, .timeLimit(.minutes(3)))
struct ISO9660LimitTests {
    static let entriesMessage = "ISO9660 image has more entries than the entry limit"
    static let nameMessage = "ISO9660 entry name is longer than 65536 bytes"
    static let linkMessage = "ISO9660 link target is longer than 65536 bytes"
    static let totalMessage = "ISO9660 entry names and link targets take more than the names limit"

    typealias ISO = SyntheticISO

    static func libarchiveError(_ url: URL, _ limits: NestingLimits = .standard) -> ArchiveError? {
        EntryCountLimitTests.libarchiveError(url, limits)
    }

    static func open(_ url: URL, _ limits: NestingLimits = .standard) async -> SevenZipNameLimitTests.Outcome {
        await EntryCountLimitTests.open(url, limits)
    }

    /// A CE chain from block `start`: `payload` bytes of `byte`, in entries of at most `piece` bytes (made by `entry`,
    /// each continuing the one before), 7 to a block, each block but the last ending in a CE to the next. Returns the
    /// blocks and the size of the first block's area (what the CE pointing at the chain gives).
    static func chain(start: Int, payload: Int, byte: UInt8 = 0x61, piece: Int = 250,
                      entry: ([UInt8], Bool) -> [UInt8] = { ISO.nm($0, continues: $1) }) -> (blocks: [[UInt8]], size: Int) {
        var pieces: [Int] = []
        var left = payload
        while left > 0 { pieces.append(min(piece, left)); left -= piece }
        let perBlock = 7
        let groups = stride(from: 0, to: pieces.count, by: perBlock).map { Array(pieces[$0..<min($0 + perBlock, pieces.count)]) }
        var areas: [[UInt8]] = groups.enumerated().map { g, sizes in
            sizes.enumerated().flatMap { i, n in
                entry(Array(repeating: byte, count: n), !(g == groups.count - 1 && i == sizes.count - 1))
            }
        }
        for g in stride(from: areas.count - 2, through: 0, by: -1) {
            areas[g] += ISO.ce(block: start + g + 1, size: areas[g + 1].count)
        }
        return (areas, areas.first?.count ?? 0)
    }

    // MARK: - Valid images still list

    /// A root extent over two blocks, a name carried on through a two-block CE chain, a symlink and a subdirectory.
    @Test func smallRockridgeImageLists() async throws {
        let long = 2_000
        let files = 40
        var dirBlock = 0
        let url = try ISO.image(children: { start in
            let c = Self.chain(start: start, payload: long)
            dirBlock = start + c.blocks.count
            var records = [ISO.file(0, susp: ISO.nm("x", continues: true) + ISO.ce(block: start, size: c.size))]
            records += (1..<files).map { ISO.file($0, susp: ISO.nm("file\($0)")) }
            records.append(ISO.file(files, susp: ISO.px(mode: 0o120777) + ISO.nm("l") + ISO.sl(Array("target".utf8))))
            records.append(ISO.record(Array("D".utf8), location: dirBlock, size: UInt32(ISO.block), directory: true,
                                      susp: ISO.nm("d")))
            return records
        }, extra: { start in
            let c = Self.chain(start: start, payload: long)
            let dir = [ISO.record([0], location: dirBlock, size: UInt32(ISO.block), directory: true, susp: ISO.nm(".")),
                       ISO.record([1], location: ISO.rootLocation, directory: true, susp: ISO.nm("..")),
                       ISO.file(0, susp: ISO.nm("g"))].flatMap { $0 }
            return c.blocks + [dir]
        })
        #expect(Self.libarchiveError(url) == nil)
        let reader = try await XarNameCharDataTests.reader(url)
        var expected = Set((1..<files).map { "file\($0)" })
        expected.formUnion(["x" + String(repeating: "a", count: long), "l", "d", "d/g"])
        #expect(Set(reader.entries.map(\.path)).isSuperset(of: expected),
                "\(Set(reader.entries.map(\.path)).symmetricDifference(expected).map { $0.prefix(40) })")
        #expect(reader.symlinkTargetByPath["l"] == "target")
    }

    /// Joliet names without Rockridge: choose_volume reads the primary root's record, then the Joliet root's (each at
    /// most 255 bytes), and the listing has the Joliet names, not the primary tree's F0;1 and D.
    @Test func jolietImageLists() async throws {
        let files = ["Read me first.txt", "Mixed Case Name With Spaces.text"]
        let url = try ISO.joliet(files: files, folder: "A Folder", inner: ["inner file.txt"])
        #expect(Self.libarchiveError(url) == nil)
        let reader = try await XarNameCharDataTests.reader(url)
        #expect(Set(reader.entries.map(\.path)) == Set(files + ["A Folder", "A Folder/inner file.txt"]))
    }

    // MARK: - Directory extents claiming more than the file

    static let claim: UInt32 = 0xFFFF_F800  // 4 GiB less one block
    static let claimedVolume = 2_100_000  // blocks: room for the claim

    /// Zero blocks after the directories: 296 KiB in all, so libarchive's first 64 KiB read does not reach EOF (at EOF
    /// a read-ahead past it fails before it allocates).
    static let tail = 128

    /// The root claims a 4 GiB extent in a 296 KiB image: the volume descriptor's root record (read by choose_volume)
    /// and its "." record (read_children) both.
    static func rootClaim() throws -> URL {
        try ISO.image(rootSize: claim, volumeBlocks: claimedVolume, tail: tail, children: { _ in
            (0..<3).map { ISO.file($0, susp: ISO.nm("f\($0)")) }
        })
    }

    /// A subdirectory claims a 4 GiB extent: only read_children reads it, once the root has been listed.
    static func subdirectoryClaim() throws -> URL {
        try ISO.image(volumeBlocks: claimedVolume, tail: tail, children: { start in
            [ISO.record(Array("D".utf8), location: start, size: claim, directory: true, susp: ISO.nm("d"))]
        }, extra: { start in
            [[ISO.record([0], location: start, size: claim, directory: true, susp: ISO.nm(".")),
              ISO.record([1], location: ISO.rootLocation, directory: true, susp: ISO.nm(".."))].flatMap { $0 }]
        })
    }

    @Test(arguments: ["root", "subdirectory"])
    func directoryClaimIsReadBlockByBlock(which: String) async throws {
        let url = try which == "root" ? Self.rootClaim() : Self.subdirectoryClaim()
        // Any block counts (a multiple of 1), so an ordinary test's burst beside the watch can fail an attempt.
        let watched = try await AllocationWatch.largestMultiple(of: 1, under: 16 << 20) { await Self.open(url) }
        #expect(watched.largest < 16 << 20, "largest block \(watched.largest)")
        // The extent ends at the end of the file: a damaged image, not a listing.
        #expect(watched.result != .opened)
    }

    // MARK: - Entry count

    static func files(_ count: Int) throws -> URL {
        try ISO.image(children: { _ in (0..<count).map { ISO.file($0, susp: ISO.nm("f\($0)")) } })
    }

    /// Every record counts, the root included, before it is allocated: the root and 4 files pass a limit of 5, the root
    /// and 5 do not, and libarchive refuses before the first header.
    @Test func entryCapIsExact() async throws {
        let limits = EntryCountLimitTests.limits(entries: 5)
        #expect(Self.libarchiveError(try Self.files(4), limits) == nil)
        #expect(await Self.open(try Self.files(4), limits) == .opened)
        #expect(Self.libarchiveError(try Self.files(5), limits) == .corrupted(Self.entriesMessage))
        #expect(await Self.open(try Self.files(5), limits) == .limit(.entryCount))
        // A directory over several blocks counts the same way.
        let many = try Self.files(300)
        #expect(Self.libarchiveError(many, EntryCountLimitTests.limits(entries: 301)) == nil)
        #expect(Self.libarchiveError(many, EntryCountLimitTests.limits(entries: 300)) == .corrupted(Self.entriesMessage))
    }

    /// The error libarchive gives for any header of `url` read with `limits`, nil once it has read them all.
    static func libarchiveErrorReadingAll(_ url: URL, _ limits: NestingLimits = .standard) -> ArchiveError? {
        do {
            let session = try ReadSession(urls: [url], password: nil, limits: limits)
            while try session.nextHeader() != nil {}
            return nil
        } catch {
            return error
        }
    }

    /// The root holds one directory, D, which holds `count` files: the refusal comes in D's extent, read after the
    /// root's.
    static func subdirectoryFiles(_ count: Int) throws -> URL {
        try ISO.image(children: { start in
            [ISO.record(Array("D".utf8), location: start, size: UInt32(ISO.block), directory: true, susp: ISO.nm("d"))]
        }, extra: { start in
            [([ISO.record([0], location: start, size: UInt32(ISO.block), directory: true, susp: ISO.nm(".")),
               ISO.record([1], location: ISO.rootLocation, directory: true, susp: ISO.nm(".."))]
              + (0..<count).map { ISO.file($0, susp: ISO.nm("g\($0)")) }).flatMap { $0 }]
        })
    }

    /// The root, D and 4 files pass a limit of 6; with a limit of 5 the root and D pass and D's last file does not.
    @Test func entryCapIsExactInASubdirectory() async throws {
        let url = try Self.subdirectoryFiles(4)
        #expect(Self.libarchiveErrorReadingAll(url, EntryCountLimitTests.limits(entries: 6)) == nil)
        #expect(await Self.open(url, EntryCountLimitTests.limits(entries: 6)) == .opened)
        #expect(Self.libarchiveErrorReadingAll(url, EntryCountLimitTests.limits(entries: 5))
                == .corrupted(Self.entriesMessage))
        #expect(await Self.open(url, EntryCountLimitTests.limits(entries: 5)) == .limit(.entryCount))
        let reader = try await XarNameCharDataTests.reader(url)
        #expect(Set(reader.entries.map(\.path)) == ["d", "d/g0", "d/g1", "d/g2", "d/g3"])
    }

    // MARK: - Names

    /// One record whose name goes on through a CE chain: "x" and `payload` bytes.
    static func longName(_ payload: Int) throws -> URL {
        try ISO.image(children: { start in
            [ISO.file(0, susp: ISO.nm("x", continues: true)
                      + ISO.ce(block: start, size: Self.chain(start: start, payload: payload).size))]
        }, extra: { start in Self.chain(start: start, payload: payload).blocks })
    }

    /// One symlink whose target goes on through a CE chain of SL entries: "x" and `payload` bytes.
    static func longLink(_ payload: Int) throws -> URL {
        let sl: ([UInt8], Bool) -> [UInt8] = { ISO.sl($0, continues: $1) }
        return try ISO.image(children: { start in
            [ISO.file(0, susp: ISO.px(mode: 0o120777) + ISO.nm("l") + ISO.sl(Array("x".utf8), continues: true)
                      + ISO.ce(block: start, size: Self.chain(start: start, payload: payload, piece: 248, entry: sl).size))]
        }, extra: { start in Self.chain(start: start, payload: payload, piece: 248, entry: sl).blocks })
    }

    @Test func nameAndLinkLimitsAreExact() async throws {
        #expect(Self.libarchiveError(try Self.longName(65_535)) == nil)
        #expect(Self.libarchiveError(try Self.longName(65_536)) == .corrupted(Self.nameMessage))
        #expect(await Self.open(try Self.longName(65_536)) == .limit(.pathLength))
        #expect(Self.libarchiveError(try Self.longLink(65_535)) == nil)
        #expect(Self.libarchiveError(try Self.longLink(65_536)) == .corrupted(Self.linkMessage))
        #expect(await Self.open(try Self.longLink(65_536)) == .limit(.pathLength))
    }

    /// `records` records whose CE entries all point at one chain of `payload` bytes of name: each record's name is
    /// "fN-" and the whole chain.
    static func sharedChain(records: Int, payload: Int) throws -> URL {
        try ISO.image(children: { start in
            let size = Self.chain(start: start, payload: payload).size
            return (0..<records).map {
                ISO.file($0, susp: ISO.nm("f\($0)-", continues: true) + ISO.ce(block: start, size: size))
            }
        }, extra: { start in Self.chain(start: start, payload: payload).blocks })
    }

    /// The bytes of every continuation area each record's pass parses, held to the names allowance plus the bytes
    /// read so far (where a valid image's distinct areas lie): 8 records share a 4-block chain of padding (no name),
    /// so the area charge binds, exactly. It peaks at the last pass over the last block: 8 × 4 blocks of passes less
    /// that block's offset.
    @Test func sharedChainIsChargedPerRecord() async throws {
        let blocks = 4
        var start = 0
        let url = try ISO.image(children: { s in
            start = s
            return (0..<8).map { ISO.file($0, susp: ISO.nm("f\($0)") + ISO.ce(block: s, size: ISO.block)) }
        }, extra: { s in Self.paddingChain(start: s, blocks: blocks) })
        let passes = 8 * blocks * ISO.block
        let total = passes - (start + blocks - 1) * ISO.block
        #expect(Self.libarchiveError(url, EntryCountLimitTests.limits(total: total)) == nil)
        #expect(Self.libarchiveError(url, EntryCountLimitTests.limits(total: total - 1))
                == .corrupted(Self.totalMessage))
        #expect(await Self.open(url, EntryCountLimitTests.limits(total: total - 1)) == .limit(.totalPathBytes))
        #expect(await Self.open(url, EntryCountLimitTests.limits(total: passes)) == .opened)
        // The allowance grows by nameBytesPerEntry for every record so far (the root and 8): 9 × per ≥ total passes.
        let per = (total + 8) / 9
        #expect(Self.libarchiveError(url, EntryCountLimitTests.limits(total: 1, perEntry: per)) == nil)
        #expect(Self.libarchiveError(url, EntryCountLimitTests.limits(total: 1, perEntry: per - 1))
                == .corrupted(Self.totalMessage))
    }

    /// Valid images can carry large continuation areas that are not names (xorriso's AAIP "AL" entries for ACLs and
    /// xattrs, kilobytes per file): 8 records each with an area of its own, a whole block of padding, 16 KiB in all,
    /// list under a 1,024-byte names limit, since every distinct area lies within the bytes read before it.
    @Test func distinctAreasOverTheAllowanceList() async throws {
        let url = try ISO.image(children: { s in
            (0..<8).map { ISO.file($0, susp: ISO.nm("f\($0)") + ISO.ce(block: s + $0, size: ISO.block)) }
        }, extra: { s in (0..<8).map { Self.paddingChain(start: s + $0, blocks: 1)[0] } })
        let limits = EntryCountLimitTests.limits(total: 1_024)
        #expect(8 * ISO.block > limits.maxTotalNameBytes)
        #expect(Self.libarchiveError(url, limits) == nil)
        #expect(await Self.open(url, limits) == .opened)
    }

    /// The bytes read so far are the most the reader has reached, not where it is: a file whose body lies before the
    /// directory listing it is read by seeking back (seekable sources only), which drops the reader's position. The
    /// root lists D1, laid out after the blocks it points back at: F's body, then D2 and the area of D2's file G, then
    /// D1's own extent, then the `areas` areas of D1's files, a whole block of padding each. D2 lists `shared` files
    /// (G first) that all share one chain of `chainBlocks` blocks of padding.
    static func areasBeforeABackwardSeek(areas: Int, shared: Int = 1, chainBlocks: Int = 1) throws -> URL {
        func d1(_ s: Int, extent: Int) -> [[UInt8]] {
            let d1 = s + 2 + chainBlocks
            return ISO.pack([
                ISO.record([0], location: d1, size: UInt32(extent * ISO.block), directory: true, susp: ISO.nm(".")),
                ISO.record([1], location: ISO.rootLocation, directory: true, susp: ISO.nm("..")),
                ISO.record(Array("F;1".utf8), location: s, size: 10, susp: ISO.nm("f")),
                ISO.record(Array("D2".utf8), location: s + 1, size: UInt32(ISO.block), directory: true,
                           susp: ISO.nm("d2")),
            ] + (0..<areas).map {
                ISO.file($0, susp: ISO.nm("f\($0)") + ISO.ce(block: d1 + extent + $0, size: ISO.block))
            })
        }
        let extent = d1(0, extent: 1).count
        return try ISO.image(children: { s in
            [ISO.record(Array("D1".utf8), location: s + 2 + chainBlocks, size: UInt32(extent * ISO.block),
                        directory: true, susp: ISO.nm("d1"))]
        }, extra: { s in
            let body: [UInt8] = Array("0123456789".utf8)
            let d2 = [ISO.record([0], location: s + 1, size: UInt32(ISO.block), directory: true, susp: ISO.nm(".")),
                      ISO.record([1], location: s + 2 + chainBlocks, size: UInt32(extent * ISO.block), directory: true,
                                 susp: ISO.nm(".."))]
                + (0..<shared).map {
                    ISO.file(areas + $0, susp: ISO.nm($0 == 0 ? "g" : "g\($0)")
                             + ISO.ce(block: s + 2, size: ISO.block))
                }
            return [body, d2.flatMap { $0 }] + Self.paddingChain(start: s + 2, blocks: chainBlocks)
                + d1(s, extent: extent)
                + (0..<areas).map { Self.paddingChain(start: s + 2 + chainBlocks + extent + $0, blocks: 1)[0] }
        })
    }

    /// After F the reader is back at F's body, and D2's area comes with (areas + 1) blocks charged, past a 1,024-byte
    /// allowance plus D2's end, though every distinct area lies within the bytes read before it (the most the reader
    /// has reached): the image lists, F and G included.
    @Test func distinctAreasAfterABackwardSeekList() async throws {
        let areas = 24
        let url = try Self.areasBeforeABackwardSeek(areas: areas)
        let limits = EntryCountLimitTests.limits(total: 1_024)
        let d2End = (ISO.rootLocation + 3) * ISO.block
        #expect((areas + 1) * ISO.block > limits.maxTotalNameBytes + d2End)
        #expect(Self.libarchiveErrorReadingAll(url, limits) == nil)
        #expect(await Self.open(url, limits) == .opened)
        let session = try ReadSession(urls: [url], password: nil, limits: limits)
        var names: [String] = []
        while let header = try session.nextHeader() { names.append(String(cString: archive_entry_pathname(header))) }
        #expect(names.contains("d1/f") && names.contains("d1/d2/g"), "\(names)")
    }

    /// The bound is the furthest position reached, not unlimited: after the backward seek, D2's 16 files share a
    /// 4-block chain, 128 KiB of passes, more than a 1,024-byte allowance plus everything the reader has passed (the
    /// image up to D1's end), and the pass that crosses it is refused with the names-limit error. With the charge
    /// removed (or its bound made unbounded) the image lists and this fails; with a limit that holds the passes it
    /// lists too.
    @Test func sharedChainAfterABackwardSeekStaysBounded() async throws {
        let shared = 16, chainBlocks = 4
        let url = try Self.areasBeforeABackwardSeek(areas: 0, shared: shared, chainBlocks: chainBlocks)
        let limits = EntryCountLimitTests.limits(total: 1_024)
        let passes = shared * chainBlocks * ISO.block
        let reached = (ISO.rootLocation + 1 + 2 + chainBlocks + 1) * ISO.block  // through D1's extent
        #expect(passes > limits.maxTotalNameBytes + reached)
        #expect(Self.libarchiveErrorReadingAll(url, limits) == .corrupted(Self.totalMessage))
        #expect(await Self.open(url, limits) == .limit(.totalPathBytes))
        #expect(Self.libarchiveErrorReadingAll(url, EntryCountLimitTests.limits(total: passes)) == nil)
    }

    /// The names a shared chain adds are charged to every record that shares it, exactly: 8 records with 180-byte
    /// names of their own share a 25-byte area that adds 20 bytes to each, 1,600 bytes of names from 200 of areas.
    @Test func sharedChainNamesAreChargedPerRecord() throws {
        let url = try ISO.image(children: { start in
            (0..<8).map { ISO.file($0, susp: ISO.nm(String(repeating: "\($0)", count: 180), continues: true)
                                     + ISO.ce(block: start, size: 25)) }
        }, extra: { _ in [ISO.nm(String(repeating: "a", count: 20))] })
        #expect(Self.libarchiveError(url, EntryCountLimitTests.limits(total: 1_600)) == nil)
        #expect(Self.libarchiveError(url, EntryCountLimitTests.limits(total: 1_599)) == .corrupted(Self.totalMessage))
    }

    /// The attack at the standard limits: 9,000 records share a 37-block chain (64,750 bytes, under the per-name
    /// limit), 583 MB of names from an 800 KB image, all built before the first header. libarchive now stops at the
    /// 256 MiB names limit (charged by length: the strings' spare capacity, up to a quarter, comes on top).
    @Test func sharedChainStopsAtTheNamesLimit() async throws {
        let url = try Self.sharedChain(records: 9_000, payload: 37 * 1_750)
        let (outcome, growth) = await SevenZipNameLimitTests.refusal(url, under: 400 << 20)
        #expect(outcome == .limit(.totalPathBytes))
        #expect(growth < 400 << 20, "growth \(growth)")
        // libarchive holds about 290 MB of names on this read too.
        await MemoryQuiet.heavy {
            #expect(Self.libarchiveError(url) == .corrupted(Self.totalMessage))
        }
    }

    /// A chain of `blocks` continuation areas from the first block after the root's extent, each 2,048 bytes of PD
    /// padding (no name) ending, but for the last, in a CE to the next.
    static func paddingChain(start: Int, blocks: Int) -> [[UInt8]] {
        func padding(_ bytes: Int) -> [UInt8] {
            var out: [UInt8] = []
            var left = bytes
            while left > 0 {
                let n = left >= 24 || left == 20 ? 20 : left  // the last entry takes the rest, 4 to 23 bytes
                out += ISO.pd(n)
                left -= n
            }
            return out
        }
        let ce = ISO.ce(block: 0, size: 0).count
        return (0..<blocks).map { i in
            i == blocks - 1 ? padding(ISO.block)
                : padding(ISO.block - ce) + ISO.ce(block: start + i + 1, size: ISO.block)
        }
    }

    /// The CPU attack: 9,000 records share a 200-block chain that grows no name, so nothing was charged, and upstream
    /// parsed 9,000 × 200 areas, 3.7 GB of SUSP from a 1 MB image, before the first header. Each pass over an area now
    /// costs its size against the names allowance: at the standard limits the reader stops after 256 MiB of areas,
    /// well under the time the whole chain takes with the limit out of the way.
    @Test func sharedChainWithoutNamesIsCharged() async throws {
        let records = 9_000, blocks = 200
        let url = try ISO.image(children: { start in
            (0..<records).map { ISO.file($0, susp: ISO.nm("f\($0)") + ISO.ce(block: start, size: ISO.block)) }
        }, extra: { start in Self.paddingChain(start: start, blocks: blocks) })
        let (unbounded, unboundedTime) = Self.cpuTime {
            Self.libarchiveError(url, EntryCountLimitTests.limits(total: 1 << 40))
        }
        let (refused, time) = Self.cpuTime { Self.libarchiveError(url) }
        #expect(unbounded == nil)
        #expect(refused == .corrupted(Self.totalMessage))
        #expect(time * 4 < unboundedTime, "refused after \(time) s, the whole chain \(unboundedTime) s")
        #expect(await Self.open(url) == .limit(.totalPathBytes))
    }

    /// A thread's CPU time for `body`.
    static func cpuTime<T>(_ body: () -> T) -> (T, Double) {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let result = body()
        return (result, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9)
    }

    // MARK: - Mapping

    @Test("Patch 0021's messages are the ones the reader maps")
    func refusalMessagesAreMapped() {
        let expected: [String: ArchiveNestingError.Limit] = [
            Self.entriesMessage: .entryCount, Self.nameMessage: .pathLength, Self.linkMessage: .pathLength,
            Self.totalMessage: .totalPathBytes,
        ]
        for (message, limit) in expected {
            #expect(PatchedNameRefusal.refusal(for: .corrupted(message)) == ArchiveNestingError(limit: limit), "\(message)")
            #expect(PatchedNameRefusal.refusal(for: .corrupted(message + ".")) == nil)
        }
    }
}
