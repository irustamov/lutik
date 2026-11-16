import Testing
import Foundation
import CLibArchive
@testable import KernirCore

@Test func libarchiveIsVendoredWithSystemCodecs() {
    #expect(String(cString: archive_version_string()) == "libarchive 3.8.10")
    let details = String(cString: archive_version_details())
    for lib in ["zlib/", "liblzma/", "bz2lib/"] { #expect(details.contains(lib)) }
}

private struct DosStamp {
    let y, mo, d, h, mi, s: Int
    var dos: UInt32 { SyntheticZip.dosTime(year: y, month: mo, day: d, hour: h, minute: mi, second: s) }
    var date: Date? {
        Calendar.current.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))
    }
}
private let stampA = DosStamp(y: 2024, mo: 3, d: 9, h: 10, mi: 20, s: 30)
private let stampB = DosStamp(y: 2001, mo: 12, d: 31, h: 23, mi: 59, s: 58)
private let stampC = DosStamp(y: 2024, mo: 7, d: 1, h: 0, mi: 0, s: 0)

@Test func dosTimesListInLocalTime() async throws {
    let stamps = [stampA, stampA, stampB, stampA, stampC]
    let zip = SyntheticZip.stored(stamps.enumerated().map { (path: "f\($0.offset).txt", dosTime: $0.element.dos, data: []) })
    let reader = try await Archive.open(at: SyntheticZip.write(zip))
    let entries = reader.entries
    #expect(entries.count == stamps.count)
    for (i, stamp) in stamps.enumerated() {
        let entry = try #require(entries.first { $0.path == "f\(i).txt" })
        #expect(entry.modificationDate == stamp.date)
    }
}

