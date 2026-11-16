import CLibArchive
import Foundation
import Testing
@testable import KernirCore

/// A 7z header keeps every entry name in one UTF-16 block, and libarchive copied the whole block before it returned
/// the first header, so no Swift-side limit could stop it: a 57 KB 7z (LZMA header) cost 597 MB, a 59 KB one with a
/// single 200 Mi-unit name 3 GB and 26 s. Kernir patch 0014 refuses a name over 65,536 UTF-16 units while it copies,
/// and a names block over 2 × 256 MiB plus 2 bytes per entry before it copies. The reader turns both refusals into
/// the `ArchiveNestingError` the Swift-side limits throw (`PatchedNameRefusal`), also behind an encrypted header.
/// The malloc measurements run in `MemoryQuiet.measure` and the LZMA writers (an encoder fed hundreds of MiB) and
/// the open that allocates a 512 MiB block in `MemoryQuiet.heavy`, so other suites' heavy sections stay out of a
/// measurement. Serialized as well: a full run once saw 143 MB of growth on all 3 attempts of an open that holds
/// under 1 MiB, with this suite's own writer beside it, and its tests stay one at a time.
@Suite("7z name limits", .serialized)
struct SevenZipNameLimitTests {
    static let nameMessage = "7-Zip entry name is longer than 65536 UTF-16 units"
    static let blockMessage = "7-Zip entry names take more UTF-16 than the names limit"

    /// The names block limit for `count` entries: 2 × 256 MiB plus each name's 2-byte terminator, for any count (it
    /// does not grow with the claimed count: EntryCountLimitTests).
    static func blockLimit(_ count: Int) -> Int { (512 << 20) + 2 * count }

    // MARK: - Building 7z headers

