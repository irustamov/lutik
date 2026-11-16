import Testing
import Foundation
@testable import KernirCore

/// Multi-volume archive reading: volume naming, byte probes and the set resolver.
struct MultiVolumeTests {
    // MARK: Naming

    static func match(_ path: String) -> [VolumeNaming] { VolumeNaming.match(URL(fileURLWithPath: path)) }

    static func name(_ url: URL?) -> String? { url?.lastPathComponent }

    @Test func testNamingRarParts() {
        let c = Self.match("/data/in/Photos.part3.rar")
        #expect(c.count == 1)
        #expect(c[0].pattern == .rarParts(width: 1))
        #expect(c[0].base == "Photos")
        #expect(c[0].openedPart == 3)
        #expect(c[0].folder.path == "/data/in")
        #expect(c[0].url(ofPart: 1).path == "/data/in/Photos.part1.rar")
        #expect(c[0].lastPartURL() == nil)

        let wide = Self.match("/d/a.part007.rar")
        #expect(wide.map(\.pattern) == [.rarParts(width: 3)])
        #expect(wide[0].openedPart == 7)
        #expect(wide[0].url(ofPart: 12).lastPathComponent == "a.part012.rar")

        let ten = Self.match("/d/x.part10.rar")
        #expect(ten.map(\.pattern) == [.rarParts(width: 2), .rarParts(width: 1)])
        #expect(ten.map(\.openedPart) == [10, 10])
        #expect(ten[0].url(ofPart: 1).lastPathComponent == "x.part01.rar")
        #expect(ten[1].url(ofPart: 1).lastPathComponent == "x.part1.rar")

        #expect(Self.match("/d/x.part1.rar").map(\.pattern) == [.rarParts(width: 1)])
        #expect(Self.match("/d/x.part01.rar").map(\.pattern) == [.rarParts(width: 2)])
        #expect(Self.match("/d/x.part010.rar").map(\.pattern) == [.rarParts(width: 3)])
        #expect(Self.match("/d/x.part010.rar")[0].openedPart == 10)
    }

    @Test func testNamingRarPartsKeepsCase() {
        let c = Self.match("/d/Photos.PART3.RAR")
        #expect(c[0].url(ofPart: 1).lastPathComponent == "Photos.PART1.RAR")
        let d = Self.match("/d/Photos.part3.Rar")
        #expect(d.count == 1)
        #expect(d[0].base == "Photos")
    }

    @Test func testNamingRarOld() {
        let r00 = Self.match("/d/x.r00")
        #expect(r00.map(\.pattern) == [.rarOld])
        #expect(r00[0].openedPart == 2)
        #expect(r00[0].base == "x")
        #expect(r00[0].url(ofPart: 1).lastPathComponent == "x.rar")
        #expect(r00[0].url(ofPart: 2).lastPathComponent == "x.r00")
        #expect(r00[0].url(ofPart: 101).lastPathComponent == "x.r99")

        let rar = Self.match("/d/x.rar")
        #expect(rar.map(\.pattern) == [.rarOld])
        #expect(rar[0].openedPart == 1)

        let upper = Self.match("/d/x.R05")
        #expect(upper[0].openedPart == 7)
        #expect(upper[0].url(ofPart: 1).lastPathComponent == "x.RAR")
        #expect(upper[0].url(ofPart: 3).lastPathComponent == "x.R01")
        #expect(Self.match("/d/x.r05")[0].url(ofPart: 1).lastPathComponent == "x.rar")
    }

    @Test func testNamingRarOldBeyondR99() {
        let s00 = Self.match("/d/x.s00")
        #expect(s00.map(\.pattern) == [.rarOld])
        #expect(s00[0].openedPart == 102)
        #expect(s00[0].url(ofPart: 1).lastPathComponent == "x.rar")
        #expect(s00[0].url(ofPart: 101).lastPathComponent == "x.r99")
        #expect(s00[0].url(ofPart: 102).lastPathComponent == "x.s00")
        #expect(s00[0].url(ofPart: 201).lastPathComponent == "x.s99")
        #expect(s00[0].url(ofPart: 202).lastPathComponent == "x.t00")
        let upper = Self.match("/d/x.S05")
        #expect(upper[0].openedPart == 107)
        #expect(upper[0].url(ofPart: 102).lastPathComponent == "x.S00")
        #expect(upper[0].url(ofPart: 1).lastPathComponent == "x.RAR")
        #expect(Self.match("/d/x.y99")[0].openedPart == (Int(UnicodeScalar("y").value - UnicodeScalar("r").value) * 100 + 99 + 2))
        // z is a spanned zip.
        #expect(Self.match("/d/x.z01").map(\.pattern) == [.zipSpanned])
    }