@Test func dosTimesStayPerArchiveUnderConcurrency() async throws {
    func zip(_ stamp: DosStamp) -> URL {
        SyntheticZip.write(SyntheticZip.stored((0..<2000).map { (path: "f\($0).txt", dosTime: stamp.dos, data: []) }))
    }
    let x = zip(stampA), y = zip(stampB)
    let dateA = try #require(stampA.date), dateB = try #require(stampB.date)
    try await withThrowingTaskGroup(of: Bool.self) { group in
        for _ in 0..<20 {
            for (url, expected) in [(x, dateA), (y, dateB)] {
                group.addTask {
                    let reader = try await Archive.open(at: url)
                    return reader.entries.count == 2000 && reader.entries.allSatisfy { $0.modificationDate == expected }
                }
            }
        }
        for try await ok in group { #expect(ok) }
    }
}

/// Kernir patch 0009: the zip reader says which entry names were declared Unicode, and the zip writer can store a
/// name's bytes verbatim with a chosen bit 11.
struct CLibArchiveTests {
    /// "Отчёт.txt" in CP1251.
    static let cp1251Name: [UInt8] = [0xCE, 0xF2, 0xF7, 0xB8, 0xF2, 0x2E, 0x74, 0x78, 0x74]
    static let stamp = SyntheticZip.dosTime(year: 2024, month: 3, day: 9, hour: 10, minute: 20, second: 30)

    /// Reads every header of `bytes` with the formats `support` enables and returns the accessor per entry.
    /// Under a UTF-8 LC_CTYPE, as the engine reads (in "C" libarchive can't convert a 0x7075 name).
    static func declaredFlags(_ bytes: [UInt8], support: (OpaquePointer?) -> Int32) -> [Int32] {
        withUTF8CType { declaredFlagsInCurrentLocale(bytes, support: support) }
    }

    private static func declaredFlagsInCurrentLocale(_ bytes: [UInt8], support: (OpaquePointer?) -> Int32) -> [Int32] {
        let a = archive_read_new()
        defer { archive_read_free(a) }
        #expect(support(a) == ARCHIVE_OK)
        return bytes.withUnsafeBytes { buf -> [Int32] in
            #expect(archive_read_open_memory(a, buf.baseAddress, buf.count) == ARCHIVE_OK)
            var flags = [Int32]()
            var entry: OpaquePointer?
            var r = archive_read_next_header(a, &entry)
            while r == ARCHIVE_OK || r == ARCHIVE_WARN {
                flags.append(kernir_read_zip_entry_name_declared(a))
                r = archive_read_next_header(a, &entry)
            }
            return flags
        }
    }

    /// One writer per call, under a UTF-8 LC_CTYPE as the engine writes: `body` adds entries; returns the bytes.
    static func written(format: (OpaquePointer?) -> Int32 = archive_write_set_format_zip,
                        _ body: (OpaquePointer?) -> Void) -> [UInt8] {
        withUTF8CType { writtenInCurrentLocale(format: format, body) }
    }

    private static func writtenInCurrentLocale(format: (OpaquePointer?) -> Int32,
                                               _ body: (OpaquePointer?) -> Void) -> [UInt8] {
        let a = archive_write_new()
        defer { archive_write_free(a) }
        #expect(format(a) == ARCHIVE_OK)
        archive_write_set_bytes_in_last_block(a, 1)
        let size = 1 << 16
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        defer { buf.deallocate() }
        var used = 0
        #expect(archive_write_open_memory(a, buf, size, &used) == ARCHIVE_OK)
        body(a)
        #expect(archive_write_close(a) == ARCHIVE_OK)
        return Array(UnsafeRawBufferPointer(start: buf, count: used))
    }

    /// Writes a regular file whose MBS pathname is `name`; returns archive_write_header's result.
    @discardableResult
    static func add(_ a: OpaquePointer?, _ name: [UInt8], type: mode_t = S_IFREG, data: [UInt8] = Array("hi".utf8)) -> Int32 {
        let e = archive_entry_new()
        defer { archive_entry_free(e) }
        archive_entry_copy_pathname(e, name.map { CChar(bitPattern: $0) } + [0])
        archive_entry_set_filetype(e, UInt32(type))
        archive_entry_set_perm(e, 0o644)
        archive_entry_set_size(e, type == S_IFREG ? Int64(data.count) : 0)
        let r = archive_write_header(a, e)
        if r >= ARCHIVE_WARN, type == S_IFREG {
            #expect(data.withUnsafeBytes { archive_write_data(a, $0.baseAddress, $0.count) } == data.count)
        }
        return r
    }

    /// Kernir's writer setup: names are stored as UTF-8 (WriteSession sets this option).
    static func utf8Zip(_ a: OpaquePointer?) -> Int32 {
        let r = archive_write_set_format_zip(a)
        return r == ARCHIVE_OK ? archive_write_set_format_option(a, "zip", "hdrcharset", "UTF-8") : r
    }

    @Test func testZipNameDeclaredFlag() {
        let zip = SyntheticZip.stored([
            (nameBytes: Array("Привет.txt".utf8), utf8Flag: true, dosTime: Self.stamp, data: Array("a".utf8)),
            (nameBytes: Self.cp1251Name, utf8Flag: false, dosTime: Self.stamp, data: Array("b".utf8)),
            (nameBytes: Self.cp1251Name, utf8Flag: false, dosTime: Self.stamp, data: Array("c".utf8)),
        ], unicodePath: [2: "Отчёт.txt"])
        #expect(Self.declaredFlags(zip, support: archive_read_support_format_zip) == [1, 0, 1])
        #expect(Self.declaredFlags(zip, support: archive_read_support_format_zip_seekable) == [1, 0, 1])
        #expect(Self.declaredFlags(zip, support: archive_read_support_format_zip_streamable) == [1, 0, 1])

        let tar = Self.written(format: archive_write_set_format_pax_restricted) { Self.add($0, Array("a.txt".utf8)) }
        #expect(Self.declaredFlags(tar, support: archive_read_support_format_all) == [-1])
        #expect(Self.declaredFlags(zip, support: archive_read_support_format_all) == [1, 0, 1])
    }

    /// Every entry's MBS pathname bytes and declared flag, reading under a UTF-8 LC_CTYPE.
    private static func pathsAndFlags(_ bytes: [UInt8], support: (OpaquePointer?) -> Int32) -> [(path: [UInt8], declared: Int32)] {
        withUTF8CType {
            let a = archive_read_new()
            defer { archive_read_free(a) }
            #expect(support(a) == ARCHIVE_OK)
            return bytes.withUnsafeBytes { buf in
                #expect(archive_read_open_memory(a, buf.baseAddress, buf.count) == ARCHIVE_OK)
                var out = [(path: [UInt8], declared: Int32)]()
                var entry: OpaquePointer?
                var r = archive_read_next_header(a, &entry)
                while r == ARCHIVE_OK || r == ARCHIVE_WARN {
                    let path = archive_entry_pathname(entry).map { Array(UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), count: strlen($0))) } ?? []
                    out.append((path: path, declared: kernir_read_zip_entry_name_declared(a)))
                    r = archive_read_next_header(a, &entry)
                }
                return out
            }
        }
    }

    /// A 0x7075 field whose name-CRC is for other bytes is stale: the name stays the main-field one, undeclared.
    @Test func testZipStaleUnicodePathIsUndeclared() {
        let zip = SyntheticZip.stored([
            (nameBytes: Self.cp1251Name, utf8Flag: false, dosTime: Self.stamp, data: Array("a".utf8)),
        ], unicodePath: [0: "Другое.txt"], staleUnicodePathCRCOf: [0: Array("Другое.txt".utf8)])
        for support in [archive_read_support_format_zip_seekable, archive_read_support_format_zip_streamable] {
            let entries = Self.pathsAndFlags(zip, support: support)
            #expect(entries.count == 1)
            guard entries.count == 1 else { continue }
            #expect(entries[0].declared == 0)
            #expect(entries[0].path == Self.cp1251Name)
        }
    }

    /// End-to-end guard: a symlink target is written to the zip verbatim. This does NOT test raw
    /// mode: the target is written verbatim without raw mode too (in a UTF-8 locale the
    /// `symlink_l` conversion fails and the writer keeps the MBS bytes).
    @Test func testZipWriterRawSymlinkTargetVerbatim() {
        let zip = Self.written(format: Self.utf8Zip) { a in
            #expect(kernir_write_zip_next_name_raw(a, 0) == ARCHIVE_OK)
            let e = archive_entry_new()
            defer { archive_entry_free(e) }
            archive_entry_copy_pathname(e, Self.cp1251Name.map { CChar(bitPattern: $0) } + [0])
            archive_entry_set_filetype(e, UInt32(S_IFLNK))
            archive_entry_set_perm(e, 0o755)
            archive_entry_copy_symlink(e, Self.cp1251Name.map { CChar(bitPattern: $0) } + [0])
            #expect(archive_write_header(a, e) == ARCHIVE_OK)
        }
        // First local header: name length at 26, extra length at 28, compressed size at 18; stored data follows.
        func u16(_ i: Int) -> Int { Int(zip[i]) | Int(zip[i + 1]) << 8 }
        guard zip.count > 30 else { Issue.record("zip too short"); return }
        let size = u16(18) | u16(20) << 16
        let start = 30 + u16(26) + u16(28)
        #expect(u16(8) == 0)
        guard start + size <= zip.count else { Issue.record("symlink data out of range"); return }
        #expect(Array(zip[start..<(start + size)]) == Self.cp1251Name)
    }

    @Test func testZipWriterRawNameVerbatim() {
        var results = [Int32]()
        let zip = Self.written(format: Self.utf8Zip) { a in
            #expect(kernir_write_zip_next_name_raw(a, 0) == ARCHIVE_OK)
            results.append(Self.add(a, Self.cp1251Name))
            results.append(Self.add(a, Self.cp1251Name))
            #expect(kernir_write_zip_next_name_raw(a, 1) == ARCHIVE_OK)
            results.append(Self.add(a, Array("Отчёт.txt".utf8)))
        }
        // Raw mode: no "Can't translate" warning. Today's behavior without the call: a warning and bit 11.
        #expect(results == [ARCHIVE_OK, ARCHIVE_WARN, ARCHIVE_OK])
        let names = SyntheticZip.centralNames(zip)
        #expect(names.count == 3)
        guard names.count == 3 else { return }
        #expect(names[0].nameBytes == Self.cp1251Name)
        #expect(names[0].flags & 0x0800 == 0)
        #expect(names[1].nameBytes != Self.cp1251Name)
        #expect(names[1].flags & 0x0800 != 0)
        #expect(names[2].nameBytes == Array("Отчёт.txt".utf8))
        #expect(names[2].flags & 0x0800 != 0)
        // The local headers agree: the reader takes bit 11 from them.
        #expect(Self.declaredFlags(zip, support: archive_read_support_format_zip_streamable) == [0, 1, 1])

        // Not a zip writer, or not a writer: refused.
        _ = Self.written(format: archive_write_set_format_pax_restricted) { a in
            #expect(kernir_write_zip_next_name_raw(a, 0) == ARCHIVE_FATAL)
        }
        let r = archive_read_new()
        defer { archive_read_free(r) }
        #expect(kernir_write_zip_next_name_raw(r, 0) == ARCHIVE_FATAL)
    }

    @Test func testZipWriterRawModeIsOneShot() {
        var results = [Int32]()
        let zip = Self.written(format: Self.utf8Zip) { a in
            #expect(kernir_write_zip_next_name_raw(a, 0) == ARCHIVE_OK)
            results.append(Self.add(a, Self.cp1251Name))
            results.append(Self.add(a, Self.cp1251Name))
            // A header that fails (zip has no FIFOs) after the call still uses it up.
            #expect(kernir_write_zip_next_name_raw(a, 0) == ARCHIVE_OK)
            results.append(Self.add(a, Self.cp1251Name, type: S_IFIFO))
            results.append(Self.add(a, Self.cp1251Name))
        }
        #expect(results == [ARCHIVE_OK, ARCHIVE_WARN, ARCHIVE_FAILED, ARCHIVE_WARN])
        let names = SyntheticZip.centralNames(zip)
        #expect(names.map { $0.nameBytes == Self.cp1251Name } == [true, false, false])
        #expect(names.map { $0.flags & 0x0800 != 0 } == [false, true, true])
    }

    /// archive_write_header can fail before the zip writer runs ("Can't add archive to itself"); the request
    /// is used up there too, so the next header is written in normal mode.
    @Test func testZipWriterRawRequestUsedUpByPreFormatFailure() {
        var results = [Int32]()
        let zip = Self.written(format: Self.utf8Zip) { a in
            archive_write_set_skip_file(a, 7, 42)
            #expect(kernir_write_zip_next_name_raw(a, 0) == ARCHIVE_OK)
            let e = archive_entry_new()
            defer { archive_entry_free(e) }
            archive_entry_copy_pathname(e, Self.cp1251Name.map { CChar(bitPattern: $0) } + [0])
            archive_entry_set_filetype(e, UInt32(S_IFREG))
            archive_entry_set_perm(e, 0o644)
            archive_entry_set_size(e, 0)
            archive_entry_set_dev(e, 7)
            archive_entry_set_ino64(e, 42)
            results.append(archive_write_header(a, e))
            results.append(Self.add(a, Self.cp1251Name))
        }
        #expect(results == [ARCHIVE_FAILED, ARCHIVE_WARN])
        let names = SyntheticZip.centralNames(zip)
        #expect(names.count == 1)
        guard names.count == 1 else { return }
        #expect(names[0].nameBytes != Self.cp1251Name)
        #expect(names[0].flags & 0x0800 != 0)
    }
}

