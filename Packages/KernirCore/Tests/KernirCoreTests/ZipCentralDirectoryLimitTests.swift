import CLibArchive
import Darwin
import Foundation
import Testing
@testable import KernirCore

/// libarchive's seekable zip reader reads the whole central directory (slurp_central_directory) before it returns the
/// first header: it callocs an entry for every record (about 190 bytes for a 46-byte record), records whose local
/// header offset repeats included, which are never listed, and parses every record's extra fields. Kernir patch 0022
/// holds the records to the limits `ReadSession` hands to libarchive (patch 0016), as the 7z and xar readers are: the
/// listed records (distinct local header offsets, the headers Swift counts) to `maxEntries`, every record to twice
/// that, and the record names to the names total; an Info-ZIP Unicode Path field no longer re-hashes the name an
/// earlier record left; and a zip64 end record whose central directory starts past it loses the seekable bid.
@Suite("Zip central directory limits", .serialized, .timeLimit(.minutes(3)))
struct ZipCentralDirectoryLimitTests {
    static let entriesMessage = "ZIP archive has more entries than the entry limit"
    static let namesMessage = "ZIP entry names take more than the names limit"
    static let commentsMessage = "ZIP entry comments take the entry names past the names limit"

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func le32(_ v: UInt32) -> [UInt8] { le16(Int(v & 0xFFFF)) + le16(Int(v >> 16)) }
    static func le64(_ v: UInt64) -> [UInt8] { le32(UInt32(v & 0xFFFF_FFFF)) + le32(UInt32(v >> 32)) }

    /// The central-directory record (46 bytes plus the name and extra fields) of an empty stored file whose local
    /// header is at `offset`.
    static func record(_ name: [UInt8], offset: UInt32, extra: [UInt8] = [], comment: [UInt8] = []) -> [UInt8] {
        le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(0) + le32(0) + le32(0) + le32(0) + le32(0)
            + le16(name.count) + le16(extra.count) + le16(comment.count) + le16(0) + le16(0) + le32(0) + le32(offset)
            + name + extra + comment
    }

    static func local(_ name: [UInt8]) -> [UInt8] {
        le32(0x0403_4B50) + le16(20) + le16(0) + le16(0) + le32(0) + le32(0) + le32(0) + le32(0)
            + le16(name.count) + le16(0) + name
    }

    /// The bytes of a zip of empty stored files named `names` (a local header and a record each), whose central
    /// directory then holds the records `more`: the local headers and the central directory. Record i carries
    /// `comments[i]` as its comment (none past the end).
    static func bytes(_ names: [String], more: [UInt8] = [], comments: [[UInt8]] = [])
        -> (head: [UInt8], central: [UInt8]) {
        var head: [UInt8] = [], central: [UInt8] = []
        for (i, n) in names.enumerated() {
            let b = Array(n.utf8)
            central += record(b, offset: UInt32(head.count), comment: i < comments.count ? comments[i] : [])
            head += local(b)
        }
        central += more
        return (head, central)
    }

    /// Writes `bytes(names, more:)` with a 32-bit end record that counts `moreCount` records more.
    static func zip(_ names: [String], more: [UInt8] = [], moreCount: Int = 0, comments: [[UInt8]] = [])
        throws -> URL {
        let (head, central) = bytes(names, more: more, comments: comments)
        let count = min(names.count + moreCount, 0xFFFF)
        let end = le32(0x0605_4B50) + le16(0) + le16(0) + le16(count) + le16(count) + le32(UInt32(central.count))
            + le32(UInt32(head.count)) + le16(0)
        let url = Fixtures.tempDir().appendingPathComponent("cd.zip")
        try Data(head + central + end).write(to: url)
        return url
    }

    /// `count` records of `name` that all point at the first local header (never listed: the offset repeats).
    static func duplicates(_ count: Int, name: [UInt8] = []) -> [UInt8] {
        Array(Array(repeating: record(name, offset: 0), count: count).joined())
    }

    static func limits(entries: Int = NestingLimits.standard.maxEntries, total: Int = 256 << 20,
                       perEntry: Int = 0) -> NestingLimits {
        EntryCountLimitTests.limits(entries: entries, total: total, perEntry: perEntry)
    }

    /// The headers libarchive returns for `url` through `ReadSession` with `limits`, or its error, before the reader
    /// maps it.
    static func headers(_ url: URL, _ limits: NestingLimits = .standard) -> Result<Int, ArchiveError> {
        do {
            let session = try ReadSession(urls: [url], password: nil, limits: limits)
            var count = 0
            while try session.nextHeader() != nil { count += 1 }
            return .success(count)
        } catch {
            return .failure(error)
        }
    }

