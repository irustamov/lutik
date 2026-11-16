import Foundation

/// Byte-level facts about one file of a possible multi-volume set, read straight from its headers.
///
/// The set resolver asks three questions the file name cannot answer: is this `.rar` really a
/// volume (and the first or the last one), how long a split 7z is in total, and which disk of a
/// spanned zip this file is. All input is untrusted: reads go through `FileHandle` with explicit
/// offsets and bounded lengths (never the whole file), sizes read from the file are added with
/// overflow checks, and every header walk advances at least one fixed header per step and stops
/// after `maxBlocks` blocks or `maxBytesRead` bytes. A walk that cannot finish answers `isLast: nil`.
enum VolumeProbe {
    /// What a RAR main header and block chain say about the volume. `nil` fields are unknown.
    struct RarVolumeInfo: Equatable {
        let isVolume: Bool
        let isFirst: Bool?
        let isLast: Bool?
    }

    private static let rar4Signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
    private static let rar5Signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
    private static let sevenZipSignature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
    private static let sevenZipStartHeaderSize: UInt64 = 32
    private static let eocdSignature: UInt32 = 0x0605_4b50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4b50
    private static let zip64EocdSignature: UInt32 = 0x0606_4b50
    private static let eocdSize: UInt64 = 22
    private static let locatorSize: UInt64 = 20
    private static let zip64EocdMinSize: UInt64 = 56
    private static let maxCommentLength: UInt64 = 0xFFFF

    /// Walk limits, so a hostile chain of tiny blocks cannot keep the probe busy.
    private static let maxBlocks = 100_000
    private static let maxBytesRead: UInt64 = 64 * 1024 * 1024

    /// Volume facts for a RAR4 or RAR5 file. `nil` when the file is not RAR (no signature at
    /// offset 0), its main header is unreadable, or RAR5 encrypts all headers (archive encryption
    /// header): then nothing past the signature can be read without a password.
    static func rar(at url: URL) throws(ArchiveError) -> RarVolumeInfo? {
        try withSource(url) { source in
            guard let head = try source.read(at: 0, count: min(source.size, 8)) else { return nil }
            if head.starts(with: rar5Signature) { return try rar5(source) }
            if head.starts(with: rar4Signature) { return try rar4(source) }
            return nil
        }
    }

    /// The whole set's size in bytes as the first part of a split 7z records it: the 32-byte
    /// signature header plus the next-header offset and size. `nil` when the file is not 7z or the
    /// sum overflows.
    static func sevenZipTotalSize(firstPart url: URL) throws(ArchiveError) -> Int64? {
        try withSource(url) { source in
            guard let header = try source.read(at: 0, count: sevenZipStartHeaderSize),
                  header.starts(with: sevenZipSignature) else { return nil }
            let (withOffset, o1) = sevenZipStartHeaderSize.addingReportingOverflow(u64(header, 12))
            let (total, o2) = withOffset.addingReportingOverflow(u64(header, 20))
            guard !o1, !o2, total <= UInt64(Int64.max) else { return nil }
            return Int64(total)
        }
    }

    /// The disk number in the zip end-of-central-directory record found in the last 64 KiB + 22
    /// bytes. A spanned set's last file (`.zip`) carries its own index, so disk > 0 means earlier
    /// `.z01`, `.z02`, ... parts exist. `found: false` when no record is there (a middle part, or
    /// not a zip); then `diskNumber` is 0. The record's comment must end exactly at EOF; trailing data → not found.
    static func zipEOCD(at url: URL) throws(ArchiveError) -> (diskNumber: Int, found: Bool) {
        try zipEOCD(parts: [url])
    }

    /// `zipEOCD(at:)` on the end of `parts` read as one file, in order: the record (and its comment, and a zip64
    /// locator before it) may start in any part, as when a byte split (`x.zip.001` ...) ends 1 ... 21 bytes past a
    /// part boundary, or a long comment spans several small parts. The same window and rule as for one file. Positions
    /// are in the joined bytes, so a zip64 record's disk number is read only where its offset means the same there:
    /// a byte split is one disk-0 zip; a spanned set's disk index comes from its `.zip` alone.
    static func zipEOCD(parts: [URL]) throws(ArchiveError) -> (diskNumber: Int, found: Bool) {
        try withSource(parts) { source in
            guard let (tail, tailStart, eocd) = try exactEOCD(source) else { return (0, false) }
            let disk = u16(tail, eocd + 4)
            guard disk == 0xFFFF else { return (Int(disk), true) }
            let eocdPosition = tailStart + UInt64(eocd)
            return (try zip64DiskNumber(source, eocdPosition: eocdPosition) ?? Int(disk), true)
        }
    }

