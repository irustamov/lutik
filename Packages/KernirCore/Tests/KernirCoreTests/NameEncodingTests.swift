import CLibArchive
import Foundation
import XCTest
@testable import KernirCore

final class NameEncodingTests: XCTestCase {
    /// One archive per row: names stored in `encoding`, detected under en-US and under each of `languages`.
    private let table: [(encoding: String.Encoding, languages: [String], names: [String])] = [
        (.windowsCP1251, ["ru-RU"], ["Отчёт за май.docx", "отчет.txt", "Фото/Лето 2024.jpg"]),
        (.cp866, ["ru-RU"], ["Привет.txt", "Отчёт_2024.doc"]),
        (.koi8R, ["ru-RU"], ["Документы/письмо.txt", "приказ.doc"]),
        (.cp932, ["ja-JP"], ["表だよ\\一覧表.txt", "ひらがな.txt", "カタカナ資料.doc", "資料v2.xlsx", "漢字.txt"]),
        (.gb18030, ["zh-Hans-CN"], ["中文文件名.txt", "报告/会议记录.docx"]),
        (.big5, ["zh-Hant-TW"], ["報告書.txt", "會議記錄.docx"]),
        (.cp949, ["ko-KR"], ["한국어 파일.txt", "보고서/회의록.hwp"]),
        (.windowsCP1252, ["de-DE"], ["Größe.txt", "Café crème.doc", "Ångström.pdf"]),
        (.cp437, [], ["Café", "Größe"]),
        (.windowsCP1250, ["cs-CZ"], ["Žluťoučký kůň.txt", "Łódź.doc"]),
        (.utf8, [], ["Привет.txt", "中文.txt"]),
    ]

    func testDetectsEachEncoding() {
        for row in table {
            let title = String.localizedName(of: row.encoding)
            let bytes = row.names.map { [UInt8]($0.data(using: row.encoding)!) }
            for language in ["en-US"] + row.languages {
                XCTAssertEqual(NameEncodingDetector.detect(bytes, preferredLanguages: [language]), row.encoding,
                               "\(title) under \(language)")
            }
            for (name, raw) in zip(row.names, bytes) {
                XCTAssertEqual(NameEncodingDetector.decode(raw, as: row.encoding), name, title)
            }
        }
    }

    func testCP437RowUsesEntryPathBytes() {
        XCTAssertEqual([UInt8]("Café".data(using: .cp437)!), [0x43, 0x61, 0x66, 0x82])
        XCTAssertEqual([UInt8]("Größe".data(using: .cp437)!), [0x47, 0x72, 0x94, 0xE1, 0x65])
    }

    /// CP1251 Cyrillic bytes all read as Latin letters in CP1252 and CP1250; they must stay Cyrillic.
    func testCyrillicDoesNotReadAsLatin() {
        let names = ["Привет.txt", "Новая папка/файл.doc"].map { [UInt8]($0.data(using: .windowsCP1251)!) }
        XCTAssertEqual(NameEncodingDetector.detect(names, preferredLanguages: ["en-US"]), .windowsCP1251)
        for name in names {
            XCTAssertEqual(NameEncodingDetector.detect([name], preferredLanguages: ["en-US"]), .windowsCP1251)
        }
    }

    /// Each name `EntryPathTests` decodes one at a time (testDecodeCP866/CP437/CP932 and
    /// testCP932DoesNotTakeRussianOrLatinNames), as a one-name archive, in any UI language.
    func testSingleNameCasesFromEntryPathTests() {
        var cases: [(bytes: [UInt8], encoding: String.Encoding, name: String)] = [
            ([0x8F, 0xE0, 0xA8, 0xA2, 0xA5, 0xE2, 0x2E, 0x74, 0x78, 0x74], .cp866, "Привет.txt"),
            ([UInt8]("Отчёт_2024.doc".data(using: .cp866)!), .cp866, "Отчёт_2024.doc"),
            ([0x43, 0x61, 0x66, 0x82], .cp437, "Café"),
            ([0x47, 0x72, 0x94, 0xE1, 0x65], .cp437, "Größe"),
        ]
        for name in ["表だよ\\一覧表.txt", "表だよ\\漢字.txt", "ひらがな.txt", "カタカナ資料.doc", "資料v2.xlsx", "漢字.txt"] {
            cases.append(([UInt8](name.data(using: .cp932)!), .cp932, name))
        }
        // testCP932DoesNotTakeRussianOrLatinNames
        for name in ["Привет.txt", "Ваше фото.jpg", "ВашеФото.jpg", "НовыйДокумент.doc", "Отчёт за май.xlsx",
                     "Документы\\Договор.pdf", "Счёт № 15.pdf", "ИТОГИ.xls"] {
            cases.append(([UInt8](name.data(using: .cp866)!), .cp866, name))
        }
        for name in ["Über.txt", "Größe Übersicht.pdf", "Café.txt", "Señor.doc", "naïve.txt", "Ärger.txt",
                     "résumé.pdf", "Zürich Bahnhof.jpg", "Ñandú.txt", "Ångström.txt"] {
            cases.append(([UInt8](name.data(using: .cp437)!), .cp437, name))
        }
        for c in cases {
            for language in ["en-US", "ru-RU", "ja-JP"] {
                XCTAssertEqual(NameEncodingDetector.detect([c.bytes], preferredLanguages: [language]), c.encoding,
                               "\(c.name) under \(language)")
            }
            XCTAssertEqual(NameEncodingDetector.decode(c.bytes, as: c.encoding), c.name)
        }
    }

    /// French Œ/œ (CP1252 0x8C/0x9C) read as Ś/ś in CP1250 and as î/£ in CP437; the names must stay CP1252.
    func testFrenchOELigatureStaysCP1252() {
        let archives = [["cœur.txt"], ["sœur.doc"], ["Œuvre.txt"], ["cœur.txt", "sœur.doc", "Œuvre.txt"],
                        ["Bœuf bourguignon.doc"], ["Œuvres complètes.pdf"], ["manœuvre.txt"]]
        for names in archives {
            let bytes = names.map { [UInt8]($0.data(using: .windowsCP1252)!) }
            for language in ["en-US", "fr-FR"] {
                XCTAssertEqual(NameEncodingDetector.detect(bytes, preferredLanguages: [language]), .windowsCP1252,
                               "\(names) under \(language)")
            }
            for (name, raw) in zip(names, bytes) {
                XCTAssertEqual(NameEncodingDetector.decode(raw, as: .windowsCP1252), name)
            }
        }
    }

    /// Polish Ś/ś (CP1250 0x8C/0x9C) read as Œ/œ in CP1252; the names must stay CP1250.
    func testPolishSAcuteStaysCP1250() {
        let archives = [["Śląsk.txt"], ["Śląsk.txt", "Gęś.doc", "Świat/środa.txt"], ["coś nowego.doc"]]
        for names in archives {
            let bytes = names.map { [UInt8]($0.data(using: .windowsCP1250)!) }
            for language in ["pl-PL", "en-US"] {
                XCTAssertEqual(NameEncodingDetector.detect(bytes, preferredLanguages: [language]), .windowsCP1250,
                               "\(names) under \(language)")
            }
            for (name, raw) in zip(names, bytes) {
                XCTAssertEqual(NameEncodingDetector.decode(raw, as: .windowsCP1250), name)
            }
        }
    }

    /// E8B1 is a GB2312 level 2 hanzi and a less frequent Big5 hanzi, and not UTF-8: the scores tie and the UI
    /// language decides.
    func testPreferredLanguageBreaksTies() {
        let name: [UInt8] = [0xE8, 0xB1, 0xE8, 0xB1]
        XCTAssertEqual(NameEncodingDetector.detect([name], preferredLanguages: ["zh-Hant"]), .big5)
        XCTAssertEqual(NameEncodingDetector.detect([name], preferredLanguages: ["zh-Hans"]), .gb18030)
    }

    func testDetectorSamplesLargeInput() {
        let names = (0..<100_000).map { [UInt8]("Папка \($0 % 100)/Отчёт \($0).docx".data(using: .windowsCP1251)!) }
        XCTAssertEqual(NameEncodingDetector.sample(names).count, NameEncodingDetector.sampleLimit)
        let start = Date()
        let encoding = NameEncodingDetector.detect(names, preferredLanguages: ["en-US"])
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(encoding, .windowsCP1251)
        XCTAssertLessThan(elapsed, 3)
    }

    func testChoicesOrder() {
        XCTAssertEqual(ArchiveNameEncoding.choices, [.utf8, .windowsCP1251, .cp866, .koi8R, .cp932, .gb18030, .big5,
                                                      .cp949, .windowsCP1252, .cp437, .windowsCP1250])
    }

