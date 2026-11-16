import Foundation

/// Minimal ISO 9660 images with Rockridge (SUSP) entries, built in memory for the reader's limit tests: 2,048-byte
/// blocks, an empty system area, the primary volume descriptor at block 16, the set terminator at block 17 and the
/// root directory extent from block 18. The root's "." record carries SP (so the reader parses SUSP) and a PX that keeps
/// it a directory; every other record must carry at least one SUSP entry, or the reader refuses it. Sizes and the
/// volume size can be claimed past the file, which is the point of the tests. At least 24 blocks (48 KiB): the bidder
/// reads 16 + 8 blocks.
enum SyntheticISO {
    static let block = 2048
    static let rootLocation = 18

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func be16(_ v: Int) -> [UInt8] { le16(v).reversed() }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    static func be32(_ v: UInt32) -> [UInt8] { le32(v).reversed() }
    /// ECMA-119 7.2.3 / 7.3.3: little-endian then big-endian.
    static func both16(_ v: Int) -> [UInt8] { le16(v) + be16(v) }
    static func both32(_ v: UInt32) -> [UInt8] { le32(v) + be32(v) }

    // MARK: - SUSP / Rockridge entries

    static func sp() -> [UInt8] { Array("SP".utf8) + [7, 1, 0xBE, 0xEF, 0] }
    static func px(mode: UInt32) -> [UInt8] {
        Array("PX".utf8) + [36, 1] + both32(mode) + both32(1) + both32(0) + both32(0)
    }
    /// NM: `continues` says the next NM entry (here or in a continuation area) carries on the name. At most 250 bytes.
    static func nm(_ name: [UInt8], continues: Bool = false) -> [UInt8] {
        precondition(name.count <= 250)
        return Array("NM".utf8) + [UInt8(5 + name.count), 1, continues ? 1 : 0] + name
    }
    static func nm(_ name: String, continues: Bool = false) -> [UInt8] { nm(Array(name.utf8), continues: continues) }
    /// SL with one text component: `continues` says the next SL entry carries on the link. At most 248 bytes.
    static func sl(_ text: [UInt8], continues: Bool = false) -> [UInt8] {
        precondition(text.count <= 248)
        return Array("SL".utf8) + [UInt8(7 + text.count), 1, continues ? 1 : 0, 0x01, UInt8(text.count)] + text
    }
    /// PD (SUSP padding) of `length` bytes in all, 4 to 255.
    static func pd(_ length: Int) -> [UInt8] {
        precondition((4...255).contains(length))
        return Array("PD".utf8) + [UInt8(length), 1] + Array(repeating: 0, count: length - 4)
    }
    /// CE: the system use area continues at `block`, `offset` bytes in, for `size` bytes.
    static func ce(block: Int, offset: Int = 0, size: Int) -> [UInt8] {
        Array("CE".utf8) + [28, 1] + both32(UInt32(block)) + both32(UInt32(offset)) + both32(UInt32(size))
    }

    // MARK: - Directory records

    /// A directory record: `identifier` is the ISO name (one byte 0 for ".", 1 for ".."), `susp` its system use area.
    static func record(_ identifier: [UInt8], location: Int = 0, size: UInt32 = 0, directory: Bool = false,
                       susp: [UInt8]) -> [UInt8] {
        let pad = identifier.count % 2 == 0 ? 1 : 0
        let length = 33 + identifier.count + pad + susp.count
        precondition(length <= 255, "record of \(length) bytes")
        var r = [UInt8(length), 0] + both32(UInt32(location)) + both32(size)
        r += [126, 1, 1, 0, 0, 0, 0]  // 2026-01-01 00:00:00 GMT
        r += [directory ? 0x02 : 0x00, 0, 0] + both16(1) + [UInt8(identifier.count)] + identifier
        r += Array(repeating: 0, count: pad) + susp
        return r
    }

    /// A zero-size regular file named `name` by NM (its location 0, so no CE it carries counts as past its data).
    static func file(_ index: Int, susp: [UInt8]) -> [UInt8] {
        record(Array("F\(index);1".utf8), susp: susp)
    }

    /// Records packed into whole blocks (a record never crosses a block), as a directory extent is laid out.
    static func pack(_ records: [[UInt8]]) -> [[UInt8]] {
        var blocks: [[UInt8]] = [[]]
        for r in records {
            if blocks[blocks.count - 1].count + r.count > block { blocks.append([]) }
            blocks[blocks.count - 1] += r
        }
        return blocks.map { $0 + Array(repeating: 0, count: block - $0.count) }
    }

    // MARK: - Images