    /// A 7z number: one byte below 0x80, else 0xFF and eight little-endian bytes.
    static func number(_ v: Int) -> [UInt8] {
        v < 0x80 ? [UInt8(v)] : [0xFF] + (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
    }

    /// Header, FilesInfo with `count` entries (all EmptyStream: directories) and the kName property up to the first
    /// name byte, for a names block of `namesBytes` bytes.
    static func headerPrefix(count: Int, namesBytes: Int) -> [UInt8] {
        let bits = [UInt8](repeating: 0xFF, count: (count + 7) / 8)
        return [0x01, 0x05] + number(count) + [0x0E] + number(bits.count) + bits
            + [0x11] + number(1 + namesBytes) + [0x00]
    }

    /// The kEnd of FilesInfo and of Header.
    static let headerSuffix: [UInt8] = [0x00, 0x00]

    /// Feeds the header to `sink` in pieces of at most 1 MiB: prefix, each name ("x" × units, then the terminator),
    /// suffix. Nothing holds the whole names block.
    static func streamHeader(_ lengths: [Int], _ sink: ([UInt8]) -> Void) {
        sink(headerPrefix(count: lengths.count, namesBytes: lengths.reduce(0) { $0 + 2 * $1 + 2 }))
        let chunk: [UInt8] = (0..<(1 << 20)).map { $0.isMultiple(of: 2) ? 0x78 : 0 }
        for units in lengths {
            var left = 2 * units
            while left > 0 {
                let n = min(left, chunk.count)
                sink(Array(chunk[0..<n]))
                left -= n
            }
            sink([0, 0])
        }
        sink(headerSuffix)
    }

    /// The 32-byte signature header for a next header at `offset` (after the signature header) of `size` bytes.
    static func signatureHeader(offset: Int, size: Int, crc: UInt32) -> [UInt8] {
        let start = number64(offset) + number64(size) + number64(Int(crc)).prefix(4)
        let startCRC = number64(Int(SyntheticZip.crc32(start))).prefix(4)
        return [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04] + startCRC + start
    }

    static func number64(_ v: Int) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

    /// A 7z of empty directories named "x" × each of `lengths` UTF-16 units. `encoded`: the header is LZMA-coded
    /// (libarchive's lzma filter, fed in 1 MiB pieces), as 7-Zip writes it, so a large names block costs a few KB.
    /// `password`: the LZMA-coded header is also 7zAES-encrypted (`encoded` is implied), as `-mhe=on` and patch
    /// 0005 write it.
    static func write(_ lengths: [Int], encoded: Bool, password: String? = nil) throws -> URL {
        let encoded = encoded || password != nil
        let dir = Fixtures.tempDir()
        let url = dir.appendingPathComponent("names.7z")
        guard encoded else {
            var header: [UInt8] = []
            streamHeader(lengths) { header += $0 }
            let file = signatureHeader(offset: 0, size: header.count, crc: SyntheticZip.crc32(header)) + header
            try Data(file).write(to: url)
            return url
        }
        // LZMA_Alone: properties (1), dictionary size (4), uncompressed size (8), then the raw LZMA stream that a 7z
        // LZMA coder holds, with those 5 property bytes as its coder properties.
        let alone = dir.appendingPathComponent("header.lzma")
        var unpackSize = 0
        withUTF8CType {
            let a = archive_write_new()
            defer { archive_write_free(a) }
            #expect(archive_write_set_format_raw(a) == ARCHIVE_OK)
            #expect(archive_write_add_filter_lzma(a) == ARCHIVE_OK)
            #expect(archive_write_set_bytes_in_last_block(a, 1) == ARCHIVE_OK)
            #expect(archive_write_open_filename(a, alone.path) == ARCHIVE_OK)
            let e = archive_entry_new()
            defer { archive_entry_free(e) }
            archive_entry_copy_pathname(e, "header")
            archive_entry_set_filetype(e, UInt32(S_IFREG))
            #expect(archive_write_header(a, e) == ARCHIVE_OK)
            streamHeader(lengths) { piece in
                unpackSize += piece.count
                piece.withUnsafeBytes { _ = archive_write_data(a, $0.baseAddress, $0.count) }
            }
            #expect(archive_write_close(a) == ARCHIVE_OK)
        }
        let lzma = [UInt8](try Data(contentsOf: alone))
        let props = Array(lzma[0..<5])
        var packed = Array(lzma[13...])
        let lzmaCoder: [UInt8] = [0x23, 0x03, 0x01, 0x01, 0x05] + props
        // EncodedHeader: PackInfo (one stream at 0) and one folder of one LZMA coder; no CRC, so none is checked.
        var folder: [UInt8] = [0x01] + lzmaCoder + [0x0C] + number(unpackSize)
        if let password {
            // [7zAES, LZMA] as 7-Zip and patch 0005 write it: the packed stream feeds 7zAES, whose output (the
            // unpadded LZMA stream) is bound to LZMA's input (InIndex 1 <- OutIndex 0). A cheap key cost (2^6).
            var p = kernir_7zaes_params()
            p.cycles_power = 6
            withUnsafeMutableBytes(of: &p.iv) { for i in 0..<16 { $0[i] = UInt8(0x40 + i) } }
            var key = [UInt8](repeating: 0, count: Int(KERNIR_7ZAES_KEY_SIZE))
            let derived = kernir_7zaes_derive_key(&p, password, &key)
            #expect(derived == 0)
            let lzmaSize = packed.count
            packed += [UInt8](repeating: 0, count: (16 - lzmaSize % 16) % 16)
            var cbc = kernir_7zaes_cbc()
            let iv = withUnsafeBytes(of: &p.iv) { Array($0) }
            let initialized = kernir_7zaes_cbc_init(&cbc, 1, key, iv)
            #expect(initialized == 0)
            var encrypted = [UInt8](repeating: 0, count: packed.count)
            let updated = kernir_7zaes_cbc_update(&cbc, packed, packed.count, &encrypted)
            #expect(updated == 0)
            kernir_7zaes_cbc_release(&cbc)
            packed = encrypted
            var aesProps = [UInt8](repeating: 0, count: 34)
            let propsSize = kernir_7zaes_encode_props(&p, &aesProps)
            aesProps = Array(aesProps.prefix(propsSize))
            folder = [0x02, 0x24, 0x06, 0xF1, 0x07, 0x01] + number(aesProps.count) + aesProps + lzmaCoder
                + number(1) + number(0) + [0x0C] + number(lzmaSize) + number(unpackSize)
        }
        let next: [UInt8] = [0x17, 0x06] + number(0) + number(1) + [0x09] + number(packed.count) + [0x00]
            + [0x07, 0x0B] + number(1) + [0x00] + folder + [0x00, 0x00]
        let file = signatureHeader(offset: packed.count, size: next.count, crc: SyntheticZip.crc32(next))
            + packed + next
        try Data(file).write(to: url)
        return url
    }

    /// A plain header that declares a names block of `namesBytes` bytes for `count` entries (and a next header long
    /// enough to hold it) but ends right after the kName property's first byte: libarchive reaches the names block
    /// limit, then runs out of header.
    static func truncated(count: Int, namesBytes: Int) throws -> URL {
        let prefix = headerPrefix(count: count, namesBytes: namesBytes)
        let declared = prefix.count + namesBytes + headerSuffix.count
        let url = Fixtures.tempDir().appendingPathComponent("truncated.7z")
        try Data(signatureHeader(offset: 0, size: declared, crc: 0) + prefix).write(to: url)
        return url
    }

    // MARK: - Measuring

    /// What `Archive.open` (or `previewListing`) did with an archive.
    enum Outcome: Equatable {
        case opened
        case limit(ArchiveNestingError.Limit)
        case corrupted(String)
        case other(String)
    }

    static func outcome(_ body: () async throws -> Void) async -> Outcome {
        do {
            try await body()
            return .opened
        } catch let e as ArchiveNestingError {
            return .limit(e.limit)
        } catch ArchiveError.corrupted(let m) {
            return .corrupted(m)
        } catch {
            return .other("\(error)")
        }
    }

    static func open(_ url: URL, password: String? = nil) async -> Outcome {
        await outcome { _ = try await Archive.open(at: url, password: password) }
    }

    /// The `Outcome` of `Archive.open` for `url` and the most malloc held beyond its starting point while it ran.
    /// malloc is process-wide, so it measures inside `MemoryQuiet.measure`, and opens up to 3 times and keeps the
    /// smallest growth: an open that copies the names holds them on every attempt.
    static func refusal(_ url: URL, password: String? = nil, under limit: Int64) async
        -> (outcome: Outcome, growth: Int64) {
        await MemoryQuiet.measure {
            var result = Outcome.opened
            var growths: [Int64] = []
            for _ in 0..<3 where growths.last.map({ $0 >= limit }) ?? true {
                let baseline = MemoryQuiet.mallocInUse()
                let sampler = MemoryQuiet.PeakSampler()
                result = await open(url, password: password)
                growths.append(max(sampler.stop(), MemoryQuiet.mallocInUse()) - baseline)
            }
            return (result, growths.min() ?? .max)
        }
    }

    /// The error libarchive itself gives for the first header of `url`, before the reader maps it.
    static func libarchiveError(_ url: URL) -> ArchiveError? {
        do {
            let session = try ReadSession(urls: [url], password: nil)
            _ = try session.nextHeader()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Tests

    @Test("Patch 0014's messages are the ones the reader maps, and nothing else is")
    func refusalMessagesAreMapped() throws {
        // Read from libarchive, so a reworded patch fails here rather than reaching callers as `.corrupted`.
        let name = try Self.write([65_537], encoded: false)
        #expect(Self.libarchiveError(name) == .corrupted(Self.nameMessage))
        let block = try Self.truncated(count: 1, namesBytes: Self.blockLimit(1) + 2)
        #expect(Self.libarchiveError(block) == .corrupted(Self.blockMessage))
        #expect(PatchedNameRefusal.refusal(for: .corrupted(Self.nameMessage)) == ArchiveNestingError(limit: .pathLength))
        #expect(PatchedNameRefusal.refusal(for: .corrupted(Self.blockMessage))
                == ArchiveNestingError(limit: .totalPathBytes))
        // Exact messages only: damage, other wording and other errors stay as they are.
        for other: ArchiveError in [.corrupted("Damaged 7-Zip archive"), .corrupted(Self.nameMessage + "."),
                                    .corrupted(Self.nameMessage.lowercased()), .io(Self.nameMessage), .wrongPassword] {
            #expect(PatchedNameRefusal.refusal(for: other) == nil, "\(other)")
        }
    }

    @Test("A name of 65,537 UTF-16 units is refused in libarchive; 65,536 reaches the Swift path limit")
    func nameLimitIsExact() async throws {
        let at = try Self.write([65_536], encoded: false)
        #expect(await Self.open(at) == .limit(.pathLength))
        let over = try Self.write([65_537], encoded: false)
        #expect(await Self.open(over) == .limit(.pathLength))
        // A later name too, after a short one.
        let later = try Self.write([5, 65_537], encoded: false)
        #expect(await Self.open(later) == .limit(.pathLength))
        #expect(await Self.outcome { _ = try await Archive.previewListing(at: later, limit: 10) } == .limit(.pathLength))
    }

    @Test("The names block limit is 512 MiB plus 2 bytes per entry, checked before the block is read")
    func blockLimitIsExact() async throws {
        for count in [1, 3] {
            // At the limit the block is read, and the truncated header runs out.
            // libarchive allocates the 512 MiB block before it reads it.
            let at = try Self.truncated(count: count, namesBytes: Self.blockLimit(count))
            #expect(await MemoryQuiet.heavy { await Self.open(at) } == .corrupted("Damaged 7-Zip archive"))
            let over = try Self.truncated(count: count, namesBytes: Self.blockLimit(count) + 2)
            #expect(await Self.open(over) == .limit(.totalPathBytes))
            #expect(await Self.outcome { _ = try await Archive.previewListing(at: over, limit: 10) }
                    == .limit(.totalPathBytes))
        }
    }

    @Test("A 64 Mi-unit name in an LZMA header is refused without copying it")
    func longNameIsRefusedEarly() async throws {
        let url = try await MemoryQuiet.heavy { try Self.write([64 << 20], encoded: true) }
        let size = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 64 << 10)
        let (outcome, growth) = await Self.refusal(url, under: 48 << 20)
        #expect(outcome == .limit(.pathLength))
        #expect(growth < 48 << 20, "malloc growth \(growth >> 20) MiB")
    }