    func testDecodeFallsBackToCP437() {
        XCTAssertEqual(NameEncodingDetector.decode([0x41, 0x82], as: .cp932), "Aé")
        XCTAssertEqual(NameEncodingDetector.decode(Array("Cafe\u{301}".utf8), as: .utf8).unicodeScalars.count, 4)
    }

    // MARK: - One encoding per archive (engine)

    /// Each detector row as a zip without bit 11 lists its own names (Locale.preferredLanguages decides only
    /// ties; every row was verified under en-US and its own language at the detector level).
    func testAutomaticListsEachLegacyZip() async throws {
        for row in table {
            let url = Self.legacyZip(row.names, as: row.encoding)
            let r = try await Self.open(url)
            XCTAssertEqual(Set(r.entries.map(\.path)), Self.listing(row.names), String.localizedName(of: row.encoding))
            XCTAssertEqual(r.nameDecoding.legacy, row.encoding, String.localizedName(of: row.encoding))
        }
    }

    func testManualChoiceRelists() async throws {
        let names = ["Отчёт за май.docx", "отчет.txt", "Фото/Лето 2024.jpg"]
        let url = Self.legacyZip(names, as: .windowsCP1251)
        let dos = try await Self.open(url, .specific(.cp866))
        let asCP866 = names.map { String(bytes: $0.data(using: .windowsCP1251)!, encoding: .cp866)! }
        XCTAssertNotEqual(asCP866, names)
        XCTAssertEqual(Set(dos.entries.map(\.path)), Self.listing(asCP866))
        XCTAssertEqual(dos.nameDecoding.legacy, .cp866)
        let windows = try await Self.open(url, .specific(.windowsCP1251))
        XCTAssertEqual(Set(windows.entries.map(\.path)), Self.listing(names))
        let automatic = try await Self.open(url)
        XCTAssertEqual(Set(automatic.entries.map(\.path)), Self.listing(names))
    }

    /// Bit-11 and 0x7075 names are declared: they keep their UTF-8 reading and stay out of detection.
    func testMixedFlaggedAndLegacyZip() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let legacy = ["Отчёт за май.docx", "отчет.txt"]
        var entries = legacy.map { (nameBytes: [UInt8]($0.data(using: .windowsCP1251)!), utf8Flag: false, dosTime: t,
                                    data: [UInt8]("x".utf8)) }
        entries.append((nameBytes: Array("中文/日本語.txt".utf8), utf8Flag: true, dosTime: t, data: [0x79]))
        // Stored in CP932, named in UTF-8 by its Unicode Path field.
        entries.append((nameBytes: [UInt8]("表.txt".data(using: .cp932)!), utf8Flag: false, dosTime: t, data: [0x7A]))
        let url = SyntheticZip.write(SyntheticZip.stored(entries, unicodePath: [3: "表.txt"]))
        let r = try await Self.open(url)
        XCTAssertEqual(Set(r.entries.map(\.path)), Self.listing(legacy + ["中文/日本語.txt", "表.txt"]))
        XCTAssertEqual(r.nameDecoding.legacy, .windowsCP1251)

