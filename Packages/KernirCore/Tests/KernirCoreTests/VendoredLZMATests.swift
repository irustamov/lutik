import Testing
import Foundation
import CLibArchive
import CLZMA

/// App Store validation rejects iOS binaries that call the system liblzma (private API there), so xz 5.8.4's
/// liblzma is vendored in the CLZMA target and built on both platforms. These tests prove libarchive runs on
/// that copy and that every liblzma path libarchive can reach works: xz streams (single and multi-threaded,
/// each check), lzma_alone, raw LZMA1/LZMA2 behind each BCJ filter and delta (the 7-Zip reader's chains),
/// and libarchive's xz/lzma filters, 7-Zip LZMA1/LZMA2 and zip lzma/xz methods.
@Suite struct VendoredLZMATests {
    @Test func libarchiveRunsOnVendoredLiblzma() {
        #expect(String(cString: lzma_version_string()) == "5.8.4")
        #expect(String(cString: archive_liblzma_version()) == "5.8.4")
        #expect(String(cString: archive_version_details()).contains("liblzma/5.8.4"))
    }

    // MARK: - liblzma directly

    /// 256 KiB, compressible but not trivial: a slow ramp with pseudo-random bytes mixed in.
    static let sample: [UInt8] = {
        var x: UInt32 = 12345
        return (0..<(256 * 1024)).map { i -> UInt8 in
            x = x &* 1_103_515_245 &+ 12345
            return i % 7 == 0 ? UInt8(truncatingIfNeeded: x >> 16) : UInt8(truncatingIfNeeded: i / 64)
        }
    }()

    /// Runs `strm` (already set up by an encoder or decoder init) over `input` until LZMA_STREAM_END;
    /// nil on any other return code. Always ends the stream.
    static func run(_ strm: inout lzma_stream, _ input: [UInt8]) -> [UInt8]? {
        defer { lzma_end(&strm) }
        var output: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        return input.withUnsafeBufferPointer { inBuf -> [UInt8]? in
            strm.next_in = inBuf.baseAddress
            strm.avail_in = inBuf.count
            while true {
                let ret = chunk.withUnsafeMutableBufferPointer { outBuf -> lzma_ret in
                    strm.next_out = outBuf.baseAddress
                    strm.avail_out = outBuf.count
                    return lzma_code(&strm, LZMA_FINISH)
                }
                output += chunk[0..<(chunk.count - strm.avail_out)]
                if ret == LZMA_STREAM_END { return output }
                if ret != LZMA_OK { return nil }
            }
        }
    }

    static func preset6() -> lzma_options_lzma {
        var opts = lzma_options_lzma()
        #expect(lzma_lzma_preset(&opts, 6) == 0)
        return opts
    }

    // Filter IDs (LZMA_FILTER_* are function-like macros Swift does not import).
    static let lzma1: lzma_vli = 0x4000_0000_0000_0001, lzma2: lzma_vli = 0x21, delta: lzma_vli = 0x03
    static let prefixes: [String: lzma_vli] = [
        "x86": 0x04, "powerpc": 0x05, "ia64": 0x06, "arm": 0x07, "armthumb": 0x08, "sparc": 0x09,
        "arm64": 0x0A, "riscv": 0x0B, "delta": 0x03,
    ]

    /// libarchive's 7-Zip reader decodes folders with lzma_raw_decoder over [BCJ or delta] + LZMA1/LZMA2,
    /// and its 7-Zip writer encodes with lzma_raw_encoder.
    @Test(arguments: ["none", "x86", "powerpc", "ia64", "arm", "armthumb", "sparc", "arm64", "riscv", "delta"],
          [VendoredLZMATests.lzma1, VendoredLZMATests.lzma2])
    func rawChainRoundTrips(prefix: String, last: lzma_vli) throws {
        var lz = Self.preset6()
        var dl = lzma_options_delta()
        dl.type = LZMA_DELTA_TYPE_BYTE
        dl.dist = 4
        let (packed, unpacked) = withUnsafeMutablePointer(to: &lz) { lzp in
            withUnsafeMutablePointer(to: &dl) { dlp -> ([UInt8]?, [UInt8]?) in
                var filters: [lzma_filter] = []
                if let id = Self.prefixes[prefix] {
                    filters.append(lzma_filter(id: id, options: id == Self.delta ? UnsafeMutableRawPointer(dlp) : nil))
                }
                filters.append(lzma_filter(id: last, options: UnsafeMutableRawPointer(lzp)))
                filters.append(lzma_filter(id: UInt64.max, options: nil))  // LZMA_VLI_UNKNOWN terminates
                var enc = lzma_stream()
                guard lzma_raw_encoder(&enc, filters) == LZMA_OK else { return (nil, nil) }
                guard let packed = Self.run(&enc, Self.sample) else { return (nil, nil) }
                var dec = lzma_stream()
                guard lzma_raw_decoder(&dec, filters) == LZMA_OK else { return (packed, nil) }
                return (packed, Self.run(&dec, packed))
            }
        }
        let p = try #require(packed)
        #expect(p.count < Self.sample.count)
        #expect(unpacked == Self.sample)
    }

