import Foundation

/// Builds valid store-method zips in memory (no extra fields unless `unixTime` or `unicodePath` asks for one), for
/// tests that need large, precisely stamped or legacy-named archives without an external tool.
enum SyntheticZip {
    static func dosTime(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> UInt32 {
        let date = UInt32(((year - 1980) << 9) | (month << 5) | day)
        let time = UInt32((hour << 11) | (minute << 5) | (second / 2))
        return (date << 16) | time
    }

    /// A path ending in "/" is written as a directory. A non-nil `unixTime` adds an "UT" extended-timestamp
    /// field (0x5455, mtime in UTC seconds) to every entry, as Info-ZIP's zip does without -X.
    static func stored(_ entries: [(path: String, dosTime: UInt32, data: [UInt8])], unixTime: UInt32? = nil) -> [UInt8] {
        let extra = unixTime.map { le16(0x5455) + le16(5) + [0x01] + le32($0) } ?? []
        return build(entries.map {
            (name: Array($0.path.utf8), flags: 0x0800, dosTime: $0.dosTime, data: $0.data, extra: extra, symlink: false)
        })
    }

    /// Raw name bytes with general-purpose bit 11 set only when `utf8Flag` is true. `unicodePath[i]` adds an
    /// Info-ZIP Unicode Path field (0x7075: version 1, CRC-32 of entry i's name bytes, the UTF-8 name) to entry i,
    /// in both its local and central headers, as Info-ZIP's zip does for names it stores in a code page.
    /// `staleUnicodePathCRCOf[i]`, when given, makes entry i's 0x7075 field carry the CRC-32 of those bytes instead,
    /// as a field left behind by a tool that renamed the entry without updating it. Entries whose index is in
    /// `symlinks` are Unix symlinks (mode 0120777) whose data is the link target's bytes.
    static func stored(_ entries: [(nameBytes: [UInt8], utf8Flag: Bool, dosTime: UInt32, data: [UInt8])],
                       unicodePath: [Int: String] = [:],
                       staleUnicodePathCRCOf: [Int: [UInt8]] = [:], symlinks: Set<Int> = []) -> [UInt8] {
        build(entries.enumerated().map { i, e in
            let extra = unicodePath[i].map { path -> [UInt8] in
                let utf8 = Array(path.utf8)
                return le16(0x7075) + le16(UInt16(5 + utf8.count)) + [0x01] + le32(crc32(staleUnicodePathCRCOf[i] ?? e.nameBytes)) + utf8
            } ?? []
            return (name: e.nameBytes, flags: e.utf8Flag ? 0x0800 : 0, dosTime: e.dosTime, data: e.data, extra: extra,
                    symlink: symlinks.contains(i))
        })
    }

    /// Writes a zip laid out like a OneDrive / SharePoint download over 4 GB and returns its URL: stored entries with
    /// general-purpose bits 3 and 11 (zero sizes and CRC in the local header, a signed 32-bit data descriptor after
    /// the data), an unused 4 GiB gap so the central directory starts above 0xFFFFFFFF, then a zip64
    /// end-of-central-directory record (version fields 0), its locator, and a 32-bit record whose central-directory
    /// offset is 0xFFFFFFFF. `locatorTotalDisks` is the locator's total-number-of-disks field: the spec says 1,
    /// OneDrive writes 0. The gap is a hole, so the file takes no real disk space on APFS; delete it when done.
    static func writeOneDriveZip64(_ entries: [(path: String, dosTime: UInt32, data: [UInt8])],
                                   locatorTotalDisks: UInt32) throws -> URL {
        let gap: UInt64 = 1 << 32
        var head = [UInt8]()
        var central = [UInt8]()
        for e in entries {
            let name = Array(e.path.utf8)
            let isDir = name.last == UInt8(ascii: "/")
            let crc = crc32(e.data)
            let size = UInt32(e.data.count)
            let offset = UInt32(head.count)
            let time = UInt16(truncatingIfNeeded: e.dosTime)
            let date = UInt16(truncatingIfNeeded: e.dosTime >> 16)

            head += le32(0x04034b50); head += le16(20); head += le16(0x0808); head += le16(0)
            head += le16(time); head += le16(date)
            head += le32(0); head += le32(0); head += le32(0)
            head += le16(UInt16(name.count)); head += le16(0)
            head += name; head += e.data
            head += le32(0x08074b50); head += le32(crc); head += le32(size); head += le32(size)

            central += le32(0x02014b50); central += le16(45); central += le16(20)
            central += le16(0x0808); central += le16(0)
            central += le16(time); central += le16(date)
            central += le32(crc); central += le32(size); central += le32(size)
            central += le16(UInt16(name.count)); central += le16(0); central += le16(0)
            central += le16(0); central += le16(0)
            central += le32(isDir ? 0x10 : 0)
            central += le32(offset)
            central += name
        }
        let count = UInt64(entries.count)
        let cdOffset = UInt64(head.count) + gap
        var tail = central
        tail += le32(0x06064b50); tail += le64(44); tail += le16(0); tail += le16(0)
        tail += le32(0); tail += le32(0)
        tail += le64(count); tail += le64(count)
        tail += le64(UInt64(central.count)); tail += le64(cdOffset)
        tail += le32(0x07064b50); tail += le32(0); tail += le64(cdOffset + UInt64(central.count)); tail += le32(locatorTotalDisks)
        tail += le32(0x06054b50); tail += le16(0); tail += le16(0)
        tail += le16(UInt16(count)); tail += le16(UInt16(count))
        tail += le32(UInt32(central.count)); tail += le32(0xFFFF_FFFF); tail += le16(0)

        let url = Fixtures.tempDir().appendingPathComponent("onedrive.zip")
        try Data(head).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: cdOffset)
        try handle.seekToEnd()
        try handle.write(contentsOf: tail)
        return url
    }

