import Foundation
import Testing
@testable import KernirCore

/// Expat hands the xar reader the text of one `<name>` or `<link>` in pieces: at every entity or character reference
/// (`&amp;`, `&lt;`, `&gt;`, `&#233;`), at each newline, and where the 64 KiB chunk of inflated TOC it was fed ends.
/// libarchive 3.8.10 kept only the first piece of a name and the last piece of a link target, so `Tom &amp; Jerry.txt`
/// listed as `Tom ` and `a&amp;b` linked to `b`: siblings collapsed into one path and extract overwrote one with the
/// other (libarchive#3849). Kernir patch 0017 joins the pieces of one element, keeps only the first `<name>` of an
/// entry (as upstream does since #2236) and the last `<link>`, and charges patch 0015's per-name and patch 0016's
/// total limits on the joined text.
@Suite("xar names in pieces", .serialized)
struct XarNameCharDataTests {
    typealias TOC = XarTOCLimitTests.TOC

    static let meta = XarTOCLimitTests.meta
    static let fileMeta = "<type>file</type><mode>0644</mode>"

    /// A xar whose TOC holds `body` (raw XML, so entity references stay as written).
    static func xar(_ body: String) throws -> URL {
        var toc = TOC()
        toc.add(body)
        return try XarTOCLimitTests.write(toc)
    }

    static func file(_ id: Int, _ name: String) -> String {
        "<file id=\"\(id)\"><name>\(name)</name>\(fileMeta)</file>"
    }

    static func symlink(_ id: Int, _ name: String, _ links: String...) -> String {
        "<file id=\"\(id)\"><name>\(name)</name><type>symlink</type><mode>0755</mode>"
            + links.map { "<link type=\"file\">\($0)</link>" }.joined() + "</file>"
    }

    /// A xar holding `pre`, `text` and `post`, with byte `split` of `text` the first byte of the second 64 KiB chunk
    /// of inflated TOC: expat hands `text` over in (at least) two pieces.
    static func straddling(_ pre: String, _ text: [UInt8], _ post: String, split: Int) throws -> URL {
        precondition(split > 0 && split < text.count)
        var toc = TOC()
        toc.pad(to: TOC.chunk - split - pre.utf8.count)
        toc.bytes += Array(pre.utf8) + text + Array(post.utf8)
        precondition(toc.bytes.count > TOC.chunk)
        return try XarTOCLimitTests.write(toc)
    }

    static func reader(_ url: URL) async throws -> LibArchiveReader {
        let opened = try await Archive.open(at: url)
        return try #require(opened as? LibArchiveReader)
    }

    static func paths(_ url: URL) async throws -> Set<String> {
        Set(try await reader(url).entries.map(\.path))
    }

    static func libarchiveError(_ url: URL, total: Int) -> ArchiveError? {
        EntryCountLimitTests.libarchiveError(url, EntryCountLimitTests.limits(total: total))
    }

    // MARK: - Names

    @Test("Names with &, < and > (entity references) list whole; siblings that shared a cut prefix stay apart")
    func entityNamesAreWhole() async throws {
        let url = try Self.xar(
            Self.file(1, "Tom &amp; Jerry.txt") + Self.file(2, "Tom &amp; Mary.txt")
                + Self.file(3, "a &lt;b&gt; c.txt") + Self.file(4, "caf&#233; &#x26; bar") + Self.file(5, "&amp;lead"))
        #expect(try await Self.paths(url) == ["Tom & Jerry.txt", "Tom & Mary.txt", "a <b> c.txt", "café & bar", "&lead"])
    }

    @Test("A name in pieces gets its parent's prefix once, and its children see the joined name")
    func piecesUnderAParent() async throws {
        let url = try Self.xar(
            "<file id=\"1\"><name>d&amp;e</name>\(Self.meta)"
                + "<file id=\"2\"><name>x&amp;y</name>\(Self.meta)" + Self.file(3, "f&lt;g") + "</file></file>")
        #expect(try await Self.paths(url) == ["d&e", "d&e/x&y", "d&e/x&y/f<g"])
    }

    /// A literal newline in the TOC (expat splits there); `&#10;` is the same character as a reference.
    @Test("A name with a newline lists whole")
    func newlineNamesAreWhole() async throws {
        let url = try Self.xar(Self.file(1, "line1\nline2.txt") + Self.file(2, "ref1&#10;ref2.txt"))
        #expect(try await Self.paths(url) == ["line1\nline2.txt", "ref1\nref2.txt"])
    }