    /// The xz filter's encoder (lzma_stream_encoder, lzma_stream_encoder_mt with threads) and decoder
    /// (lzma_stream_decoder) with each check libarchive and xz files use.
    @Test(arguments: ["none", "crc32", "crc64", "sha256"], [UInt32(1), 2])
    func xzStreamRoundTrips(checkName: String, threads: UInt32) throws {
        let checks = ["none": LZMA_CHECK_NONE, "crc32": LZMA_CHECK_CRC32, "crc64": LZMA_CHECK_CRC64, "sha256": LZMA_CHECK_SHA256]
        let check = try #require(checks[checkName])
        var lz = Self.preset6()
        let packed = withUnsafeMutablePointer(to: &lz) { lzp -> [UInt8]? in
            let filters = [lzma_filter(id: Self.lzma2, options: UnsafeMutableRawPointer(lzp)),
                           lzma_filter(id: UInt64.max, options: nil)]
            var enc = lzma_stream()
            if threads == 1 {
                guard lzma_stream_encoder(&enc, filters, check) == LZMA_OK else { return nil }
            } else {
                return filters.withUnsafeBufferPointer { fp -> [UInt8]? in
                    var mt = lzma_mt()
                    mt.threads = threads
                    mt.block_size = 64 * 1024  // several blocks, so both threads work
                    mt.filters = fp.baseAddress
                    mt.check = check
                    guard lzma_stream_encoder_mt(&enc, &mt) == LZMA_OK else { return nil }
                    return Self.run(&enc, Self.sample)
                }
            }
            return Self.run(&enc, Self.sample)
        }
        let p = try #require(packed)
        var dec = lzma_stream()
        #expect(lzma_stream_decoder(&dec, UInt64.max, 0) == LZMA_OK)
        #expect(Self.run(&dec, p) == Self.sample)
        #expect(lzma_cputhreads() >= 1)
    }

    /// The .lzma filter and the zip lzma method: lzma_alone_encoder / lzma_alone_decoder.
    @Test func lzmaAloneRoundTrips() throws {
        var lz = Self.preset6()
        var enc = lzma_stream()
        #expect(lzma_alone_encoder(&enc, &lz) == LZMA_OK)
        let packed = try #require(Self.run(&enc, Self.sample))
        var dec = lzma_stream()
        #expect(lzma_alone_decoder(&dec, UInt64.max) == LZMA_OK)
        #expect(Self.run(&dec, packed) == Self.sample)
    }