/// Kernir patch 0010: the RAR4 reader says whether it used a Unicode name (FHD_UNICODE) for the current header.
extension CLibArchiveTests {
    /// "Привет.txt" and "сон.txt" in CP866. "сон" is E1 AE AD, valid UTF-8 (U+1BAD), yet an OEM name.
    static let cp866Name: [UInt8] = [0x8F, 0xE0, 0xA8, 0xA2, 0xA5, 0xE2, 0x2E, 0x74, 0x78, 0x74]
    static let cp866Son: [UInt8] = [0xE1, 0xAE, 0xAD, 0x2E, 0x74, 0x78, 0x74]

    /// archive_read_next_header's result, then kernir_read_rar_entry_name_declared and the UTF-8 pathname, for
    /// every call until one returns neither ARCHIVE_OK nor ARCHIVE_WARN (that call included, with no path).
    /// Under a UTF-8 LC_CTYPE, as the engine reads.
    static func rarSteps(_ bytes: [UInt8], support: (OpaquePointer?) -> Int32 = archive_read_support_format_rar)
        -> [(r: Int32, declared: Int32, path: String?)] {
        withUTF8CType {
            let a = archive_read_new()
            defer { archive_read_free(a) }
            #expect(support(a) == ARCHIVE_OK)
            // No format chosen yet: not RAR4.
            #expect(kernir_read_rar_entry_name_declared(a) == 0)
            return bytes.withUnsafeBytes { buf in
                #expect(archive_read_open_memory(a, buf.baseAddress, buf.count) == ARCHIVE_OK)
                var steps = [(r: Int32, declared: Int32, path: String?)]()
                var entry: OpaquePointer?
                while true {
                    let r = archive_read_next_header(a, &entry)
                    let ok = r == ARCHIVE_OK || r == ARCHIVE_WARN
                    let path = ok ? archive_entry_pathname_utf8(entry).map { String(cString: $0) } : nil
                    steps.append((r: r, declared: kernir_read_rar_entry_name_declared(a), path: path))
                    if !ok { return steps }
                }
            }
        }
    }