    /// Each central-directory entry's name bytes and general-purpose flags, in directory order. Reads any zip
    /// with a 32-bit end-of-central-directory record (no zip64), such as a small one libarchive wrote.
    static func centralNames(_ zip: [UInt8]) -> [(nameBytes: [UInt8], flags: UInt16)] {
        guard zip.count >= 22,
              let eocd = stride(from: zip.count - 22, through: 0, by: -1).first(where: { u32(zip, $0) == 0x06054b50 })
        else { return [] }
        let count = Int(u16(zip, eocd + 10))
        var p = Int(u32(zip, eocd + 16))
        var names = [(nameBytes: [UInt8], flags: UInt16)]()
        for _ in 0..<count {
            guard p + 46 <= zip.count, u32(zip, p) == 0x02014b50 else { break }
            let nameLength = Int(u16(zip, p + 28))
            let rest = Int(u16(zip, p + 30)) + Int(u16(zip, p + 32))
            guard p + 46 + nameLength <= zip.count else { break }
            names.append((nameBytes: Array(zip[(p + 46)..<(p + 46 + nameLength)]), flags: u16(zip, p + 8)))
            p += 46 + nameLength + rest
        }
        return names
    }

    /// Each central-directory entry's extra-field header IDs (e.g. 0x7075 for an Info-ZIP Unicode Path field), in
    /// directory order. Same limits as `centralNames`.
    static func centralExtraIDs(_ zip: [UInt8]) -> [[UInt16]] {
        guard zip.count >= 22,
              let eocd = stride(from: zip.count - 22, through: 0, by: -1).first(where: { u32(zip, $0) == 0x06054b50 })
        else { return [] }
        var p = Int(u32(zip, eocd + 16))
        var result = [[UInt16]]()
        for _ in 0..<Int(u16(zip, eocd + 10)) {
            guard p + 46 <= zip.count, u32(zip, p) == 0x02014b50 else { break }
            var q = p + 46 + Int(u16(zip, p + 28))
            let end = q + Int(u16(zip, p + 30))
            guard end <= zip.count else { break }
            var ids = [UInt16]()
            while q + 4 <= end {
                ids.append(u16(zip, q))
                q += 4 + Int(u16(zip, q + 2))
            }
            result.append(ids)
            p = end + Int(u16(zip, p + 32))
        }
        return result
    }

    /// A name ending in "/" is written as a directory.
    private static func build(_ entries: [(name: [UInt8], flags: UInt16, dosTime: UInt32, data: [UInt8], extra: [UInt8],
                                           symlink: Bool)]) -> [UInt8] {
        var out = [UInt8]()
        var central = [UInt8]()
        var count = 0
        for e in entries {
            let name = e.name
            let extra = e.extra
            let isDir = name.last == UInt8(ascii: "/")
            let data = isDir ? [] : e.data
            let crc = crc32(data)
            let offset = UInt32(out.count)
            let time = UInt16(truncatingIfNeeded: e.dosTime)
            let date = UInt16(truncatingIfNeeded: e.dosTime >> 16)

            out += le32(0x04034b50); out += le16(10); out += le16(e.flags); out += le16(0)
            out += le16(time); out += le16(date)
            out += le32(crc); out += le32(UInt32(data.count)); out += le32(UInt32(data.count))
            out += le16(UInt16(name.count)); out += le16(UInt16(extra.count))
            out += name; out += extra; out += data

            central += le32(0x02014b50); central += le16(0x031e); central += le16(10)
            central += le16(e.flags); central += le16(0)
            central += le16(time); central += le16(date)
            central += le32(crc); central += le32(UInt32(data.count)); central += le32(UInt32(data.count))
            central += le16(UInt16(name.count)); central += le16(UInt16(extra.count)); central += le16(0)
            central += le16(0); central += le16(0)
            central += le32((isDir ? 0o040755 : e.symlink ? 0o120777 : 0o100644) << 16 | (isDir ? 0x10 : 0))
            central += le32(offset)
            central += name; central += extra
            count += 1
        }
        let cdOffset = UInt32(out.count)
        out += central
        if count >= 0xFFFF {
            // More than 65 534 entries: zip64 end-of-central-directory record and locator.
            let zip64Offset = UInt64(out.count)
            out += le32(0x06064b50); out += le64(44); out += le16(45); out += le16(45)
            out += le32(0); out += le32(0)
            out += le64(UInt64(count)); out += le64(UInt64(count))
            out += le64(UInt64(central.count)); out += le64(UInt64(cdOffset))
            out += le32(0x07064b50); out += le32(0); out += le64(zip64Offset); out += le32(1)
        }
        let n16 = UInt16(min(count, 0xFFFF))
        out += le32(0x06054b50); out += le16(0); out += le16(0)
        out += le16(n16); out += le16(n16)
        out += le32(UInt32(central.count)); out += le32(cdOffset); out += le16(0)
        return out
    }

    static func write(_ bytes: [UInt8]) -> URL {
        let url = Fixtures.tempDir().appendingPathComponent("synthetic.zip")
        try? Data(bytes).write(to: url)
        return url
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(u16(b, i)) | UInt32(u16(b, i + 2)) << 16 }
    private static func le64(_ v: UInt64) -> [UInt8] { le32(UInt32(v & 0xFFFF_FFFF)) + le32(UInt32(v >> 32)) }
    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}
