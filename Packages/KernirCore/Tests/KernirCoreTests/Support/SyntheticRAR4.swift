import Foundation

/// Builds RAR 4 archives of stored files in memory (WinRAR 2.x-4.x headers, header CRC16s computed), for tests
/// that need OEM and Unicode entry names without an external tool.
enum SyntheticRAR4 {
    /// `unicode` nil: a plain (OEM) name. Non-nil sets FHD_UNICODE: "" stores `name` alone (libarchive reads it as
    /// UTF-8); otherwise WinRAR's form, `name`, NUL, then `unicode` as UTF-16LE units (every flag pair 2: a full
    /// unit follows). The archive ends with a 7-byte end-of-archive block. Entries whose index is in
    /// `unknownHostOS` name host OS 9, which libarchive rejects after it has parsed the entry's name.
    static func bytes(_ entries: [(name: [UInt8], unicode: String?, data: [UInt8])],
                      unknownHostOS: Set<Int> = []) -> [UInt8] {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        func le32(_ v: UInt32) -> [UInt8] { le16(Int(v & 0xFFFF)) + le16(Int(v >> 16)) }
        /// A block: CRC16 (low half of the CRC-32 of everything after it), then `body` (type first).
        func block(_ body: [UInt8]) -> [UInt8] { le16(Int(SyntheticZip.crc32(body) & 0xFFFF)) + body }
        var out: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
        out += block([0x73] + le16(0) + le16(13) + [UInt8](repeating: 0, count: 6))
        for (i, e) in entries.enumerated() {
            var name = e.name
            if let unicode = e.unicode, !unicode.isEmpty {
                name += [0, 0]  // NUL, then the high byte (unused: every unit is stored whole)
                let units = Array(unicode.utf16)
                for start in stride(from: 0, to: units.count, by: 4) {
                    name.append(0xAA)
                    for u in units[start..<min(start + 4, units.count)] { name += le16(Int(u)) }
                }
            }
            let flags = 0x8000 | (e.unicode == nil ? 0 : 0x0200)
            var body: [UInt8] = [0x74] + le16(flags) + le16(32 + name.count)
            body += le32(UInt32(e.data.count)) + le32(UInt32(e.data.count))
            body.append(unknownHostOS.contains(i) ? 9 : 2)  // 2: Win32
            body += le32(SyntheticZip.crc32(e.data)) + le32(0x58A1_6000) + [20, 0x30] + le16(name.count)
            body += le32(0x20) + name
            out += block(body) + e.data
        }
        out += block([0x7B] + le16(0x4000) + le16(7))
        return out
    }

    /// `bytes(entries)` written to "legacy.rar" in a fresh temp dir.
    static func write(_ entries: [(name: [UInt8], unicode: String?, data: [UInt8])]) -> URL {
        let url = Fixtures.tempDir().appending(path: "legacy.rar")
        try? Data(bytes(entries)).write(to: url)
        return url
    }
}