    @Test func testNamingMaxPartAndNoAliasing() {
        let old = Self.match("/d/x.rar")[0]
        #expect(old.maxPart == 801)
        #expect(old.url(ofPart: 801).lastPathComponent == "x.y99")
        // Past the last name nothing maps back onto an existing name.
        var seen = Set((1...801).map { old.url(ofPart: $0).lastPathComponent })
        #expect(seen.count == 801)
        for n in 802...1000 { #expect(seen.insert(old.url(ofPart: n).lastPathComponent).inserted, "part \(n)") }
        #expect(Self.match("/d/x.7z.002")[0].maxPart == 9999)
        #expect(Self.match("/d/x.zip.0010")[0].maxPart == 9999)
        #expect(Self.match("/d/x.z02")[0].maxPart == 9999)
        #expect(Self.match("/d/x.zip")[0].maxPart == 9999)
        #expect(Self.match("/d/x.part03.rar")[0].maxPart == 9999)
        #expect(Self.match("/d/x.part003.rar")[0].maxPart == 9999)
    }

    @Test func testResolveRarOldEnumerationIsCapped() throws {
        // 801 copies of a "more volumes follow" RAR4 part fill every old-style name up to .y99: the walk
        // must stop there and report part 802 missing, not loop over aliased names forever.
        let part = try Data(contentsOf: Self.rarFixture("rar4-old.rar"))
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let naming = VolumeNaming.match(dir.appendingPathComponent("w.rar"))[0]
        var files: [String: Data] = [:]
        for n in 1...801 { files[naming.url(ofPart: n).lastPathComponent] = part }
        Fixtures.makeFiles(files, in: dir)
        do {
            let urls = try VolumeSetResolver.resolve(dir.appendingPathComponent("w.rar"))
            Issue.record("expected .missing, got \(String(describing: urls?.count)) parts")
        } catch let error as ArchiveVolumeError {
            #expect(error.reason == .missing)
            #expect(error.part == 802)
        }
    }

    @Test func testNamingNumbered() {
        let c = Self.match("/d/x.7z.002")
        #expect(c.map(\.pattern) == [.numbered(width: 3)])
        #expect(c[0].base == "x.7z")
        #expect(c[0].openedPart == 2)
        #expect(c[0].url(ofPart: 1).lastPathComponent == "x.7z.001")
        #expect(c[0].url(ofPart: 10).lastPathComponent == "x.7z.010")
        #expect(Self.match("/d/x.zip.0010").map(\.pattern) == [.numbered(width: 4)])
        #expect(Self.match("/d/x.zip.0010")[0].openedPart == 10)
        #expect(Self.match("/d/x.7z.000").isEmpty)
    }

    @Test func testNamingSpanned() {
        let z = Self.match("/d/x.z02")
        #expect(z.map(\.pattern) == [.zipSpanned])
        #expect(z[0].openedPart == 2)
        #expect(z[0].base == "x")
        #expect(z[0].url(ofPart: 1).lastPathComponent == "x.z01")
        #expect(z[0].url(ofPart: 100).lastPathComponent == "x.z100")
        #expect(Self.name(z[0].lastPartURL()) == "x.zip")

        let zip = Self.match("/d/x.zip")
        #expect(zip.map(\.pattern) == [.zipSpanned])
        #expect(zip[0].openedPart == 0)
        #expect(Self.name(zip[0].lastPartURL()) == "x.zip")
        #expect(zip[0].url(ofPart: 1).lastPathComponent == "x.z01")

        let upper = Self.match("/d/x.Z01")
        #expect(upper[0].url(ofPart: 1).lastPathComponent == "x.Z01")
        #expect(Self.name(upper[0].lastPartURL()) == "x.ZIP")
        #expect(Self.name(Self.match("/d/x.ZIP")[0].lastPartURL()) == "x.ZIP")
    }

    @Test func testNamingNone() {
        for path in ["/d/x.7z", "/d/x.part.rar", "/d/x.tar.gz", "/d/x.z", "/d/x", "/d/x.r0", "/d/x.01", "/d/x.7z.99999999999999999999"] {
            #expect(Self.match(path).isEmpty, "\(path)")
        }
    }

    // MARK: Probes

    static func rarFixture(_ name: String) -> URL { ReaderListingTests.fixture("third-party/rar-multivolume/" + name) }

    static func singleRar(_ name: String) -> URL { ReaderListingTests.fixture("third-party/rar/" + name) }

    static func setFixture(_ name: String) -> URL { ReaderListingTests.fixture("multivolume/" + name) }

    static func fileSize(_ url: URL) throws -> Int64 {
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
        return size.int64Value
    }

    typealias Info = VolumeProbe.RarVolumeInfo

    @Test func testRar5Probe() throws {
        #expect(try VolumeProbe.rar(at: Self.rarFixture("rar5-multi.part01.rar")) == Info(isVolume: true, isFirst: true, isLast: false))
        #expect(try VolumeProbe.rar(at: Self.rarFixture("rar5-multi.part02.rar")) == Info(isVolume: true, isFirst: false, isLast: false))
        #expect(try VolumeProbe.rar(at: Self.rarFixture("rar5-multi.part08.rar")) == Info(isVolume: true, isFirst: false, isLast: true))
        let single = try #require(try VolumeProbe.rar(at: Self.singleRar("rar5-compressed.rar")))
        #expect(!single.isVolume)
        #expect(single.isLast == true)
    }

    @Test func testRar5EncryptedHeadersProbeIsNil() throws {
        #expect(try VolumeProbe.rar(at: Self.singleRar("rar5-encrypted-headers.rar")) == nil)
    }

    @Test func testRar4Probe() throws {
        #expect(try VolumeProbe.rar(at: Self.rarFixture("rar4-files.part1.rar")) == Info(isVolume: true, isFirst: true, isLast: false))
        #expect(try VolumeProbe.rar(at: Self.rarFixture("rar4-files.part2.rar")) == Info(isVolume: true, isFirst: false, isLast: false))
        #expect(try VolumeProbe.rar(at: Self.rarFixture("rar4-files.part6.rar")) == Info(isVolume: true, isFirst: false, isLast: true))
        #expect(try VolumeProbe.rar(at: Self.rarFixture("rar4-multi.part0001.rar")) == Info(isVolume: true, isFirst: true, isLast: false))
        #expect(try VolumeProbe.rar(at: Self.rarFixture("rar4-multi.part0004.rar")) == Info(isVolume: true, isFirst: false, isLast: true))
        // Old-style names: the first volume is `.rar`, the rest `.r00`, `.r01`, ...
        #expect(try VolumeProbe.rar(at: Self.rarFixture("rar4-old.rar")) == Info(isVolume: true, isFirst: true, isLast: false))
        #expect(try VolumeProbe.rar(at: Self.rarFixture("rar4-old.r00")) == Info(isVolume: true, isFirst: false, isLast: false))
        #expect(try VolumeProbe.rar(at: Self.rarFixture("rar4-old.r04")) == Info(isVolume: true, isFirst: false, isLast: true))
        let single = try #require(try VolumeProbe.rar(at: Self.singleRar("rar4-basic.rar")))
        #expect(!single.isVolume)
    }

    @Test func testRar4EncryptedHeadersProbe() throws {
        // The main header is readable; everything after it is encrypted, so the end is unknown.
        #expect(try VolumeProbe.rar(at: Self.singleRar("rar4-encrypted-headers.rar")) == Info(isVolume: false, isFirst: nil, isLast: nil))
    }

    @Test func testRarProbeOnOtherFiles() throws {
        #expect(try VolumeProbe.rar(at: Self.setFixture("span.zip")) == nil)
        #expect(try VolumeProbe.rar(at: Self.setFixture("s7.7z.001")) == nil)
        let dir = Fixtures.tempDir()
        // A RAR4 signature followed by a main header claiming a 3-byte size: malformed, never a trap.
        Fixtures.makeFiles([
            "empty.rar": Data(),
            "sig4.rar": Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]),
            "bad4.rar": Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0, 0, 0x73, 0x01, 0x00, 0x03, 0x00]),
            "loop5.rar": Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00, 0, 0, 0, 0, 0x00]),
        ], in: dir)
        #expect(try VolumeProbe.rar(at: dir.appendingPathComponent("empty.rar")) == nil)
        #expect(try VolumeProbe.rar(at: dir.appendingPathComponent("sig4.rar")) == nil)
        #expect(try VolumeProbe.rar(at: dir.appendingPathComponent("bad4.rar")) == nil)
        #expect(try VolumeProbe.rar(at: dir.appendingPathComponent("loop5.rar")) == nil)
        // A volume whose block chain runs off the end of the file: the end is unknown.
        var cut = try Data(contentsOf: Self.rarFixture("rar4-files.part6.rar"))
        cut.removeLast(100)
        Fixtures.makeFiles(["cut.rar": cut], in: dir)
        #expect(try VolumeProbe.rar(at: dir.appendingPathComponent("cut.rar")) == Info(isVolume: true, isFirst: false, isLast: nil))
        #expect(throws: ArchiveError.self) { try VolumeProbe.rar(at: dir.appendingPathComponent("missing.rar")) }
    }

    @Test func testSevenZipTotalSize() throws {
        for set in ["s7", "s7e"] {
            let parts = (1...3).map { Self.setFixture("\(set).7z.00\($0)") }
            let sum = try parts.reduce(Int64(0)) { $0 + (try Self.fileSize($1)) }
            #expect(try VolumeProbe.sevenZipTotalSize(firstPart: parts[0]) == sum, "\(set)")
        }
        #expect(try VolumeProbe.sevenZipTotalSize(firstPart: Self.setFixture("span.zip")) == nil)
        let dir = Fixtures.tempDir()
        var huge = Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4, 0, 0, 0, 0])
        huge.append(Data(repeating: 0xFF, count: 16))
        huge.append(Data(count: 4))
        Fixtures.makeFiles(["huge.7z": huge, "short.7z": Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])], in: dir)
        #expect(try VolumeProbe.sevenZipTotalSize(firstPart: dir.appendingPathComponent("huge.7z")) == nil)
        #expect(try VolumeProbe.sevenZipTotalSize(firstPart: dir.appendingPathComponent("short.7z")) == nil)
    }

    @Test func testZipEOCD() throws {
        let span = try VolumeProbe.zipEOCD(at: Self.setFixture("span.zip"))
        #expect(span.found && span.diskNumber == 2)
        let spane = try VolumeProbe.zipEOCD(at: Self.setFixture("spane.zip"))
        #expect(spane.found && spane.diskNumber == 2)
        let last = try VolumeProbe.zipEOCD(at: Self.setFixture("sz.zip.003"))
        #expect(last.found && last.diskNumber == 0)
        #expect(try VolumeProbe.zipEOCD(at: Self.setFixture("sz.zip.001")).found == false)
        #expect(try VolumeProbe.zipEOCD(at: Self.setFixture("span.z01")).found == false)
        let single = try VolumeProbe.zipEOCD(at: ReaderListingTests.fixture("showcase/project.zip"))
        #expect(single.found && single.diskNumber == 0)
    }

    @Test func testZipEOCDZip64DiskNumber() throws {
        // An EOCD with disk 0xFFFF, preceded by a Zip64 record (disk 5) and its locator.
        var record = Data([0x50, 0x4B, 0x06, 0x06])
        record.append(contentsOf: [44, 0, 0, 0, 0, 0, 0, 0, 45, 0, 45, 0, 5, 0, 0, 0, 5, 0, 0, 0])
        record.append(Data(count: 32))
        var locator = Data([0x50, 0x4B, 0x06, 0x07, 5, 0, 0, 0])
        locator.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0])
        var eocd = Data([0x50, 0x4B, 0x05, 0x06, 0xFF, 0xFF, 0xFF, 0xFF])
        eocd.append(Data(repeating: 0xFF, count: 12))
        eocd.append(contentsOf: [0, 0])
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["z64.zip": record + locator + eocd], in: dir)
        let info = try VolumeProbe.zipEOCD(at: dir.appendingPathComponent("z64.zip"))
        #expect(info.found && info.diskNumber == 5)
    }

    /// A complete small zip (EOCD comment `comment`) with `leading` bytes before and `trailing` after.
    private static func zipBlob(comment: [UInt8], leading: Int, trailing: Int) -> Data {
        var d = Data(repeating: 0x41, count: leading)
        d.append(contentsOf: [0x50, 0x4B, 0x03, 0x04] + [UInt8](repeating: 0, count: 26))      // local header
        d.append(contentsOf: [0x50, 0x4B, 0x01, 0x02] + [UInt8](repeating: 0, count: 42))      // central entry
        d.append(contentsOf: [0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 1, 0, 1, 0, 46, 0, 0, 0, 30, 0, 0, 0])
        d.append(contentsOf: [UInt8(comment.count), 0])
        d.append(contentsOf: comment)
        d.append(Data(repeating: 0x42, count: trailing))
        return d
    }

    @Test func testZipEOCDRejectsTrailingDataAfterEOCD() throws {
        // A stored inner zip inside a non-final part: its EOCD is in the tail, with data after it.
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Fixtures.makeFiles([
            "inner.zip.001": Self.zipBlob(comment: [], leading: 100, trailing: 500),
            "trail1.zip": Self.zipBlob(comment: [], leading: 0, trailing: 1),
        ], in: dir)
        #expect(try VolumeProbe.zipEOCD(at: dir.appendingPathComponent("inner.zip.001")).found == false)
        #expect(try VolumeProbe.zipEOCD(at: dir.appendingPathComponent("trail1.zip")).found == false)
    }

    @Test func testZipEOCDCommentEndingAtEOFIsFound() throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Fixtures.makeFiles([
            "comment.zip": Self.zipBlob(comment: Array("hello".utf8), leading: 10, trailing: 0),
            "plain.zip": Self.zipBlob(comment: [], leading: 10, trailing: 0),
        ], in: dir)
        for name in ["comment.zip", "plain.zip"] {
            let info = try VolumeProbe.zipEOCD(at: dir.appendingPathComponent(name))
            #expect(info.found && info.diskNumber == 0)
        }
    }

    // MARK: Resolver

    /// Every set: the directory under Fixtures/ and its parts in read order.
    static let sets: [(name: String, dir: String, parts: [String])] = [
        ("rar5", "third-party/rar-multivolume", (1...8).map { "rar5-multi.part0\($0).rar" }),
        ("rar4-multi", "third-party/rar-multivolume", (1...4).map { "rar4-multi.part000\($0).rar" }),
        ("rar4-files", "third-party/rar-multivolume", (1...6).map { "rar4-files.part\($0).rar" }),
        ("rar4-old", "third-party/rar-multivolume", ["rar4-old.rar"] + (0...4).map { "rar4-old.r0\($0)" }),
        ("s7", "multivolume", (1...3).map { "s7.7z.00\($0)" }),
        ("s7e", "multivolume", (1...3).map { "s7e.7z.00\($0)" }),
        ("sz", "multivolume", (1...3).map { "sz.zip.00\($0)" }),
        ("span", "multivolume", ["span.z01", "span.z02", "span.zip"]),
        ("spane", "multivolume", ["spane.z01", "spane.z02", "spane.zip"]),
    ]

    static func set(_ name: String) -> (dir: String, parts: [String]) {
        let s = sets.first { $0.name == name }!
        return (s.dir, s.parts)
    }

    /// Copies `names` of the fixture folder `fixtureDir` into a fresh temp dir; returns the temp dir.
    static func copy(_ names: [String], from fixtureDir: String, as renamed: [String: String] = [:]) throws -> URL {
        let dir = Fixtures.tempDir()
        for name in names {
            try FileManager.default.copyItem(at: ReaderListingTests.fixture(fixtureDir + "/" + name),
                                             to: dir.appendingPathComponent(renamed[name] ?? name))
        }
        return dir
    }

    /// Copies set `name`, leaving out `without`.
    static func copySet(_ name: String, without: Set<String> = []) throws -> URL {
        let s = set(name)
        return try copy(s.parts.filter { !without.contains($0) }, from: s.dir)
    }

    static func resolvedNames(_ url: URL) throws -> [String]? {
        try VolumeSetResolver.resolve(url)?.map(\.lastPathComponent)
    }

    /// Resolving `opened` throws an `ArchiveVolumeError` with these fields; `folder` is `opened`'s parent.
    static func expectVolumeError(_ opened: URL, _ reason: ArchiveVolumeError.Reason, part: Int?, fileName: String,
                                  setName: String, openedPart: Int,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            let urls = try VolumeSetResolver.resolve(opened)
            Issue.record("expected \(reason) part \(String(describing: part)), got \(String(describing: urls?.map(\.lastPathComponent)))",
                         sourceLocation: sourceLocation)
        } catch let error as ArchiveVolumeError {
            #expect(error.reason == reason, sourceLocation: sourceLocation)
            #expect(error.part == part, sourceLocation: sourceLocation)
            #expect(error.fileName == fileName, sourceLocation: sourceLocation)
            #expect(error.setName == setName, sourceLocation: sourceLocation)
            #expect(error.openedPart == openedPart, sourceLocation: sourceLocation)
            #expect(error.folder.standardizedFileURL.path == opened.deletingLastPathComponent().standardizedFileURL.path,
                    sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func testResolveEachSetFromEveryPart() throws {
        for s in Self.sets {
            let dir = try Self.copySet(s.name)
            defer { try? FileManager.default.removeItem(at: dir) }
            let expected = s.parts.map { dir.appendingPathComponent($0).path }
            for opened in [s.parts.first!, s.parts[s.parts.count / 2], s.parts.last!] {
                let urls = try VolumeSetResolver.resolve(dir.appendingPathComponent(opened))
                #expect(urls?.map(\.path) == expected, "\(s.name) opened at \(opened)")
            }
        }
    }

    @Test func testMissingLastPart() throws {
        let rar5 = try Self.copySet("rar5", without: ["rar5-multi.part08.rar"])
        defer { try? FileManager.default.removeItem(at: rar5) }
        Self.expectVolumeError(rar5.appendingPathComponent("rar5-multi.part01.rar"), .missing, part: 8,
                               fileName: "rar5-multi.part08.rar", setName: "rar5-multi.part01.rar", openedPart: 1)

        let rar4 = try Self.copySet("rar4-files", without: ["rar4-files.part6.rar"])
        defer { try? FileManager.default.removeItem(at: rar4) }
        Self.expectVolumeError(rar4.appendingPathComponent("rar4-files.part3.rar"), .missing, part: 6,
                               fileName: "rar4-files.part6.rar", setName: "rar4-files.part1.rar", openedPart: 3)

        let s7 = try Self.copySet("s7", without: ["s7.7z.003"])
        defer { try? FileManager.default.removeItem(at: s7) }
        Self.expectVolumeError(s7.appendingPathComponent("s7.7z.001"), .missing, part: 3,
                               fileName: "s7.7z.003", setName: "s7.7z.001", openedPart: 1)
        Self.expectVolumeError(s7.appendingPathComponent("s7.7z.002"), .missing, part: 3,
                               fileName: "s7.7z.003", setName: "s7.7z.001", openedPart: 2)

        let sz = try Self.copySet("sz", without: ["sz.zip.003"])
        defer { try? FileManager.default.removeItem(at: sz) }
        Self.expectVolumeError(sz.appendingPathComponent("sz.zip.002"), .missing, part: 3,
                               fileName: "sz.zip.003", setName: "sz.zip.001", openedPart: 2)
    }

    @Test func testMissingMiddlePart() throws {
        let dir = try Self.copySet("rar5", without: ["rar5-multi.part04.rar"])
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.expectVolumeError(dir.appendingPathComponent("rar5-multi.part02.rar"), .missing, part: 4,
                               fileName: "rar5-multi.part04.rar", setName: "rar5-multi.part01.rar", openedPart: 2)
        // Opened past the gap: the gap comes before the opened part.
        Self.expectVolumeError(dir.appendingPathComponent("rar5-multi.part06.rar"), .missing, part: 4,
                               fileName: "rar5-multi.part04.rar", setName: "rar5-multi.part01.rar", openedPart: 6)
        // The `missing/` fixture: s7 without .002, opened at .003.
        let s7 = try Self.copy(["s7.7z.001", "s7.7z.003"], from: "multivolume/missing")
        defer { try? FileManager.default.removeItem(at: s7) }
        Self.expectVolumeError(s7.appendingPathComponent("s7.7z.003"), .missing, part: 2,
                               fileName: "s7.7z.002", setName: "s7.7z.001", openedPart: 3)
        Self.expectVolumeError(s7.appendingPathComponent("s7.7z.001"), .missing, part: 2,
                               fileName: "s7.7z.002", setName: "s7.7z.001", openedPart: 1)
    }

    @Test func testMissingFirstPartFromMiddle() throws {
        // Issue case: "RAR5 from part02 drops the first file".
        let dir = try Self.copySet("rar5", without: ["rar5-multi.part01.rar"])
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.expectVolumeError(dir.appendingPathComponent("rar5-multi.part03.rar"), .missing, part: 1,
                               fileName: "rar5-multi.part01.rar", setName: "rar5-multi.part01.rar", openedPart: 3)
        Self.expectVolumeError(dir.appendingPathComponent("rar5-multi.part02.rar"), .missing, part: 1,
                               fileName: "rar5-multi.part01.rar", setName: "rar5-multi.part01.rar", openedPart: 2)
    }

    @Test func testRar4Part1Alone() throws {
        let dir = try Self.copy(["rar4-files.part1.rar"], from: "third-party/rar-multivolume")
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.expectVolumeError(dir.appendingPathComponent("rar4-files.part1.rar"), .missing, part: 2,
                               fileName: "rar4-files.part2.rar", setName: "rar4-files.part1.rar", openedPart: 1)
    }

    @Test func testSpannedWithoutZip() throws {
        let dir = try Self.copySet("span", without: ["span.zip"])
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.expectVolumeError(dir.appendingPathComponent("span.z01"), .missing, part: nil,
                               fileName: "span.zip", setName: "span.zip", openedPart: 1)
    }

    @Test func testSpannedWithoutZ01() throws {
        // The `missing/` fixture: span.z02 + span.zip.
        let dir = try Self.copy(["span.z02", "span.zip"], from: "multivolume/missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        Self.expectVolumeError(dir.appendingPathComponent("span.zip"), .missing, part: 1,
                               fileName: "span.z01", setName: "span.zip", openedPart: 0)
        Self.expectVolumeError(dir.appendingPathComponent("span.z02"), .missing, part: 1,
                               fileName: "span.z01", setName: "span.zip", openedPart: 2)
    }

    @Test func testUnreadablePartIsNoAccess() throws {
        let dir = try Self.copySet("rar5")
        let part2 = dir.appendingPathComponent("rar5-multi.part02.rar")
        defer {
            chmod(part2.path, 0o644)
            try? FileManager.default.removeItem(at: dir)
        }
        #expect(chmod(part2.path, 0) == 0)
        Self.expectVolumeError(dir.appendingPathComponent("rar5-multi.part01.rar"), .noAccess, part: 2,
                               fileName: "rar5-multi.part02.rar", setName: "rar5-multi.part01.rar", openedPart: 1)

        let s7 = try Self.copySet("s7")
        let s7part2 = s7.appendingPathComponent("s7.7z.002")
        defer {
            chmod(s7part2.path, 0o644)
            try? FileManager.default.removeItem(at: s7)
        }
        #expect(chmod(s7part2.path, 0) == 0)
        Self.expectVolumeError(s7.appendingPathComponent("s7.7z.003"), .noAccess, part: 2,
                               fileName: "s7.7z.002", setName: "s7.7z.001", openedPart: 3)
    }

    @Test func testNonVolumeNamedLikePartOpensSingle() throws {
        let dir = try Self.copy(["rar5-compressed.rar", "rar4-basic.rar"], from: "third-party/rar",
                                as: ["rar5-compressed.rar": "report.part1.rar", "rar4-basic.rar": "notes.part01.rar"])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try VolumeSetResolver.resolve(dir.appendingPathComponent("report.part1.rar")) == nil)
        #expect(try VolumeSetResolver.resolve(dir.appendingPathComponent("notes.part01.rar")) == nil)
        // A plain single RAR (old-naming candidate) with an unrelated `.r00` beside it.
        let plain = try Self.copy(["rar5-compressed.rar"], from: "third-party/rar", as: ["rar5-compressed.rar": "x.rar"])
        defer { try? FileManager.default.removeItem(at: plain) }
        Fixtures.makeFiles(["x.r00": Data("garbage".utf8)], in: plain)
        #expect(try VolumeSetResolver.resolve(plain.appendingPathComponent("x.rar")) == nil)
        // Not a volume name at all.
        #expect(try VolumeSetResolver.resolve(ReaderListingTests.fixture("7z/lzma2.7z")) == nil)
    }

    @Test func testPlainZipIgnoresZ01Sibling() throws {
        let dir = try Self.copy(["project.zip"], from: "showcase", as: ["project.zip": "x.zip"])
        defer { try? FileManager.default.removeItem(at: dir) }
        Fixtures.makeFiles(["x.z01": Data(repeating: 0x5A, count: 4096)], in: dir)
        #expect(try VolumeSetResolver.resolve(dir.appendingPathComponent("x.zip")) == nil)
        // Opened at the stray .z01: the .zip says it is a single-disk zip, so the .z01 is no part of it.
        #expect(try VolumeSetResolver.resolve(dir.appendingPathComponent("x.z01")) == nil)
    }

    @Test func testRarOldNaming() throws {
        let dir = try Self.copySet("rar4-old")
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = try Self.resolvedNames(dir.appendingPathComponent("rar4-old.r02"))
        #expect(names == ["rar4-old.rar", "rar4-old.r00", "rar4-old.r01", "rar4-old.r02", "rar4-old.r03", "rar4-old.r04"])
        let short = try Self.copySet("rar4-old", without: ["rar4-old.r04"])
        defer { try? FileManager.default.removeItem(at: short) }
        Self.expectVolumeError(short.appendingPathComponent("rar4-old.r02"), .missing, part: 6,
                               fileName: "rar4-old.r04", setName: "rar4-old.rar", openedPart: 4)
    }

    @Test func testNumberedSingleParts() throws {
        // A complete 7z or zip as a lone `.001` opens as a set of one; anything else falls through (nil).
        let dir = try Self.copy(["lzma2.7z"], from: "7z", as: ["lzma2.7z": "one.7z.001"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: ReaderListingTests.fixture("showcase/project.zip"),
                                         to: dir.appendingPathComponent("one.zip.001"))
        Fixtures.makeFiles(["one.bin.001": Data("plain bytes".utf8),
                            "two.tar.001": Data("first half".utf8), "two.tar.002": Data("second half".utf8)], in: dir)
        #expect(try Self.resolvedNames(dir.appendingPathComponent("one.7z.001")) == ["one.7z.001"])
        #expect(try Self.resolvedNames(dir.appendingPathComponent("one.zip.001")) == ["one.zip.001"])
        #expect(try VolumeSetResolver.resolve(dir.appendingPathComponent("one.bin.001")) == nil)
        // Neither 7z nor zip: completeness cannot be checked, so the parts found are the set.
        #expect(try Self.resolvedNames(dir.appendingPathComponent("two.tar.002")) == ["two.tar.001", "two.tar.002"])
    }

    @Test func testLoneNumberedFileWithoutInnerExtensionOpensSingle() async throws {
        // A renamed single tar (`x.2024`, `scan.100`, `data.007`) is not a split set: open it alone.
        let original = ReaderListingTests.fixture("tar/macos-bsdtar.tar")
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = try await Archive.open(at: original, password: nil)
        for name in ["x.2024", "scan.100", "data.007"] {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.copyItem(at: original, to: url)
            #expect(try VolumeSetResolver.resolve(url) == nil, "\(name)")
        }
        let url = dir.appendingPathComponent("x.2024")
        let reader = try await Archive.open(at: url, password: nil)
        #expect(reader.volumeURLs == [url])
        #expect(reader.entries.map(\.path) == expected.entries.map(\.path))
        #expect(!reader.entries.isEmpty)
    }

    @Test func testLoneNumberedPartWithInnerExtensionIsMissingPart1() throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Fixtures.makeFiles(["Photos.7z.002": Data("second half".utf8)], in: dir)
        Self.expectVolumeError(dir.appendingPathComponent("Photos.7z.002"), .missing, part: 1,
                               fileName: "Photos.7z.001", setName: "Photos.7z.001", openedPart: 2)
    }

    @Test func testSpannedOpenedPastItsDiskCount() throws {
        // span.zip says 3 disks; a stray span.z05 beside it is no part of that set.
        let dir = try Self.copySet("span")
        defer { try? FileManager.default.removeItem(at: dir) }
        Fixtures.makeFiles(["span.z05": Data(repeating: 1, count: 100)], in: dir)
        #expect(try VolumeSetResolver.resolve(dir.appendingPathComponent("span.z05")) == nil)
        #expect(try Self.resolvedNames(dir.appendingPathComponent("span.zip")) == ["span.z01", "span.z02", "span.zip"])
    }
}

