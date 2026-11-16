import Compression
import Foundation
import Testing
@testable import KernirCore

/// libarchive's xar reader inflates and parses the whole XML TOC before it returns the first header, and builds every
/// entry's full pathname by copying its parent's, so no Swift-side limit came in time: a 13.6 KB xar of 4,000 nested
/// folders cost 2.6 GB and 12-21 s. Kernir patch 0015 refuses, while the TOC is parsed, an entry more than 200 levels
/// deep, a pathname or link target over 65,536 bytes, pathnames and link targets over 256 MiB in all, and hardlink
/// target copies that would take that total past 256 MiB (patch 0016 grows it past 524,288 files and caps their count:
/// EntryCountLimitTests). The reader turns each refusal into the `ArchiveNestingError`
/// the Swift-side limit for the same thing throws (`PatchedNameRefusal`).
@Suite("xar TOC limits", .serialized)
struct XarTOCLimitTests {
    static let depthMessage = "xar entry nests more than 200 directories deep"
    static let nameMessage = "xar entry name is longer than 65536 bytes"
    static let linkMessage = "xar link target is longer than 65536 bytes"
    static let totalMessage = "xar entry names and link targets take more than the names limit"
    static let hardlinkMessage = "xar hardlink targets take the entry names past the names limit"
    /// Patch 0020: an <ea>'s <name> over 65,536 bytes.
    static let eaNameMessage = "xar extended attribute name is longer than 65536 bytes"

    static let totalLimit = 256 << 20
    static let meta = "<type>directory</type><mode>0755</mode>"
    static let bare = "<type>directory</type>"

    // MARK: - Building xar TOCs

    /// An uncompressed TOC. libarchive inflates it 64 KiB at a time and expat splits text at those boundaries; patch
    /// 0017 joins the pieces (XarNameCharDataTests), and `text` still pads a name that would cross one to the next
    /// boundary, so each limit here is reached by a name handed over in one piece.
    struct TOC {
        static let chunk = 1 << 16
        var bytes: [UInt8] = Array(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<xar><toc><creation-time>2024-01-01T00:00:00</creation-time>"
                .utf8)
        private var nextID = 0

        mutating func id() -> Int {
            nextID += 1
            return nextID
        }

        mutating func add(_ s: String) { bytes += Array(s.utf8) }

        /// `pre`, then `text` kept within one 64 KiB chunk when it fits in one, then `post`.
        mutating func add(_ pre: String, text: [UInt8], _ post: String) {
            let start = bytes.count + pre.utf8.count
            if !text.isEmpty, text.count <= Self.chunk, start / Self.chunk != (start + text.count - 1) / Self.chunk {
                bytes += [UInt8](repeating: 0x20, count: Self.chunk - start % Self.chunk)
            }
            bytes += Array(pre.utf8) + text + Array(post.utf8)
        }

        /// Spaces up to `offset`.
        mutating func pad(to offset: Int) {
            precondition(offset >= bytes.count)
            bytes += [UInt8](repeating: 0x20, count: offset - bytes.count)
        }

        /// `<file>` with a name of `n` × `byte` and `body`, left open.
        mutating func open(_ n: Int, _ byte: UInt8 = 0x61, _ body: String = XarTOCLimitTests.meta) {
            add("<file id=\"\(id())\"><name>", text: [UInt8](repeating: byte, count: n), "</name>" + body)
        }
    }

    /// A xar of `toc`: the 28-byte header (TOC checksum algorithm 0, so none is checked) and the zlib-coded TOC, no
    /// heap.
    static func write(_ toc: TOC) throws -> URL {
        var toc = toc
        toc.add("</toc></xar>")
        let src = toc.bytes
        let capacity = src.count + src.count / 8 + 4096
        var deflated = [UInt8](repeating: 0, count: capacity)
        let n = src.withUnsafeBufferPointer { s in
            deflated.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(d.baseAddress!, capacity, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(n > 0)
        // COMPRESSION_ZLIB is raw deflate: add the zlib header and the Adler-32 trailer.
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in src {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let body = [0x78, 0x9C] + deflated[0..<n] + be(UInt64((b << 16) | a), 4)
        let header = be(0x7861_7221, 4) + be(28, 2) + be(1, 2) + be(UInt64(body.count), 8) + be(UInt64(src.count), 8)
            + be(0, 4)
        let url = Fixtures.tempDir().appendingPathComponent("toc.xar")
        try Data(header + body).write(to: url)
        return url
    }

    static func be(_ v: UInt64, _ width: Int) -> [UInt8] {
        (0..<width).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * $0)) }
    }

