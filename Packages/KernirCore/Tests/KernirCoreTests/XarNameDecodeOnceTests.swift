import CLibArchive
import Foundation
import Testing
@testable import KernirCore

/// Kernir patch 0018. Expat hands the text of one `<name enctype="base64">` over in pieces (at the end of each 64 KiB
/// chunk of inflated TOC, at newlines, at character references); patch 0017 joined them but decoded each piece on its
/// own, so a piece that ended inside a 4-character group decoded wrongly ("QUJ" + "D" read "AB", "QU" + "JD" read
/// garbage). 0018 collects the raw text (whitespace left out, at most 87,384 characters: 65,536 bytes' worth) and
/// decodes it once, at `</name>`, where it charges 0015's per-name and 0016's total limits. It also joins the pieces
/// of an `<ea>`'s `<name>`, which kept only its last one (`x&amp;y` read "y"), within the same per-name limit.
@Suite("xar names decoded once", .serialized)
struct XarNameDecodeOnceTests {
    typealias Base = XarNameCharDataTests

    static let name = "Tom & Jerry.txt"
    static let encoded = Data(name.utf8).base64EncodedString()  // VG9tICYgSmVycnkudHh0

    static func b64File(_ id: Int, _ text: String) -> String {
        "<file id=\"\(id)\"><name enctype=\"base64\">\(text)</name>\(Base.fileMeta)</file>"
    }

    /// `text` (ASCII) broken into lines of `width` characters, joined by `separator`.
    static func wrap(_ text: String, _ width: Int, _ separator: String = "\n") -> String {
        let bytes = Array(text.utf8)
        return stride(from: 0, to: bytes.count, by: width).map {
            String(decoding: bytes[$0..<min($0 + width, bytes.count)], as: UTF8.self)
        }.joined(separator: separator)
    }

    /// `text` with `insert` put before character `at`.
    static func split(_ text: String, at: Int, _ insert: String) -> String {
        String(text.prefix(at)) + insert + String(text.dropFirst(at))
    }

    // MARK: - Base64 names in pieces

    @Test("A base64 name split inside a 4-character group decodes whole: QUJ|D and QU|JD")
    func groupSplits() async throws {
        // "ABC" is QUJD: a character reference splits it after 3 and after 2 characters.
        let url = try Base.xar(Self.b64File(1, "QUJ&#68;") + Self.b64File(2, "QU&#74;D")
                               + Self.b64File(3, "Q&#85;JD") + Self.b64File(4, "QUJD&#82;EVG"))
        #expect(try await Base.paths(url) == ["ABC", "ABC", "ABC", "ABCDEF"])
    }

    @Test("A base64 name across the 64 KiB TOC chunk boundary decodes whole, wherever the boundary falls")
    func boundarySplits() async throws {
        for at in 1..<Self.encoded.count {
            let url = try Base.straddling("<file id=\"1\"><name enctype=\"base64\">", Array(Self.encoded.utf8),
                                          "</name>\(Base.fileMeta)</file>", split: at)
            #expect(try await Base.paths(url) == [Self.name], "boundary before character \(at)")
        }
    }

    @Test("A base64 name wrapped at any column (a newline, CRLF, spaces) decodes whole")
    func newlineSplits() async throws {
        for at in 1..<Self.encoded.count {
            let url = try Base.xar(Self.b64File(1, Self.split(Self.encoded, at: at, "\n"))
                                   + Self.b64File(2, Self.split(Self.encoded, at: at, "\r\n  \t")))
            #expect(try await Base.paths(url) == [Self.name], "line break before character \(at)")
        }
        // Lines of 75 characters (not whole groups), as a wrapping tool might write them.
        let long = Data(String(repeating: "0123456789", count: 30).utf8).base64EncodedString()
        let url = try Base.xar(Self.b64File(1, Self.wrap(long, 75)))
        #expect(try await Base.paths(url) == [String(repeating: "0123456789", count: 30)])
    }

    @Test("A base64 name split at character references decodes whole, wherever they fall")
    func referenceSplits() async throws {
        let chars = Array(Self.encoded.unicodeScalars)
        for at in 0..<chars.count {
            var text = ""
            for (i, c) in chars.enumerated() { text += i == at ? "&#\(c.value);" : String(c) }
            let url = try Base.xar(Self.b64File(1, text))
            #expect(try await Base.paths(url) == [Self.name], "reference at character \(at)")
        }
    }