// MARK: - End to end (the reader takes every part)

extension MultiVolumeTests {
    /// One entry of a set in Fixtures/multivolume/EXPECTED.json.
    struct ExpectedEntry {
        let path: String
        let isDirectory: Bool
        let size: Int64?
        let sha256: String?
        let crc32: String?
        let isSymlink: Bool
    }

    /// EXPECTED.json's entries and password for test set `name` (the `sets` names; "rar5" is "rar5-multi").
    static func expected(_ name: String) throws -> (entries: [ExpectedEntry], password: String?) {
        let data = try Data(contentsOf: ReaderListingTests.fixture("multivolume/EXPECTED.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sets = try #require(root["sets"] as? [String: Any])
        let set = try #require(sets[name == "rar5" ? "rar5-multi" : name] as? [String: Any])
        let entries = try #require(set["entries"] as? [[String: Any]]).map { e in
            ExpectedEntry(path: e["path"] as! String, isDirectory: e["dir"] as! Bool,
                          size: (e["size"] as? NSNumber)?.int64Value, sha256: e["sha256"] as? String,
                          crc32: e["crc32"] as? String, isSymlink: e["symlink"] as? Bool ?? false)
        }
        return (entries, set["password"] as? String)
    }

    static func crc32(of url: URL) throws -> String {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in try Data(contentsOf: url) { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return String(format: "%08X", crc ^ 0xFFFF_FFFF)
    }

    /// The reader lists exactly the expected files (path, size) and every expected folder; any other
    /// folder is a synthesized ancestor. EXPECTED.json gives a symlink its target length; the reader
    /// reports it as libarchive does (0), so a symlink's size is not compared.
    static func expectListing(_ reader: any ArchiveReading, _ expected: [ExpectedEntry], _ label: String,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let files = reader.entries.filter { !$0.isDirectory }
        let links = Set(expected.filter(\.isSymlink).map(\.path))
        #expect(Dictionary(uniqueKeysWithValues: files.map { ($0.path, links.contains($0.path) ? nil : $0.size) })
                == Dictionary(uniqueKeysWithValues: expected.filter { !$0.isDirectory }
                    .map { ($0.path, $0.isSymlink ? nil : $0.size) }),
                "\(label)", sourceLocation: sourceLocation)
        let dirs = Set(reader.entries.filter(\.isDirectory).map(\.path))
        #expect(Set(expected.filter(\.isDirectory).map(\.path)).isSubset(of: dirs), "\(label)",
                sourceLocation: sourceLocation)
        for d in dirs {
            #expect(files.contains { $0.path.hasPrefix(d + "/") } || expected.contains { $0.path == d },
                    "\(label): unexpected folder \(d)", sourceLocation: sourceLocation)
        }
    }

    @Test func testOpenListsWholeSetFromAnyPart() async throws {
        for s in Self.sets {
            let (expected, password) = try Self.expected(s.name)
            let dir = ReaderListingTests.fixture(s.dir)
            for opened in [s.parts.first!, s.parts[s.parts.count / 2], s.parts.last!] {
                let url = dir.appendingPathComponent(opened)
                let label = "\(s.name) opened at \(opened)"
                let reader = try await Archive.open(at: url, password: password)
                Self.expectListing(reader, expected, label)
                #expect(reader.volumeURLs.map(\.path) == (try VolumeSetResolver.resolve(url))?.map(\.path), "\(label)")
                #expect(reader.volumeURLs.map(\.lastPathComponent) == s.parts, "\(label)")
                #expect(reader.url == url, "\(label)")
            }
        }
    }

    @Test func testSingleFileVolumeURLsIsItself() async throws {
        let url = ReaderListingTests.fixture("showcase/project.zip")
        let reader = try await Archive.open(at: url)
        #expect(reader.volumeURLs == [url])
    }

    @Test func testExtractIdenticalBytes() async throws {
        for s in Self.sets where s.name != "rar4-multi" {
            let (expected, password) = try Self.expected(s.name)
            let opened = ReaderListingTests.fixture(s.dir).appendingPathComponent(s.parts[s.parts.count / 2])
            let reader = try await Archive.open(at: opened, password: password)
            let out = Fixtures.tempDir()
            defer { try? FileManager.default.removeItem(at: out) }
            try await reader.extract(nil, to: out, progress: nil)
            for e in expected where !e.isDirectory {
                try Self.expectBytes(out.appending(path: e.path), e, "\(s.name)")
            }
            // Quick Look's path: the entry whose data ends the set.
            let last = try #require(expected.last { !$0.isDirectory }, "\(s.name)")
            try Self.expectBytes(try await reader.extractToTemporaryFile(last.path), last, "\(s.name) temporary")
        }
    }

    /// `file` has `e`'s size and SHA-256 (rar5-multi: CRC-32).
    static func expectBytes(_ file: URL, _ e: ExpectedEntry, _ label: String,
                            sourceLocation: SourceLocation = #_sourceLocation) throws {
        if let sha = e.sha256 {
            #expect(try sha256(of: file) == sha, "\(label): \(e.path)", sourceLocation: sourceLocation)
        } else if let crc = e.crc32 {
            #expect(try Self.crc32(of: file) == crc, "\(label): \(e.path)", sourceLocation: sourceLocation)
        } else {
            Issue.record("\(label): \(e.path) has no checksum", sourceLocation: sourceLocation)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        #expect(size == e.size, "\(label): \(e.path)", sourceLocation: sourceLocation)
    }

    @Test func testEncryptedSevenZipSet() async throws {
        let s = Self.set("s7e")
        let (expected, _) = try Self.expected("s7e")
        let dir = ReaderListingTests.fixture(s.dir)
        for opened in s.parts {
            let url = dir.appendingPathComponent(opened)
            await #expect(throws: ArchiveError.passwordRequired) { _ = try await Archive.open(at: url) }
            await #expect(throws: ArchiveError.passwordRequired) {
                _ = try await Archive.previewListing(at: url, limit: 10)
            }
            await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "nope") }
        }
        let reader = try await Archive.open(at: dir.appendingPathComponent(s.parts[2]), password: "kernir")
        Self.expectListing(reader, expected, "s7e")
        #expect(reader.isEncrypted)
        let out = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: out) }
        try await reader.extract(nil, to: out, progress: nil)
        for e in expected where !e.isDirectory {
            #expect(try sha256(of: out.appending(path: e.path)) == e.sha256, "\(e.path)")
        }
    }

    @Test func testZipFactsFromCentralDirectoryPart() async throws {
        // The central directory sits in the set's last part: the probe reads it there, so the facts are
        // exact (the header-flag fallback would say AES-256 and no method).
        let dir = ReaderListingTests.fixture("multivolume")
        for opened in ["spane.z01", "spane.zip"] {
            let spane = try await Archive.open(at: dir.appendingPathComponent(opened), password: "kernir")
            #expect(spane.isEncrypted)
            #expect(spane.encryption == .zipCrypto, "\(opened)")
            #expect(spane.compressionMethod == .deflate, "\(opened)")
            await #expect(throws: ArchiveError.wrongPassword) {
                _ = try await Archive.open(at: dir.appendingPathComponent(opened), password: "nope")
            }
        }
        let span = try await Archive.open(at: dir.appendingPathComponent("span.z02"))
        #expect(span.encryption == ArchiveEncryption.none)
        #expect(span.compressionMethod == .deflate)
        let sz = try await Archive.open(at: dir.appendingPathComponent("sz.zip.001"))
        #expect(sz.encryption == ArchiveEncryption.none)
        #expect(sz.compressionMethod == .store)
    }

    /// A one-entry zip whose EOCD says it is disk `thisDisk` and its central directory starts on disk
    /// `cdDisk` at offset 0. The entry is ZipCrypto-encrypted deflate.
    static func diskZip(thisDisk: UInt16, cdDisk: UInt16) -> Data {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { le16(UInt16(v & 0xFFFF)) + le16(UInt16(v >> 16)) }
        var central: [UInt8] = [0x50, 0x4B, 0x01, 0x02] + le16(20) + le16(20) + le16(1) + le16(8)
        central += le16(0) + le16(0) + le32(0) + le32(17) + le32(5) + le16(1) + le16(0) + le16(0)
        central += le16(0) + le16(0) + le32(0) + le32(0) + [UInt8(ascii: "a")]
        var eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + le16(thisDisk) + le16(cdDisk) + le16(1) + le16(1)
        eocd += le32(UInt32(central.count)) + le32(0) + le16(0)
        return Data(central + eocd)
    }

    @Test func testZipProbeRefusesDirectoryOnAnotherDisk() throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Fixtures.makeFiles(["same.bin": Self.diskZip(thisDisk: 2, cdDisk: 2),
                            "other.bin": Self.diskZip(thisDisk: 2, cdDisk: 1)], in: dir)
        // Same disk: offsets are relative to this file, so the directory is read.
        #expect(try ZipEncryptionProbe.detect(at: dir.appendingPathComponent("same.bin")).encryption == .zipCrypto)
        // Another disk: the offset points into a different file; reading it here would misreport.
        #expect(throws: ArchiveError.self) {
            _ = try ZipEncryptionProbe.detect(at: dir.appendingPathComponent("other.bin"))
        }
    }

    @Test func testPreviewListingWholeSet() async throws {
        for name in ["s7", "span", "rar5", "sz"] {
            let s = Self.set(name)
            let last = ReaderListingTests.fixture(s.dir).appendingPathComponent(s.parts.last!)
            let reader = try await Archive.open(at: last)
            let visible = reader.entries.filter { !$0.isMacOSMetadata }
            let preview = try await Archive.previewListing(at: last, limit: 100)
            #expect(preview.visibleEntryCount == visible.count, "\(name)")
            #expect(preview.visibleFileSize == visible.filter { !$0.isDirectory }.reduce(0) { $0 + ($1.size ?? 0) },
                    "\(name)")
            #expect(preview.format == reader.format, "\(name)")
        }
    }

    @Test func testPreviewListingMissingPart() async throws {
        let s7 = try Self.copy(["s7.7z.001", "s7.7z.003"], from: "multivolume/missing")
        defer { try? FileManager.default.removeItem(at: s7) }
        let span = try Self.copy(["span.z02", "span.zip"], from: "multivolume/missing")
        defer { try? FileManager.default.removeItem(at: span) }
        for (url, part) in [(s7.appendingPathComponent("s7.7z.001"), 2), (s7.appendingPathComponent("s7.7z.003"), 2),
                            (span.appendingPathComponent("span.zip"), 1)] {
            for open in [true, false] {
                do {
                    if open {
                        _ = try await Archive.open(at: url)
                    } else {
                        _ = try await Archive.previewListing(at: url, limit: 10)
                    }
                    Issue.record("\(url.lastPathComponent) (open: \(open)) did not throw")
                } catch let error as ArchiveVolumeError {
                    #expect(error.reason == .missing, "\(url.lastPathComponent)")
                    #expect(error.part == part, "\(url.lastPathComponent)")
                } catch {
                    Issue.record("\(url.lastPathComponent) (open: \(open)): unexpected \(error)")
                }
            }
        }
    }

    @Test func testPartChangedAfterOpen() async throws {
        for name in ["s7", "span"] {
            let dir = try Self.copySet(name)
            defer { try? FileManager.default.removeItem(at: dir) }
            let parts = Self.set(name).parts
            let reader = try await Archive.open(at: dir.appendingPathComponent(parts[0]))
            let handle = try FileHandle(forWritingTo: dir.appendingPathComponent(parts[1]))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
            let out = Fixtures.tempDir()
            defer { try? FileManager.default.removeItem(at: out) }
            await #expect(throws: ArchiveError.io("archive changed on disk"), "\(name)") {
                try await reader.extract(nil, to: out, progress: nil)
            }
            await #expect(throws: ArchiveError.io("archive changed on disk"), "\(name)") {
                _ = try await reader.extractToTemporaryFile("gamma.bin")
            }
        }
    }

    /// Zeroes the 24 bytes that end at the last non-zero byte of `url`. RAR volumes are padded with zeros
    /// after their end-of-archive header (RAR4: 20 bytes, RAR5: 8), so this wipes that header.
    static func wipeEndHeader(_ url: URL) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        let last = try #require(bytes.lastIndex { $0 != 0 })
        for i in max(0, last - 23)...last { bytes[i] = 0 }
        try Data(bytes).write(to: url)
    }

    @Test func testNoPartialListWhenLastPartHeaderUnreadable() async throws {
        // The last parts are gone and the new last part's end header is wiped, so VolumeProbe cannot tell
        // whether more parts follow (isLast nil) and the resolver accepts the parts it found. libarchive
        // then runs out of data inside the set: open and preview must fail, never list part of it.
        let cases: [(set: String, keep: Int)] = [("rar5", 7), ("rar4-files", 5), ("rar5", 3), ("rar4-files", 2)]
        for c in cases {
            let s = Self.set(c.set)
            let (expected, _) = try Self.expected(c.set)
            let dir = try Self.copySet(c.set, without: Set(s.parts.dropFirst(c.keep)))
            defer { try? FileManager.default.removeItem(at: dir) }
            let newLast = dir.appendingPathComponent(s.parts[c.keep - 1])
            try Self.wipeEndHeader(newLast)
            let label = "\(c.set) with \(c.keep) parts"
            #expect(try VolumeProbe.rar(at: newLast)?.isLast == nil, "\(label)")
            let opened = dir.appendingPathComponent(s.parts[0])
            #expect(try VolumeSetResolver.resolve(opened)?.count == c.keep, "\(label)")
            do {
                let reader = try await Archive.open(at: opened)
                Issue.record("\(label): open listed \(reader.entries.map(\.path)) of \(expected.map(\.path))")
            } catch {
                #expect(error is ArchiveError || error is ArchiveVolumeError, "\(label): \(error)")
            }
            do {
                let preview = try await Archive.previewListing(at: opened, limit: 100)
                Issue.record("\(label): preview listed \(preview.entries.map(\.path)) of \(expected.map(\.path))")
            } catch {
                #expect(error is ArchiveError || error is ArchiveVolumeError, "\(label): \(error)")
            }
        }
    }

    @Test func testDetectFormatFromAnyPart() throws {
        // Like open, detection reads the whole set: a spanned zip's `.zip` (the part a person opens) or a
        // `.7z.002` alone has no recognizable start. With a part missing it reads the given file alone.
        let formats: [String: ArchiveFormat] = ["rar5": .rar, "rar4-multi": .rar, "rar4-files": .rar, "rar4-old": .rar,
                                                "s7": .sevenZip, "s7e": .sevenZip, "sz": .zip, "span": .zip, "spane": .zip]
        for s in Self.sets {
            for part in s.parts {
                let url = ReaderListingTests.fixture(s.dir).appendingPathComponent(part)
                #expect(Archive.detectFormat(at: url) == formats[s.name], "\(s.name): \(part)")
            }
        }
        let missing = ReaderListingTests.fixture("multivolume/missing")
        #expect(Archive.detectFormat(at: missing.appendingPathComponent("s7.7z.001")) == .sevenZip)
        #expect(Archive.detectFormat(at: missing.appendingPathComponent("span.zip")) == nil)
    }

    @Test func testSaveAsFromSet() async throws {
        // A set is read-only, but Save As copies it into a single archive of a writable format.
        for (name, format) in [("s7", ArchiveFormat.zip), ("span", .sevenZip)] {
            let s = Self.set(name)
            let (expected, _) = try Self.expected(name)
            let source = try await Archive.open(at: ReaderListingTests.fixture(s.dir).appendingPathComponent(s.parts[1]))
            let scratch = Fixtures.tempDir()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let saved = scratch.appendingPathComponent("saved.\(format.fileExtension)")
            try await ArchiveWriter.write(source: source, changes: .init(), format: format, to: saved, options: nil)
            let label = "\(name) saved as \(format)"
            let reopened = try await Archive.open(at: saved)
            #expect(reopened.format == format, "\(label)")
            #expect(reopened.volumeURLs == [saved], "\(label)")
            Self.expectListing(reopened, expected, label)
            #expect(Set(reopened.entries.map(\.path)) == Set(source.entries.map(\.path)), "\(label)")
            let out = scratch.appendingPathComponent("out")
            try await reopened.extract(nil, to: out, progress: nil)
            for e in expected where !e.isDirectory {
                try Self.expectBytes(out.appending(path: e.path), e, label)
            }
        }
    }

    /// The bytes of every file in `dir`, by name.
    static func contents(of dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            out[name] = try Data(contentsOf: dir.appendingPathComponent(name))
        }
        return out
    }

    @Test func testSaveOntoPartRefused() async throws {
        // Writing over a part would destroy the set being read: refused before anything is written,
        // however the part is named. A save beside the parts still works.
        for name in ["s7", "span"] {
            let s = Self.set(name)
            let dir = try Self.copySet(name)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = try await Archive.open(at: dir.appendingPathComponent(s.parts[0]))
            let format = source.format
            let part = source.volumeURLs[1]
            let other: ArchiveFormat = format == .zip ? .sevenZip : .zip
            let before = try Self.contents(of: dir)

            let links = Fixtures.tempDir()
            defer { try? FileManager.default.removeItem(at: links) }
            let linkedFile = links.appendingPathComponent("link.\(format.fileExtension)")
            try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: part)
            let linkedDir = links.appendingPathComponent("dir")
            try FileManager.default.createSymbolicLink(at: linkedDir, withDestinationURL: dir)
            let hardLink = links.appendingPathComponent("hard")
            try FileManager.default.linkItem(at: part, to: hardLink)

            var targets: [(URL, ArchiveFormat, String)] = [
                (part, format, "the part"),
                (part, other, "the part, other format"),
                (source.volumeURLs.last!, format, "the last part"),
                (URL(fileURLWithPath: dir.path + "/./sub/../" + part.lastPathComponent), format, "dotted path"),
                (linkedFile, format, "symlink to the part"),
                (linkedDir.appendingPathComponent(part.lastPathComponent), format, "path through a linked folder"),
                (hardLink, format, "hard link to the part"),
            ]
            if name == "s7" { targets.append((source.url, format, "the opened part")) }
            let upper = dir.appendingPathComponent(part.lastPathComponent.uppercased())
            if FileManager.default.fileExists(atPath: upper.path) {   // a case-insensitive volume
                targets.append((upper, format, "other case"))
            }
            for (target, format, label) in targets {
                await #expect(throws: ArchiveError.readOnlyFormat(source.format), "\(name): \(label)") {
                    try await ArchiveWriter.write(source: source, changes: .init(), format: format, to: target,
                                                  options: nil)
                }
            }
            #expect(try Self.contents(of: dir) == before, "\(name): the parts changed")

            // A part that vanished after open: its path is still the set's, even through a linked folder.
            let last = source.volumeURLs.last!
            try FileManager.default.removeItem(at: last)
            for target in [last, linkedDir.appendingPathComponent(last.lastPathComponent)] {
                await #expect(throws: ArchiveError.readOnlyFormat(source.format), "\(name): \(target.path)") {
                    try await ArchiveWriter.write(source: source, changes: .init(), format: format, to: target,
                                                  options: nil)
                }
            }
            #expect(!FileManager.default.fileExists(atPath: last.path), "\(name)")
        }

        // Next to the parts is fine, and an in-place save of a single file is unchanged.
        let dir = try Self.copySet("s7")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await Archive.open(at: dir.appendingPathComponent("s7.7z.001"))
        let beside = dir.appendingPathComponent("s7.7z")
        try await ArchiveWriter.write(source: source, changes: .init(), format: .sevenZip, to: beside, options: nil)
        let single = try await Archive.open(at: beside)
        #expect(single.volumeURLs == [beside])
        try await ArchiveWriter.write(source: single, changes: .init(removedPaths: ["gamma.bin"]), format: .sevenZip,
                                      to: beside, options: nil)
        #expect(try await Archive.open(at: beside).entries.contains { $0.path == "gamma.bin" } == false)
    }
}
