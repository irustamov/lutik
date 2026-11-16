import Compression
import Foundation

/// Second-chance detection for a tar inside a gzip or xz stream that libarchive cannot bid on.
///
/// libarchive's gzip and xz filters fill a whole 64 KiB output block before returning anything, and a
/// stream that ends inside that first block fails with "truncated ... input" while the filters are
/// still being chosen, before any format bids. The tar header at the front is intact, so the format is
/// knowable: this decodes the first 512 bytes with the Compression framework and checks the tar header
/// checksum. Opening such a file still fails, with `.corrupted`.
enum CompressedTarProbe {
    private static let headLimit = 64 * 1024
    private static let block = 512

    static func format(at url: URL) -> ArchiveFormat? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: headLimit), data.count >= 6 else { return nil }
        let b = [UInt8](data)
        if b[0] == 0x1F, b[1] == 0x8B, b[2] == 0x08, let start = gzipPayloadOffset(b) {
            return isTarHeader(decode(Array(b[start...]), COMPRESSION_ZLIB)) ? .tarGzip : nil
        }
        if b.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) {
            return isTarHeader(decode(b, COMPRESSION_LZMA)) ? .tarXz : nil
        }
        return nil
    }

    /// Offset of the deflate data after a gzip member header (RFC 1952), or nil if the header is cut
    /// short or uses reserved flags.
    static func gzipPayloadOffset(_ b: [UInt8]) -> Int? {
        guard b.count > 10 else { return nil }
        let flags = b[3]
        guard flags & 0xE0 == 0 else { return nil }
        var i = 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard i + 2 <= b.count else { return nil }
            i += 2 + Int(b[i]) + Int(b[i + 1]) << 8
        }
        for bit: UInt8 in [0x08, 0x10] where flags & bit != 0 {  // FNAME, FCOMMENT: NUL-terminated
            guard i < b.count, let nul = b[i...].firstIndex(of: 0) else { return nil }
            i = nul + 1
        }
        if flags & 0x02 != 0 { i += 2 }  // FHCRC
        return i < b.count ? i : nil
    }

    /// Up to the first 512 decoded bytes; fewer when the input ends or is invalid.
    static func decode(_ input: [UInt8], _ algorithm: compression_algorithm) -> [UInt8] {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
            return []
        }
        defer { compression_stream_destroy(stream) }
        var out = [UInt8](repeating: 0, count: block)
        var produced = 0
        input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                stream.pointee.src_ptr = s
                stream.pointee.src_size = src.count
                stream.pointee.dst_ptr = d
                stream.pointee.dst_size = block
                while stream.pointee.dst_size > 0 {
                    let before = (stream.pointee.src_size, stream.pointee.dst_size)
                    let status = compression_stream_process(stream, 0)
                    if status != COMPRESSION_STATUS_OK { break }
                    if before == (stream.pointee.src_size, stream.pointee.dst_size) { break }
                }
                produced = block - stream.pointee.dst_size
            }
        }
        return Array(out[..<produced])
    }

    /// A full 512-byte block, not all zero, whose checksum field (octal, bytes 148..<156) matches the
    /// byte sum with that field counted as spaces. Old tars summed signed bytes, so both are accepted.
    static func isTarHeader(_ h: [UInt8]) -> Bool {
        guard h.count == block, h.contains(where: { $0 != 0 }) else { return false }
        var stored = 0
        var digits = 0
        for c in h[148..<156] {
            if c == 0x20 && digits == 0 { continue }
            guard c >= 0x30 && c <= 0x37 else { break }
            stored = stored * 8 + Int(c - 0x30)
            digits += 1
        }
        guard digits > 0 else { return false }
        var unsigned = 0
        var signed = 0
        for (i, c) in h.enumerated() {
            let v = (148..<156).contains(i) ? UInt8(0x20) : c
            unsigned += Int(v)
            signed += Int(Int8(bitPattern: v))
        }
        return stored == unsigned || stored == signed
    }
}