    /// `d` nested folders named `n` × "a", with metadata (listed) or bare (never listed), then `tail` inside the
    /// deepest one.
    static func deep(_ d: Int, _ n: Int, bare: Bool = false, tail: String = "") throws -> URL {
        var toc = TOC()
        for _ in 0..<d { toc.open(n, 0x61, bare ? Self.bare : Self.meta) }
        toc.add(tail)
        for _ in 0..<d { toc.add("</file>") }
        return try write(toc)
    }

    /// `d` name lengths whose chain of folders has a deepest pathname of exactly `length` bytes.
    static func chain(_ length: Int, _ d: Int = 200) -> [Int] {
        let body = length - (d - 1)
        return (0..<d).map { body / d + ($0 < body % d ? 1 : 0) }
    }

    /// 200 nested folders whose deepest pathname is exactly `length` bytes.
    static func path(_ length: Int) throws -> URL {
        var toc = TOC()
        let names = chain(length)
        for n in names { toc.open(n, 0x62) }
        for _ in names { toc.add("</file>") }
        return try write(toc)
    }

    /// One text of `length` bytes ("é", then "x"s) whose first byte ends the first 64 KiB chunk: expat holds the
    /// split character back and hands the whole text over in one piece with the next chunk. `link`: a symlink's
    /// target, else a folder's name.
    static func split(link: Bool, _ length: Int) throws -> URL {
        let pre = link
            ? "<file id=\"1\"><name>s</name><type>symlink</type><mode>0755</mode><link type=\"file\">"
            : "<file id=\"1\"><name>"
        let post = link ? "</link></file>" : "</name>" + meta + "</file>"
        var toc = TOC()
        toc.pad(to: TOC.chunk - 1 - pre.utf8.count)
        toc.bytes += Array(pre.utf8) + Array("é".utf8) + [UInt8](repeating: 0x78, count: length - 2) + Array(post.utf8)
        return try write(toc)
    }

    /// Stored pathnames that add up to exactly 256 MiB + `delta`: a listed "ok", a bare chain of 199 folders down to
    /// a 59,999-byte pathname, bare children of it (at depth 200), and a last bare top-level folder for the remainder.
    static func total(_ delta: Int) throws -> URL {
        var toc = TOC()
        var total = 2
        toc.add("<file id=\"\(toc.id())\"><name>ok</name>\(meta)</file>")
        let names = chain(59_999, 199)
        var path = 0
        for n in names {
            path = path == 0 ? n : path + 1 + n
            total += path
            toc.open(n, 0x62, bare)
        }
        var k = 0
        while totalLimit - total >= path + 2 {
            toc.add("<file id=\"\(toc.id())\"><name>\(String(k % 16, radix: 16))</name>\(bare)</file>")
            k += 1
            total += path + 2
        }
        for _ in names { toc.add("</file>") }
        let rest = totalLimit + delta - total
        if rest > 0 {
            toc.open(rest, 0x72, bare)
            toc.add("</file>")
        }
        return try write(toc)
    }

    /// An original file at a `length`-byte pathname (at depth 200, in a bare chain of 199 folders) and `count`
    /// hardlinks to it at the top.
    static func hardlinks(_ count: Int, to length: Int) throws -> URL {
        var toc = TOC()
        let names = chain(length - 2, 199)
        for n in names { toc.open(n, 0x62, bare) }
        toc.add("<file id=\"9999999\"><name>o</name><type link=\"original\">hardlink</type><mode>0644</mode></file>")
        for _ in names { toc.add("</file>") }
        for i in 0..<count {
            toc.add(
                "<file id=\"\(toc.id())\"><name>h\(i)</name><type link=\"9999999\">hardlink</type><mode>0644</mode></file>")
        }
        return try write(toc)
    }

    // MARK: - Measuring

    /// What `Archive.open` (or `previewListing`) did with an archive.
    enum Outcome: Equatable {
        case opened
        case limit(ArchiveNestingError.Limit)
        case other(String)
    }

    static func outcome(_ body: () async throws -> Void) async -> Outcome {
        do {
            try await body()
            return .opened
        } catch let e as ArchiveNestingError {
            return .limit(e.limit)
        } catch {
            return .other("\(error)")
        }
    }