    @Test("A base64 name in pieces gets its parent's prefix once; only an entry's first <name> counts")
    func prefixAndFirstName() async throws {
        let url = try Base.xar(
            "<file id=\"1\"><name>p&amp;q</name>\(XarTOCLimitTests.meta)"
                + "<file id=\"2\"><name enctype=\"base64\">QU&#74;D\nREVG</name>\(XarTOCLimitTests.meta)"
                + Self.b64File(3, "eH&#108;6") + "</file></file>"
                + "<file id=\"4\"><name enctype=\"base64\">R0&#104;J</name><name>zz</name>\(Base.fileMeta)</file>"
                + "<file id=\"5\"><name>first</name><name enctype=\"base64\">QU&#74;D</name>\(Base.fileMeta)</file>")
        #expect(try await Base.paths(url) == ["p&q", "p&q/ABCDEF", "p&q/ABCDEF/xyz", "GHI", "first"])
    }

    // MARK: - Limits

    @Test("A base64 name over 65,536 bytes, or over 87,384 characters of base64, is refused")
    func base64Limit() async throws {
        let message = XarTOCLimitTests.nameMessage
        let b64 = { (n: Int) in Data(repeating: 0x61, count: n).base64EncodedString() }
        #expect(b64(65_536).count == 87_384)
        let (at, over) = (try Base.xar(Self.b64File(1, b64(65_536))), try Base.xar(Self.b64File(1, b64(65_537))))
        #expect(XarTOCLimitTests.libarchiveError(at) == nil)
        #expect(XarTOCLimitTests.libarchiveError(over) == .corrupted(message))
        #expect(await XarTOCLimitTests.open(over) == .limit(.pathLength))
        // Line breaks do not count against the raw limit.
        let wrapped = try Base.xar(Self.b64File(1, Self.wrap(b64(65_536), 75, "\r\n")))
        #expect(XarTOCLimitTests.libarchiveError(wrapped) == nil)
        // The raw text is capped before it is decoded: decoding would stop at "*" and give a 3-byte name, but the
        // text is one character over 87,384.
        let junk = try Base.xar(Self.b64File(1, "QUJD*" + String(repeating: "A", count: 87_380)))
        #expect(XarTOCLimitTests.libarchiveError(junk) == .corrupted(message))
        let junkAt = try Base.xar(Self.b64File(1, "QUJD*" + String(repeating: "A", count: 87_379)))
        #expect(XarTOCLimitTests.libarchiveError(junkAt) == nil)
        // The parent's prefix counts: 65,530 + "/" + 6 decoded bytes in pieces.
        let nested = try Base.xar(
            "<file id=\"1\"><name>\(String(repeating: "p", count: 65_530))</name>\(XarTOCLimitTests.meta)"
                + Self.b64File(2, "QU&#74;D\nREVG") + "</file>")
        #expect(XarTOCLimitTests.libarchiveError(nested) == .corrupted(message))
        let nestedAt = try Base.xar(
            "<file id=\"1\"><name>\(String(repeating: "p", count: 65_530))</name>\(XarTOCLimitTests.meta)"
                + Self.b64File(2, "QU&#74;\nD") + "</file>")
        #expect(XarTOCLimitTests.libarchiveError(nestedAt) == nil)
        // Exactly 65,536 with the prefix: 65,530 + "/" + 5 decoded bytes ("ABCDE") in pieces is accepted, 6 refused (above).
        let nestedExact = try Base.xar(
            "<file id=\"1\"><name>\(String(repeating: "p", count: 65_530))</name>\(XarTOCLimitTests.meta)"
                + Self.b64File(2, "QU&#74;D\nREU=") + "</file>")
        #expect(XarTOCLimitTests.libarchiveError(nestedExact) == nil)
    }

    @Test("Base64 decoding stops at the first '=': per-line padding keeps only the first line (upstream xar.c)")
    func paddingStopsDecode() async throws {
        // 0017 decoded each piece, so "QQ==" + "Qg==" read "AB"; one decode of "QQ==Qg==" stops at the first '='.
        // Writers (libarchive, xar) pad only at the end of the whole name, where this reads whole.
        let url = try Base.xar(Self.b64File(1, "QQ==\nQg==") + Self.b64File(2, "QUJDREU=") + Self.b64File(3, "QUI="))
        #expect(try await Base.paths(url) == ["A", "ABCDE", "AB"])
    }