    static func declared(_ steps: [(r: Int32, declared: Int32, path: String?)]) -> [Int32] { steps.map(\.declared) }
    static func results(_ steps: [(r: Int32, declared: Int32, path: String?)]) -> [Int32] { steps.map(\.r) }

    /// WinRAR's encoded form (OEM name, NUL, encoded UTF-16) and the no-NUL plain UTF-8 form are both Unicode.
    @Test func testRAR4UnicodeNamesDeclared() {
        let rar = SyntheticRAR4.bytes([
            (name: [UInt8]("Отчёт ?итоги?.txt".data(using: .cp866)!), unicode: "Отчёт «итоги».txt", data: [0x61]),
            (name: Array("Ёлка «зима».txt".utf8), unicode: "", data: [0x62]),
        ])
        let steps = Self.rarSteps(rar)
        #expect(Self.results(steps) == [ARCHIVE_OK, ARCHIVE_OK, ARCHIVE_EOF])
        #expect(steps.map(\.path) == ["Отчёт «итоги».txt", "Ёлка «зима».txt", nil])
        #expect(Self.declared(steps) == [1, 1, 0])
        // The same through format detection.
        #expect(Self.declared(Self.rarSteps(rar, support: archive_read_support_format_all)) == [1, 1, 0])
    }