    static func open(_ url: URL) async -> Outcome {
        await outcome { _ = try await Archive.open(at: url) }
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

    /// The `Outcome` of `Archive.open` for `url`, the most malloc held beyond its starting point while it ran, and
    /// the time it took. malloc is process-wide, so it measures inside `MemoryQuiet.measure`, and while the outcome
    /// is `expected` it opens up to 3 times and keeps the smallest growth: an open that builds the pathnames holds
    /// them on every attempt.
    static func refusal(_ url: URL, _ expected: Outcome, under limit: Int64) async
        -> (outcome: Outcome, growth: Int64, seconds: Double)
    {
        await MemoryQuiet.measure {
            var result = Outcome.opened
            var growths: [Int64] = []
            var seconds: [Double] = []
            for _ in 0..<3 where growths.isEmpty || (growths.last! >= limit && result == expected) {
                let baseline = MemoryQuiet.mallocInUse()
                let sampler = MemoryQuiet.PeakSampler()
                let start = Date()
                result = await open(url)
                seconds.append(Date().timeIntervalSince(start))
                growths.append(max(sampler.stop(), MemoryQuiet.mallocInUse()) - baseline)
            }
            return (result, growths.min() ?? .max, seconds.min() ?? .infinity)
        }
    }

    // MARK: - Tests

    @Test("Patch 0015's messages are the ones the reader maps, each to its limit, and nothing else is")
    func refusalMessagesAreMapped() throws {
        // Read from libarchive, so a reworded patch fails here rather than reaching callers as `.corrupted`.
        let refused: [(url: URL, message: String, limit: ArchiveNestingError.Limit)] = [
            (try Self.deep(201, 3), Self.depthMessage, .depth),
            (try Self.split(link: false, 65_537), Self.nameMessage, .pathLength),
            (try Self.split(link: true, 65_537), Self.linkMessage, .pathLength),
            (try Self.hardlinks(5_000, to: 65_000), Self.hardlinkMessage, .totalPathBytes),
            (try XarNameDecodeOnceTests.longEAName(65_537), Self.eaNameMessage, .pathLength),
        ]
        for r in refused {
            #expect(Self.libarchiveError(r.url) == .corrupted(r.message))
            #expect(PatchedNameRefusal.refusal(for: .corrupted(r.message)) == ArchiveNestingError(limit: r.limit))
        }
        // The total's own message is read from libarchive in `totalLimitIsExact`, which builds the 256 MiB TOC.
        #expect(PatchedNameRefusal.refusal(for: .corrupted(Self.totalMessage))
                == ArchiveNestingError(limit: .totalPathBytes))
        // Exact messages only: a TOC that does not parse, other wording and other errors stay as they are.
        for other: ArchiveError in [.corrupted("XML Parsing failed"), .corrupted(Self.depthMessage + "."),
                                    .corrupted(Self.totalMessage.uppercased()), .io(Self.linkMessage)] {
            #expect(PatchedNameRefusal.refusal(for: other) == nil, "\(other)")
        }
    }