    @Test("A names block just over the limit in an LZMA header is refused without reading it")
    func namesBlockIsRefusedEarly() async throws {
        // 4,097 names of 65,535 units: every name is within the name limit, the block is 128 KiB over 512 MiB.
        let url = try await MemoryQuiet.heavy { try Self.write(Array(repeating: 65_535, count: 4_097), encoded: true) }
        let size = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 128 << 10)
        let (outcome, growth) = await Self.refusal(url, under: 48 << 20)
        #expect(outcome == .limit(.totalPathBytes))
        #expect(growth < 48 << 20, "malloc growth \(growth >> 20) MiB")
    }

    @Test("Ordinary names still open, from plain, LZMA and encrypted headers")
    func ordinaryNamesOpen() async throws {
        for (encoded, password) in [(false, nil), (true, nil), (true, "pw")] as [(Bool, String?)] {
            let url = try Self.write([1, 100, 255, 1_000, 4_000], encoded: encoded, password: password)
            let reader = try await Archive.open(at: url, password: password)
            #expect(reader.entries.map { $0.path.utf8.count }.sorted() == [1, 100, 255, 1_000, 4_000])
            #expect(reader.entries.allSatisfy { $0.isDirectory })
        }
    }

    /// Behind an encrypted header (-mhe=on) the names are reached only once the password decrypts the header.
    /// With it, the refusal is the limit, not `.wrongPassword` (the reader's answer to any failed encrypted header
    /// decode) and still without copying the names; without it the header is never decoded, so the answer is
    /// `.passwordRequired`; a wrong password garbles the header (`.wrongPassword`).
    @Test("An encrypted header refuses a 64 Mi-unit name as the limit, without copying it")
    func encryptedHeaderNameIsRefusedEarly() async throws {
        let url = try await MemoryQuiet.heavy { try Self.write([64 << 20], encoded: true, password: "pw") }
        let size = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 64 << 10)
        let (outcome, growth) = await Self.refusal(url, password: "pw", under: 48 << 20)
        #expect(outcome == .limit(.pathLength))
        #expect(growth < 48 << 20, "malloc growth \(growth >> 20) MiB")
        #expect(await Self.outcome { _ = try await Archive.previewListing(at: url, password: "pw", limit: 10) }
                == .limit(.pathLength))
        #expect(await Self.open(url) == .other("\(ArchiveError.passwordRequired)"))
        #expect(await Self.open(url, password: "wrong") == .other("\(ArchiveError.wrongPassword)"))
    }

    @Test("An encrypted header refuses a names block over the limit as the limit, without reading it")
    func encryptedHeaderNamesBlockIsRefusedEarly() async throws {
        let url = try await MemoryQuiet.heavy {
            try Self.write(Array(repeating: 65_535, count: 4_097), encoded: true, password: "pw")
        }
        let (outcome, growth) = await Self.refusal(url, password: "pw", under: 48 << 20)
        #expect(outcome == .limit(.totalPathBytes))
        #expect(growth < 48 << 20, "malloc growth \(growth >> 20) MiB")
        #expect(await Self.open(url) == .other("\(ArchiveError.passwordRequired)"))
    }

    @Test("An encrypted header with a 65,536-unit name reaches the Swift path limit")
    func encryptedHeaderAtTheNameLimit() async throws {
        let url = try Self.write([65_536], encoded: true, password: "pw")
        #expect(await Self.open(url, password: "pw") == .limit(.pathLength))
    }
}