    @Test("The names total charges a base64 name in pieces once, by its decoded length")
    func base64Total() throws {
        let message = XarTOCLimitTests.totalMessage
        // 3,000 bytes in lines of 75 characters: 3,000 bytes, not the 4,000 of base64 or anything per piece.
        let long = Data(repeating: 0x62, count: 3_000).base64EncodedString()
        let url = try Base.xar(Self.b64File(1, Self.wrap(long, 75)))
        #expect(Base.libarchiveError(url, total: 3_000) == nil)
        #expect(Base.libarchiveError(url, total: 2_999) == .corrupted(message))
        // An ignored second base64 <name> costs nothing.
        let names = try Base.xar(
            "<file id=\"1\"><name>a&amp;b</name><name enctype=\"base64\">\(long)</name>\(Base.fileMeta)</file>")
        #expect(Base.libarchiveError(names, total: 3) == nil)
        #expect(Base.libarchiveError(names, total: 2) == .corrupted(message))
    }

    // MARK: - <ea><name>

    struct ReadFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// Path to extended-attribute names of every entry of the xar at `url`, read with libarchive itself.
    static func eaNames(_ url: URL) throws -> [String: [String]] {
        let a = archive_read_new()
        defer { archive_read_free(a) }
        archive_read_support_format_xar(a)
        guard archive_read_open_filename(a, url.path, 10_240) == ARCHIVE_OK else {
            throw ReadFailure(description: String(cString: archive_error_string(a)))
        }
        var result: [String: [String]] = [:]
        var entry: OpaquePointer?
        while true {
            let r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK, let entry else {
                throw ReadFailure(description: archive_error_string(a).map { String(cString: $0) } ?? "\(r)")
            }
            var names: [String] = []
            archive_entry_xattr_reset(entry)
            var name: UnsafePointer<CChar>?
            var value: UnsafeRawPointer?
            var size = 0
            while archive_entry_xattr_next(entry, &name, &value, &size) == ARCHIVE_OK, let name {
                names.append(String(cString: name))
            }
            result[String(cString: archive_entry_pathname(entry))] = names
        }
        return result
    }

    static func ea(_ nameElements: String) -> String {
        "<ea id=\"0\"><length>1</length><offset>0</offset><size>1</size>"
            + "<encoding style=\"application/octet-stream\"/>\(nameElements)</ea>"
    }

