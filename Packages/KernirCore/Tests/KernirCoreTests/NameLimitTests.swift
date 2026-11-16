import CLibArchive
import Foundation
import Testing
@testable import KernirCore

/// The name limits that bound what the listing holds and computes before any path is charged (the name caps,
/// combining marks and hardlink targets): stored names and link targets are capped as each header is read (64 KiB
/// each, 256 MiB in all), a run of more than 30 combining marks is refused before anything normalizes it, and
/// hardlink targets are charged like paths.
@Suite("Name limits")
struct NameLimitTests {
    struct Item {
        var path: String
        var type: mode_t = mode_t(S_IFREG)
        var link: String? = nil
        var size = 0

        static func file(_ path: String, size: Int = 0) -> Item { Item(path: path, size: size) }
        static func symlink(_ path: String, to target: String) -> Item {
            Item(path: path, type: mode_t(S_IFLNK), link: target)
        }
        /// A hardlink header (`archive_entry_copy_hardlink`) to `target`.
        static func hardlink(_ path: String, to target: String) -> Item {
            Item(path: path, type: mode_t(S_IFREG), link: target, size: -1)
        }
    }

    /// A pax tar ("tar") or a gzipped one ("tar.gz") of `items`, written by libarchive. Data bytes are "x".
    static func tar(_ items: [Item], as kind: String = "tar") -> URL {
        let url = Fixtures.tempDir().appendingPathComponent("names." + kind)
        withUTF8CType {
            let a = archive_write_new()
            defer { archive_write_free(a) }
            #expect(archive_write_set_format_pax_restricted(a) == ARCHIVE_OK)
            if kind == "tar.gz" { #expect(archive_write_add_filter_gzip(a) == ARCHIVE_OK) }
            #expect(archive_write_open_filename(a, url.path) == ARCHIVE_OK)
            for item in items {
                let e = archive_entry_new()
                defer { archive_entry_free(e) }
                archive_entry_copy_pathname(e, item.path)
                archive_entry_set_filetype(e, UInt32(item.type))
                archive_entry_set_perm(e, 0o644)
                if item.type == mode_t(S_IFLNK) {
                    archive_entry_copy_symlink(e, item.link)
                } else if item.size < 0 {
                    archive_entry_copy_hardlink(e, item.link)
                }
                archive_entry_set_size(e, Int64(max(item.size, 0)))
                #expect(archive_write_header(a, e) == ARCHIVE_OK)
                if item.size > 0 {
                    let data = [UInt8](repeating: UInt8(ascii: "x"), count: item.size)
                    #expect(data.withUnsafeBytes { archive_write_data(a, $0.baseAddress, $0.count) } == item.size)
                }
            }
            #expect(archive_write_close(a) == ARCHIVE_OK)
        }
        return url
    }

    /// `url` cut short by `drop` bytes, so reading past its early headers fails.
    static func truncated(_ url: URL, drop: Int) throws -> URL {
        let data = try Data(contentsOf: url)
        let out = Fixtures.tempDir().appendingPathComponent("cut-" + url.lastPathComponent)
        try data.prefix(data.count - drop).write(to: out)
        return out
    }

    static func zip(_ paths: [String]) -> URL { NestingLimitTests.zip(paths) }

    /// A fixed name total of `total` bytes (no per-entry growth: EntryCountLimitTests covers that).
    static func limits(total: Int) -> NestingLimits {
        var l = NestingLimits.standard
        l.maxTotalNameBytes = total
        l.nameBytesPerEntry = 0
        return l
    }

    /// open and previewListing both refuse `url` with `limit`.
    static func expectRefused(_ url: URL, _ limit: ArchiveNestingError.Limit, limits: NestingLimits = .standard,
                              nameEncoding: ArchiveNameEncoding = .automatic,
                              sourceLocation: SourceLocation = #_sourceLocation) async {
        await #expect(throws: ArchiveNestingError(limit: limit), sourceLocation: sourceLocation) {
            _ = try await LibArchiveReader.open(at: url, password: nil, nameEncoding: nameEncoding, limits: limits)
        }
        await #expect(throws: ArchiveNestingError(limit: limit), sourceLocation: sourceLocation) {
            _ = try await LibArchiveReader.previewListing(at: url, password: nil, limit: 10, limits: limits)
        }
    }

    /// `count` combining marks, alternating U+0301 (class 230) and U+0316 (class 220) so NFC must reorder them.
    static func marks(_ count: Int) -> String {
        String(String.UnicodeScalarView((0..<count).map { $0 % 2 == 0 ? "\u{301}" : "\u{316}" }))
    }

    static func seconds(_ d: Duration) -> Double { NestingLimitTests.seconds(d) }

    @Test func standardNameLimits() {
        #expect(NestingLimits.standard.maxRawNameBytes == 65_536)
        #expect(NestingLimits.standard.maxTotalNameBytes == 268_435_456)
        #expect(EntryPath.maxCombiningRun == 30)
    }

    // MARK: - Caps as each header is read

    /// The first header's 100 KB name is refused as it is read: the truncated tail is never reached, so the error is
    /// the name's, not `.corrupted`.
    @Test func longFirstNameIsRefusedBeforeTheTruncatedTail() async throws {
        let full = Self.tar([.file(String(repeating: "n", count: 100_000)), .file("b.bin", size: 65_536),
                             .file("c.txt")])
        let url = try Self.truncated(full, drop: 40_000)
        await Self.expectRefused(url, .pathLength)
    }

    /// The running total stops the listing too: the second name passes it, and the truncated tail is never read.
    @Test func totalIsCheckedAsEachHeaderIsRead() async throws {
        let full = Self.tar([.file("aaa"), .file("bbb"), .file("b.bin", size: 65_536), .file("c.txt")])
        let url = try Self.truncated(full, drop: 40_000)
        await #expect(throws: ArchiveError.self) {
            _ = try await LibArchiveReader.open(at: url, password: nil, limits: Self.limits(total: 1 << 20))
        }
        await Self.expectRefused(url, .totalPathBytes, limits: Self.limits(total: 5))
    }

    /// 64 KiB of stored name opens when it normalizes short ("./" padding); one byte more is refused.
    @Test(arguments: ["tar", "tar.gz"])
    func storedNameCapIs64KiB(kind: String) async throws {
        let padding = String(repeating: "./", count: 32_767)
        let atCap = padding + "xx"
        #expect(atCap.utf8.count == 65_536)
        let reader = try await Archive.open(at: Self.tar([.file(atCap)], as: kind))
        #expect(reader.entries.map(\.path) == ["xx"])
        await Self.expectRefused(Self.tar([.file(padding + "xxx")], as: kind), .pathLength)
    }

    /// A GNU tar (././@LongLink) of empty files under raw name bytes, which need not be UTF-8.
    static func gnuTar(_ names: [[UInt8]]) -> URL {
        let url = Fixtures.tempDir().appendingPathComponent("gnu.tar")
        withUTF8CType {
            let a = archive_write_new()
            defer { archive_write_free(a) }
            #expect(archive_write_set_format_gnutar(a) == ARCHIVE_OK)
            #expect(archive_write_open_filename(a, url.path) == ARCHIVE_OK)
            for name in names {
                let e = archive_entry_new()
                defer { archive_entry_free(e) }
                (name + [0]).withUnsafeBufferPointer {
                    $0.withMemoryRebound(to: CChar.self) { archive_entry_copy_pathname(e, $0.baseAddress) }
                }
                archive_entry_set_filetype(e, UInt32(S_IFREG))
                archive_entry_set_perm(e, 0o644)
                archive_entry_set_size(e, 0)
                #expect(archive_write_header(a, e) == ARCHIVE_OK)
            }
            #expect(archive_write_close(a) == ARCHIVE_OK)
        }
        return url
    }

    /// A stored name that is not UTF-8 (Latin-1 "\u{E9}" bytes, GNU long name) has no UTF-8 reading: its raw bytes
    /// count all the same.
    @Test func undecodableStoredNameCountsItsRawBytes() async throws {
        let padding = Array(String(repeating: "./", count: 32_767).utf8)
        let reader = try await Archive.open(at: Self.gnuTar([padding + [0xE9, 0xE9]]))
        #expect(reader.entries.count == 1)
        await Self.expectRefused(Self.gnuTar([padding + [0xE9, 0xE9, 0xE9]]), .pathLength)
    }

    /// A symlink target is held as stored: 64 KiB opens, one byte more is refused.
    @Test func symlinkTargetCapIs64KiB() async throws {
        let target = String(repeating: "t", count: 65_536)
        let reader = try await LibArchiveReader.open(at: Self.tar([.symlink("l", to: target)]), password: nil)
        #expect(reader.symlinkTargetByPath["l"] == target)
        await Self.expectRefused(Self.tar([.symlink("l", to: target + "t")]), .pathLength)
    }

    /// A hardlink target is charged like a path: stored over 64 KiB, or over 16 KiB once normalized, is refused.
    @Test func hardlinkTargetIsChargedLikeAPath() async throws {
        let atLimit = String(repeating: "t", count: 16_384)
        let reader = try await LibArchiveReader.open(at: Self.tar([.file(atLimit), .hardlink("h", to: atLimit)]),
                                                     password: nil)
        #expect(reader.hardlinkTargetByPath["h"] == atLimit)
        await Self.expectRefused(Self.tar([.hardlink("h", to: atLimit + "t")]), .pathLength)
        await Self.expectRefused(Self.tar([.hardlink("h", to: String(repeating: "./", count: 32_768) + "t")]),
                                 .pathLength)
    }

    /// The total counts names and both kinds of link target, as stored: 3 + (2 + 1) + (2 + 3) = 11.
    @Test func totalCountsNamesAndLinkTargets() async throws {
        let url = Self.tar([.file("aaa"), .symlink("bb", to: "c"), .hardlink("dd", to: "aaa")])
        _ = try await LibArchiveReader.open(at: url, password: nil, limits: Self.limits(total: 11))
        _ = try await LibArchiveReader.previewListing(at: url, password: nil, limit: 10, limits: Self.limits(total: 11))
        await Self.expectRefused(url, .totalPathBytes, limits: Self.limits(total: 10))
    }

    // MARK: - Combining marks

    /// The base letter "x" has no precomposed form with these marks: libarchive's own NFC of a declared name (on
    /// Darwin) would turn "a" and U+0301 into "\u{E1}", one mark fewer.
    @Test(arguments: ["synthetic zip", "tar"])
    func thirtyCombiningMarksOpenThirtyOneRefuse(kind: String) async throws {
        let thirty = "x" + Self.marks(30) + ".txt"
        let url = kind == "tar" ? Self.tar([.file(thirty)]) : Self.zip([thirty])
        let reader = try await Archive.open(at: url)
        #expect(reader.entries.map(\.path) == [thirty.precomposedStringWithCanonicalMapping])
        let thirtyOne = "x" + Self.marks(31) + ".txt"
        await Self.expectRefused(kind == "tar" ? Self.tar([.file(thirtyOne)]) : Self.zip([thirtyOne]), .combiningMarks)
    }

    /// A run counts every mark, class 0 included (U+0F90, a Tibetan subjoined letter), and a base letter ends it.
    @Test func runCountsEveryMarkAndEndsAtABaseLetter() async throws {
        _ = try await Archive.open(at: Self.zip(["a" + String(repeating: "\u{F90}", count: 30)]))
        await Self.expectRefused(Self.zip(["a" + String(repeating: "\u{F90}", count: 31)]), .combiningMarks)
        _ = try await Archive.open(at: Self.zip(["a" + Self.marks(30) + "b" + Self.marks(30) + "/c" + Self.marks(30)]))
    }

    @Test func linkTargetsAreScannedForMarks() async throws {
        let target = "t" + Self.marks(31)
        await Self.expectRefused(Self.tar([.symlink("l", to: target)]), .combiningMarks)
        await Self.expectRefused(Self.tar([.hardlink("h", to: target)]), .combiningMarks)
    }

    /// A legacy name decodes to marks too: GB18030 encodes every scalar.
    @Test func legacyGB18030NameIsScanned() async throws {
        func url(_ name: String) throws -> URL {
            let bytes = try #require(name.data(using: .gb18030))
            return SyntheticZip.write(SyntheticZip.stored([(nameBytes: Array(bytes), utf8Flag: false,
                                                            dosTime: 0x5821_0000, data: [])]))
        }
        // U+0316 round-trips through CoreFoundation's GB18030; U+0301 does not.
        func name(_ marks: Int) -> String { "\u{540D}" + String(repeating: "\u{316}", count: marks) + ".txt" }
        let reader = try await LibArchiveReader.open(at: try url(name(30)), password: nil,
                                                     nameEncoding: .specific(.gb18030))
        #expect(reader.entries.map { Array($0.path.utf8) } == [Array(name(30).utf8)])
        await #expect(throws: ArchiveNestingError(limit: .combiningMarks)) {
            _ = try await LibArchiveReader.open(at: try url(name(31)), password: nil, nameEncoding: .specific(.gb18030))
        }
    }

    /// Real names with marks open, listed as NFC: Vietnamese stored decomposed, Tibetan stacks and vowel signs.
    @Test(arguments: ["synthetic zip", "tar"])
    func realMarkedNamesOpen(kind: String) async throws {
        let names = ["Tie\u{302}\u{301}ng Vie\u{323}\u{302}t/ghi chu\u{301}.txt",
                     "\u{F56}\u{F7C}\u{F51}\u{F0B}\u{F61}\u{F72}\u{F42}/\u{F56}\u{F66}\u{F92}\u{FB2}\u{F74}\u{F56}\u{F66}.txt",
                     "\u{F68}\u{F7C}\u{F7E}\u{F0B}\u{F58}\u{F0B}\u{F4E}\u{F72}\u{F0B}\u{F54}\u{F51}\u{FA8}\u{F7A}\u{F0B}\u{F67}\u{F71}\u{F74}\u{F83}.txt"]
        let url = kind == "tar" ? Self.tar(names.map { .file($0) }) : Self.zip(names)
        let reader = try await Archive.open(at: url)
        // Bytes: a Set<String> would also match a decomposed spelling.
        let paths = Set(reader.entries.map { Array($0.path.utf8) })
        for n in names { #expect(paths.contains(Array(n.precomposedStringWithCanonicalMapping.utf8))) }
        #expect(paths.contains(Array("Ti\u{1EBF}ng Vi\u{1EC7}t/ghi ch\u{FA}.txt".utf8)))
    }

    /// Every NFC site skips a run past the limit, so no name costs quadratic time before the listing refuses it.
    @Test func nfcSitesSkipLongRuns() {
        // Bytes, not String ==, which holds for any two canonically equivalent spellings.
        let long = "a" + Self.marks(31)
        let short = "a" + Self.marks(30)
        let nfc = Array(short.precomposedStringWithCanonicalMapping.utf8)
        #expect(nfc != Array(short.utf8))
        #expect(EntryPath.normalize(long).map { Array($0.utf8) } == Array(long.utf8))
        #expect(EntryPath.normalize(short).map { Array($0.utf8) } == nfc)
        #expect(Array(NameEncodingDetector.decode(Array(long.utf8), as: .utf8).utf8) == Array(long.utf8))
        #expect(Array(NameEncodingDetector.decode(Array(short.utf8), as: .utf8).utf8) == nfc)
        #expect(Array(EntryNameDecoder.decode(Array(long.utf8)).utf8) == Array(long.utf8))
    }

    /// Forty declared 60 KB names of marks: the header loop normalized each one (about 0.4 s apiece) before this.
    @Test func longMarkNamesAreNotNormalizedWhileListing() async throws {
        let url = Self.zip((0..<40).map { "\($0)" + Self.marks(30_000) })
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await #expect(throws: ArchiveNestingError(limit: .combiningMarks)) {
                _ = try await Archive.open(at: url)
            }
        }
        #expect(Self.seconds(elapsed) < 5, "took \(elapsed)")
    }

    /// The repack guard compares bytes: both sides are NFC already, and String == would reorder marks again.
    @Test func readsAsPathComparesBytes() {
        #expect(EntryNameDecoder.readsAsPath("\u{E9}", path: "\u{E9}", isDirectory: false))
        #expect(!EntryNameDecoder.readsAsPath("e\u{301}", path: "\u{E9}", isDirectory: false))
        #expect(EntryNameDecoder.readsAsPath("a/", path: "a", isDirectory: true))
        #expect(!EntryNameDecoder.readsAsPath("a/", path: "a", isDirectory: false))
        #expect(!EntryNameDecoder.readsAsPath("ab", path: "a", isDirectory: true))
        #expect(!EntryNameDecoder.readsAsPath("e\u{301}/", path: "\u{E9}", isDirectory: true))
    }
}