    /// The archive comment of the zip end-of-central-directory record `zipEOCD` finds (the one whose comment ends
    /// exactly at EOF), verbatim; empty when the record has none. `nil` when there is no such record (not a zip, or
    /// data appended after the comment).
    static func zipComment(at url: URL) throws(ArchiveError) -> [UInt8]? {
        try zipComment(parts: [url])
    }

    /// `zipComment(at:)` on the end of `parts` read as one file (see `zipEOCD(parts:)`): a comment that spans parts
    /// is returned whole.
    static func zipComment(parts: [URL]) throws(ArchiveError) -> [UInt8]? {
        try withSource(parts) { source in
            guard let (tail, _, eocd) = try exactEOCD(source) else { return nil }
            return Array(tail[(eocd + Int(eocdSize))...])
        }
    }

    /// The last 64 KiB + 22 bytes, where they start, and the index in them of the last end-of-central-directory
    /// record whose comment ends exactly at EOF. A looser match would take the EOCD of a stored inner zip lying in
    /// a non-final part's tail.
    private static func exactEOCD(_ source: FileSource) throws -> (tail: [UInt8], tailStart: UInt64, index: Int)? {
        guard source.size >= eocdSize else { return nil }
        let tailLength = min(source.size, eocdSize + maxCommentLength)
        let tailStart = source.size - tailLength
        guard let tail = try source.read(at: tailStart, count: tailLength) else { return nil }
        var i = tail.count - Int(eocdSize)
        while i >= 0 {
            if u32(tail, i) == eocdSignature, Int(u16(tail, i + 20)) == tail.count - i - Int(eocdSize) {
                return (tail, tailStart, i)
            }
            i -= 1
        }
        return nil
    }

    // MARK: - Bounds-checked file access

    /// One file, or a set's parts read as one file (`JoinedFile`).
    private typealias FileSource = JoinedFile

    /// Reads for a header walk: small reads served from a cached window, with a total byte budget.
    private struct WalkReader {
        let source: FileSource
        private(set) var bytesRead: UInt64 = 0
        private var windowStart: UInt64 = 0
        private var window: [UInt8] = []
        private static let chunk: UInt64 = 16 * 1024

        init(source: FileSource) { self.source = source }

        /// Up to `count` bytes at `offset` (fewer at EOF); `nil` past EOF or over the read budget.
        mutating func read(at offset: UInt64, upTo count: UInt64) throws -> [UInt8]? {
            guard offset < source.size else { return nil }
            let wanted = min(count, source.size - offset)
            let windowEnd = windowStart + UInt64(window.count)
            if offset < windowStart || offset + wanted > windowEnd {
                let length = min(max(wanted, Self.chunk), source.size - offset)
                guard bytesRead + length <= VolumeProbe.maxBytesRead,
                      let bytes = try source.read(at: offset, count: length) else { return nil }
                bytesRead += length
                windowStart = offset
                window = bytes
            }
            let from = Int(offset - windowStart)
            return Array(window[from..<from + Int(wanted)])
        }
    }

    private static func withSource<T>(_ url: URL, _ body: (FileSource) throws -> T) throws(ArchiveError) -> T {
        try withSource([url], body)
    }