    static func open(_ url: URL, _ limits: NestingLimits) async -> EntryCountLimitTests.Outcome {
        await EntryCountLimitTests.open(url, limits)
    }

    // MARK: - Entries

    /// Record maxEntries + 1 with a new local header offset is refused while libarchive reads the central directory,
    /// before the first header; Swift maps it to the entry cap it applies itself.
    @Test func zipEntryCapIsExact() async throws {
        let limits = Self.limits(entries: 5)
        let five = (1...5).map { "f\($0)" }
        #expect(Self.headers(try Self.zip(five), limits) == .success(5))
        #expect(await Self.open(try Self.zip(five), limits) == .opened)
        #expect(EntryCountLimitTests.libarchiveError(try Self.zip(five + ["f6"]), limits)
                == .corrupted(Self.entriesMessage))
        #expect(await Self.open(try Self.zip(five + ["f6"]), limits) == .limit(.entryCount))
    }

    /// A record whose local header offset repeats is never a header, so it does not count, but libarchive allocates
    /// it: every record is held to 2 × maxEntries, whatever it is.
    @Test func repeatedOffsetsAreHeldToTheEntryCapAgain() async throws {
        let limits = Self.limits(entries: 5)
        let one = try Self.zip(["a"], more: Self.duplicates(9), moreCount: 9)
        #expect(Self.headers(one, limits) == .success(1))
        #expect(await Self.open(one, limits) == .opened)
        let over = try Self.zip(["a"], more: Self.duplicates(10), moreCount: 10)
        #expect(Self.headers(over, limits) == .failure(.corrupted(Self.entriesMessage)))
        #expect(await Self.open(over, limits) == .limit(.entryCount))
        let five = (1...5).map { "f\($0)" }
        #expect(Self.headers(try Self.zip(five, more: Self.duplicates(5), moreCount: 5), limits) == .success(5))
        #expect(Self.headers(try Self.zip(five, more: Self.duplicates(6), moreCount: 6), limits)
                == .failure(.corrupted(Self.entriesMessage)))
    }

    /// The record cap saturates: an entry limit of 2^63 + 2 would wrap 2 × it to 4.
    @Test func recordCapSaturates() throws {
        let url = try Self.zip(["a"], more: Self.duplicates(9), moreCount: 9)
        guard let a = archive_read_new() else { throw ArchiveError.io("archive_read_new") }
        defer { archive_read_free(a) }
        _ = kernir_read_set_name_limits(a, (1 << 63) + 2, 256 << 20, 512)
        archive_read_support_format_zip_seekable(a)
        #expect(archive_read_open_filename(a, url.path, 10_240) == ARCHIVE_OK)
        var entry: OpaquePointer?
        let r = archive_read_next_header(a, &entry)
        #expect(r == ARCHIVE_OK, "\(archive_error_string(a).map { String(cString: $0) } ?? "rc \(r)")")
    }

    /// 1 listed record and 500,000 that repeat its offset (23 MB) with an entry limit of 10,000: upstream callocs
    /// every record (95 MB) before the first header; the patch stops at record 20,001. Up to 3 attempts, the smallest
    /// growth kept: a parallel suite's short burst is left to the retries (MemoryQuiet).
    @Test func recordsPastTheCapAreNotAllocated() async throws {
        let url = try Self.zip(["a"], more: Self.duplicates(500_000), moreCount: 500_000)
        let limits = Self.limits(entries: 10_000)
        let expected = EntryCountLimitTests.Outcome.limit(.entryCount)
        let bound: Int64 = 16 << 20
        let (outcome, growth) = await MemoryQuiet.measure {
            var outcome = EntryCountLimitTests.Outcome.opened
            var growths: [Int64] = []
            for _ in 0..<3 where growths.isEmpty || (growths.last! >= bound && outcome == expected) {
                let baseline = MemoryQuiet.mallocInUse()
                let sampler = MemoryQuiet.PeakSampler()
                outcome = await Self.open(url, limits)
                growths.append(max(sampler.stop(), MemoryQuiet.mallocInUse()) - baseline)
            }
            return (outcome, growths.min() ?? .max)
        }
        #expect(outcome == expected)
        #expect(growth < bound, "malloc growth \(growth >> 20) MiB")
    }

    // MARK: - Names

    /// The record names are charged to the names total as they are read: max(total, perEntry × the listed records so
    /// far), as Swift charges the headers.
    @Test func recordNamesAreChargedToTheNamesTotal() async throws {
        func name(_ n: Int, _ c: Character) -> String { String(repeating: c, count: n) }
        let fixed = Self.limits(total: 100)
        #expect(Self.headers(try Self.zip([name(50, "a"), name(50, "b")]), fixed) == .success(2))
        let over = try Self.zip([name(50, "a"), name(51, "b")])
        #expect(Self.headers(over, fixed) == .failure(.corrupted(Self.namesMessage)))
        #expect(await Self.open(over, fixed) == .limit(.totalPathBytes))
        // 30 per listed record once that is more than 100.
        let grown = Self.limits(total: 100, perEntry: 30)
        let names = ["a", "b", "c", "d"].map { name(30, Character($0)) }
        #expect(Self.headers(try Self.zip(names), grown) == .success(4))
        #expect(Self.headers(try Self.zip(names + [name(31, "e")]), grown)
                == .failure(.corrupted(Self.namesMessage)))
        // A record that repeats an offset is charged too, but does not grow the allowance.
        #expect(Self.headers(try Self.zip([name(50, "a")], more: Self.duplicates(1, name: Array(name(50, "b").utf8)),
                                          moreCount: 1), fixed) == .success(1))
        #expect(Self.headers(try Self.zip([name(50, "a")], more: Self.duplicates(1, name: Array(name(51, "b").utf8)),
                                          moreCount: 1), fixed) == .failure(.corrupted(Self.namesMessage)))
        #expect(Self.headers(try Self.zip(names, more: Self.duplicates(1, name: [0x7A]), moreCount: 1), grown)
                == .failure(.corrupted(Self.namesMessage)))
    }

    // MARK: - Comments

    /// The comments libarchive keeps for `url`'s headers (patch 0012), in order, or its error.
    static func comments(_ url: URL, _ limits: NestingLimits) -> Result<[[UInt8]], ArchiveError> {
        do {
            let session = try ReadSession(urls: [url], password: nil, limits: limits)
            var comments: [[UInt8]] = []
            while try session.nextHeader() != nil { comments.append(session.zipEntryComment ?? [0xFF]) }
            return .success(comments)
        } catch {
            return .failure(error)
        }
    }

    /// Patch 0025: the record comments, which patch 0012 keeps in memory for every record before the first header
    /// (up to 65,535 bytes each, so about the central directory's size in all), are charged to the names total
    /// with the names, before they are copied: names plus comments over it are refused with their own message, mapped
    /// to the names limit.
    @Test func recordCommentsAreChargedToTheNamesTotal() async throws {
        func bytes(_ n: Int, _ c: Character) -> [UInt8] { Array(String(repeating: c, count: n).utf8) }
        let fixed = Self.limits(total: 100)
        let names = [String(repeating: "a", count: 25), String(repeating: "b", count: 25)]
        let fits = try Self.zip(names, comments: [bytes(20, "x"), bytes(30, "y")])
        #expect(Self.comments(fits, fixed) == .success([bytes(20, "x"), bytes(30, "y")]))
        #expect(await Self.open(fits, fixed) == .opened)
        let over = try Self.zip(names, comments: [bytes(20, "x"), bytes(31, "y")])
        #expect(Self.comments(over, fixed) == .failure(.corrupted(Self.commentsMessage)))
        #expect(await Self.open(over, fixed) == .limit(.totalPathBytes))
        // A record whose offset repeats keeps its comment too, so it is charged.
        let repeated = try Self.zip([names[0]], more: Self.record(bytes(25, "b"), offset: 0, comment: bytes(51, "z")),
                                    moreCount: 1)
        #expect(Self.headers(repeated, fixed) == .failure(.corrupted(Self.commentsMessage)))
        // Its counterpart, a 50-byte comment that brings the total to exactly 100, is taken.
        let repeatedFits = try Self.zip([names[0]], more: Self.record(bytes(25, "b"), offset: 0, comment: bytes(50, "z")),
                                        moreCount: 1)
        #expect(Self.headers(repeatedFits, fixed) == .success(1))
        // The allowance grows with the listed records, as for the names: 30 per record once that is more than 100.
        let grown = Self.limits(total: 100, perEntry: 30)
        let four = ["a", "b", "c", "d"]
        #expect(Self.headers(try Self.zip(four, comments: Array(repeating: bytes(29, "c"), count: 4)), grown)
                == .success(4))
        #expect(Self.headers(try Self.zip(four, comments: Array(repeating: bytes(29, "c"), count: 3) + [bytes(30, "c")]),
                             grown) == .failure(.corrupted(Self.commentsMessage)))
    }

    /// The comments share the names counter: when earlier comments use up the allowance, the next record's name is
    /// refused with the names message (the comments message is for a comment), and `open` maps both to
    /// `.totalPathBytes`.
    @Test func commentsThatFillTheTotalRefuseTheNextName() async throws {
        func bytes(_ n: Int, _ c: Character) -> [UInt8] { Array(String(repeating: c, count: n).utf8) }
        let fixed = Self.limits(total: 100)
        let first = String(repeating: "a", count: 10), second = String(repeating: "b", count: 10)
        // 10 + 80 = 90 so far: a 10-byte second name makes exactly 100 and is taken, an 11-byte one is refused.
        let fits = try Self.zip([first, second], comments: [bytes(80, "x"), []])
        #expect(Self.headers(fits, fixed) == .success(2))
        #expect(await Self.open(fits, fixed) == .opened)
        let over = try Self.zip([first, second + "b"], comments: [bytes(80, "x"), []])
        #expect(Self.headers(over, fixed) == .failure(.corrupted(Self.namesMessage)))
        #expect(await Self.open(over, fixed) == .limit(.totalPathBytes))
    }

    /// Records of the longest comment a record holds (65,535 bytes) and 3-byte names, over a names total of 16 such
    /// records and one more name: 16 fit, 17 or 40 are refused at the 17th comment, before the first header (patch
    /// 0012 alone kept all 40, 2.6 MB).
    @Test func longCommentsAreHeldToTheNamesTotal() async throws {
        let limits = Self.limits(total: 16 * (3 + 0xFFFF) + 3)
        let longest = [UInt8](repeating: 0x63, count: 0xFFFF)
        let names = (100..<140).map { "\($0)" }
        let sixteen = try Self.zip(Array(names.prefix(16)), comments: Array(repeating: longest, count: 16))
        #expect(Self.comments(sixteen, limits) == .success(Array(repeating: longest, count: 16)))
        let forty = try Self.zip(names, comments: Array(repeating: longest, count: 40))
        #expect(Self.headers(forty, limits) == .failure(.corrupted(Self.commentsMessage)))
        #expect(await Self.open(forty, limits) == .limit(.totalPathBytes))
        let seventeen = try Self.zip(Array(names.prefix(17)), comments: Array(repeating: longest, count: 17))
        #expect(Self.headers(seventeen, limits) == .failure(.corrupted(Self.commentsMessage)))
    }

    // MARK: - Extra fields

    /// A thread's CPU time for `body`.
    static func cpuTime<T>(_ body: () -> T) -> (T, Double) {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let result = body()
        return (result, Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9)
    }

    /// An Info-ZIP Unicode Path field (0x7075) of `name` with the CRC `crc`.
    static func unicodePath(_ name: [UInt8], crc: UInt32) -> [UInt8] {
        le16(0x7075) + le16(5 + name.count) + [1] + le32(crc) + name
    }

    /// Upstream parsed each record's 0x7075 field against the pathname of the entry being returned, which the
    /// central directory never sets: one record's 65,000-byte Unicode path stayed there, and every later 56-byte
    /// record with a 0x7075 field whose CRC does not match it hashed all 65,000 bytes again (a 1,000-fold cost). The
    /// central directory's 0x7075 names were never used (the local header's name and fields replace them), so the
    /// patch no longer parses them there.
    @Test func unicodePathFieldsDoNotRehashAnEarlierName() throws {
        let count = 200_000
        func url(_ length: Int) throws -> URL {
            let first = Self.record([], offset: 0, extra: Self.unicodePath(Array(repeating: 0x78, count: length),
                                                                          crc: 0))
            let rest = Self.record([], offset: 0, extra: Self.unicodePath([0x79], crc: 0))
            return try Self.zip(["a"], more: first + Array(Array(repeating: rest, count: count).joined()),
                                moreCount: count + 1)
        }
        let long = try url(65_000), short = try url(1)
        let (control, controlTime) = Self.cpuTime { Self.headers(short) }
        let (result, time) = Self.cpuTime { Self.headers(long) }
        #expect(control == .success(1))
        #expect(result == .success(1))
        #expect(time < 0.2 + 3 * controlTime, "65,000-byte name: \(time) s, 1-byte name: \(controlTime) s")
    }

    // MARK: - zip64 end record

    /// A zip of `names` with a zip64 end record that claims `cdSize` and `cdOffset` (nil: the real ones), its locator
    /// and a 32-bit end record that defers to them (0xFFFFFFFF).
    static func zip64(_ names: [String], cdSize: UInt64? = nil, cdOffset: UInt64? = nil) throws -> URL {
        let (head, central) = bytes(names)
        let count = UInt64(names.count)
        let eocd64 = UInt64(head.count + central.count)
        var tail = le32(0x0606_4B50) + le64(44) + le16(45) + le16(45) + le32(0) + le32(0) + le64(count) + le64(count)
        tail += le64(cdSize ?? UInt64(central.count)) + le64(cdOffset ?? UInt64(head.count))
        tail += le32(0x0706_4B50) + le32(0) + le64(eocd64) + le32(1)
        tail += le32(0x0605_4B50) + le16(0) + le16(0) + le16(Int(count)) + le16(Int(count)) + le32(0xFFFF_FFFF)
            + le32(0xFFFF_FFFF) + le16(0)
        let url = Fixtures.tempDir().appendingPathComponent("cd64.zip")
        try Data(head + central + tail).write(to: url)
        return url
    }

    /// The headers libarchive returns for `url`, and whether the first came from a central directory (the seekable
    /// reader; the streaming one has no record: kernir_read_zip_entry_comment returns 0).
    static func reader(_ url: URL) throws -> (headers: Int, seekable: Bool) {
        let session = try ReadSession(urls: [url], password: nil)
        var count = 0, seekable = false
        while let _ = try session.nextHeader() {
            if count == 0 {
                var bytes: UnsafeRawPointer?
                var length = 0
                seekable = kernir_read_zip_entry_comment(session.handle, &bytes, &length) == 1
            }
            count += 1
        }
        return (count, seekable)
    }

    /// Whether the seekable zip reader alone opens `url` (bids on it).
    static func seekableBids(_ url: URL) throws -> Bool {
        guard let a = archive_read_new() else { throw ArchiveError.io("archive_read_new") }
        defer { archive_read_free(a) }
        archive_read_support_format_zip_seekable(a)
        return archive_read_open_filename(a, url.path, 10_240) == ARCHIVE_OK
    }

    /// The zip64 end record's central directory must start at or before the record: otherwise the seekable reader
    /// does not bid and the streaming one reads the local headers. Its size is not checked (nothing reads it): a wrong
    /// one keeps the seekable reader and the central directory's data.
    @Test func zip64CentralDirectoryMustStartBeforeItsEndRecord() throws {
        let names = ["a", "b"]
        let honest = try Self.reader(try Self.zip64(names))
        #expect(honest.headers == 2 && honest.seekable)
        for cdSize: UInt64 in [0, 1 << 40, UInt64.max] {
            let size = try Self.reader(try Self.zip64(names, cdSize: cdSize))
            #expect(size.headers == 2 && size.seekable, "CD size \(cdSize)")
        }
        let offset = try Self.reader(try Self.zip64(names, cdOffset: 1 << 40))
        #expect(offset.headers == 2 && !offset.seekable)
        // The boundary: the zip64 end record's own offset bids (an empty central directory for the seekable
        // reader), 1 byte past it does not.
        let (head, central) = Self.bytes(names)
        let end = UInt64(head.count + central.count)
        let exact = try Self.zip64(names, cdOffset: end)
        #expect(try Self.seekableBids(exact))
        #expect(try Self.reader(exact).headers == 0)
        let past = try Self.zip64(names, cdOffset: end + 1)
        #expect(try !Self.seekableBids(past))
        let streamed = try Self.reader(past)
        #expect(streamed.headers == 2 && !streamed.seekable)
    }

    // MARK: - Mapping

    @Test func refusalMessagesAreMapped() {
        #expect(PatchedNameRefusal.refusal(for: .corrupted(Self.entriesMessage))
                == ArchiveNestingError(limit: .entryCount))
        #expect(PatchedNameRefusal.refusal(for: .corrupted(Self.namesMessage))
                == ArchiveNestingError(limit: .totalPathBytes))
        #expect(PatchedNameRefusal.refusal(for: .corrupted(Self.commentsMessage))
                == ArchiveNestingError(limit: .totalPathBytes))
        #expect(PatchedNameRefusal.refusal(for: .corrupted(Self.namesMessage + ".")) == nil)
    }
}