    /// The image: the root directory holds `children(ceStart)` (packed into blocks from block 18; `ceStart` is the
    /// first block after them, where `extra` goes, one 2,048-byte block each), then `tail` blocks of zeros and padding
    /// to 24 blocks. `rootSize` claims the root's size (in the volume descriptor and its "." record) and
    /// `volumeBlocks` the volume's size in blocks; by default both are the real ones.
    static func image(rootSize: UInt32? = nil, volumeBlocks: Int? = nil, tail: Int = 0,
                      children: (_ ceStart: Int) -> [[UInt8]], extra: (_ ceStart: Int) -> [[UInt8]] = { _ in [] })
        throws -> URL {
        func dots(_ size: UInt32) -> [[UInt8]] {
            [record([0], location: rootLocation, size: size, directory: true, susp: sp() + px(mode: 0o40755)),
             record([1], location: rootLocation, size: size, directory: true, susp: px(mode: 0o40755))]
        }
        let extentBlocks = pack(dots(0) + children(0)).count
        let ceStart = rootLocation + extentBlocks
        let size = rootSize ?? UInt32(extentBlocks * block)
        let extent = pack(dots(size) + children(ceStart))
        precondition(extent.count == extentBlocks, "children change size with ceStart")
        var blocks = extent + extra(ceStart).map { b -> [UInt8] in
            precondition(b.count <= block)
            return b + Array(repeating: 0, count: block - b.count)
        }
        blocks += Array(repeating: Array(repeating: 0, count: block), count: tail)
        let total = max(24, rootLocation + blocks.count)
        let volume = volumeBlocks ?? total
        var bytes = [UInt8](repeating: 0, count: 16 * block)
        bytes += pvd(volumeBlocks: volume, rootSize: size)
        bytes += [255] + Array("CD001".utf8) + [1] + Array(repeating: 0, count: block - 7)
        for b in blocks { bytes += b }
        bytes += Array(repeating: 0, count: total * block - bytes.count)
        let url = Fixtures.tempDir().appendingPathComponent("t.iso")
        try Data(bytes).write(to: url)
        return url
    }

    /// A block of SUSP entries, padded by `image`.
    static func area(_ entries: [UInt8]...) -> [UInt8] {
        let a = entries.flatMap { $0 }
        precondition(a.count <= block)
        return a
    }

    /// The primary volume descriptor, or with `joliet` a Joliet supplementary one (UCS-2 level 3), whose root
    /// directory is at block `root`.
    static func pvd(volumeBlocks: Int, rootSize: UInt32, root: Int = rootLocation, joliet: Bool = false) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: block)
        func put(_ offset: Int, _ bytes: [UInt8]) { p.replaceSubrange(offset..<offset + bytes.count, with: bytes) }
        put(0, [joliet ? 2 : 1] + Array("CD001".utf8) + [1])
        if joliet { put(88, Array("%/E".utf8)) }  // escape sequences
        put(8, Array(repeating: 0x20, count: 64))  // system and volume identifiers
        put(80, both32(UInt32(volumeBlocks)))
        put(120, both16(1))  // volume set size
        put(124, both16(1))  // volume sequence number
        put(128, both16(block))
        put(132, both32(0))  // path table size
        put(140, le32(UInt32(rootLocation)))  // type L path table (never read)
        put(156, record([0], location: root, size: rootSize, directory: true, susp: []))
        put(881, [1])  // file structure version
        return p
    }

    // MARK: - Joliet

    /// UCS-2 big-endian, as Joliet identifiers are.
    static func ucs2(_ s: String) -> [UInt8] { s.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }

    /// A Joliet image without Rockridge: the primary volume descriptor at block 16, a Joliet SVD at 17 and the
    /// terminator at 18; then one-block directory extents: the primary root (19), the Joliet root (20), and the
    /// subdirectory in each tree (21, 22). The root holds the zero-size files `files` and a directory `folder` that
    /// holds `inner`; the primary tree calls them F0;1, F1;1... and D (and G0;1...), names a listing must not show.
    static func joliet(files: [String], folder: String, inner: [String]) throws -> URL {
        let primaryRoot = 19, jolietRoot = 20, primarySub = 21, jolietSub = 22
        func dir(_ at: Int, parent: Int, _ children: [[UInt8]]) -> [UInt8] {
            let blocks = pack([record([0], location: at, size: UInt32(block), directory: true, susp: []),
                               record([1], location: parent, size: UInt32(block), directory: true, susp: [])]
                              + children)
            precondition(blocks.count == 1, "directory over one block")
            return blocks[0]
        }
        func sub(_ identifier: [UInt8], _ at: Int) -> [UInt8] {
            record(identifier, location: at, size: UInt32(block), directory: true, susp: [])
        }
        let extents = [
            dir(primaryRoot, parent: primaryRoot,
                files.indices.map { record(Array("F\($0);1".utf8), susp: []) } + [sub(Array("D".utf8), primarySub)]),
            dir(jolietRoot, parent: jolietRoot,
                files.map { record(ucs2($0 + ";1"), susp: []) } + [sub(ucs2(folder), jolietSub)]),
            dir(primarySub, parent: primaryRoot, inner.indices.map { record(Array("G\($0);1".utf8), susp: []) }),
            dir(jolietSub, parent: jolietRoot, inner.map { record(ucs2($0 + ";1"), susp: []) }),
        ]
        let total = 24
        var bytes = [UInt8](repeating: 0, count: 16 * block)
        bytes += pvd(volumeBlocks: total, rootSize: UInt32(block), root: primaryRoot)
        bytes += pvd(volumeBlocks: total, rootSize: UInt32(block), root: jolietRoot, joliet: true)
        bytes += [255] + Array("CD001".utf8) + [1] + Array(repeating: 0, count: block - 7)
        for e in extents { bytes += e }
        bytes += Array(repeating: 0, count: total * block - bytes.count)
        let url = Fixtures.tempDir().appendingPathComponent("t.iso")
        try Data(bytes).write(to: url)
        return url
    }
}
