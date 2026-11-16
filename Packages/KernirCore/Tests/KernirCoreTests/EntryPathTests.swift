import CLibArchive
import XCTest
@testable import KernirCore

final class EntryPathTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(EntryPath.normalize("./a/b/"), "a/b")
        XCTAssertEqual(EntryPath.normalize("/abs/x"), "abs/x")
        XCTAssertEqual(EntryPath.normalize("../../etc/passwd"), "etc/passwd")
        XCTAssertEqual(EntryPath.normalize("a//b/./c"), "a/b/c")
        XCTAssertEqual(EntryPath.normalize("a/../b"), "a/b")
        for s in [".", "", "/", "./"] { XCTAssertNil(EntryPath.normalize(s)) }
    }

    func testIsSelected() {
        XCTAssertTrue(EntryPath.isSelected("src/a.swift", by: ["src"]))
        XCTAssertTrue(EntryPath.isSelected("src", by: ["src"]))
        XCTAssertFalse(EntryPath.isSelected("srcx/a", by: ["src"]))
    }

    func testFastNormalizeMatchesScalarPath() {
        let alphabet = ["a", ".", "/", "\\", "\0", "é"]
        var inputs = [""]
        var frontier = [""]
        for _ in 1...5 {
            frontier = frontier.flatMap { p in alphabet.map { p + $0 } }
            inputs += frontier
        }
        for s in inputs {
            let n = EntryPath.normalize(s)
            XCTAssertEqual(n, EntryPath.normalizeScalars(s), "normalize \(s.debugDescription)")
            XCTAssertEqual(EntryPath.ancestors(of: s), EntryPath.ancestorsScalars(of: s),
                           "ancestors raw \(s.debugDescription)")
            if let n {
                XCTAssertEqual(EntryPath.ancestors(of: n), EntryPath.ancestorsScalars(of: n),
                               "ancestors \(n.debugDescription)")
            }
        }
    }

    func testAncestors() {
        XCTAssertEqual(EntryPath.ancestors(of: "a/b/c"), ["a", "a/b"])
        XCTAssertEqual(EntryPath.ancestors(of: "a"), [])
    }

    /// Byte-level safety invariant for every normalized result.
    private func assertSafe(_ s: String?, file: StaticString = #filePath, line: UInt = #line) {
        guard let s else { return }
        let bytes = Array(s.utf8)
        XCTAssertNotEqual(bytes.first, 0x2F, file: file, line: line)
        XCTAssertFalse(bytes.contains(0), file: file, line: line)
        for c in bytes.split(separator: 0x2F, omittingEmptySubsequences: false) {
            XCTAssertFalse(c.isEmpty || Array(c) == [0x2E] || Array(c) == [0x2E, 0x2E], file: file, line: line)
        }
    }

    func testNormalizeCombiningMarkAfterSlash() {
        let r = EntryPath.normalize("../\u{301}../etc/x")!
        XCTAssertTrue(r.unicodeScalars.elementsEqual("\u{301}../etc/x".unicodeScalars))
        for s in ["../\u{301}../etc/x", "a/.\u{301}/b", "...", "a\u{0}b/c", "a\\b", "./a/b/", "/abs/x", "../../etc/passwd"] {
            assertSafe(EntryPath.normalize(s))
        }
        XCTAssertNotEqual(r.utf8.first, 0x2F)
        let comps = r.unicodeScalars.split(separator: "/").map { String(String.UnicodeScalarView($0)) }
        XCTAssertEqual(comps.map { Array($0.unicodeScalars) },
                       ["\u{301}..", "etc", "x"].map { Array($0.unicodeScalars) })
        XCTAssertFalse(comps.contains { $0.unicodeScalars.elementsEqual("..".unicodeScalars) })
        XCTAssertEqual(Array(EntryPath.normalize("a/.\u{301}/b")!.unicodeScalars),
                       Array("a/.\u{301}/b".unicodeScalars))
        XCTAssertEqual(EntryPath.normalize("..."), "...")
        XCTAssertEqual(EntryPath.normalize("a\u{0}b/c"), "ab/c")
        XCTAssertNil(EntryPath.normalize("\u{0}"))
        XCTAssertEqual(EntryPath.normalize("a\\b"), "a\\b")
    }

    func testScalarLevelAncestorsAndSelection() {
        XCTAssertEqual(EntryPath.ancestors(of: "a/\u{301}b/c").map { Array($0.unicodeScalars) },
                       ["a", "a/\u{301}b"].map { Array($0.unicodeScalars) })
        XCTAssertTrue(EntryPath.isSelected("src/a", by: ["src"]))
        XCTAssertFalse(EntryPath.isSelected("src\u{301}/a", by: ["src"]))
    }

    /// `parent(of:)` and `split(_:)` see a "/" that a combining mark, a ZWJ or a Prepend scalar hides in a Character.
    func testParentAndSplitOnScalars() {
        XCTAssertEqual(EntryPath.parent(of: "d/\u{301}x").map { Array($0.unicodeScalars) }, ["d"])
        XCTAssertEqual(EntryPath.parent(of: "a/\u{301}b/c").map { Array($0.unicodeScalars) },
                       Array("a/\u{301}b".unicodeScalars))
        XCTAssertEqual(EntryPath.parent(of: "d\u{600}/x").map { Array($0.unicodeScalars) }, ["d", "\u{600}"])
        XCTAssertEqual(EntryPath.parent(of: "/r/d/\u{200D}x"), "/r/d")
        XCTAssertEqual(EntryPath.parent(of: "a/b"), "a")
        XCTAssertEqual(EntryPath.parent(of: "/x"), "")
        XCTAssertNil(EntryPath.parent(of: "x"))
        XCTAssertNil(EntryPath.parent(of: ""))
        XCTAssertEqual(EntryPath.split("a/\u{301}b/\u{200D}c").map { Array($0.unicodeScalars) },
                       [["a"], ["\u{301}", "b"], ["\u{200D}", "c"]])
        XCTAssertEqual(EntryPath.split("d\u{600}/x").map { Array($0.unicodeScalars) }, [["d", "\u{600}"], ["x"]])
        XCTAssertEqual(EntryPath.split("/a//b/"), ["a", "b"])
        XCTAssertEqual(EntryPath.split(""), [])
    }

    func testDecodeUTF8() {
        XCTAssertEqual(EntryNameDecoder.decode(Array("Привет.txt".utf8)), "Привет.txt")
    }

    func testDecodeCP866() {
        XCTAssertEqual(EntryNameDecoder.decode([0x8F, 0xE0, 0xA8, 0xA2, 0xA5, 0xE2, 0x2E, 0x74, 0x78, 0x74]), "Привет.txt")
        let bytes = cp866Bytes("Отчёт_2024.doc")
        XCTAssertEqual(EntryNameDecoder.decode(bytes), "Отчёт_2024.doc")
    }

    func testDecodeCP437() {
        XCTAssertEqual(EntryNameDecoder.decode([0x43, 0x61, 0x66, 0x82]), "Café")
        XCTAssertEqual(EntryNameDecoder.decode([0x47, 0x72, 0x94, 0xE1, 0x65]), "Größe")
    }

    func testDecodeCP932() {
        for name in ["表だよ\\一覧表.txt", "表だよ\\漢字.txt", "ひらがな.txt", "カタカナ資料.doc", "資料v2.xlsx", "漢字.txt"] {
            XCTAssertEqual(EntryNameDecoder.decode(cp932Bytes(name)), name)
        }
    }

    /// Russian and Western names keep their decoding even where the bytes are also valid CP932.
    func testCP932DoesNotTakeRussianOrLatinNames() {
        for name in ["Привет.txt", "Ваше фото.jpg", "ВашеФото.jpg", "НовыйДокумент.doc", "Отчёт за май.xlsx",
                     "Документы\\Договор.pdf", "Счёт № 15.pdf", "ИТОГИ.xls"] {
            XCTAssertEqual(EntryNameDecoder.decode(cp866Bytes(name)), name)
        }
        let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        for name in ["Über.txt", "Größe Übersicht.pdf", "Café.txt", "Señor.doc", "naïve.txt", "Ärger.txt",
                     "résumé.pdf", "Zürich Bahnhof.jpg", "Ñandú.txt", "Ångström.txt"] {
            XCTAssertEqual(EntryNameDecoder.decode([UInt8](name.data(using: cp437)!)), name)
        }
    }

    func testDecodeNFC() {
        let s = EntryNameDecoder.decode(Array("Cafe\u{301}".utf8))
        XCTAssertEqual(s.unicodeScalars.count, 4)
    }

    func testPathnameOfUTF8Entry() {
        let e = archive_entry_new()!
        defer { archive_entry_free(e) }
        archive_entry_update_pathname_utf8(e, "dir/Cafe\u{301}.txt")
        XCTAssertEqual(EntryNameDecoder.pathname(of: e), "dir/Café.txt")
    }

    func testPathnameOfRawCP866Entry() {
        let e = archive_entry_new()!
        defer { archive_entry_free(e) }
        let bytes = cp866Bytes("Привет.txt") + [0]
        bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                archive_entry_copy_pathname(e, $0)
            }
        }
        XCTAssertEqual(EntryNameDecoder.pathname(of: e), "Привет.txt")
    }

    private func cp932Bytes(_ s: String) -> [UInt8] {
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        return [UInt8](s.data(using: enc)!)
    }

    private func cp866Bytes(_ s: String) -> [UInt8] {
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosRussian.rawValue)))
        return [UInt8](s.data(using: enc)!)
    }
}