        // Manual CP866: declared names unchanged, the two legacy names read as CP866 from the same bytes.
        let asCP866 = legacy.map { String(bytes: $0.data(using: .windowsCP1251)!, encoding: .cp866)! }
        XCTAssertNotEqual(asCP866, legacy)
        let manual = try await Self.open(url, .specific(.cp866))
        XCTAssertEqual(Set(manual.entries.map(\.path)), Self.listing(asCP866 + ["中文/日本語.txt", "表.txt"]))
        XCTAssertEqual(manual.nameDecoding.legacy, .cp866)
    }

    func testDeclaredNamesIgnoreManualChoice() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let flagged = SyntheticZip.write(SyntheticZip.stored(["Привет.txt", "中文/日本語.txt"].map {
            (nameBytes: Array($0.utf8), utf8Flag: true, dosTime: t, data: [UInt8]("x".utf8))
        }))
        for url in [ReaderListingTests.fixture("7z/unicode.7z"), flagged] {
            let automatic = try await Self.open(url)
            let manual = try await Self.open(url, .specific(.cp866))
            XCTAssertFalse(automatic.entries.isEmpty)
            XCTAssertEqual(manual.entries.map(\.path), automatic.entries.map(\.path), url.lastPathComponent)
            XCTAssertNil(manual.nameDecoding.legacy)
            XCTAssertFalse(manual.nameDecoding.hasLegacyNames)
            XCTAssertFalse(automatic.nameDecoding.hasLegacyNames)
        }
    }

    /// 表 is 95 5C in CP932. The directory entry "表/" alone reads as CP866 "Х\/" one name at a time; decided per
    /// archive, it joins its file's folder: exactly one "表".
    func testCP932BackslashTrailByteStillJoined() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let dir: [UInt8] = [0x95, 0x5C, 0x2F]
        let file: [UInt8] = [0x95, 0x5C, 0x2F, 0x88, 0xEA, 0x97, 0x97, 0x95, 0x5C, 0x2E, 0x74, 0x78, 0x74]
        let url = SyntheticZip.write(SyntheticZip.stored([
            (nameBytes: dir, utf8Flag: false, dosTime: t, data: []),
            (nameBytes: file, utf8Flag: false, dosTime: t, data: [UInt8]("x".utf8)),
        ]))
        let r = try await Self.open(url)
        XCTAssertEqual(r.entries.map(\.path), ["表", "表/一覧表.txt"])
        XCTAssertEqual(r.entries.filter(\.isDirectory).map(\.path), ["表"])
        XCTAssertEqual(r.nameDecoding.legacy, .cp932)

        let manual = try await Self.open(url, .specific(.cp932))
        XCTAssertEqual(manual.entries.map(\.path), ["表", "表/一覧表.txt"])
        XCTAssertEqual(manual.entries.filter(\.isDirectory).map(\.path), ["表"])
        XCTAssertEqual(manual.nameDecoding.legacy, .cp932)
    }

    /// Different raw spellings of one name decode and normalize to one path: the last header wins, as for exact
    /// duplicates.
    func testLegacyNamesCollidingAfterDecode() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let name = [UInt8]("Папка/Отчёт.txt".data(using: .windowsCP1251)!)
        let spellings = [name, Array("./".utf8) + name, [UInt8]("Папка//Отчёт.txt".data(using: .windowsCP1251)!)]
        let url = SyntheticZip.write(SyntheticZip.stored(spellings.enumerated().map { i, bytes in
            (nameBytes: bytes, utf8Flag: false, dosTime: t, data: [UInt8](repeating: 0x61, count: i + 1))
        }))
        let r = try await Self.open(url)
        XCTAssertEqual(r.entries.map(\.path), ["Папка", "Папка/Отчёт.txt"])
        XCTAssertEqual(r.entries.last?.size, 3)
        XCTAssertEqual(r.headerOrdinalByPath["Папка/Отчёт.txt"], 2)
        XCTAssertEqual(r.nameDecoding.legacy, .windowsCP1251)

        // Extract-all: no crash, no overwrite error, one file holding the winning (last) header's bytes.
        let out = Fixtures.tempDir()
        try await r.extract(nil, to: out, progress: nil)
        XCTAssertEqual(Self.diskListing(out), ["Папка", "Папка/Отчёт.txt"])
        let file = out.appending(path: "Папка").appending(path: "Отчёт.txt")
        XCTAssertEqual(try Data(contentsOf: file), Data([0x61, 0x61, 0x61]))
    }

    /// WinRAR 2.x-4.x stores an OEM (CP866) name, plus a Unicode copy (FHD_UNICODE) only when the name does not
    /// fit OEM. The Unicode names are declared: they keep their reading under every choice and stay out of
    /// detection, so the OEM name alone decides the archive's encoding.
    func testMixedOEMAndUnicodeRAR4() async throws {
        let oem = "Привет.txt", unicode = "Отчёт «итоги».txt", utf8Form = "Ёлка «зима».txt"
        let url = SyntheticRAR4.write([
            (name: [UInt8](oem.data(using: .cp866)!), unicode: nil, data: Array("one".utf8)),
            // WinRAR's form: the OEM spelling ("?" for « »), NUL, then the Unicode name.
            (name: [UInt8]("Отчёт ?итоги?.txt".data(using: .cp866)!), unicode: unicode, data: Array("two".utf8)),
            // FHD_UNICODE with no NUL: the name bytes are UTF-8.
            (name: Array(utf8Form.utf8), unicode: "", data: Array("three".utf8)),
        ])
        let automatic = try await Self.open(url)
        XCTAssertEqual(automatic.entries.map(\.path), [oem, unicode, utf8Form])
        XCTAssertEqual(automatic.nameDecoding.legacy, .cp866)
        let out = Fixtures.tempDir()
        try await automatic.extract(nil, to: out, progress: nil)
        XCTAssertEqual(Self.diskListing(out), [oem, unicode, utf8Form])

        let manual = try await Self.open(url, .specific(.cp866))
        XCTAssertEqual(manual.entries.map(\.path), [oem, unicode, utf8Form])
        XCTAssertEqual(manual.nameDecoding.legacy, .cp866)

        // Another manual choice changes the OEM name only.
        let windows = try await Self.open(url, .specific(.windowsCP1251))
        let oemAsCP1251 = try XCTUnwrap(String(bytes: oem.data(using: .cp866)!, encoding: .windowsCP1251))
        XCTAssertNotEqual(oemAsCP1251, oem)
        XCTAssertEqual(windows.entries.map(\.path), [oemAsCP1251.precomposedStringWithCanonicalMapping, unicode, utf8Form])
    }

    /// The mixed archive plus an OEM "сон.txt": its CP866 bytes E1 AE AD are valid UTF-8 (U+1BAD), so only the
    /// reader's own word (patch 0010) tells it is an OEM name. Under automatic and under manual CP866 every name
    /// lists right, and the Unicode name reads the same under both.
    func testOEMNameThatIsValidUTF8StaysLegacyInRAR4() async throws {
        let oem = "Привет.txt", unicode = "Отчёт «итоги».txt", son = "сон.txt"
        let sonBytes = [UInt8](son.data(using: .cp866)!)
        XCTAssertEqual(sonBytes, [0xE1, 0xAE, 0xAD] + Array(".txt".utf8))
        XCTAssertNotNil(String(bytes: sonBytes, encoding: .utf8))
        let url = SyntheticRAR4.write([
            (name: [UInt8](oem.data(using: .cp866)!), unicode: nil, data: Array("one".utf8)),
            (name: [UInt8]("Отчёт ?итоги?.txt".data(using: .cp866)!), unicode: unicode, data: Array("two".utf8)),
            (name: sonBytes, unicode: nil, data: Array("three".utf8)),
        ])
        for encoding in [ArchiveNameEncoding.automatic, .specific(.cp866)] {
            let r = try await Self.open(url, encoding)
            XCTAssertEqual(r.entries.map(\.path), [oem, unicode, son], "\(encoding)")
            XCTAssertEqual(r.nameDecoding.legacy, .cp866, "\(encoding)")
            let out = Fixtures.tempDir()
            try await r.extract(nil, to: out, progress: nil)
            XCTAssertEqual(Self.diskListing(out), [oem, unicode, son], "\(encoding)")
            XCTAssertEqual(try Data(contentsOf: out.appending(path: son)), Data("three".utf8), "\(encoding)")
        }
    }

    /// A RAR4 archive with only OEM names (and ASCII ones) still detects CP866.
    func testPureOEMRAR4Detects() async throws {
        let names = ["Привет.txt", "Отчёт_2024.doc", "Документы/отчёт.txt", "readme.txt"]
        let url = SyntheticRAR4.write(names.map { (name: [UInt8]($0.data(using: .cp866)!), unicode: nil, data: Array($0.utf8)) })
        let r = try await Self.open(url)
        XCTAssertEqual(Set(r.entries.map(\.path)), Self.listing(names))
        XCTAssertEqual(r.nameDecoding.legacy, .cp866)
    }

    /// Two different CP932 byte strings for one character: 87 54 (NEC row 13) and FA 4A (IBM extension) both
    /// decode to "Ⅰ". The two headers become one listed entry; the later header wins and extract writes one file.
    func testLegacyNamesCollidingThroughDecoding() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let nec: [UInt8] = [0x87, 0x54] + Array(".txt".utf8), ibm: [UInt8] = [0xFA, 0x4A] + Array(".txt".utf8)
        XCTAssertEqual(String(bytes: nec, encoding: .cp932), "Ⅰ.txt")
        XCTAssertEqual(String(bytes: ibm, encoding: .cp932), "Ⅰ.txt")
        let others = ["ひらがな.txt", "カタカナ資料.doc"]
        let url = SyntheticZip.write(SyntheticZip.stored(
            [(nameBytes: nec, utf8Flag: false, dosTime: t, data: Array("first".utf8)),
             (nameBytes: ibm, utf8Flag: false, dosTime: t, data: Array("second!".utf8))]
            + others.map { (nameBytes: [UInt8]($0.data(using: .cp932)!), utf8Flag: false, dosTime: t, data: [0x78]) }))
        for encoding in [ArchiveNameEncoding.automatic, .specific(.cp932)] {
            let r = try await Self.open(url, encoding)
            XCTAssertEqual(r.nameDecoding.legacy, .cp932, "\(encoding)")
            XCTAssertEqual(r.entries.map(\.path), ["Ⅰ.txt"] + others, "\(encoding)")
            XCTAssertEqual(r.entries.first?.size, 7, "\(encoding)")
            XCTAssertEqual(r.headerOrdinalByPath["Ⅰ.txt"], 1, "\(encoding)")

            let out = Fixtures.tempDir()
            try await r.extract(nil, to: out, progress: nil)
            XCTAssertEqual(Self.diskListing(out), Set(["Ⅰ.txt"] + others), "\(encoding)")
            XCTAssertEqual(try Data(contentsOf: out.appending(path: "Ⅰ.txt")), Data("second!".utf8), "\(encoding)")
        }
    }

    func testExtractUsesChosenEncoding() async throws {
        let names = ["Отчёт за май.docx", "Фото/Лето 2024.jpg"]
        let zipURL = Self.legacyZip(names, as: .windowsCP1251)
        let zipReader = try await Self.open(zipURL)
        let out = Fixtures.tempDir()
        try await zipReader.extract(nil, to: out, progress: nil)
        XCTAssertEqual(Self.diskListing(out), Set(zipReader.entries.map(\.path)))
        XCTAssertEqual(Self.diskListing(out), Self.listing(names))

        // A tar symlink whose target is stored in CP1251 too: the target decodes like the names.
        let cp1251 = { (s: String) in [UInt8](s.data(using: .windowsCP1251)!) }
        let tarURL = Self.ustar([
            (name: cp1251("Отчёт.txt"), type: UInt8(ascii: "0"), link: [], data: Array("data".utf8)),
            (name: cp1251("ссылка"), type: UInt8(ascii: "2"), link: cp1251("Отчёт.txt"), data: []),
        ])
        let tar = try await Self.open(tarURL)
        XCTAssertEqual(tar.entries.map(\.path), ["Отчёт.txt", "ссылка"])
        XCTAssertEqual(tar.symlinkTargetByPath["ссылка"], "Отчёт.txt")
        let tarOut = Fixtures.tempDir()
        try await tar.extract(nil, to: tarOut, progress: nil)
        XCTAssertEqual(Self.diskListing(tarOut), ["Отчёт.txt", "ссылка"])
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: tarOut.appending(path: "ссылка").path)
        XCTAssertEqual(target.precomposedStringWithCanonicalMapping, "Отчёт.txt")
        let temp = try await tar.extractToTemporaryFile("ссылка")
        XCTAssertEqual(try Data(contentsOf: temp), Data("data".utf8))
    }

    /// The CP1251 ustar symlink of `testExtractUsesChosenEncoding`, saved into another family (zip, 7z): the
    /// repack writes the target decoded with the source's encoding, so it still names "Отчёт.txt".
    func testRepackDecodesLegacySymlinkTarget() async throws {
        let tarURL = Self.ustar([
            (name: Self.cp1251("Отчёт.txt"), type: UInt8(ascii: "0"), link: [], data: Array("data".utf8)),
            (name: Self.cp1251("ссылка"), type: UInt8(ascii: "2"), link: Self.cp1251("Отчёт.txt"), data: []),
        ])
        let tar = try await Self.open(tarURL)
        XCTAssertEqual(tar.nameDecoding.legacy, .windowsCP1251)
        for format in [ArchiveFormat.zip, .sevenZip] {
            let out = Fixtures.tempDir().appending(path: "saved.\(format.fileExtension)")
            try await ArchiveWriter.write(source: tar, changes: ArchiveChangeSet(), format: format, to: out)
            let saved = try await Self.open(out)
            XCTAssertEqual(saved.entries.map(\.path), ["Отчёт.txt", "ссылка"], "\(format)")
            XCTAssertEqual(saved.symlinkTargetByPath["ссылка"], "Отчёт.txt", "\(format)")
            let disk = Fixtures.tempDir()
            try await saved.extract(nil, to: disk, progress: nil)
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: disk.appending(path: "ссылка").path)
            XCTAssertEqual(target.precomposedStringWithCanonicalMapping, "Отчёт.txt", "\(format)")
        }
    }

    /// Plain ustar names, a hardlink target and a directory, all stored in CP1251.
    func testUstarCP1251Tar() async throws {
        let cp1251 = { (s: String) in [UInt8](s.data(using: .windowsCP1251)!) }
        let url = Self.ustar([
            (name: cp1251("Фото/"), type: UInt8(ascii: "5"), link: [], data: []),
            (name: cp1251("Фото/Лето 2024.jpg"), type: UInt8(ascii: "0"), link: [], data: Array("jpg".utf8)),
            (name: cp1251("Отчёт за май.docx"), type: UInt8(ascii: "0"), link: [], data: Array("doc".utf8)),
            (name: cp1251("копия.jpg"), type: UInt8(ascii: "1"), link: cp1251("Фото/Лето 2024.jpg"), data: []),
        ])
        let r = try await Self.open(url)
        XCTAssertEqual(r.entries.map(\.path), ["Фото", "Фото/Лето 2024.jpg", "Отчёт за май.docx", "копия.jpg"])
        XCTAssertEqual(r.hardlinkTargetByPath["копия.jpg"], "Фото/Лето 2024.jpg")
        XCTAssertEqual(r.nameDecoding.legacy, .windowsCP1251)
        let out = Fixtures.tempDir()
        try await r.extract(["копия.jpg"], to: out, progress: nil)
        XCTAssertEqual(try Data(contentsOf: out.appending(path: "копия.jpg")), Data("jpg".utf8))
    }

    /// List, extract one entry, repack with one removal; every pass agrees with the first listing.
    func testListExtractRepackAgreeUnderAutomatic() async throws {
        let names = ["Документы/отчёт.txt", "Привет.txt", "Отчёт_2024.doc"]
        let url = Self.legacyZip(names, as: .cp866)
        let r = try await Self.open(url)
        let listing = r.entries.map(\.path)
        XCTAssertEqual(Set(listing), Self.listing(names))

        let out = Fixtures.tempDir()
        try await r.extract(["Документы/отчёт.txt"], to: out, progress: nil)
        XCTAssertEqual(Self.diskListing(out), ["Документы", "Документы/отчёт.txt"])

        let dest = Fixtures.tempDir().appending(path: "out.zip")
        try await ArchiveWriter.write(source: r, changes: ArchiveChangeSet(removedPaths: ["Привет.txt"]), format: .zip,
                                      to: dest)
        let repacked = try await Self.open(dest)
        XCTAssertEqual(repacked.entries.map(\.path), listing.filter { $0 != "Привет.txt" })
        XCTAssertEqual(repacked.entries.map(\.id), r.entries.map(\.id).filter { $0 != "Привет.txt" })
    }

    func testOpenWithEncodingReportsIt() async throws {
        let cp866 = ReaderListingTests.fixture("zip/cp866.zip")
        let manual = try await Archive.open(at: cp866, nameEncoding: .specific(.windowsCP1251))
        XCTAssertEqual(manual.nameEncoding, .specific(.windowsCP1251))
        XCTAssertEqual(manual.legacyNameEncoding, .windowsCP1251)
        let automatic = try await Archive.open(at: cp866)
        XCTAssertEqual(automatic.nameEncoding, .automatic)
        XCTAssertEqual(automatic.legacyNameEncoding, .cp866)
        XCTAssertEqual(Set(automatic.entries.map(\.path)), ["Документы", "Документы/отчёт.txt", "Привет.txt"])
        let sevenZip = try await Archive.open(at: ReaderListingTests.fixture("7z/unicode.7z"),
                                              nameEncoding: .specific(.windowsCP1251))
        XCTAssertEqual(sevenZip.nameEncoding, .specific(.windowsCP1251))
        XCTAssertNil(sevenZip.legacyNameEncoding)
    }

    // MARK: - Save keeps untouched names' raw bytes

    /// zip -> zip: the kept CP1251 entry keeps its bytes and no bit 11, the kept bit-11 entry its bytes and bit 11.
    /// The 0x7075 entry is declared: it is written as today, UTF-8 with bit 11, and no entry carries a 0x7075 field.
    /// The added file is UTF-8 with bit 11.
    func testZipSaveKeepsRawBytesAndFlags() async throws {
        let source = try await Self.open(Self.mixedZip())
        XCTAssertEqual(source.nameDecoding.legacy, .windowsCP1251)
        let out = try await Self.saveZip(source, removing: "отчет.txt")
        try Self.assertKeptRawAndAddedUTF8(out)
        let reopened = try await Self.open(out)
        XCTAssertEqual(reopened.entries.map(\.path), ["Отчёт за май.docx", "Привет.txt", "表.txt", "Новый.txt"])
    }

    /// Opened as CP866 (names shown as mojibake), saved with one removal: the kept entries are still the source's
    /// CP1251 bytes, so an automatic open of the result reads them right again.
    func testSaveAfterManualChoiceKeepsRawBytes() async throws {
        let source = try await Self.open(Self.mixedZip(), .specific(.cp866))
        let removed = try XCTUnwrap(String(bytes: Self.cp1251("отчет.txt"), encoding: .cp866))
        XCTAssertTrue(source.entries.contains { $0.path == removed })
        let out = try await Self.saveZip(source, removing: removed)
        try Self.assertKeptRawAndAddedUTF8(out)
        let reopened = try await Self.open(out)
        XCTAssertEqual(reopened.entries.map(\.path), ["Отчёт за май.docx", "Привет.txt", "表.txt", "Новый.txt"])
    }

    /// CP1251 ustar -> tar with one removal: every kept name, hardlink target and symlink target reads back as the
    /// same raw bytes (libarchive's pax writer stores them with hdrcharset=BINARY). Removal only, so every name
    /// written is a kept one; `testTarSaveWithAddedNameWritesEveryNameUTF8` is the added-file variant.
    func testTarSaveKeepsRawBytes() async throws {
        let cp1251 = Self.cp1251
        let url = Self.cleanCP1251Tar()
        let source = try await Self.open(url)
        let out = Fixtures.tempDir().appending(path: "saved.tar")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["удалить.txt"]),
                                      format: .tar, to: out)

        let expected = try Self.rawNames(url).filter { $0.name != cp1251("удалить.txt") }
        XCTAssertEqual(expected.count, 5)
        XCTAssertEqual(try Self.rawNames(out), expected)
        XCTAssertNotNil(try Data(contentsOf: out).range(of: Data("hdrcharset=BINARY".utf8)))
        let reopened = try await Self.open(out)
        XCTAssertEqual(reopened.entries.map(\.path), source.entries.map(\.path).filter { $0 != "удалить.txt" })
        XCTAssertEqual(reopened.hardlinkTargetByPath["копия.jpg"], "Фото/Лето 2024.jpg")
        XCTAssertEqual(reopened.symlinkTargetByPath["ссылка"], "Отчёт за май.docx")
    }

    /// Probe A: the same tar plus an added Cyrillic file. A tar's names are never declared, so one
    /// decoding reads them all back: the save writes every name and link target as UTF-8 (no BINARY header), and
    /// the reopened archive lists every name as before the save, links included. An ASCII addition keeps the raw
    /// bytes: ASCII reads the same in every encoding.
    func testTarSaveWithAddedNameWritesEveryNameUTF8() async throws {
        let url = Self.cleanCP1251Tar()
        let source = try await Self.open(url)
        XCTAssertEqual(source.nameDecoding.legacy, .windowsCP1251)
        let before = source.entries.map(\.path).filter { $0 != "удалить.txt" }

        let out = try await Self.saveTar(source, removing: "удалить.txt", adding: "Новый файл.txt")
        let raw = try Self.rawNames(out)
        let written = before.map { $0 == "Фото" ? "Фото/" : $0 } + ["Новый файл.txt"]
        XCTAssertEqual(raw.map(\.name), written.map { Array($0.utf8) })
        XCTAssertEqual(raw.compactMap(\.hardlink), [Array("Фото/Лето 2024.jpg".utf8)])
        XCTAssertEqual(raw.compactMap(\.symlink), [Array("Отчёт за май.docx".utf8)])
        XCTAssertNil(try Data(contentsOf: out).range(of: Data("hdrcharset=BINARY".utf8)))
        let reopened = try await Self.open(out)
        XCTAssertEqual(reopened.entries.map(\.path), before + ["Новый файл.txt"])
        XCTAssertEqual(reopened.hardlinkTargetByPath["копия.jpg"], "Фото/Лето 2024.jpg")
        XCTAssertEqual(reopened.symlinkTargetByPath["ссылка"], "Отчёт за май.docx")
        try await Self.assertExtracts(reopened, "копия.jpg", "jpg")

        let ascii = try await Self.saveTar(source, removing: "удалить.txt", adding: "new.txt")
        let expected = try Self.rawNames(url).filter { $0.name != Self.cp1251("удалить.txt") }
        XCTAssertEqual(try Self.rawNames(ascii),
                       expected + [RawName(name: Array("new.txt".utf8), hardlink: nil, symlink: nil)])
        let reopenedASCII = try await Self.open(ascii)
        XCTAssertEqual(reopenedASCII.entries.map(\.path), before + ["new.txt"])
    }

    /// Probe B: kept "Лето 2024.jpg", a hardlink "./копия.jpg" and a symlink "./ссылка" to it. The two
    /// spellings miss the exact-match guard and are not ASCII, so the save (removal only, and with an added
    /// Cyrillic file) writes every name UTF-8: the reopened archive lists the same names, the hardlink resolves
    /// and extracts the target's bytes.
    func testTarSaveWithGuardMissWritesEveryNameUTF8() async throws {
        let cp1251 = Self.cp1251
        let url = Self.ustar([
            (name: cp1251("Лето 2024.jpg"), type: UInt8(ascii: "0"), link: [], data: Array("jpg".utf8)),
            (name: cp1251("Отчёт за май.docx"), type: UInt8(ascii: "0"), link: [], data: Array("doc".utf8)),
            (name: cp1251("./копия.jpg"), type: UInt8(ascii: "1"), link: cp1251("Лето 2024.jpg"), data: []),
            (name: cp1251("./ссылка"), type: UInt8(ascii: "2"), link: cp1251("Лето 2024.jpg"), data: []),
            (name: cp1251("удалить.txt"), type: UInt8(ascii: "0"), link: [], data: Array("x".utf8)),
        ])
        let source = try await Self.open(url)
        XCTAssertEqual(source.nameDecoding.legacy, .windowsCP1251)
        let before = ["Лето 2024.jpg", "Отчёт за май.docx", "копия.jpg", "ссылка"]
        XCTAssertEqual(source.entries.map(\.path), before + ["удалить.txt"])
        for added in [nil, "Новый файл.txt"] {
            let out = try await Self.saveTar(source, removing: "удалить.txt", adding: added)
            let names = before + (added.map { [$0] } ?? [])
            let raw = try Self.rawNames(out)
            XCTAssertEqual(raw.map(\.name), names.map { Array($0.utf8) }, "\(String(describing: added))")
            XCTAssertEqual(raw.compactMap(\.hardlink), [Array("Лето 2024.jpg".utf8)], "\(String(describing: added))")
            XCTAssertEqual(raw.compactMap(\.symlink), [Array("Лето 2024.jpg".utf8)], "\(String(describing: added))")
            XCTAssertNil(try Data(contentsOf: out).range(of: Data("hdrcharset=BINARY".utf8)))
            let reopened = try await Self.open(out)
            XCTAssertEqual(reopened.entries.map(\.path), names, "\(String(describing: added))")
            XCTAssertEqual(reopened.hardlinkTargetByPath["копия.jpg"], "Лето 2024.jpg")
            XCTAssertEqual(reopened.symlinkTargetByPath["ссылка"], "Лето 2024.jpg")
            try await Self.assertExtracts(reopened, "копия.jpg", "jpg")
        }
    }

    /// Zip: CP1251 names spelled "./x", "a//b", "../x" and "/x", plus plain CP1251 names. The listing
    /// normalizes all four (none is dropped or refused). After a save with one unrelated removal each of them is
    /// written as its normalized path in UTF-8 with bit 11, while the plain name keeps its bytes and its missing
    /// bit 11 (zip decides entry by entry). The reopened archive lists the same paths.
    func testZipSaveWritesInexactSpellingsAsUTF8() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let url = SyntheticZip.write(SyntheticZip.stored(Self.inexactSpellings.map {
            (nameBytes: Self.cp1251($0), utf8Flag: false, dosTime: t, data: Array($0.utf8))
        }))
        let source = try await Self.open(url)
        XCTAssertEqual(source.nameDecoding.legacy, .windowsCP1251)
        XCTAssertEqual(source.entries.map(\.path), Self.inexactListing + ["удалить.txt"])
        let out = Fixtures.tempDir().appending(path: "saved.zip")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["удалить.txt"]),
                                      format: .zip, to: out)
        let central = SyntheticZip.centralNames([UInt8](try Data(contentsOf: out)))
        XCTAssertEqual(central.map(\.nameBytes), [
            Array("Отчёт1.txt".utf8), Array("Папка/Отчёт2.txt".utf8), Array("Отчёт3.txt".utf8),
            Array("Отчёт4.txt".utf8), Self.cp1251("Отчёт5.txt"),
        ])
        XCTAssertEqual(central.map { $0.flags & 0x0800 != 0 }, [true, true, true, true, false])
        let reopened = try await Self.open(out)
        XCTAssertEqual(reopened.entries.map(\.path), Self.inexactListing)
        XCTAssertEqual(reopened.nameDecoding.legacy, .windowsCP1251)
    }

    /// Tar: the same names in a ustar. The four spellings miss the guard and are not ASCII, so the whole
    /// save is UTF-8 (C-1): plain UTF-8 paths, no BINARY header, and the reopened archive lists the same paths.
    /// With ASCII spellings instead, the save keeps the plain names' raw bytes and writes the four as their
    /// normalized ASCII paths.
    func testTarSaveWritesInexactSpellingsAsUTF8() async throws {
        let url = Self.ustar(Self.inexactSpellings.map {
            (name: Self.cp1251($0), type: UInt8(ascii: "0"), link: [], data: Array($0.utf8))
        })
        let source = try await Self.open(url)
        XCTAssertEqual(source.entries.map(\.path), Self.inexactListing + ["удалить.txt"])
        let out = try await Self.saveTar(source, removing: "удалить.txt", adding: nil)
        let written = ["Отчёт1.txt", "Папка/Отчёт2.txt", "Отчёт3.txt", "Отчёт4.txt", "Отчёт5.txt"]
        XCTAssertEqual(try Self.rawNames(out).map(\.name), written.map { Array($0.utf8) })
        XCTAssertNil(try Data(contentsOf: out).range(of: Data("hdrcharset=BINARY".utf8)))
        let reopened = try await Self.open(out)
        XCTAssertEqual(reopened.entries.map(\.path), Self.inexactListing)

        let asciiURL = Self.ustar(["./a.txt", "b//c.txt", "../d.txt", "/e.txt", "Отчёт5.txt", "удалить.txt"].map {
            (name: Self.cp1251($0), type: UInt8(ascii: "0"), link: [], data: Array($0.utf8))
        })
        let asciiSource = try await Self.open(asciiURL)
        XCTAssertEqual(asciiSource.entries.map(\.path),
                       ["a.txt", "b", "b/c.txt", "d.txt", "e.txt", "Отчёт5.txt", "удалить.txt"])
        let asciiOut = try await Self.saveTar(asciiSource, removing: "удалить.txt", adding: nil)
        XCTAssertEqual(try Self.rawNames(asciiOut).map(\.name),
                       ["a.txt", "b/c.txt", "d.txt", "e.txt"].map { Array($0.utf8) } + [Self.cp1251("Отчёт5.txt")])
        let reopenedASCII = try await Self.open(asciiOut)
        XCTAssertEqual(reopenedASCII.entries.map(\.path), ["a.txt", "b", "b/c.txt", "d.txt", "e.txt", "Отчёт5.txt"])
    }

    /// A hardlink whose own target field is spelled "./Лето.jpg" (its target header is the plain "Лето.jpg").
    /// The link is written with the target header's stored bytes, so the saved link names "Лето.jpg" in CP1251,
    /// not the "./" spelling; the reopened archive resolves it and extracts the target's bytes.
    func testTarHardlinkTargetSpellingIsNotCopied() async throws {
        let cp1251 = Self.cp1251
        let url = Self.ustar([
            (name: cp1251("Лето.jpg"), type: UInt8(ascii: "0"), link: [], data: Array("jpg".utf8)),
            (name: cp1251("копия.jpg"), type: UInt8(ascii: "1"), link: cp1251("./Лето.jpg"), data: []),
            (name: cp1251("удалить.txt"), type: UInt8(ascii: "0"), link: [], data: Array("x".utf8)),
        ])
        let source = try await Self.open(url)
        XCTAssertEqual(source.hardlinkTargetByPath["копия.jpg"], "Лето.jpg")
        let out = try await Self.saveTar(source, removing: "удалить.txt", adding: nil)
        XCTAssertEqual(try Self.rawNames(out), [
            RawName(name: cp1251("Лето.jpg"), hardlink: nil, symlink: nil),
            RawName(name: cp1251("копия.jpg"), hardlink: cp1251("Лето.jpg"), symlink: nil),
        ])
        let reopened = try await Self.open(out)
        XCTAssertEqual(reopened.entries.map(\.path), ["Лето.jpg", "копия.jpg"])
        XCTAssertEqual(reopened.hardlinkTargetByPath["копия.jpg"], "Лето.jpg")
        try await Self.assertExtracts(reopened, "копия.jpg", "jpg")
    }

    /// A zip symlink whose target is stored in CP1251 keeps its name and target bytes (and no bit 11) on a
    /// zip -> zip save; the reopened listing shows the same decoded target. (Tar: `testTarSaveKeepsRawBytes`.)
    func testZipSaveKeepsRawSymlinkTarget() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let url = SyntheticZip.write(SyntheticZip.stored([
            (nameBytes: Self.cp1251("Отчёт.txt"), utf8Flag: false, dosTime: t, data: Array("data".utf8)),
            (nameBytes: Self.cp1251("ссылка"), utf8Flag: false, dosTime: t, data: Self.cp1251("Отчёт.txt")),
            (nameBytes: Self.cp1251("удалить.txt"), utf8Flag: false, dosTime: t, data: Array("x".utf8)),
        ], symlinks: [1]))
        let source = try await Self.open(url)
        XCTAssertEqual(source.symlinkTargetByPath["ссылка"], "Отчёт.txt")
        let out = Fixtures.tempDir().appending(path: "saved.zip")
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["удалить.txt"]),
                                      format: .zip, to: out)
        XCTAssertEqual(try Self.rawNames(out), [
            RawName(name: Self.cp1251("Отчёт.txt"), hardlink: nil, symlink: nil),
            RawName(name: Self.cp1251("ссылка"), hardlink: nil, symlink: Self.cp1251("Отчёт.txt")),
        ])
        let central = SyntheticZip.centralNames([UInt8](try Data(contentsOf: out)))
        XCTAssertEqual(central.map { $0.flags & 0x0800 != 0 }, [false, false])
        let reopened = try await Self.open(out)
        XCTAssertEqual(reopened.entries.map(\.path), ["Отчёт.txt", "ссылка"])
        XCTAssertEqual(reopened.symlinkTargetByPath["ссылка"], "Отчёт.txt")
    }

    /// A hardlink "копия.jpg" to a header spelled "./Лето.jpg", which misses the guard. Not ASCII, so the
    /// save is all UTF-8; the written link is still a hardlink to the written target, and extracts its bytes.
    /// With an ASCII target "./photo.jpg" the target alone could be written UTF-8 while the rest stays raw; then
    /// the raw-named link must not be kept (its target has no stored bytes to reuse): `keepsStoredName`'s
    /// hardlink rule turns it into a UTF-8 name, which makes this save all UTF-8 too.
    func testTarHardlinkToGuardMissTarget() async throws {
        let cp1251 = Self.cp1251
        for target in ["Лето.jpg", "photo.jpg"] {
            let url = Self.ustar([
                (name: cp1251("./" + target), type: UInt8(ascii: "0"), link: [], data: Array("jpg".utf8)),
                (name: cp1251("копия.jpg"), type: UInt8(ascii: "1"), link: cp1251("./" + target), data: []),
                (name: cp1251("Отчёт за май.docx"), type: UInt8(ascii: "0"), link: [], data: Array("doc".utf8)),
                (name: cp1251("удалить.txt"), type: UInt8(ascii: "0"), link: [], data: Array("x".utf8)),
            ])
            let source = try await Self.open(url)
            XCTAssertEqual(source.hardlinkTargetByPath["копия.jpg"], target)
            let out = try await Self.saveTar(source, removing: "удалить.txt", adding: nil)
            XCTAssertEqual(try Self.rawNames(out), [
                RawName(name: Array(target.utf8), hardlink: nil, symlink: nil),
                RawName(name: Array("копия.jpg".utf8), hardlink: Array(target.utf8), symlink: nil),
                RawName(name: Array("Отчёт за май.docx".utf8), hardlink: nil, symlink: nil),
            ], target)
            let reopened = try await Self.open(out)
            XCTAssertEqual(reopened.entries.map(\.path), [target, "копия.jpg", "Отчёт за май.docx"], target)
            XCTAssertEqual(reopened.hardlinkTargetByPath["копия.jpg"], target, target)
            try await Self.assertExtracts(reopened, "копия.jpg", "jpg")
        }
    }

    /// The copy-side hardlink rule inside a save that STAYS raw: the legacy name "Лето 2024.jpg" keeps its CP1251
    /// bytes, the guard-miss target "./photo.jpg" is written as "photo.jpg", and the ASCII link "copy.jpg" to it
    /// must be written as a hardlink to that written target (it has no stored bytes to reuse).
    func testTarHardlinkToGuardMissTargetInRawSave() async throws {
        let cp1251 = Self.cp1251
        let url = Self.ustar([
            (name: cp1251("Лето 2024.jpg"), type: UInt8(ascii: "0"), link: [], data: Array("legacy".utf8)),
            (name: cp1251("./photo.jpg"), type: UInt8(ascii: "0"), link: [], data: Array("jpg".utf8)),
            (name: cp1251("copy.jpg"), type: UInt8(ascii: "1"), link: cp1251("./photo.jpg"), data: []),
            (name: cp1251("удалить.txt"), type: UInt8(ascii: "0"), link: [], data: Array("x".utf8)),
        ])
        let source = try await Self.open(url)
        XCTAssertEqual(source.hardlinkTargetByPath["copy.jpg"], "photo.jpg")
        let out = try await Self.saveTar(source, removing: "удалить.txt", adding: nil)
        XCTAssertEqual(try Self.rawNames(out), [
            RawName(name: cp1251("Лето 2024.jpg"), hardlink: nil, symlink: nil),
            RawName(name: Array("photo.jpg".utf8), hardlink: nil, symlink: nil),
            RawName(name: Array("copy.jpg".utf8), hardlink: Array("photo.jpg".utf8), symlink: nil),
        ])
        let reopened = try await Self.open(out)
        XCTAssertEqual(reopened.hardlinkTargetByPath["copy.jpg"], "photo.jpg")
        try await Self.assertExtracts(reopened, "copy.jpg", "jpg")
    }

    /// A: an ASCII hardlink spelled "./copy.jpg" (a guard miss, so written under its UTF-8 path) to the
    /// kept legacy name "Лето.jpg". The link target is not ASCII, so the save (removal only, and with an ASCII
    /// addition) is all UTF-8: a raw save would write the link's target as UTF-8 next to the CP1251 target header,
    /// and the reopened link would name a header that does not exist.
    func testTarGuardMissASCIIHardlinkToLegacyTarget() async throws {
        let cp1251 = Self.cp1251
        let url = Self.ustar([
            (name: cp1251("Лето.jpg"), type: UInt8(ascii: "0"), link: [], data: Array("jpg".utf8)),
            (name: cp1251("./copy.jpg"), type: UInt8(ascii: "1"), link: cp1251("Лето.jpg"), data: []),
            (name: cp1251("удалить.txt"), type: UInt8(ascii: "0"), link: [], data: Array("x".utf8)),
        ])
        let source = try await Self.open(url)
        XCTAssertEqual(source.nameDecoding.legacy, .windowsCP1251)
        let before = ["Лето.jpg", "copy.jpg"]
        XCTAssertEqual(source.entries.map(\.path), before + ["удалить.txt"])
        XCTAssertEqual(source.hardlinkTargetByPath["copy.jpg"], "Лето.jpg")
        for added in [nil, "new.txt"] {
            let label = String(describing: added)
            let out = try await Self.saveTar(source, removing: "удалить.txt", adding: added)
            let names = before + (added.map { [$0] } ?? [])
            XCTAssertEqual(try Self.rawNames(out), [
                RawName(name: Array("Лето.jpg".utf8), hardlink: nil, symlink: nil),
                RawName(name: Array("copy.jpg".utf8), hardlink: Array("Лето.jpg".utf8), symlink: nil),
            ] + (added.map { [RawName(name: Array($0.utf8), hardlink: nil, symlink: nil)] } ?? []), label)
            let reopened = try await Self.open(out)
            XCTAssertEqual(reopened.entries.map(\.path), names, label)
            XCTAssertEqual(reopened.hardlinkTargetByPath["copy.jpg"], "Лето.jpg", label)
            try await Self.assertExtracts(reopened, "copy.jpg", "jpg")
        }
    }

    /// B: an ASCII symlink spelled "./link" (a guard miss) whose target is the legacy "Лето.jpg". The
    /// target is written from its decoded string, so it is not ASCII and the save is all UTF-8; the reopened
    /// symlink names the same target as before the save.
    func testTarGuardMissASCIISymlinkToLegacyTarget() async throws {
        let cp1251 = Self.cp1251
        let url = Self.ustar([
            (name: cp1251("Лето.jpg"), type: UInt8(ascii: "0"), link: [], data: Array("jpg".utf8)),
            (name: cp1251("./link"), type: UInt8(ascii: "2"), link: cp1251("Лето.jpg"), data: []),
            (name: cp1251("удалить.txt"), type: UInt8(ascii: "0"), link: [], data: Array("x".utf8)),
        ])
        let source = try await Self.open(url)
        XCTAssertEqual(source.nameDecoding.legacy, .windowsCP1251)
        let before = ["Лето.jpg", "link"]
        XCTAssertEqual(source.entries.map(\.path), before + ["удалить.txt"])
        XCTAssertEqual(source.symlinkTargetByPath["link"], "Лето.jpg")
        for added in [nil, "new.txt"] {
            let label = String(describing: added)
            let out = try await Self.saveTar(source, removing: "удалить.txt", adding: added)
            XCTAssertEqual(try Self.rawNames(out), [
                RawName(name: Array("Лето.jpg".utf8), hardlink: nil, symlink: nil),
                RawName(name: Array("link".utf8), hardlink: nil, symlink: Array("Лето.jpg".utf8)),
            ] + (added.map { [RawName(name: Array($0.utf8), hardlink: nil, symlink: nil)] } ?? []), label)
            let reopened = try await Self.open(out)
            XCTAssertEqual(reopened.entries.map(\.path), before + (added.map { [$0] } ?? []), label)
            XCTAssertEqual(reopened.symlinkTargetByPath["link"], "Лето.jpg", label)
        }
    }

    /// The save adds an ASCII folder holding a symlink whose target is "Отчёт за май.docx". Every added
    /// name is ASCII, so only the symlink's target makes the save all UTF-8; the reopened archive shows that target
    /// and the kept names (and their links) as before.
    func testTarAddedSymlinkWithLegacyTargetWritesEveryNameUTF8() async throws {
        let url = Self.cleanCP1251Tar()
        let source = try await Self.open(url)
        XCTAssertEqual(source.nameDecoding.legacy, .windowsCP1251)
        let before = source.entries.map(\.path).filter { $0 != "удалить.txt" }

        let folder = Fixtures.tempDir().appending(path: "links")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "report").path,
                                                   withDestinationPath: "Отчёт за май.docx")
        let changes = ArchiveChangeSet(removedPaths: ["удалить.txt"],
                                       additions: [.init(sourceURL: folder, destinationDirectory: "")])
        let out = Fixtures.tempDir().appending(path: "saved.tar")
        try await ArchiveWriter.write(source: source, changes: changes, format: .tar, to: out)

        let raw = try Self.rawNames(out)
        let written = before.map { $0 == "Фото" ? "Фото/" : $0 } + ["links/", "links/report"]
        XCTAssertEqual(raw.map(\.name), written.map { Array($0.utf8) })
        XCTAssertEqual(raw.compactMap(\.hardlink), [Array("Фото/Лето 2024.jpg".utf8)])
        // The file system hands back the target decomposed; the writer stores it precomposed (NFC).
        XCTAssertEqual(raw.compactMap(\.symlink), Array(repeating: Array("Отчёт за май.docx".utf8), count: 2))
        XCTAssertNil(try Data(contentsOf: out).range(of: Data("hdrcharset=BINARY".utf8)))
        let reopened = try await Self.open(out)
        XCTAssertEqual(reopened.entries.map(\.path), before + ["links", "links/report"])
        XCTAssertEqual(reopened.symlinkTargetByPath["links/report"], "Отчёт за май.docx")
        XCTAssertEqual(reopened.symlinkTargetByPath["ссылка"], "Отчёт за май.docx")
        XCTAssertEqual(reopened.hardlinkTargetByPath["копия.jpg"], "Фото/Лето 2024.jpg")
        try await Self.assertExtracts(reopened, "копия.jpg", "jpg")
    }

    /// A CP1251 tar opened with a manual CP866 choice (names shown as mojibake). A save with one removal
    /// and an ASCII addition stays raw: every kept header's name and link bytes are the source's, so an automatic
    /// open reads them right again. A save with a non-ASCII addition is all UTF-8 and writes every kept name and
    /// link target in the DISPLAYED (CP866) reading: main's behaviour, kept on purpose.
    func testTarSaveAfterManualChoice() async throws {
        let url = Self.cleanCP1251Tar()
        let source = try await Self.open(url, .specific(.cp866))
        let shown = { (s: String) in String(bytes: Self.cp1251(s), encoding: .cp866)! }
        let original = ["Фото", "Фото/Лето 2024.jpg", "Отчёт за май.docx", "удалить.txt", "копия.jpg", "ссылка"]
        XCTAssertEqual(source.entries.map(\.path), original.map(shown))
        XCTAssertNotEqual(shown("удалить.txt"), "удалить.txt")
        let removed = shown("удалить.txt")
        let kept = original.filter { $0 != "удалить.txt" }

        let rawOut = try await Self.saveTar(source, removing: removed, adding: "new.txt")
        let sourceRaw = try Self.rawNames(url).filter { $0.name != Self.cp1251("удалить.txt") }
        XCTAssertEqual(try Self.rawNames(rawOut),
                       sourceRaw + [RawName(name: Array("new.txt".utf8), hardlink: nil, symlink: nil)])
        let reopenedRaw = try await Self.open(rawOut)
        XCTAssertEqual(reopenedRaw.entries.map(\.path), kept + ["new.txt"])

        let utf8Out = try await Self.saveTar(source, removing: removed, adding: "Новый файл.txt")
        let raw = try Self.rawNames(utf8Out)
        let written = kept.map { $0 == "Фото" ? "Фото/" : $0 }.map(shown) + ["Новый файл.txt"]
        XCTAssertEqual(raw.map(\.name), written.map { Array($0.utf8) })
        XCTAssertEqual(raw.compactMap(\.hardlink), [Array(shown("Фото/Лето 2024.jpg").utf8)])
        XCTAssertEqual(raw.compactMap(\.symlink), [Array(shown("Отчёт за май.docx").utf8)])
        let reopened = try await Self.open(utf8Out)
        XCTAssertEqual(reopened.entries.map(\.path), kept.map(shown) + ["Новый файл.txt"])
    }

    /// zip -> 7z is another family: names are written as the source displays them (automatic or manual).
    func testZipToSevenZipWritesDecodedNames() async throws {
        let url = Self.legacyZip(["Отчёт за май.docx", "Фото/Лето 2024.jpg"], as: .windowsCP1251)
        for encoding in [ArchiveNameEncoding.automatic, .specific(.cp866)] {
            let source = try await Self.open(url, encoding)
            let out = Fixtures.tempDir().appending(path: "saved.7z")
            try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: .sevenZip, to: out)
            let saved = try await Self.open(out)
            XCTAssertEqual(Set(saved.entries.map(\.path)), Set(source.entries.map(\.path)), "\(encoding)")
            XCTAssertNil(saved.nameDecoding.legacy)
        }
    }

    /// 7-Zip lists the saved zip's added UTF-8 name (and the kept bit-11 one) as Kernir wrote them.
    func testInteropSevenZipListsSavedZip() async throws {
        guard let sevenZip = Tool.sevenZip else {
            if Tool.interopRequired { return XCTFail("7-Zip is not installed (KERNIR_REQUIRE_INTEROP=1)") }
            throw XCTSkip("7-Zip is not installed")
        }
        let out = try await Self.saveZip(try await Self.open(Self.mixedZip()), removing: "отчет.txt")
        let run = try Tool.run(sevenZip, ["l", "-slt", out.path])
        XCTAssertEqual(run.status, 0, run.stderr)
        let paths = String(decoding: run.stdout, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("Path = ") }.map { $0.dropFirst(7).precomposedStringWithCanonicalMapping }
        XCTAssertTrue(paths.contains("Новый.txt"), "\(paths)")
        XCTAssertTrue(paths.contains("Привет.txt"), "\(paths)")
    }

    // MARK: Helpers

    private static func cp1251(_ s: String) -> [UInt8] { [UInt8](s.data(using: .windowsCP1251)!) }

    /// "./x", "a//b", "../x" and "/x" spellings of CP1251 names, a plain one, and one a save removes.
    private static let inexactSpellings = ["./Отчёт1.txt", "Папка//Отчёт2.txt", "../Отчёт3.txt", "/Отчёт4.txt",
                                           "Отчёт5.txt", "удалить.txt"]
    /// What `inexactSpellings` lists as, without "удалить.txt".
    private static let inexactListing = ["Отчёт1.txt", "Папка", "Папка/Отчёт2.txt", "Отчёт3.txt", "Отчёт4.txt",
                                         "Отчёт5.txt"]

    /// A CP1251 ustar: a folder, two files, "удалить.txt", a hardlink and a symlink, all names exact.
    private static func cleanCP1251Tar() -> URL {
        ustar([
            (name: cp1251("Фото/"), type: UInt8(ascii: "5"), link: [], data: []),
            (name: cp1251("Фото/Лето 2024.jpg"), type: UInt8(ascii: "0"), link: [], data: Array("jpg".utf8)),
            (name: cp1251("Отчёт за май.docx"), type: UInt8(ascii: "0"), link: [], data: Array("doc".utf8)),
            (name: cp1251("удалить.txt"), type: UInt8(ascii: "0"), link: [], data: Array("x".utf8)),
            (name: cp1251("копия.jpg"), type: UInt8(ascii: "1"), link: cp1251("Фото/Лето 2024.jpg"), data: []),
            (name: cp1251("ссылка"), type: UInt8(ascii: "2"), link: cp1251("Отчёт за май.docx"), data: []),
        ])
    }

    /// Saves `source` as a tar without `removed`, plus a new top-level file named `added` when given.
    private static func saveTar(_ source: LibArchiveReader, removing removed: String, adding added: String?)
        async throws -> URL {
        var changes = ArchiveChangeSet(removedPaths: [removed])
        if let added {
            let input = Fixtures.tempDir().appending(path: added)
            try Data("new".utf8).write(to: input)
            changes.additions = [.init(sourceURL: input, destinationDirectory: "")]
        }
        let out = Fixtures.tempDir().appending(path: "saved.tar")
        try await ArchiveWriter.write(source: source, changes: changes, format: .tar, to: out)
        return out
    }

    /// Extracting `path` alone gives a file holding `contents`.
    private static func assertExtracts(_ reader: LibArchiveReader, _ path: String, _ contents: String,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let out = Fixtures.tempDir()
        try await reader.extract([path], to: out, progress: nil)
        XCTAssertEqual(try Data(contentsOf: out.appending(path: path)), Data(contents.utf8), file: file, line: line)
    }

    /// A CP1251 no-flag entry, a bit-11 UTF-8 entry, a CP1251 entry for removal, and a CP932 entry named "表.txt"
    /// by its 0x7075 field.
    private static func mixedZip() -> URL {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        return SyntheticZip.write(SyntheticZip.stored([
            (nameBytes: cp1251("Отчёт за май.docx"), utf8Flag: false, dosTime: t, data: Array("a".utf8)),
            (nameBytes: Array("Привет.txt".utf8), utf8Flag: true, dosTime: t, data: Array("b".utf8)),
            (nameBytes: cp1251("отчет.txt"), utf8Flag: false, dosTime: t, data: Array("c".utf8)),
            (nameBytes: [UInt8]("表.txt".data(using: .cp932)!), utf8Flag: false, dosTime: t, data: Array("d".utf8)),
        ], unicodePath: [3: "表.txt"]))
    }

    /// Saves `source` as a zip without `removed` and with a new file "Новый.txt".
    private static func saveZip(_ source: LibArchiveReader, removing removed: String) async throws -> URL {
        let input = Fixtures.tempDir().appending(path: "Новый.txt")
        try Data("new".utf8).write(to: input)
        let out = Fixtures.tempDir().appending(path: "saved.zip")
        let changes = ArchiveChangeSet(removedPaths: [removed],
                                       additions: [.init(sourceURL: input, destinationDirectory: "")])
        try await ArchiveWriter.write(source: source, changes: changes, format: .zip, to: out)
        return out
    }

    /// `mixedZip` saved by `saveZip`: central names and bit 11 exactly as stated, no 0x7075 field anywhere.
    private static func assertKeptRawAndAddedUTF8(_ out: URL, file: StaticString = #filePath,
                                                  line: UInt = #line) throws {
        let zip = [UInt8](try Data(contentsOf: out))
        let central = SyntheticZip.centralNames(zip)
        XCTAssertEqual(central.map(\.nameBytes),
                       [cp1251("Отчёт за май.docx"), Array("Привет.txt".utf8), Array("表.txt".utf8),
                        Array("Новый.txt".utf8)], file: file, line: line)
        XCTAssertEqual(central.map { $0.flags & 0x0800 != 0 }, [false, true, true, true], file: file, line: line)
        let extras = SyntheticZip.centralExtraIDs(zip)
        XCTAssertEqual(extras.count, central.count, file: file, line: line)
        // Only a guard: the bundled zip writer never emits 0x7075, so this cannot fail today. The name-bytes and
        // bit-11 asserts above are what catch a raw-mode bug.
        XCTAssertFalse(extras.contains { $0.contains(0x7075) }, "\(extras)", file: file, line: line)
    }

    struct RawName: Equatable {
        let name: [UInt8]
        let hardlink: [UInt8]?
        let symlink: [UInt8]?
    }

    /// Every header's stored name and link bytes, as libarchive reads them (no decoding). Any format (tar, zip).
    private static func rawNames(_ url: URL) throws -> [RawName] {
        func bytes(_ p: UnsafePointer<CChar>?) -> [UInt8]? {
            p.map { Array(UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self),
                                              count: strlen($0))) }
        }
        let session = try ReadSession(url: url, password: nil)
        var result: [RawName] = []
        while let e = try session.nextHeader() {
            result.append(withUTF8CType {
                RawName(name: bytes(archive_entry_pathname(e)) ?? [], hardlink: bytes(archive_entry_hardlink(e)),
                        symlink: bytes(archive_entry_symlink(e)))
            })
        }
        return result
    }

    private static func open(_ url: URL, _ nameEncoding: ArchiveNameEncoding = .automatic) async throws
        -> LibArchiveReader {
        let reader = try await Archive.open(at: url, nameEncoding: nameEncoding)
        return try XCTUnwrap(reader as? LibArchiveReader)
    }

    /// `names` plus their ancestors: what a listing shows.
    private static func listing(_ names: [String]) -> Set<String> {
        Set(names.flatMap { EntryPath.ancestors(of: $0) + [$0] })
    }

    /// A zip without bit 11 whose names are stored in `encoding`.
    private static func legacyZip(_ names: [String], as encoding: String.Encoding) -> URL {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        return SyntheticZip.write(SyntheticZip.stored(names.map {
            (nameBytes: [UInt8]($0.data(using: encoding)!), utf8Flag: false, dosTime: t, data: Array($0.utf8))
        }))
    }

    /// Relative paths (NFC) of everything under `root`.
    private static func diskListing(_ root: URL) -> Set<String> {
        let fm = FileManager.default
        var out = Set<String>()
        func walk(_ dir: URL, _ prefix: String) {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let rel = prefix + name.precomposedStringWithCanonicalMapping
                out.insert(rel)
                var isDir: ObjCBool = false
                let url = dir.appending(path: name)
                if (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil,
                   fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    walk(url, rel + "/")
                }
            }
        }
        walk(root, "")
        return out
    }

    /// A ustar archive with raw name and link bytes (no pax headers), written to a fresh temp dir.
    private static func ustar(_ entries: [(name: [UInt8], type: UInt8, link: [UInt8], data: [UInt8])]) -> URL {
        func field(_ bytes: [UInt8], _ length: Int) -> [UInt8] {
            Array(bytes.prefix(length)) + [UInt8](repeating: 0, count: max(0, length - bytes.count))
        }
        func octal(_ value: Int, _ length: Int) -> [UInt8] {
            let digits = String(value, radix: 8)
            return Array((String(repeating: "0", count: length - 1 - digits.count) + digits).utf8) + [0]
        }
        var out: [UInt8] = []
        for e in entries {
            var h = field(e.name, 100) + octal(e.type == UInt8(ascii: "5") ? 0o755 : 0o644, 8)
            h += octal(0, 8) + octal(0, 8) + octal(e.data.count, 12) + octal(1_700_000_000, 12)
            h += [UInt8](repeating: 0x20, count: 8) + [e.type] + field(e.link, 100)
            h += Array("ustar\0".utf8) + Array("00".utf8) + field([], 32) + field([], 32)
            h += octal(0, 8) + octal(0, 8) + field([], 155)
            h = field(h, 512)
            let sum = h.reduce(0) { $0 + Int($1) }
            h.replaceSubrange(148..<156, with: octal(sum, 7) + [0x20])
            out += h + e.data + [UInt8](repeating: 0, count: (512 - e.data.count % 512) % 512)
        }
        out += [UInt8](repeating: 0, count: 1024)
        let url = Fixtures.tempDir().appending(path: "legacy.tar")
        try? Data(out).write(to: url)
        return url
    }
}