    // MARK: - Through libarchive

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let format: @Sendable (OpaquePointer?) -> Int32
        let filter: (@Sendable (OpaquePointer?) -> Int32)?
        let options: String?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "tar.xz", format: archive_write_set_format_pax_restricted, filter: archive_write_add_filter_xz, options: nil),
        Case(name: "tar.xz threads=2", format: archive_write_set_format_pax_restricted, filter: archive_write_add_filter_xz,
             options: "xz:threads=2"),
        Case(name: "tar.lzma", format: archive_write_set_format_pax_restricted, filter: archive_write_add_filter_lzma, options: nil),
        Case(name: "7z lzma1", format: archive_write_set_format_7zip, filter: nil, options: "7zip:compression=lzma1"),
        Case(name: "7z lzma2", format: archive_write_set_format_7zip, filter: nil, options: "7zip:compression=lzma2"),
        Case(name: "zip lzma", format: archive_write_set_format_zip, filter: nil, options: "zip:compression=lzma"),
        Case(name: "zip xz threads=2", format: archive_write_set_format_zip, filter: nil,
             options: "zip:compression=xz,zip:threads=2"),
    ]

    @Test(arguments: VendoredLZMATests.cases)
    func libarchiveRoundTrips(_ c: Case) throws {
        let files: [String: [UInt8]] = ["a.bin": Self.sample, "b.txt": Array(repeating: 0x61, count: 10_000)]
        let w = try #require(archive_write_new())
        defer { archive_write_free(w) }
        func werr() -> String { archive_error_string(w).map { String(cString: $0) } ?? "" }
        #expect(c.format(w) == ARCHIVE_OK, "\(werr())")
        if let filter = c.filter { #expect(filter(w) == ARCHIVE_OK, "\(werr())") }
        if let options = c.options { #expect(archive_write_set_options(w, options) == ARCHIVE_OK, "\(werr())") }
        let size = 4 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 1)
        defer { buf.deallocate() }
        var used = 0
        #expect(archive_write_open_memory(w, buf, size, &used) == ARCHIVE_OK, "\(werr())")
        for (name, data) in files.sorted(by: { $0.key < $1.key }) {
            let e = archive_entry_new()
            defer { archive_entry_free(e) }
            archive_entry_set_pathname(e, name)
            archive_entry_set_filetype(e, UInt32(S_IFREG))
            archive_entry_set_perm(e, 0o644)
            archive_entry_set_size(e, Int64(data.count))
            #expect(archive_write_header(w, e) == ARCHIVE_OK, "\(werr())")
            #expect(data.withUnsafeBytes { archive_write_data(w, $0.baseAddress, $0.count) } == data.count, "\(werr())")
        }
        #expect(archive_write_close(w) == ARCHIVE_OK, "\(werr())")
        #expect(used > 0 && used < Self.sample.count, "\(c.name): \(used) bytes")

        let r = try #require(archive_read_new())
        defer { archive_read_free(r) }
        func rerr() -> String { archive_error_string(r).map { String(cString: $0) } ?? "" }
        archive_read_support_filter_all(r)
        archive_read_support_format_all(r)
        #expect(archive_read_open_memory(r, buf, used) == ARCHIVE_OK, "\(rerr())")
        var read: [String: [UInt8]] = [:]
        var entry: OpaquePointer?
        while archive_read_next_header(r, &entry) == ARCHIVE_OK {
            let name = String(cString: archive_entry_pathname(entry))
            var data: [UInt8] = []
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = chunk.withUnsafeMutableBytes { archive_read_data(r, $0.baseAddress, $0.count) }
                if n <= 0 { #expect(n == 0, "\(name): \(rerr())"); break }
                data += chunk[0..<n]
            }
            read[name] = data
        }
        #expect(read == files, "\(c.name): \(rerr())")
    }
}

#if os(macOS)
/// 7-Zip-made folders with BCJ/ARM64/delta filters in front of LZMA/LZMA2: the reader's filter chains on real
/// 7-Zip output (skipped without 7-Zip unless KERNIR_REQUIRE_INTEROP=1).
@Suite struct VendoredLZMASevenZipInteropTests {
    @Test(arguments: [["-m0=BCJ", "-m1=LZMA2"], ["-m0=ARM64", "-m1=LZMA2"], ["-m0=ARMT", "-m1=LZMA2"],
                      ["-m0=Delta:4", "-m1=LZMA"], ["-m0=PPC", "-m1=LZMA"], ["-m0=SPARC", "-m1=LZMA2"]])
    func sevenZipFiltersRead(args: [String]) async throws {
        guard try SevenZip.required() != nil else { return }
        let inputs: [String: Data] = ["a.bin": Data(VendoredLZMATests.sample), "dir/b.txt": Data(repeating: 0x62, count: 5000)]
        let url = try SevenZip.make("t.7z", files: inputs, args: args)
        let r = try #require(archive_read_new())
        defer { archive_read_free(r) }
        func rerr() -> String { archive_error_string(r).map { String(cString: $0) } ?? "" }
        archive_read_support_format_7zip(r)
        #expect(archive_read_open_filename(r, url.path, 64 * 1024) == ARCHIVE_OK, "\(rerr())")
        var read: [String: Data] = [:]
        var entry: OpaquePointer?
        while archive_read_next_header(r, &entry) == ARCHIVE_OK {
            let name = String(cString: archive_entry_pathname(entry))
            guard archive_entry_filetype(entry) == mode_t(S_IFREG) else { continue }
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = chunk.withUnsafeMutableBytes { archive_read_data(r, $0.baseAddress, $0.count) }
                if n <= 0 { #expect(n == 0, "\(name): \(rerr())"); break }
                data.append(contentsOf: chunk[0..<n])
            }
            read[name] = data
        }
        #expect(read == inputs, "\(args): \(rerr())")
    }
}
#endif
