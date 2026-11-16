import CLibArchive
import Foundation
import Testing
@testable import KernirCore

/// A crafted archive can nest folders thousands deep (a zip name holds 64 KB, a pax path has no limit). Every folder a
/// path implies is listed with its whole path, so open and previewListing paid memory and time quadratic in the
/// depth: a 128 KB zip took 1.2 GB. The reader now refuses paths past `NestingLimits` before it builds any folder.
@Suite("Nesting limits")
struct NestingLimitTests {
    private static let stamp = SyntheticZip.dosTime(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 6)

    /// "d/d/.../f" with `components` components.
    static func deep(_ components: Int, leaf: String = "f") -> String {
        String(repeating: "d/", count: components - 1) + leaf
    }

    /// A store zip of empty files, written by `SyntheticZip` (UTF-8 flag set).
    static func zip(_ paths: [String]) -> URL {
        SyntheticZip.write(SyntheticZip.stored(paths.map { (path: $0, dosTime: stamp, data: []) }))
    }

    /// An archive of empty files written by libarchive: "tar" (pax), "tar.gz", "7z" or "zip". A path ending in "/" is
    /// a folder entry.
    static func written(_ paths: [String], as kind: String) -> URL {
        let url = Fixtures.tempDir().appendingPathComponent("nest." + kind)
        withUTF8CType {
            let a = archive_write_new()
            defer { archive_write_free(a) }
            switch kind {
            case "7z": #expect(archive_write_set_format_7zip(a) == ARCHIVE_OK)
            case "zip": #expect(archive_write_set_format_zip(a) == ARCHIVE_OK)
            default: #expect(archive_write_set_format_pax_restricted(a) == ARCHIVE_OK)
            }
            if kind == "tar.gz" { #expect(archive_write_add_filter_gzip(a) == ARCHIVE_OK) }
            #expect(archive_write_open_filename(a, url.path) == ARCHIVE_OK)
            for p in paths {
                let e = archive_entry_new()
                defer { archive_entry_free(e) }
                archive_entry_copy_pathname(e, p)
                let folder = p.hasSuffix("/")
                archive_entry_set_filetype(e, UInt32(folder ? S_IFDIR : S_IFREG))
                archive_entry_set_perm(e, folder ? 0o755 : 0o644)
                archive_entry_set_size(e, 0)
                #expect(archive_write_header(a, e) == ARCHIVE_OK)
            }
            #expect(archive_write_close(a) == ARCHIVE_OK)
        }
        return url
    }

    static func archive(_ paths: [String], as kind: String) -> URL {
        kind == "synthetic zip" ? zip(paths) : written(paths, as: kind)
    }

    static let kinds = ["synthetic zip", "zip", "tar", "tar.gz", "7z"]

    /// open and previewListing both refuse `url` with `limit`.
    static func expectRefused(_ url: URL, _ limit: ArchiveNestingError.Limit, limits: NestingLimits = .standard,
                              sourceLocation: SourceLocation = #_sourceLocation) async {
        await #expect(throws: ArchiveNestingError(limit: limit), sourceLocation: sourceLocation) {
            _ = try await LibArchiveReader.open(at: url, password: nil, limits: limits)
        }
        await #expect(throws: ArchiveNestingError(limit: limit), sourceLocation: sourceLocation) {
            _ = try await LibArchiveReader.previewListing(at: url, password: nil, limit: 10, limits: limits)
        }
    }

    // MARK: - Depth

    @Test(arguments: kinds)
    func twoHundredComponentsOpen(kind: String) async throws {
        let path = Self.deep(200)
        let url = Self.archive([path], as: kind)
        let reader = try await Archive.open(at: url)
        #expect(reader.entries.count == 200)
        #expect(reader.entries.last?.path == path)
        let preview = try await Archive.previewListing(at: url, limit: 10)
        #expect(preview.visibleEntryCount == 200)
        #expect(Archive.tree(from: reader.entries).count == 1)
    }

    @Test(arguments: kinds)
    func twoHundredOneComponentsRefuse(kind: String) async throws {
        let url = Self.archive(["a.txt", Self.deep(201), "b.txt"], as: kind)
        await #expect(throws: ArchiveNestingError(limit: .depth)) { _ = try await Archive.open(at: url) }
        await #expect(throws: ArchiveNestingError(limit: .depth)) {
            _ = try await Archive.previewListing(at: url, limit: 10)
        }
    }

    /// Components are counted on the normalized path: "./", "//" and ".." spellings add none.
    @Test func depthCountsNormalizedComponents() async throws {
        let padded = String(repeating: "d/./", count: 199) + "/f"
        let reader = try await Archive.open(at: Self.zip([padded]))
        #expect(reader.entries.count == 200)
        await Self.expectRefused(Self.zip([String(repeating: "d//", count: 200) + "f"]), .depth)
    }

    /// The deep header is the last one: nothing is visited (no folder is built) before the refusal.
    @Test func refusalComesBeforeAnyVisit() throws {
        let url = Self.zip(["a/b.txt", "c/d.txt", Self.deep(201)])
        let session = try ReadSession(urls: [url], password: nil)
        var visited = 0
        #expect(throws: ArchiveNestingError(limit: .depth)) {
            _ = try LibArchiveReader.walkHeaders(session: session, url: url, password: nil, nameEncoding: .automatic) {
                _ in visited += 1
            }
        }
        #expect(visited == 0)
    }

    /// A byte-split zip set reads as one archive, and is refused as one.
    @Test func multiVolumeSetRefuses() async throws {
        let bytes = SyntheticZip.stored([(path: Self.deep(201), dosTime: Self.stamp, data: [])])
        let dir = Fixtures.tempDir()
        let half = bytes.count / 2
        try Data(bytes[..<half]).write(to: dir.appendingPathComponent("set.zip.001"))
        try Data(bytes[half...]).write(to: dir.appendingPathComponent("set.zip.002"))
        await Self.expectRefused(dir.appendingPathComponent("set.zip.001"), .depth)
    }

    // MARK: - Path bytes

    @Test(arguments: kinds)
    func sixteenKiBPathOpensOneMoreByteRefuses(kind: String) async throws {
        let limit = NestingLimits.standard.maxPathBytes
        let atLimit = String(repeating: "a", count: limit / 2 - 1) + "/" + String(repeating: "b", count: limit / 2)
        #expect(atLimit.utf8.count == limit)
        let reader = try await Archive.open(at: Self.archive([atLimit], as: kind))
        #expect(reader.entries.map(\.path) == [String(atLimit.prefix(limit / 2 - 1)), atLimit])
        await Self.expectRefused(Self.archive([atLimit + "c"], as: kind), .pathLength)
    }

    /// The limit counts UTF-8 bytes, not Characters.
    @Test func pathBytesAreUTF8() async throws {
        let limit = NestingLimits.standard.maxPathBytes
        let twoByte = String(repeating: "\u{E9}", count: limit / 2)   // é, 2 bytes each
        _ = try await Archive.open(at: Self.zip([twoByte]))
        await Self.expectRefused(Self.zip([twoByte + "x"]), .pathLength)
    }

    // MARK: - Totals (small limits, exact boundaries)

    /// Fixed totals unless a per-path allowance is given.
    static func limits(folderBytes: Int = .max, folderBytesPerPath: Int = 0, ancestorWork: Int = .max,
                       ancestorWorkPerPath: Int = 0) -> NestingLimits {
        NestingLimits(maxComponents: 200, maxPathBytes: 16 << 10, maxFolderBytes: folderBytes,
                      folderBytesPerPath: folderBytesPerPath, maxAncestorWork: ancestorWork,
                      ancestorWorkPerPath: ancestorWorkPerPath)
    }

    /// Folders "aaa" (3) and "aaa/b" (5), then "x" (1), each plus the 128-byte overhead: 393. A folder is counted once,
    /// however many paths share it and wherever they stand.
    @Test func folderBytesBoundary() async throws {
        #expect(NestingLimits.folderOverhead == 128)
        let paths = ["aaa/b/c", "x/y", "aaa/b/d", "aaa/e", "top.txt"]
        for kind in ["synthetic zip", "tar"] {
            let url = Self.archive(paths, as: kind)
            let reader = try await LibArchiveReader.open(at: url, password: nil, limits: Self.limits(folderBytes: 393))
            #expect(reader.entries.count == 8)
            _ = try await LibArchiveReader.previewListing(at: url, password: nil, limit: 10,
                                                          limits: Self.limits(folderBytes: 393))
            await Self.expectRefused(url, .folderBytes, limits: Self.limits(folderBytes: 392))
        }
    }

    /// Ancestor bytes per path, summed over every path: "aaa/b/c" 3 + 5, "x/y" 1, "aaa/b/d" 3 + 5, "aaa/e" 3: 20.
    @Test func ancestorWorkBoundary() async throws {
        let paths = ["aaa/b/c", "x/y", "aaa/b/d", "aaa/e", "top.txt"]
        for kind in ["synthetic zip", "tar"] {
            let url = Self.archive(paths, as: kind)
            _ = try await LibArchiveReader.open(at: url, password: nil, limits: Self.limits(ancestorWork: 20))
            await Self.expectRefused(url, .ancestorWork, limits: Self.limits(ancestorWork: 19))
        }
    }

    /// "aaa/x" is new under the known "aaa": 3 + 5 + 5, plus 3 x 128 = 397. Counting stops at the first known folder
    /// from the deepest one up, never from the outermost one down.
    @Test func folderBytesChargeANewFolderUnderAKnownOne() async throws {
        for kind in ["synthetic zip", "tar"] {
            let url = Self.archive(["aaa/b/c", "aaa/x/y"], as: kind)
            _ = try await LibArchiveReader.open(at: url, password: nil, limits: Self.limits(folderBytes: 397))
            await Self.expectRefused(url, .folderBytes, limits: Self.limits(folderBytes: 396))
        }
    }

    /// "ab/c" and "a/bc" have the same bytes but for where the "/" stands: four folders, 2 + 4 + 1 + 4 + 4 x 128 = 523.
    @Test func folderBytesTellFoldersApartByTheirSlashes() async throws {
        for kind in ["synthetic zip", "tar"] {
            let url = Self.archive(["ab/c/f", "a/bc/f"], as: kind)
            _ = try await LibArchiveReader.open(at: url, password: nil, limits: Self.limits(folderBytes: 523))
            await Self.expectRefused(url, .folderBytes, limits: Self.limits(folderBytes: 522))
        }
    }

    /// A path past both totals at once reports ancestorWork, the one checked first ("aaa/b/c": 8 and 264).
    @Test func ancestorWorkIsCheckedBeforeFolderBytes() async throws {
        let url = Self.zip(["aaa/b/c"])
        _ = try await LibArchiveReader.open(at: url, password: nil, limits: Self.limits(folderBytes: 264, ancestorWork: 8))
        await Self.expectRefused(url, .ancestorWork, limits: Self.limits(folderBytes: 263, ancestorWork: 7))
    }

    /// An archive of folder entries only ("d/", "d/d/", ...) is charged like any other: 200 open, 201 refuse.
    @Test(arguments: ["tar", "zip"])
    func folderEntriesAreCharged(kind: String) async throws {
        func folders(_ depth: Int) -> [String] { (1...depth).map { String(repeating: "d/", count: $0) } }
        let reader = try await Archive.open(at: Self.written(folders(200), as: kind))
        #expect(reader.entries.count == 200)
        let allFolders = reader.entries.allSatisfy { $0.isDirectory }
        #expect(allFolders)
        await Self.expectRefused(Self.written(folders(201), as: kind), .depth)
    }

    /// Cancelled once every header is read: the charge stops at its first path, before the 201-deep one refuses.
    @Test func cancelledBeforeTheChargeThrowsCancelled() async throws {
        let url = Self.zip([Self.deep(201), "a.txt"])
        let task = Task {
            let session = try ReadSession(urls: [url], password: nil)
            _ = try LibArchiveReader.walkHeaders(session: session, url: url, password: nil, nameEncoding: .automatic,
                                                 afterListing: { withUnsafeCurrentTask { $0?.cancel() } }) { _ in }
        }
        await #expect(throws: ArchiveError.cancelled) { try await task.value }
        // Not cancelled, the same walk refuses the path.
        let session = try ReadSession(urls: [url], password: nil)
        #expect(throws: ArchiveNestingError(limit: .depth)) {
            _ = try LibArchiveReader.walkHeaders(session: session, url: url, password: nil, nameEncoding: .automatic) {
                _ in
            }
        }
    }

    /// A duplicate header is charged again: it is visited again.
    @Test func duplicatePathsChargeAncestorWorkAgain() async throws {
        let url = Self.zip(["aaa/b", "aaa/b"])
        _ = try await LibArchiveReader.open(at: url, password: nil, limits: Self.limits(ancestorWork: 6))
        await Self.expectRefused(url, .ancestorWork, limits: Self.limits(ancestorWork: 5))
    }

    // MARK: - Totals that grow with the paths charged so far (small limits, exact boundaries)

    /// "aaa/b/c" costs 8 of ancestor work. As the fourth path it is allowed 4 x 2 = 8, past the fixed 7, and opens; as
    /// the third it is allowed only the fixed 7. Allowed from the paths so far, not from all the archive holds: as the
    /// first of four it is refused, although the four together would be allowed 8.
    @Test func ancestorWorkGrowsWithThePathsChargedSoFar() async throws {
        let limits = Self.limits(ancestorWork: 7, ancestorWorkPerPath: 2)
        for kind in ["synthetic zip", "tar"] {
            let url = Self.archive(["f1", "f2", "f3", "aaa/b/c"], as: kind)
            let reader = try await LibArchiveReader.open(at: url, password: nil, limits: limits)
            #expect(reader.entries.count == 6)
            _ = try await LibArchiveReader.previewListing(at: url, password: nil, limit: 10, limits: limits)
            await Self.expectRefused(Self.archive(["f1", "f2", "aaa/b/c"], as: kind), .ancestorWork, limits: limits)
            await Self.expectRefused(Self.archive(["aaa/b/c", "f1", "f2", "f3"], as: kind), .ancestorWork,
                                     limits: limits)
        }
    }

    /// The folders "aaa" and "aaa/b" cost 3 + 5 + 2 x 128 = 264. As the fourth path, "aaa/b/c" is allowed 4 x 66 = 264
    /// and opens; as the third or the first, only the fixed 263.
    @Test func folderBytesGrowWithThePathsChargedSoFar() async throws {
        let limits = Self.limits(folderBytes: 263, folderBytesPerPath: 66)
        for kind in ["synthetic zip", "tar"] {
            let url = Self.archive(["f1", "f2", "f3", "aaa/b/c"], as: kind)
            let reader = try await LibArchiveReader.open(at: url, password: nil, limits: limits)
            #expect(reader.entries.count == 6)
            _ = try await LibArchiveReader.previewListing(at: url, password: nil, limit: 10, limits: limits)
            await Self.expectRefused(Self.archive(["f1", "f2", "aaa/b/c"], as: kind), .folderBytes, limits: limits)
            await Self.expectRefused(Self.archive(["aaa/b/c", "f1", "f2", "f3"], as: kind), .folderBytes,
                                     limits: limits)
        }
    }

    /// A total that grew with the paths refuses before any visit too.
    @Test(arguments: [(ArchiveNestingError.Limit.ancestorWork, NestingLimitTests.limits(ancestorWork: 7,
                                                                                         ancestorWorkPerPath: 2)),
                      (.folderBytes, NestingLimitTests.limits(folderBytes: 263, folderBytesPerPath: 66))])
    func grownTotalsRefuseBeforeAnyVisit(limit: ArchiveNestingError.Limit, limits: NestingLimits) throws {
        let url = Self.zip(["f1", "f2", "aaa/b/c"])
        let session = try ReadSession(urls: [url], password: nil)
        var visited = 0
        #expect(throws: ArchiveNestingError(limit: limit)) {
            _ = try LibArchiveReader.walkHeaders(session: session, url: url, password: nil, nameEncoding: .automatic,
                                                 limits: limits) { _ in visited += 1 }
        }
        #expect(visited == 0)
    }

    /// A header the walk skips (a name that normalizes to nothing: "./", "..") is not charged and buys no allowance.
    /// After three of them "aaa/b/c" is still the first path charged, and is refused; after three one-name paths it
    /// opens (as in the two Grow tests above).
    @Test(arguments: [(ArchiveNestingError.Limit.ancestorWork, NestingLimitTests.limits(ancestorWork: 7,
                                                                                         ancestorWorkPerPath: 2)),
                      (.folderBytes, NestingLimitTests.limits(folderBytes: 263, folderBytesPerPath: 66))])
    func skippedHeadersBuyNoAllowance(limit: ArchiveNestingError.Limit, limits: NestingLimits) async throws {
        for kind in ["synthetic zip", "tar"] {
            let counted = Self.archive(["f1", "f2", "f3", "aaa/b/c"], as: kind)
            _ = try await LibArchiveReader.open(at: counted, password: nil, limits: limits)
            await Self.expectRefused(Self.archive(["./", "..", "./", "aaa/b/c"], as: kind), limit, limits: limits)
        }
    }

    /// A per-path allowance times the path count saturates at Int.max instead of overflowing.
    @Test func grownTotalsDoNotOverflow() throws {
        var budget = NestingBudget(Self.limits(folderBytes: 0, folderBytesPerPath: .max, ancestorWork: 0,
                                               ancestorWorkPerPath: .max))
        for path in ["a/b", "c/d", "e/f"] { try budget.charge(path) }
        #expect(budget.paths == 3)
        #expect(budget.ancestorWork == 3)
        #expect(budget.folderBytes == 3 * 129)
    }

    // MARK: - Totals that grow with the paths charged so far (standard limits)

    /// The standard allowances: 8 KiB of ancestor work and 512 bytes of folders per path charged so far, once that
    /// passes the fixed 1 GiB and 64 MiB. Literal values, so a change to the standard limits fails here.
    @Test func standardAllowancesPerPath() {
        let s = NestingLimits.standard
        #expect(s.maxAncestorWork == 1_073_741_824)
        #expect(s.ancestorWorkPerPath == 8_192)
        #expect(s.maxFolderBytes == 67_108_864)
        #expect(s.folderBytesPerPath == 512)
    }

    /// 200 components in 16,384 bytes with every "/" at the end: the most ancestor work one path can cost, 3,220,616
    /// bytes, all in new folders (3,246,088 bytes with the overhead) when `trunk` is new. `trunk` is 15,986 bytes.
    static func costliest(trunk: String = String(repeating: "t", count: 15_986)) -> String {
        precondition(trunk.utf8.count == 15_986)
        return trunk + String(repeating: "/d", count: 199)
    }

    /// A first component of `count` bytes, then `slashes` one-letter components: `slashes x count +
    /// slashes x (slashes - 1)` of ancestor work, and 128 more per folder in folder bytes when `letter` starts no
    /// other path.
    static func tuning(_ letter: Character, _ count: Int, _ slashes: Int) -> String {
        String(repeating: letter, count: count) + String(repeating: "/d", count: slashes)
    }

    /// Exactly at the allowance of 262,226 paths, 8,192 bytes each (2,148,155,392): 261,558 one-name paths, then a
    /// 4,520-byte path, then 667 of the costliest paths. Opens; one byte more refuses at the last path, and so does one
    /// one-name path fewer. The one-name paths come first: allowance bought early is what an attacker would front-load,
    /// and it stays 8 KiB per path.
    @Test func ancestorWorkStandardBoundaryAtManyPaths() throws {
        let costly = Self.costliest()
        #expect(Self.ancestorBytes(costly) == 3_220_616)
        func run(cheap: Int, tuning: String) throws(ArchiveNestingError) -> NestingBudget {
            var budget = NestingBudget(.standard)
            for i in 0..<cheap { try budget.charge("c\(i)") }
            try budget.charge(tuning)
            for _ in 0..<667 { try budget.charge(costly) }
            return budget
        }
        let exact = Self.tuning("t", 74, 40)
        #expect(Self.ancestorBytes(exact) == 4_520)
        let budget = try run(cheap: 261_558, tuning: exact)
        #expect(budget.paths == 262_226)
        #expect(budget.ancestorWork == 2_148_155_392)
        #expect(budget.ancestorWork == 8_192 * 262_226)

        let oneMore = Self.tuning("t", 105, 33)
        #expect(Self.ancestorBytes(oneMore) == 4_521)
        #expect(throws: ArchiveNestingError(limit: .ancestorWork)) { _ = try run(cheap: 261_558, tuning: oneMore) }
        #expect(throws: ArchiveNestingError(limit: .ancestorWork)) { _ = try run(cheap: 261_557, tuning: exact) }
    }

    /// Exactly at the allowance of 262,144 paths, 512 bytes each (134,217,728): 262,102 one-name paths, then a path
    /// whose 170 new folders cost 1,128,120 bytes, then 41 of the costliest paths under new trunks. Opens; one byte
    /// more refuses at the last path, and so does one one-name path fewer.
    @Test func folderBytesStandardBoundaryAtManyPaths() throws {
        func run(cheap: Int, tuning: String) throws(ArchiveNestingError) -> NestingBudget {
            var budget = NestingBudget(.standard)
            for i in 0..<cheap { try budget.charge("c\(i)") }
            try budget.charge(tuning)
            for i in 0..<41 {
                try budget.charge(Self.costliest(trunk: String(repeating: "t", count: 15_976) + Self.pad(i, 10)))
            }
            return budget
        }
        let budget = try run(cheap: 262_102, tuning: Self.tuning("g", 6_339, 170))
        #expect(budget.paths == 262_144)
        #expect(budget.folderBytes == 134_217_728)
        #expect(budget.folderBytes == 512 * 262_144)
        #expect(throws: ArchiveNestingError(limit: .folderBytes)) {
            _ = try run(cheap: 262_102, tuning: Self.tuning("g", 7_193, 151))   // 1,128,121 bytes of folders
        }
        #expect(throws: ArchiveNestingError(limit: .folderBytes)) {
            _ = try run(cheap: 262_101, tuning: Self.tuning("g", 6_339, 170))
        }
    }

    /// `n` in decimal, zero-padded to `width` digits.
    static func pad(_ n: Int, _ width: Int) -> String {
        let digits = String(n)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// The paths of a tar of a home folder under a Time Machine-style prefix, folders listed before their contents:
    /// "Project 00000", "Project 00001", ... each a chain of 16 folders ("Folder level 01" ...) with `filesPerFolder`
    /// files in each, until `count` entries. 23 components and 347 bytes at most.
    static func timeMachineTree(count: Int, filesPerFolder: Int, _ body: (String) throws -> Void) rethrows {
        let prefix = "Backups.backupdb/Mac-mini/2026-11-11-120000/Macintosh HD - Data/Users/x/Project "
        let files = (0..<filesPerFolder).map { "/Document " + pad($0, 2) + " final.txt" }
        let levels = (1...16).map { "/Folder level " + pad($0, 2) }
        var emitted = 0
        var project = 0
        while true {
            var folder = prefix + pad(project, 5)
            for level in levels {
                guard emitted < count else { return }
                try body(folder)
                emitted += 1
                for file in files {
                    guard emitted < count else { return }
                    try body(folder + file)
                    emitted += 1
                }
                folder += level
            }
            project += 1
        }
    }

    /// A whole home folder or disk in one tar, under a Time Machine-style prefix: 1,000,000 entries, 1 in 4 a folder.
    /// About 1,640 bytes of ancestor work per path, under the deepest real tree measured under such a prefix
    /// (DerivedData, 2,190): past both fixed totals, 1 GiB of ancestor work and 64 MiB of folders (83 MB). Opens
    /// within the allowances that grow with the paths. Charged without an archive: the budget holds about 8 MiB at the
    /// end, so the test is not `.memoryHeavy`.
    @Test func wideTimeMachineBackupOpens() throws {
        var budget = NestingBudget(.standard)
        var deepest = 0
        var longest = 0
        try Self.timeMachineTree(count: 1_000_000, filesPerFolder: 3) { path in
            if path.utf8.count > longest {
                longest = path.utf8.count
                deepest = path.utf8.reduce(1) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
            }
            try budget.charge(path)
        }
        #expect(budget.paths == 1_000_000)
        #expect(longest == 347)
        #expect(deepest == 23)
        #expect(budget.ancestorWork > 1 << 30)
        #expect(budget.ancestorWork / budget.paths < 2_190)
        #expect(budget.folderBytes > 64 << 20)
    }

    /// The attack a check against all the archive's paths would let through: the costliest paths first, past the
    /// fixed total, then enough one-name paths that their 8 KiB (or 512 bytes) each would cover it. Refused at the
    /// costliest path that passes the fixed total (the 334th, or the 21st under new trunks), before any one-name path
    /// is charged: an allowance only grows with paths already charged. Gzip makes the 140,000 one-name headers small on
    /// disk. No wall-clock bound, since gate runs are loaded: the same paths charged in-process show where the refusal
    /// comes.
    @Test(.memoryHeavy, arguments: [ArchiveNestingError.Limit.ancestorWork, .folderBytes])
    func costlyPathsBeforeTheirAllowanceRefuse(limit: ArchiveNestingError.Limit) async throws {
        let costly: [String]
        if limit == .ancestorWork {
            costly = Array(repeating: Self.costliest(), count: 334)
            #expect(costly.dropLast().reduce(0) { $0 + Self.ancestorBytes($1) } <= 1 << 30)
            #expect(costly.reduce(0) { $0 + Self.ancestorBytes($1) } > 1 << 30)
            #expect(8_192 * (334 + 140_000) >= 334 * 3_220_616)
        } else {
            costly = (0..<21).map { Self.costliest(trunk: String(repeating: "t", count: 15_976) + Self.pad($0, 10)) }
            #expect(20 * 3_246_088 <= 64 << 20 && 21 * 3_246_088 > 64 << 20)
            #expect(512 * (21 + 140_000) >= 21 * 3_246_088)
        }
        let paths = costly + (0..<140_000).map { "c\($0)" }
        func charge(_ count: Int) throws(ArchiveNestingError) {
            var budget = NestingBudget(.standard)
            for path in paths.prefix(count) { try budget.charge(path) }
        }
        try charge(costly.count - 1)
        #expect(throws: ArchiveNestingError(limit: limit)) { try charge(costly.count) }
        let url = Self.written(paths, as: "tar.gz")
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? .max
        #expect(size < 16 << 20)
        await Self.expectRefused(url, limit)
    }

    // MARK: - Crafted archives at the standard limits (memory cases)

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// One 64,001-byte name 32,000 levels deep (deep1.zip: 1.2 GB at open), and the same depth in a
    /// pax path: refused at once.
    @Test(arguments: ["synthetic zip", "tar"])
    func reviewDeepNameRefusesFast(kind: String) async throws {
        let url = Self.archive([Self.deep(32_001)], as: kind)
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await Self.expectRefused(url, .pathLength) }
        #expect(Self.seconds(elapsed) < 10, "took \(elapsed)")
        // Under the byte limit, the depth limit catches the same nesting.
        await Self.expectRefused(Self.archive([Self.deep(8_000)], as: kind), .depth)
    }

    /// Ten names under one 31,995-level prefix, each in its own folder (shared10.zip: 2.9 GB, 7.6 s).
    @Test func reviewSharedPrefixRefusesFast() async throws {
        let prefix = String(repeating: "d/", count: 31_995)
        let url = Self.zip((0..<10).map { prefix + "x\($0)/f" })
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await Self.expectRefused(url, .pathLength) }
        #expect(Self.seconds(elapsed) < 10, "took \(elapsed)")
    }

    /// Paths inside both per-path limits that add up to the 1 GiB of ancestor work: each one is a 15,000-byte
    /// folder, 197 one-letter folders and its own last folder, about 3 MB of ancestors, under a shared trunk (few
    /// distinct folders). 355 of them take 1,073,663,665 bytes, just under 1 GiB, and open; the 356th passes it.
    /// Literal counts, so a change to the standard limit fails here. Gzip makes the headers tiny on disk.
    @Test(.memoryHeavy) func ancestorWorkStandardBudgetIsOneGiB() async throws {
        let trunk = String(repeating: "t", count: 15_000) + "/" + String(repeating: "d/", count: 197)
        let paths = (0..<356).map { trunk + "x\($0)/f" }
        #expect(paths.prefix(355).reduce(0) { $0 + Self.ancestorBytes($1) } == 1_073_663_665)
        #expect(paths.reduce(0) { $0 + Self.ancestorBytes($1) } > 1 << 30)
        let reader = try await Archive.open(at: Self.written(Array(paths.prefix(355)), as: "tar.gz"))
        #expect(reader.entries.count == 198 + 355 * 2)
        let url = Self.written(paths, as: "tar.gz")
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await Self.expectRefused(url, .ancestorWork) }
        #expect(Self.seconds(elapsed) < 30, "took \(elapsed)")
    }

    /// Distinct 15,000-byte top folders, each with 198 folders beneath: 3,049,874 bytes of new folders per path (with
    /// the overhead). 22 paths take 67,097,228 bytes, just under 64 MiB, and open; the 23rd passes it.
    @Test(.memoryHeavy) func folderBytesStandardBudgetIs64MiB() async throws {
        let tail = "/" + String(repeating: "d/", count: 198) + "f"
        let paths = (0..<23).map { String(repeating: "t", count: 14_990) + String(format: "%010d", $0) + tail }
        let reader = try await Archive.open(at: Self.written(Array(paths.prefix(22)), as: "tar.gz"))
        #expect(reader.entries.count == 22 * 200)
        let url = Self.written(paths, as: "tar.gz")
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await Self.expectRefused(url, .folderBytes) }
        #expect(Self.seconds(elapsed) < 30, "took \(elapsed)")
    }

    /// Sum of the byte offsets of every "/" in `path`: the bytes of its ancestor paths.
    static func ancestorBytes(_ path: String) -> Int {
        path.utf8.enumerated().reduce(0) { $1.element == UInt8(ascii: "/") ? $0 + $1.offset : $0 }
    }
}
