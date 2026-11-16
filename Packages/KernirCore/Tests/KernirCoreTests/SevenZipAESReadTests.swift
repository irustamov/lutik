#if os(macOS)
import Testing
import Foundation
import CryptoKit
import CLibArchive

/// Patch 0004: libarchive's 7zip reader decrypts 7zAES folders and encrypted headers. Raw libarchive API
/// only (no KernirCore error mapping). Fixtures come from 7-Zip (`SevenZip.make`).
@Suite("7z AES read (libarchive patch 0004)", .timeLimit(.minutes(2)))
struct SevenZipAESReadTests {
    /// a.txt = "alpha\n" x 1000, b.bin = 200 000 deterministic pseudo-random bytes, d/c.txt = "gamma".
    static let inputs: [String: Data] = {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        var bin = [UInt8](repeating: 0, count: 200_000)
        for i in bin.indices {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17   // xorshift64
            bin[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return ["a.txt": Data(String(repeating: "alpha\n", count: 1000).utf8),
                "b.bin": Data(bin),
                "d/c.txt": Data("gamma".utf8)]
    }()

    struct Failure: Error, CustomStringConvertible {
        enum Stage: String { case open, header, data }
        let stage: Stage
        let code: Int
        let message: String
        let entry: String?
        var description: String { "\(stage.rawValue) failed (\(code)) at \(entry ?? "-"): \(message)" }
    }

    struct Listing {
        var files: [String: Data] = [:]
        var encrypted: [String: Bool] = [:]
    }

    /// Reads every entry with archive_read_data. Throws the first failure (open, next_header or data).
    static func readAll(_ url: URL, passphrase: String?) throws -> Listing {
        let a = try #require(archive_read_new())
        defer { archive_read_free(a) }
        archive_read_support_format_7zip(a)
        if let passphrase { try #require(archive_read_add_passphrase(a, passphrase) == ARCHIVE_OK) }
        func message() -> String { archive_error_string(a).map { String(cString: $0) } ?? "" }

        var r = archive_read_open_filename(a, url.path, 64 * 1024)
        guard r == ARCHIVE_OK else { throw Failure(stage: .open, code: Int(r), message: message(), entry: nil) }
        var listing = Listing()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var entry: OpaquePointer?
            r = archive_read_next_header(a, &entry)
            if r == ARCHIVE_EOF { break }
            guard r == ARCHIVE_OK, let entry else {
                throw Failure(stage: .header, code: Int(r), message: message(), entry: nil)
            }
            let path = String(cString: archive_entry_pathname(entry))
            listing.encrypted[path] = archive_entry_is_data_encrypted(entry) != 0
            guard (archive_entry_filetype(entry) & mode_t(S_IFMT)) == mode_t(S_IFREG) else { continue }
            var data = Data()
            while true {
                let n = archive_read_data(a, &buffer, buffer.count)
                if n == 0 { break }
                guard n > 0 else { throw Failure(stage: .data, code: n, message: message(), entry: path) }
                data.append(contentsOf: buffer[0..<n])
            }
            listing.files[path] = data
        }
        return listing
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func expectContents(_ listing: Listing, _ expected: [String: Data] = inputs,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(listing.files.keys.sorted() == expected.keys.sorted(), sourceLocation: sourceLocation)
        for (path, data) in expected {
            #expect(listing.files[path].map(sha) == sha(data), "\(path)", sourceLocation: sourceLocation)
        }
    }

    /// Builds the standard fixture with `args` and checks it reads back with `passphrase`.
    static func roundTrip(_ args: [String], passphrase: String = "pw",
                          sourceLocation: SourceLocation = #_sourceLocation) throws {
        guard try SevenZip.required(sourceLocation: sourceLocation) != nil else { return }
        let url = try SevenZip.make("t.7z", files: inputs, args: args)
        let listing = try readAll(url, passphrase: passphrase)
        expectContents(listing, sourceLocation: sourceLocation)
        for path in inputs.keys { #expect(listing.encrypted[path] == true, "\(path)", sourceLocation: sourceLocation) }
    }

    @Test func dataOnlyDecrypts() throws { try Self.roundTrip(["-ppw"]) }
    @Test func solidDecrypts() throws { try Self.roundTrip(["-ppw", "-ms=on"]) }
    @Test func storeDecrypts() throws { try Self.roundTrip(["-ppw", "-mx0"]) }
    @Test func headerEncryptedDecrypts() throws { try Self.roundTrip(["-ppw", "-mhe=on"]) }

    @Test func bcj2Decrypts() throws {
        guard let tool = try SevenZip.required() else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw", "-mf=BCJ2"])
        let run = try Tool.run(tool.path, ["l", "-slt", "-ppw", url.path])
        let listing = String(decoding: run.stdout, as: UTF8.self)
        #expect(run.status == 0)
        #expect(listing.contains("BCJ2") && listing.contains("7zAES"), "\(listing)")
        Self.expectContents(try Self.readAll(url, passphrase: "pw"))
    }

    @Test(arguments: ["пароль", "🔑ключ"])
    func unicodePasswordsDecrypt(_ password: String) throws {
        try Self.roundTrip(["-p" + password], passphrase: password)
    }

    @Test func noPassphraseNamesThePassphrase() throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw"])
        let a = try #require(archive_read_new())
        defer { archive_read_free(a) }
        archive_read_support_format_7zip(a)
        #expect(archive_read_open_filename(a, url.path, 64 * 1024) == ARCHIVE_OK)
        var entry: OpaquePointer?
        var sawFile = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        while archive_read_next_header(a, &entry) == ARCHIVE_OK, let entry {
            guard (archive_entry_filetype(entry) & mode_t(S_IFMT)) == mode_t(S_IFREG) else { continue }
            sawFile = true
            #expect(archive_entry_is_data_encrypted(entry) == 1)
            let n = archive_read_data(a, &buffer, buffer.count)
            #expect(n == Int(ARCHIVE_FAILED))
            let message = archive_error_string(a).map { String(cString: $0) } ?? ""
            #expect(message.contains("Passphrase required"), "\(message)")
        }
        #expect(sawFile)

        let he = try SevenZip.make("he.7z", files: Self.inputs, args: ["-ppw", "-mhe=on"])
        do {
            _ = try Self.readAll(he, passphrase: nil)
            Issue.record("an encrypted header was read without a passphrase")
        } catch let failure as Failure {
            #expect(failure.stage == .header)
            #expect(failure.code == Int(ARCHIVE_FATAL))
            #expect(failure.message.contains("Passphrase required"), "\(failure.message)")
        }
    }

    @Test func wrongPassphraseFailsDecode() throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw"])
        do {
            _ = try Self.readAll(url, passphrase: "nope")
            Issue.record("a wrong passphrase decoded")
        } catch let failure as Failure {
            #expect(failure.stage == .data, "\(failure)")
            #expect(!failure.message.contains("Passphrase required"), "\(failure)")
        }

        let he = try SevenZip.make("he.7z", files: Self.inputs, args: ["-ppw", "-mhe=on"])
        do {
            _ = try Self.readAll(he, passphrase: "nope")
            Issue.record("a wrong passphrase decoded the header")
        } catch let failure as Failure {
            #expect(failure.stage == .header, "\(failure)")
        }
    }

    /// 200 folders share one key (7-Zip writes cost 2^19, no salt): reading them all must cost far less
    /// than 200 derivations. The bound is relative to one derivation timed here, on this machine and load.
    @Test func nonSolidManyFoldersDeriveKeyOnce() throws {
        guard try SevenZip.required() != nil else { return }
        var files: [String: Data] = [:]
        for i in 0..<200 { files["f\(i).txt"] = Data("file \(i)\n".utf8) }
        let url = try SevenZip.make("many.7z", files: files, args: ["-ppw", "-ms=off"])

        var params = kernir_7zaes_params()
        params.cycles_power = 19
        var key = [UInt8](repeating: 0, count: 32)
        var derivation = Duration.seconds(3600)
        for _ in 0..<5 {
            let t0 = ContinuousClock.now
            #expect(kernir_7zaes_derive_key(&params, "pw", &key) == 0)
            derivation = min(derivation, ContinuousClock.now - t0)
        }

        let start = ContinuousClock.now
        let listing = try Self.readAll(url, passphrase: "pw")
        let elapsed = ContinuousClock.now - start
        Self.expectContents(listing, files)
        // A missing key cache costs >= 200 derivations; one derivation plus decoding stays well under 50.
        #expect(elapsed < derivation * 50, "read \(elapsed), one derivation \(derivation)")
    }

    /// The decryption stage sits under every coder: PPMd also peeks past its input at buffer boundaries.
    @Test(arguments: [["-m0=PPMd"], ["-m0=BZip2"], ["-m0=Deflate"], ["-mf=BCJ"], ["-mf=Delta:4"],
                      ["-m0=PPMd", "-mhe=on"], ["-mx0", "-ms=on"]])
    func otherCodersDecrypt(_ args: [String]) throws { try Self.roundTrip(["-ppw"] + args) }

    /// Entries skipped without reading are decoded (and decrypted) when a later entry of the same solid
    /// folder is read; ciphertext never comes out.
    @Test(arguments: [["-ms=on"], ["-mx0", "-ms=on"], ["-m0=PPMd", "-ms=on"]])
    func skippedEntriesThenReadInSolidFolder(_ args: [String]) throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw"] + args)
        for wanted in Self.inputs.keys {
            let a = try #require(archive_read_new())
            defer { archive_read_free(a) }
            archive_read_support_format_7zip(a)
            #expect(archive_read_add_passphrase(a, "pw") == ARCHIVE_OK)
            #expect(archive_read_open_filename(a, url.path, 64 * 1024) == ARCHIVE_OK)
            var entry: OpaquePointer?
            var got: Data?
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while archive_read_next_header(a, &entry) == ARCHIVE_OK, let entry {
                guard String(cString: archive_entry_pathname(entry)) == wanted else { continue }
                var data = Data()
                while true {
                    let n = archive_read_data(a, &buffer, buffer.count)
                    #expect(n >= 0, "\(wanted): \(archive_error_string(a).map { String(cString: $0) } ?? "")")
                    if n <= 0 { break }
                    data.append(contentsOf: buffer[0..<n])
                }
                got = data
            }
            #expect(got.map(Self.sha) == Self.inputs[wanted].map(Self.sha), "\(wanted)")
        }
    }

    /// A flipped ciphertext byte or a truncated file reads as an error or as the exact contents: never a
    /// crash, never different bytes reported as success (in a store folder only the CRC can tell, so that
    /// mismatch fails too).
    @Test(arguments: [["-ppw"], ["-ppw", "-mx0"], ["-ppw", "-mhe=on"]])
    func damagedCiphertextFails(_ args: [String]) throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: args)
        let original = try Data(contentsOf: url)
        let nextHeader = original[12..<20].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let damaged = url.deletingLastPathComponent().appendingPathComponent("damaged.7z")
        var cases: [Data] = []
        for offset in [32, 33, 47, 48, 32 + nextHeader / 2, 32 + nextHeader - 17, 32 + nextHeader - 1] {
            var d = original
            d[offset] ^= 0x01
            cases.append(d)
        }
        for length in [32 + 15, 32 + nextHeader / 2, 32 + nextHeader - 1, original.count - 1] {
            cases.append(original.prefix(length))
        }
        for (i, d) in cases.enumerated() {
            try d.write(to: damaged)
            // A flip in the last block of the header's packed stream can land in range-coder bytes LZMA never
            // reads; the contents are then exact (seen for the last-byte flip in all three forms).
            if let listing = try? Self.readAll(damaged, passphrase: "pw") {
                #expect(listing.files == Self.inputs, "case \(i) returned different bytes")
            }
        }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }

    /// Malformed 7zAES properties or a key cost past 2^24 name "AES coder properties" (the error mapping keys on it).
    /// The header is left uncompressed (-mhc=off) so the coder record can be edited; both CRCs are redone.
    @Test func badCoderPropertiesNameThem() throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw", "-mhc=off"])
        let original = try Data(contentsOf: url)
        let nextHeader = 32 + original[12..<20].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        // Coder record: flags 0x24 (4-byte id, has properties), 06 F1 07 01, property size, properties.
        let id: [UInt8] = [0x24, 0x06, 0xF1, 0x07, 0x01]
        let at = try #require((nextHeader..<original.count - id.count).first { original[$0..<$0 + id.count].elementsEqual(id) })
        let props = at + id.count + 1
        #expect(original[props - 1] >= 2 && original[props] & 0xC0 != 0, "expected salt/IV flags in \(original[props])")

        for (name, mutate) in [("cost 2^30", { (d: inout Data) in d[props] = (d[props] & 0xC0) | 30 }),
                               ("size mismatch", { (d: inout Data) in d[props + 1] ^= 0x01 })] {
            var d = original
            mutate(&d)
            let header = d[nextHeader...]
            withUnsafeBytes(of: Self.crc32(Data(header)).littleEndian) { d.replaceSubrange(28..<32, with: $0) }
            withUnsafeBytes(of: Self.crc32(d[12..<32]).littleEndian) { d.replaceSubrange(8..<12, with: $0) }
            let damaged = url.deletingLastPathComponent().appendingPathComponent("props.7z")
            try d.write(to: damaged)
            do {
                _ = try Self.readAll(damaged, passphrase: "pw")
                Issue.record("\(name): read without error")
            } catch let failure as Failure {
                #expect(failure.stage == .data, "\(name): \(failure)")
                #expect(failure.code == Int(ARCHIVE_FAILED), "\(name): \(failure)")
                #expect(failure.message.contains("AES coder properties"), "\(name): \(failure)")
            }
        }
    }

    @Test func plainSevenZipUnchanged() throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("plain.7z", files: Self.inputs, args: [])
        let listing = try Self.readAll(url, passphrase: nil)
        Self.expectContents(listing)
        for path in Self.inputs.keys { #expect(listing.encrypted[path] == false, "\(path)") }
    }
}
#endif