    /// Pure OEM names are undeclared, including one whose CP866 bytes happen to be valid UTF-8.
    @Test func testRAR4OEMNamesUndeclared() {
        #expect(String(bytes: Self.cp866Son, encoding: .cp866) == "сон.txt")
        #expect(String(bytes: Self.cp866Son, encoding: .utf8) != nil)
        #expect(String(bytes: Self.cp866Name, encoding: .cp866) == "Привет.txt")
        let rar = SyntheticRAR4.bytes([
            (name: Self.cp866Name, unicode: nil, data: [0x61]),
            (name: Self.cp866Son, unicode: nil, data: [0x62]),
            (name: Array("readme.txt".utf8), unicode: nil, data: [0x63]),
        ])
        let steps = Self.rarSteps(rar)
        #expect(Self.results(steps).dropLast().allSatisfy { $0 == ARCHIVE_OK || $0 == ARCHIVE_WARN })
        #expect(Self.results(steps).count == 4)
        #expect(Self.declared(steps) == [0, 0, 0, 0])
    }

    /// The value is per header: a Unicode entry's 1 does not carry over to the OEM entries after it.
    @Test func testRAR4DeclaredDoesNotCarryOver() {
        let rar = SyntheticRAR4.bytes([
            (name: [UInt8]("Отчёт ?итоги?.txt".data(using: .cp866)!), unicode: "Отчёт «итоги».txt", data: [0x61]),
            (name: Self.cp866Son, unicode: nil, data: [0x62]),
            (name: Array("Ёлка «зима».txt".utf8), unicode: "", data: [0x63]),
            (name: Self.cp866Name, unicode: nil, data: [0x64]),
        ])
        let steps = Self.rarSteps(rar)
        #expect(Self.results(steps).count == 5)
        #expect(Self.declared(steps) == [1, 0, 1, 0, 0])
    }