    @Test("A name across a 64 KiB TOC chunk boundary lists whole")
    func boundaryNamesAreWhole() async throws {
        let url = try Self.straddling(
            "<file id=\"1\"><name>", Array("boundary-name.txt".utf8), "</name>\(Self.fileMeta)</file>", split: 8)
        #expect(try await Self.paths(url) == ["boundary-name.txt"])
        // A two-byte character split by the boundary, then an entity reference in the second chunk.
        let mixed = try Self.straddling(
            "<file id=\"1\"><name>", Array("abcé&amp;tail".utf8), "</name>\(Self.fileMeta)</file>", split: 4)
        #expect(try await Self.paths(mixed) == ["abcé&tail"])
    }

    @Test("Only an entry's first <name> counts, also when either one comes in pieces")
    func firstNameOnly() async throws {
        let url = try Self.xar(
            "<file id=\"1\"><name>a&amp;b</name><name>zz</name>\(Self.fileMeta)</file>"
                + "<file id=\"2\"><name>one</name><name>t&amp;wo</name>\(Self.fileMeta)</file>"
                + "<file id=\"3\"><name>first</name><name>second</name>\(Self.fileMeta)</file>")
        #expect(try await Self.paths(url) == ["a&b", "one", "first"])
    }

    @Test("A base64 name decodes, also when wrapped into lines")
    func base64Name() async throws {
        let encoded = Data("b64 & name.txt".utf8).base64EncodedString()
        let url = try Self.xar(
            "<file id=\"1\"><name enctype=\"base64\">\(encoded)</name>\(Self.fileMeta)</file>")
        #expect(try await Self.paths(url) == ["b64 & name.txt"])
        // Wrapped into lines of whole 4-character groups, as base64 often is.
        let wrapped = try Self.xar("<file id=\"1\"><name enctype=\"base64\">\(encoded.prefix(8))\n"
                                   + "\(encoded.dropFirst(8))</name>\(Self.fileMeta)</file>")
        #expect(try await Self.paths(wrapped) == ["b64 & name.txt"])
    }

    /// The `<ea>`'s own name is joined since patch 0018 (XarNameDecodeOnceTests.eaNameInPieces); here: the file's
    /// joined name, and the listing without error.
    @Test("A file name in pieces lists whole next to an <ea> whose name also has an entity reference")
    func nameInPiecesWithEA() async throws {
        let url = try Self.xar(
            "<file id=\"1\"><name>Tom &amp; Jerry.txt</name>\(Self.fileMeta)"
                + "<ea id=\"0\"><length>1</length><offset>0</offset><size>1</size>"
                + "<encoding style=\"application/octet-stream\"/><name>x&amp;y</name></ea></file>")
        // The <ea> value is one byte of heap, which starts right after the TOC.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: [0x76])
        try handle.close()
        #expect(try await Self.paths(url) == ["Tom & Jerry.txt"])
    }

    // MARK: - Link targets

    @Test("A link target in pieces (entity references, a newline, a 64 KiB boundary) is whole")
    func linkTargetsAreWhole() async throws {
        let url = try Self.xar(
            Self.symlink(1, "l1", "a&amp;b") + Self.symlink(2, "l2", "x&lt;y&gt;z/w") + Self.symlink(3, "l3", "n1\nn2"))
        let r = try await Self.reader(url)
        #expect(r.symlinkTargetByPath == ["l1": "a&b", "l2": "x<y>z/w", "l3": "n1\nn2"])
        let boundary = try Self.straddling(
            "<file id=\"1\"><name>s</name><type>symlink</type><mode>0755</mode><link type=\"file\">",
            Array("boundary-target/x&amp;y".utf8), "</link></file>", split: 8)
        #expect(try await Self.reader(boundary).symlinkTargetByPath == ["s": "boundary-target/x&y"])
    }

    @Test("Of two <link> elements the last one counts, whole and alone")
    func lastLinkOnly() async throws {
        let url = try Self.xar(Self.symlink(1, "s", "fi&amp;rst", "se&amp;cond"))
        #expect(try await Self.reader(url).symlinkTargetByPath == ["s": "se&cond"])
    }

    // MARK: - Limits on the joined text

    /// `n` bytes of "a" and "&" in turn, written as `a&amp;` pairs: about `n` pieces.
    static func pieces(_ n: Int) -> String {
        String(repeating: "a&amp;", count: n / 2) + (n % 2 == 1 ? "a" : "")
    }

