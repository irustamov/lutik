import Foundation

/// Writes small store-method zips whose names are stored in a legacy code page (general-purpose bit 11
/// clear, no Unicode Path field), the way old Windows and DOS tools wrote them.
enum LegacyZip {
    /// A zip at a fresh temporary path holding `paths` (a path ending in "/" is a folder), each name stored as
    /// its bytes in `encoding`; a file's contents are its path in UTF-8. The caller removes the parent folder.
    static func write(_ paths: [String], as encoding: String.Encoding) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyZip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("legacy.zip")
        try Data(bytes(paths, as: encoding)).write(to: url)
        return url
    }

    static func bytes(_ paths: [String], as encoding: String.Encoding) -> [UInt8] {
        var out = [UInt8]()
        var central = [UInt8]()
        // 2024-05-01 12:00:00 in DOS time.
        let time: UInt16 = 12 << 11
        let date = UInt16(((2024 - 1980) << 9) | (5 << 5) | 1)
        for path in paths {
            let name = [UInt8](path.data(using: encoding)!)
            let isFolder = path.hasSuffix("/")
            let data = isFolder ? [] : Array(path.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            out += le32(0x04034b50) + le16(10) + le16(0) + le16(0) + le16(time) + le16(date)
            out += le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count))
            out += le16(UInt16(name.count)) + le16(0) + name + data
            central += le32(0x02014b50) + le16(0x031e) + le16(10) + le16(0) + le16(0) + le16(time) + le16(date)
            central += le32(crc) + le32(UInt32(data.count)) + le32(UInt32(data.count))
            central += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0)
            central += le32((isFolder ? 0o040755 : 0o100644) << 16 | (isFolder ? 0x10 : 0)) + le32(offset) + name
        }
        let centralOffset = UInt32(out.count)
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(UInt16(paths.count)) + le16(UInt16(paths.count))
        out += le32(UInt32(central.count)) + le32(centralOffset) + le16(0)
        return out
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]
    }

    private static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data {
            c ^= UInt32(b)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        }
        return c ^ 0xFFFFFFFF
    }
}

extension String.Encoding {
    /// DOS Russian, which `String.Encoding` has no member for.
    static let testCP866 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosRussian.rawValue)))
}