    private static func withSource<T>(_ urls: [URL], _ body: (FileSource) throws -> T) throws(ArchiveError) -> T {
        do {
            return try body(try JoinedFile(urls))
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw .io("Could not read \(urls[urls.count - 1].lastPathComponent): \(error.localizedDescription)")
        }
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(u16(b, i)) | UInt32(u16(b, i + 2)) << 16 }
    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, i)) | UInt64(u32(b, i + 4)) << 32 }

    // MARK: - RAR4

    private static let rar4MarkSize: UInt64 = 7
    private static let rar4BlockSize: UInt64 = 7
    private static let rar4MainType: UInt8 = 0x73
    private static let rar4FileType: UInt8 = 0x74
    private static let rar4ServiceType: UInt8 = 0x7A
    private static let rar4EndType: UInt8 = 0x7B

    /// RAR 1.5-4.x. The main header follows the 7-byte marker; its flags say volume, first volume
    /// and encrypted headers. Each block is HEAD_CRC(2) HEAD_TYPE(1) HEAD_FLAGS(2) HEAD_SIZE(2),
    /// then ADD_SIZE(4) when flag 0x8000 is set or the block is a file header (where it is
    /// PACK_SIZE, with HIGH_PACK_SIZE at offset 32 when flag 0x0100 is set).
    private static func rar4(_ source: FileSource) throws -> RarVolumeInfo? {
        guard let main = try source.read(at: rar4MarkSize, count: rar4BlockSize),
              main[2] == rar4MainType else { return nil }
        let flags = u16(main, 3)
        let headSize = UInt64(u16(main, 5))
        guard headSize >= rar4BlockSize else { return nil }

        let isVolume = flags & 0x0001 != 0
        // MHD_FIRSTVOLUME (0x0100) is only guaranteed by RAR 3.0+, which also sets MHD_NEWNUMBERING
        // (0x0010). Older volumes lack both, so their first-ness is unknown, not false.
        let isFirst: Bool? = flags & 0x0010 != 0 ? flags & 0x0100 != 0 : nil
        // MHD_PASSWORD: every block after the main header is encrypted.
        if flags & 0x0080 != 0 { return RarVolumeInfo(isVolume: isVolume, isFirst: isFirst, isLast: nil) }
        // A single archive is its own last part; no need to walk it.
        guard isVolume else { return RarVolumeInfo(isVolume: false, isFirst: isFirst, isLast: true) }
        let isLast = try rar4IsLast(source, from: rar4MarkSize + headSize)
        return RarVolumeInfo(isVolume: true, isFirst: isFirst, isLast: isLast)
    }

    /// Walks the blocks after the main header. The end block's EARC_NEXT_VOLUME (0x0001) decides;
    /// without an end block, a last file header with LHD_SPLIT_AFTER (0x0002) means more parts
    /// follow. Anything else, including a malformed or truncated chain, is unknown (`nil`).
    private static func rar4IsLast(_ source: FileSource, from start: UInt64) throws -> Bool? {
        var reader = WalkReader(source: source)
        var position = start
        var lastFileSplitAfter = false
        for _ in 0..<maxBlocks {
            if position == source.size { return lastFileSplitAfter ? false : nil }
            // 36 bytes cover the fixed block header plus a file header's HIGH_PACK_SIZE.
            guard let block = try reader.read(at: position, upTo: 36), block.count >= Int(rar4BlockSize) else { return nil }
            let type = block[2]
            let flags = u16(block, 3)
            let headSize = UInt64(u16(block, 5))
            guard headSize >= rar4BlockSize else { return nil }
            if type == rar4EndType { return flags & 0x0001 == 0 }

            let isFileLike = type == rar4FileType || type == rar4ServiceType
            var addSize: UInt64 = 0
            if flags & 0x8000 != 0 || isFileLike {
                guard headSize >= 11, block.count >= 11 else { return nil }
                addSize = UInt64(u32(block, 7))
            }
            if isFileLike {
                guard headSize >= 32 else { return nil }
                if flags & 0x0100 != 0 {
                    guard headSize >= 36, block.count >= 36 else { return nil }
                    addSize |= UInt64(u32(block, 32)) << 32
                }
            }
            if type == rar4FileType { lastFileSplitAfter = flags & 0x0002 != 0 }

            let (length, o1) = headSize.addingReportingOverflow(addSize)
            let (next, o2) = position.addingReportingOverflow(length)
            guard !o1, !o2, next <= source.size else { return nil }
            position = next
        }
        return nil
    }

    // MARK: - RAR5

    private static let rar5SignatureSize: UInt64 = 8
    /// The format caps a header at 2 MB (its size vint is at most 3 bytes).
    private static let rar5MaxHeaderSize: UInt64 = 2 * 1024 * 1024
    /// Enough of a header for the common fields plus a main or end header's own vints.
    private static let rar5HeaderPrefix: UInt64 = 128

    private struct Rar5Header {
        let type: UInt64
        let flags: UInt64
        /// The type-specific fields that follow the common ones, as far as they were read.
        let body: ArraySlice<UInt8>
        /// Where the next header starts (after this header's data area).
        let next: UInt64
    }

    /// RAR 5.0+. Headers are CRC32(4), size vint, then (counted by size) type, flags, extra-area
    /// size when flag 0x0001, data-area size when flag 0x0002, and the type's fields. The main
    /// header (type 1) carries archive flags: 0x0001 volume, 0x0002 volume number present (absent
    /// on the first volume). An archive encryption header (type 4) hides everything else.
    private static func rar5(_ source: FileSource) throws -> RarVolumeInfo? {
        var reader = WalkReader(source: source)
        guard let main = try rar5Header(&reader, at: rar5SignatureSize), main.type == 1 else { return nil }
        var body = main.body
        guard let archiveFlags = vint(&body) else { return nil }
        let isVolume = archiveFlags & 0x0001 != 0
        var isFirst = true
        if archiveFlags & 0x0002 != 0 {
            guard let number = vint(&body) else { return nil }
            isFirst = number == 0
        }
        // A single archive is its own last part; no need to walk it.
        guard isVolume else { return RarVolumeInfo(isVolume: false, isFirst: isFirst, isLast: true) }
        let isLast = try rar5IsLast(&reader, from: main.next)
        return RarVolumeInfo(isVolume: true, isFirst: isFirst, isLast: isLast)
    }

    /// The end-of-archive header (type 5) decides: its flag 0x0001 means more volumes follow.
    /// Without one, a last file header with 0x0010 (data continues in the next volume) means not
    /// last. Anything else, including a malformed or truncated chain, is unknown (`nil`).
    private static func rar5IsLast(_ reader: inout WalkReader, from start: UInt64) throws -> Bool? {
        var position = start
        var lastFileSplitAfter = false
        for _ in 0..<maxBlocks {
            if position == reader.source.size { return lastFileSplitAfter ? false : nil }
            guard let header = try rar5Header(&reader, at: position) else { return nil }
            if header.type == 5 {
                var body = header.body
                guard let endFlags = vint(&body) else { return nil }
                return endFlags & 0x0001 == 0
            }
            if header.type == 2 { lastFileSplitAfter = header.flags & 0x0010 != 0 }
            position = header.next
        }
        return nil
    }

    /// Reads one header at `position`; `nil` when it is malformed or leaves the file. `next` is
    /// always past `position`, so a walk advances.
    private static func rar5Header(_ reader: inout WalkReader, at position: UInt64) throws -> Rar5Header? {
        guard let prefix = try reader.read(at: position, upTo: 4 + 3 + rar5HeaderPrefix), prefix.count > 4 else { return nil }
        var sizeField = prefix[4...]
        let sizeFieldStart = sizeField.startIndex
        guard let headerSize = vint(&sizeField), headerSize > 0, headerSize <= rar5MaxHeaderSize else { return nil }
        let headerStart = position + 4 + UInt64(sizeField.startIndex - sizeFieldStart)
        let available = prefix.count - (sizeField.startIndex - prefix.startIndex)
        var fields = sizeField.prefix(Int(min(headerSize, UInt64(available))))

        guard let type = vint(&fields), let flags = vint(&fields) else { return nil }
        if flags & 0x0001 != 0 { guard vint(&fields) != nil else { return nil } }
        var dataSize: UInt64 = 0
        if flags & 0x0002 != 0 {
            guard let size = vint(&fields) else { return nil }
            dataSize = size
        }
        let (headerEnd, o1) = headerStart.addingReportingOverflow(headerSize)
        let (next, o2) = headerEnd.addingReportingOverflow(dataSize)
        guard !o1, !o2, next <= reader.source.size else { return nil }
        return Rar5Header(type: type, flags: flags, body: fields, next: next)
    }

    /// A RAR5 variable-length integer: 7 bits per byte, low bits first, high bit set on all but the
    /// last byte, at most 10 bytes. Consumes it from `bytes`; `nil` when cut off or over 64 bits.
    private static func vint(_ bytes: inout ArraySlice<UInt8>) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while let byte = bytes.popFirst() {
            let bits = UInt64(byte & 0x7F)
            guard shift < 64, shift < 63 || bits <= 1 else { return nil }
            value |= bits << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    // MARK: - Zip64

    /// The disk number from the Zip64 end-of-central-directory record, found through the locator
    /// just before the EOCD. The record's offset is relative to its own disk, so it is read only when
    /// it lies in this file before the locator; otherwise the locator's disk count gives the last
    /// disk's index. `nil` when there is no locator.
    private static func zip64DiskNumber(_ source: FileSource, eocdPosition: UInt64) throws -> Int? {
        guard eocdPosition >= locatorSize,
              let locator = try source.read(at: eocdPosition - locatorSize, count: locatorSize),
              u32(locator, 0) == zip64LocatorSignature else { return nil }
        let recordOffset = u64(locator, 8)
        let totalDisks = u32(locator, 16)
        let locatorPosition = eocdPosition - locatorSize
        if recordOffset <= locatorPosition, zip64EocdMinSize <= locatorPosition - recordOffset,
           let record = try source.read(at: recordOffset, count: zip64EocdMinSize),
           u32(record, 0) == zip64EocdSignature {
            return Int(u32(record, 16))
        }
        return totalDisks > 0 ? Int(totalDisks - 1) : nil
    }
}