    @Test("A name over 65,536 bytes is refused when it arrives in pieces (entity references or a chunk boundary)")
    func joinedNameLimit() async throws {
        let message = XarTOCLimitTests.nameMessage
        let entity = { (n: Int) in try Self.xar(Self.file(1, String(repeating: "a", count: 40_000) + "&amp;"
                                                             + String(repeating: "b", count: n - 40_001))) }
        let (at, over) = (try entity(65_536), try entity(65_537))
        #expect(XarTOCLimitTests.libarchiveError(at) == nil)
        #expect(XarTOCLimitTests.libarchiveError(over) == .corrupted(message))
        #expect(await XarTOCLimitTests.open(over) == .limit(.pathLength))
        let boundary = { (n: Int) in
            try Self.straddling("<file id=\"1\"><name>", [UInt8](repeating: 0x63, count: n),
                                "</name>\(Self.fileMeta)</file>", split: 100)
        }
        let (boundaryAt, boundaryOver) = (try boundary(65_536), try boundary(65_537))
        #expect(XarTOCLimitTests.libarchiveError(boundaryAt) == nil)
        #expect(XarTOCLimitTests.libarchiveError(boundaryOver) == .corrupted(message))
        // The parent's prefix counts too: 65,530 + "/" + 6 bytes in pieces.
        let nested = try Self.xar(
            "<file id=\"1\"><name>\(String(repeating: "p", count: 65_530))</name>\(Self.meta)"
                + Self.file(2, "q&amp;r&amp;st") + "</file>")
        #expect(XarTOCLimitTests.libarchiveError(nested) == .corrupted(message))
    }

    @Test("A link target over 65,536 bytes is refused when it arrives in pieces")
    func joinedLinkLimit() async throws {
        let message = XarTOCLimitTests.linkMessage
        let entity = { (n: Int) in
            try Self.xar(Self.symlink(1, "s", String(repeating: "a", count: 40_000) + "&amp;"
                                          + String(repeating: "b", count: n - 40_001)))
        }
        let (at, over) = (try entity(65_536), try entity(65_537))
        #expect(XarTOCLimitTests.libarchiveError(at) == nil)
        #expect(XarTOCLimitTests.libarchiveError(over) == .corrupted(message))
        #expect(await XarTOCLimitTests.open(over) == .limit(.pathLength))
        let boundary = { (n: Int) in
            try Self.straddling("<file id=\"1\"><name>s</name><type>symlink</type><mode>0755</mode><link type=\"file\">",
                                [UInt8](repeating: 0x63, count: n), "</link></file>", split: 100)
        }
        let (boundaryAt, boundaryOver) = (try boundary(65_536), try boundary(65_537))
        #expect(XarTOCLimitTests.libarchiveError(boundaryAt) == nil)
        #expect(XarTOCLimitTests.libarchiveError(boundaryOver) == .corrupted(message))
    }

    @Test("The names total charges a name or link target in pieces once, by its joined length")
    func joinedTotal() throws {
        let message = XarTOCLimitTests.totalMessage
        // One 20,000-byte name in about 20,000 pieces: 20,000 bytes, not the sum of its growing prefixes.
        let name = try Self.xar(Self.file(1, Self.pieces(20_000)))
        #expect(Self.libarchiveError(name, total: 20_000) == nil)
        #expect(Self.libarchiveError(name, total: 19_999) == .corrupted(message))
        // A 1-byte name and a 20,000-byte link target in pieces.
        let link = try Self.xar(Self.symlink(1, "s", Self.pieces(20_000)))
        #expect(Self.libarchiveError(link, total: 20_001) == nil)
        #expect(Self.libarchiveError(link, total: 20_000) == .corrupted(message))
        // A replaced <link> no longer counts: "s" and "b&c", not "x" too.
        let twice = try Self.xar(Self.symlink(1, "s", "x", "b&amp;c"))
        #expect(Self.libarchiveError(twice, total: 4) == nil)
        #expect(Self.libarchiveError(twice, total: 3) == .corrupted(message))
        // An ignored second <name> costs nothing.
        let names = try Self.xar(
            "<file id=\"1\"><name>a&amp;b</name><name>\(String(repeating: "z", count: 1_000))</name>\(Self.fileMeta)</file>")
        #expect(Self.libarchiveError(names, total: 3) == nil)
        #expect(Self.libarchiveError(names, total: 2) == .corrupted(message))
    }
}