    /// A xar of `body` with one byte of heap (every <ea> here takes it), right after the TOC.
    static func withHeap(_ body: String) throws -> URL {
        let url = try Base.xar(body)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: [0x76])
        try handle.close()
        return url
    }

    @Test("An <ea>'s <name> in pieces is whole, next to a file name in pieces: no cross-talk either way")
    func eaNameInPieces() throws {
        let after = try Self.withHeap(
            "<file id=\"1\"><name>Tom &amp; Jerry.txt</name>\(Base.fileMeta)" + Self.ea("<name>x&amp;y</name>")
                + "</file>")
        #expect(try Self.eaNames(after) == ["Tom & Jerry.txt": ["x&y"]])
        // The <ea> first, and the file name in base64 pieces.
        let before = try Self.withHeap(
            "<file id=\"1\">" + Self.ea("<name>e&#10;a&lt;</name>")
                + "<name enctype=\"base64\">QU&#74;D</name>\(Base.fileMeta)</file>")
        #expect(try Self.eaNames(before) == ["ABC": ["e\na<"]])
        // Of two <name> elements in one <ea>, the last counts, whole.
        let twice = try Self.withHeap(
            "<file id=\"1\"><name>f</name>\(Base.fileMeta)" + Self.ea("<name>o&amp;ne</name><name>t&amp;wo</name>")
                + "</file>")
        #expect(try Self.eaNames(twice) == ["f": ["t&wo"]])
        // An empty <name/> after a name does not replace it (upstream keeps the earlier one).
        let empty = try Self.withHeap(
            "<file id=\"1\"><name>f</name>\(Base.fileMeta)" + Self.ea("<name>a</name><name/>") + "</file>")
        #expect(try Self.eaNames(empty) == ["f": ["a"]])
    }

    /// A xar of one file "f" with one <ea> whose <name> is `n` bytes, in two pieces (at an entity reference).
    static func longEAName(_ n: Int) throws -> URL {
        try withHeap("<file id=\"1\"><name>f</name>\(Base.fileMeta)"
            + ea("<name>" + String(repeating: "a", count: 40_000) + "&amp;"
                 + String(repeating: "b", count: n - 40_001) + "</name>") + "</file>")
    }

    @Test("An <ea>'s <name> over 65,536 bytes is refused when it arrives in pieces, with its own message, as the path limit")
    func eaNameLimit() async throws {
        let (at, over) = (try Self.longEAName(65_536), try Self.longEAName(65_537))
        #expect(XarTOCLimitTests.libarchiveError(at) == nil)
        // Patch 0020: not the entry-name message 0018 reused.
        #expect(XarTOCLimitTests.libarchiveError(over) == .corrupted(XarTOCLimitTests.eaNameMessage))
        #expect(await XarTOCLimitTests.open(over) == .limit(.pathLength))
    }

    @Test("Patch 0020: <ea> names are charged to the names total once, by their joined length; a replaced one is not")
    func eaNameTotal() async throws {
        let message = XarTOCLimitTests.totalMessage
        // "f" (1) + "x&y" (3, in pieces) = 4.
        let one = try Self.withHeap(
            "<file id=\"1\"><name>f</name>\(Base.fileMeta)" + Self.ea("<name>x&amp;y</name>") + "</file>")
        #expect(Base.libarchiveError(one, total: 4) == nil)
        #expect(Base.libarchiveError(one, total: 3) == .corrupted(message))
        #expect(await EntryCountLimitTests.open(one, EntryCountLimitTests.limits(total: 3)) == .limit(.totalPathBytes))
        // Of two <name> elements in one <ea>, only the last is charged: 1 + 4, not 1 + 4 + 4.
        let twice = try Self.withHeap(
            "<file id=\"1\"><name>f</name>\(Base.fileMeta)" + Self.ea("<name>o&amp;ne</name><name>t&amp;wo</name>")
                + "</file>")
        #expect(Base.libarchiveError(twice, total: 5) == nil)
        #expect(Base.libarchiveError(twice, total: 4) == .corrupted(message))
        #expect(await EntryCountLimitTests.open(twice, EntryCountLimitTests.limits(total: 4)) == .limit(.totalPathBytes))
        // The <ea> before the file name, and <ea> names on two files, all add up: 1 + 2 + 1 + 3 = 7.
        let two = try Self.withHeap(
            "<file id=\"1\">" + Self.ea("<name>ab</name>") + "<name>f</name>\(Base.fileMeta)</file>"
                + "<file id=\"2\"><name>g</name>\(Base.fileMeta)" + Self.ea("<name>cde</name>") + "</file>")
        #expect(Base.libarchiveError(two, total: 7) == nil)
        #expect(Base.libarchiveError(two, total: 6) == .corrupted(message))
        #expect(await EntryCountLimitTests.open(two, EntryCountLimitTests.limits(total: 6)) == .limit(.totalPathBytes))
    }

    @Test("Patch 0020: with a per-entry allowance, an <ea> name is held to what the <file> elements so far allow")
    func eaNameAllowanceGrows() async throws {
        // Two files: "ff" (2), then "g" (1) with an <ea> name of `k` bytes. The allowance is 4 bytes per <file>
        // so far (the total floor is 1): 4 at the first file, 8 at the second, where the <ea> name is charged.
        // 2 + 1 + 5 = 8 fits only because the second <file> raised the allowance; one byte more does not.
        func xar(_ k: Int) throws -> URL {
            try Self.withHeap(
                "<file id=\"1\"><name>ff</name>\(Base.fileMeta)</file>"
                    + "<file id=\"2\"><name>g</name>\(Base.fileMeta)"
                    + Self.ea("<name>" + String(repeating: "e", count: k) + "</name>") + "</file>")
        }
        let limits = EntryCountLimitTests.limits(total: 1, perEntry: 4)
        #expect(EntryCountLimitTests.libarchiveError(try xar(5), limits) == nil)
        #expect(EntryCountLimitTests.libarchiveError(try xar(6), limits) == .corrupted(XarTOCLimitTests.totalMessage))
        #expect(await EntryCountLimitTests.open(try xar(6), limits) == .limit(.totalPathBytes))
        // Below the second file's allowance (3 bytes per file: 6) the 5-byte one is refused too.
        #expect(EntryCountLimitTests.libarchiveError(try xar(5), EntryCountLimitTests.limits(total: 1, perEntry: 3))
                == .corrupted(XarTOCLimitTests.totalMessage))
    }

    @Test("Patch 0020: an <ea> <name enctype=\"base64\"> is charged at its stored length; only file names are decoded")
    func eaNameBase64IsRaw() throws {
        // "QUJD" is "ABC", but an <ea> name is not decoded: it is 4 bytes, "f" + 4 = 5.
        let url = try Self.withHeap(
            "<file id=\"1\"><name>f</name>\(Base.fileMeta)" + Self.ea("<name enctype=\"base64\">QUJD</name>")
                + "</file>")
        #expect(try Self.eaNames(url) == ["f": ["QUJD"]])
        #expect(Base.libarchiveError(url, total: 5) == nil)
        #expect(Base.libarchiveError(url, total: 4) == .corrupted(XarTOCLimitTests.totalMessage))
    }
}