    @Test("4,000 nested folders in a 14 KB xar are refused at the 201st, without building the pathnames")
    func deepChainIsRefusedEarly() async throws {
        let url = try Self.deep(4_000, 255)
        let size = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 32 << 10)
        let (outcome, growth, seconds) = await Self.refusal(url, .limit(.depth), under: 48 << 20)
        #expect(outcome == .limit(.depth))
        #expect(growth < 48 << 20, "malloc growth \(growth >> 20) MiB")
        #expect(seconds < 5, "took \(seconds) s")
    }

    @Test("200 levels open; a 201st is refused in libarchive as the depth limit, also when its folders are bare")
    func depthLimitIsExact() async throws {
        let at = try Self.deep(200, 3)
        let reader = try await Archive.open(at: at)
        #expect(reader.entries.count == 200)
        #expect(reader.entries.map { $0.path.utf8.count }.max() == 799)
        let over = try Self.deep(201, 3)
        #expect(Self.libarchiveError(over) == .corrupted(Self.depthMessage))
        #expect(await Self.open(over) == .limit(.depth))
        #expect(await Self.outcome { _ = try await Archive.previewListing(at: over, limit: 10) } == .limit(.depth))
        // Folders with only a name and a type are never listed, but they still nest and cost their pathnames.
        let bare = try Self.deep(201, 3, bare: true)
        #expect(Self.libarchiveError(bare) == .corrupted(Self.depthMessage))
        #expect(await Self.open(bare) == .limit(.depth))
    }

    @Test("A pathname of 65,537 bytes is refused in libarchive, 65,536 in Swift, both as the path limit")
    func nameLimitIsExact() async throws {
        let at = try Self.path(65_536)
        #expect(Self.libarchiveError(at) == nil)
        #expect(await Self.open(at) == .limit(.pathLength))
        let over = try Self.path(65_537)
        #expect(Self.libarchiveError(over) == .corrupted(Self.nameMessage))
        #expect(await Self.open(over) == .limit(.pathLength))
        #expect(await Self.outcome { _ = try await Archive.previewListing(at: over, limit: 10) } == .limit(.pathLength))
        // One name at and over the limit, handed over in one piece.
        let oneAt = try Self.split(link: false, 65_536)
        #expect(Self.libarchiveError(oneAt) == nil)
        #expect(await Self.open(oneAt) == .limit(.pathLength))
        let oneOver = try Self.split(link: false, 65_537)
        #expect(Self.libarchiveError(oneOver) == .corrupted(Self.nameMessage))
        #expect(await Self.open(oneOver) == .limit(.pathLength))
    }

    @Test("A link target of 65,537 bytes is refused in libarchive as the path limit; 65,536 opens")
    func linkLimitIsExact() async throws {
        let at = try await Archive.open(at: Self.split(link: true, 65_536))
        #expect(at.entries.map(\.path) == ["s"])
        let over = try Self.split(link: true, 65_537)
        #expect(Self.libarchiveError(over) == .corrupted(Self.linkMessage))
        #expect(await Self.open(over) == .limit(.pathLength))
    }

    @Test("Pathnames of exactly 256 MiB in all open; one byte more is refused as the total limit")
    func totalLimitIsExact() async throws {
        // libarchive holds about 290 MB of pathnames on each of these reads.
        try await MemoryQuiet.heavy {
            let at = try await Archive.open(at: Self.total(0))
            #expect(at.entries.map(\.path) == ["ok"])
            let over = try Self.total(1)
            #expect(Self.libarchiveError(over) == .corrupted(Self.totalMessage))
            #expect(await Self.open(over) == .limit(.totalPathBytes))
        }
    }

    @Test("Hardlink target copies past 256 MiB are refused before they are made, as the total limit")
    func hardlinkCopiesAreCharged() async throws {
        // 5,000 copies of a 65,000-byte pathname: 325 MB.
        let url = try Self.hardlinks(5_000, to: 65_000)
        let size = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 64 << 10)
        #expect(Self.libarchiveError(url) == .corrupted(Self.hardlinkMessage))
        let (outcome, growth, _) = await Self.refusal(url, .limit(.totalPathBytes), under: 48 << 20)
        #expect(outcome == .limit(.totalPathBytes))
        #expect(growth < 48 << 20, "malloc growth \(growth >> 20) MiB")
        // 100 copies pass libarchive and reach the Swift path limit.
        let few = try Self.hardlinks(100, to: 65_000)
        #expect(await Self.open(few) == .limit(.pathLength))
    }

    @Test("A refusal keeps its message when the XML breaks later in the same chunk")
    func refusalKeepsItsMessage() async throws {
        let broken = "<file id=\"77777\"><name>z</name></nope>"
        let refused = try Self.deep(201, 3, tail: broken)
        #expect(Self.libarchiveError(refused) == .corrupted(Self.depthMessage))
        #expect(await Self.open(refused) == .limit(.depth))
        // The same tail breaks the TOC: libarchive sets the xar format only once the TOC is read, so a TOC that does
        // not parse reads as an unknown format.
        let within = try Self.deep(199, 3, tail: broken)
        #expect(await Self.open(within) == .other("\(ArchiveError.unsupportedFormat)"))
    }

    @Test("An ordinary tree with a symlink and a hardlink still opens")
    func ordinaryTreeOpens() async throws {
        var toc = TOC()
        toc.add("<file id=\"1\"><name>docs</name>\(Self.meta)")
        toc.add("<file id=\"2\"><name>\(String(repeating: "n", count: 255))</name>\(Self.meta)")
        toc.add("<file id=\"3\"><name>deeper</name>\(Self.meta)</file></file>")
        toc.add("<file id=\"4\"><name>link</name><type>symlink</type><mode>0755</mode><link type=\"file\">orig</link></file>")
        toc.add("<file id=\"5\"><name>orig</name><type link=\"original\">hardlink</type><mode>0644</mode></file>")
        toc.add("</file>")
        toc.add("<file id=\"6\"><name>copy</name><type link=\"5\">hardlink</type><mode>0644</mode></file>")
        let reader = try await Archive.open(at: Self.write(toc))
        let long = String(repeating: "n", count: 255)
        #expect(Set(reader.entries.map(\.path)) == [
            "docs", "docs/\(long)", "docs/\(long)/deeper", "docs/link", "docs/orig", "copy",
        ])
    }
}