    /// Not the RAR4 reader: 0 (patch 0009's zip accessor returns -1 there; patch 0010 returns 0).
    @Test func testRAR4DeclaredIsZeroForOtherFormats() {
        let zip = SyntheticZip.stored([
            (nameBytes: Array("Привет.txt".utf8), utf8Flag: true, dosTime: Self.stamp, data: Array("a".utf8)),
        ])
        let tar = Self.written(format: archive_write_set_format_pax_restricted) { Self.add($0, Array("Привет.txt".utf8)) }
        for bytes in [zip, tar] {
            let steps = Self.rarSteps(bytes, support: archive_read_support_format_all)
            #expect(Self.results(steps) == [ARCHIVE_OK, ARCHIVE_EOF])
            #expect(Self.declared(steps) == [0, 0])
        }
        // Not a reader at all.
        _ = Self.written(format: archive_write_set_format_pax_restricted) { a in
            #expect(kernir_read_rar_entry_name_declared(a) == 0)
        }
        #expect(kernir_read_rar_entry_name_declared(nil) == 0)
    }

    /// A failing header after a Unicode one leaves 0: a bad header CRC (fails before the name is parsed) and an
    /// unknown host OS (fails after the reader has taken the Unicode name).
    @Test func testRAR4HeaderErrorResetsDeclared() {
        let unicode: (name: [UInt8], unicode: String?, data: [UInt8]) =
            (name: [UInt8]("Отчёт ?итоги?.txt".data(using: .cp866)!), unicode: "Отчёт «итоги».txt", data: [0x61])
        let utf8: (name: [UInt8], unicode: String?, data: [UInt8]) =
            (name: Array("Ёлка «зима».txt".utf8), unicode: "", data: [0x62])

        // The second file header starts where the one-entry archive's end block (7 bytes) starts.
        var badCRC = SyntheticRAR4.bytes([unicode, utf8])
        badCRC[SyntheticRAR4.bytes([unicode]).count - 7] ^= 0xFF
        let crcSteps = Self.rarSteps(badCRC)
        #expect(Self.results(crcSteps) == [ARCHIVE_OK, ARCHIVE_FATAL])
        #expect(Self.declared(crcSteps) == [1, 0])

        // A second header with the first one's name would be read as its multivolume continuation, so the
        // encoded-form second entry has a name of its own.
        let unicode2: (name: [UInt8], unicode: String?, data: [UInt8]) =
            (name: [UInt8]("Итоги ?2024?.txt".data(using: .cp866)!), unicode: "Итоги «2024».txt", data: [0x63])
        for second in [unicode2, utf8] {
            let steps = Self.rarSteps(SyntheticRAR4.bytes([unicode, second], unknownHostOS: [1]))
            #expect(Self.results(steps) == [ARCHIVE_OK, ARCHIVE_FATAL])
            #expect(Self.declared(steps) == [1, 0])
        }
    }
}
