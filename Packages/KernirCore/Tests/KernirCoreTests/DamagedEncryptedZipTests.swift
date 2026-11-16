import Foundation
import Testing
@testable import KernirCore

/// Damaged or unsupported encrypted zips must never answer with a password error the right password
/// cannot fix (by design: never a password loop). Fixtures are built here from the engine's writer or
/// /usr/bin/zip plus byte patches, so no corpus files are needed.
struct DamagedEncryptedZipTests {
    static let password = "pw"

    // MARK: - Zip byte helpers

    static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }
    static func put16(_ b: inout [UInt8], _ i: Int, _ v: Int) {
        b[i] = UInt8(v & 0xff); b[i + 1] = UInt8((v >> 8) & 0xff)
    }

    /// Central-directory offset and, per entry, its central-header and local-header offsets.
    /// Assumes an EOCD without comment (the last 22 bytes).
    struct Layout { let cdOffset: Int; let entries: [(cd: Int, local: Int)] }
    static func layout(_ b: [UInt8]) -> Layout {
        let e = b.count - 22
        precondition(u32(b, e) == 0x0605_4b50, "EOCD not at the end")
        let off = u32(b, e + 16), size = u32(b, e + 12)
        var p = off
        var list: [(Int, Int)] = []
        while p < off + size {
            list.append((p, u32(b, p + 42)))
            p += 46 + u16(b, p + 28) + u16(b, p + 30) + u16(b, p + 32)
        }
        return Layout(cdOffset: off, entries: list)
    }

    /// Byte offset of the first data byte of the entry whose local header is at `local`.
    static func dataStart(_ b: [UInt8], local: Int) -> Int { local + 30 + u16(b, local + 26) + u16(b, local + 28) }

    /// Sets the actual-method field of every 0x9901 extra field in [start, start+len).
    static func patchAESMethod(_ b: inout [UInt8], extraStart start: Int, length: Int, method: Int) {
        var i = start
        while i + 4 <= start + length {
            let id = u16(b, i), l = u16(b, i + 2)
            if id == 0x9901 { put16(&b, i + 4 + 5, method) }
            i += 4 + l
        }
    }

    /// The vendor version (1 = AE-1, 2 = AE-2) of the 0x9901 field in the central header at `cd`.
    static func aesVendorVersion(_ b: [UInt8], cd: Int) -> Int? {
        var i = cd + 46 + u16(b, cd + 28)
        let end = i + u16(b, cd + 30)
        while i + 4 <= end {
            let id = u16(b, i), l = u16(b, i + 2)
            if id == 0x9901 { return u16(b, i + 4) }
            i += 4 + l
        }
        return nil
    }

    static func write(_ b: [UInt8], _ name: String = "d.zip") -> URL {
        let url = Fixtures.tempDir().appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(b))
        return url
    }

    static func randomData(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    /// An engine-written zip of `files` in the given order, encrypted with `enc` and password "pw".
    static func engineZip(_ files: [(String, Data)], encryption enc: ArchiveEncryption,
                          method: ArchiveCompressionMethod = .deflate) async throws -> [UInt8] {
        let dir = Fixtures.tempDir()
        for (name, data) in files { Fixtures.makeFiles([name: data], in: dir) }
        let dest = Fixtures.tempDir().appendingPathComponent("e.zip")
        let changes = ArchiveChangeSet(additions: files.map {
            .init(sourceURL: dir.appendingPathComponent($0.0), destinationDirectory: "")
        })
        try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: dest,
                                      options: ArchiveWriteOptions(method: method, encryption: enc, password: password))
        return [UInt8](try Data(contentsOf: dest))
    }

    static func twoFileEngineZip(_ enc: ArchiveEncryption) async throws -> [UInt8] {
        try await engineZip([("a.bin", randomData(6000)), ("b.txt", Data(repeating: 0x62, count: 6000))],
                            encryption: enc)
    }

    /// An Info-ZIP ZipCrypto zip (sizes in the local headers, no data descriptors).
    static func infoZip(_ extraArgs: [String] = [], files: [String: Data]) throws -> [UInt8] {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(files, in: dir)
        try Fixtures.run("/usr/bin/zip", ["-q"] + extraArgs + ["-P", password, "i.zip"] + files.keys.sorted(), cwd: dir)
        return [UInt8](try Data(contentsOf: dir.appendingPathComponent("i.zip")))
    }

    /// The error thrown by `body`, or nil when it succeeds.
    static func error(_ body: () async throws -> Void) async -> ArchiveError? {
        do { try await body(); return nil } catch let e as ArchiveError { return e } catch {
            Issue.record("non-ArchiveError \(error)")
            return .notImplemented
        }
    }

    static func isCorrupted(_ e: ArchiveError?) -> Bool {
        if case .corrupted = e { return true }
        return false
    }

    // MARK: - Truncation and the EOF message

    @Test(arguments: [ArchiveEncryption.aes256, .zipCrypto])
    func truncatedEncryptedZipIsCorruptedWithRightPassword(_ enc: ArchiveEncryption) async throws {
        let z = try await Self.twoFileEngineZip(enc)
        let cd = Self.layout(z).cdOffset
        for (label, cut) in [("at CD", cd), ("mid data", cd - 100)] {
            let url = Self.write(Array(z.prefix(cut)))
            let right = await Self.error { _ = try await Archive.open(at: url, password: Self.password) }
            #expect(Self.isCorrupted(right), "\(enc) cut \(label), right password: \(String(describing: right))")
            // Without a password, a data-descriptor zip may still ask once.
            let none = await Self.error { _ = try await Archive.open(at: url, password: nil) }
            #expect(Self.isCorrupted(none) || none == .passwordRequired,
                    "\(enc) cut \(label), no password: \(String(describing: none))")
        }
    }

    @Test func truncatedInfoZipEncryptedZipIsCorrupted() async throws {
        let z = try Self.infoZip(files: ["a.txt": Data(repeating: 0x61, count: 5000),
                                         "b.txt": Data(repeating: 0x62, count: 5000)])
        let cd = Self.layout(z).cdOffset
        for (label, cut) in [("at CD", cd), ("mid data", cd - 100)] {
            let url = Self.write(Array(z.prefix(cut)))
            for pw in [Self.password, nil] as [String?] {
                let e = await Self.error { _ = try await Archive.open(at: url, password: pw) }
                #expect(Self.isCorrupted(e), "Info-ZIP cut \(label), password \(pw ?? "nil"): \(String(describing: e))")
            }
        }
    }

    @Test func cleanEndOfFileSaysTheArchiveEndsUnexpectedly() async throws {
        let z = try await Self.twoFileEngineZip(.aes256)
        let url = Self.write(Array(z.prefix(Self.layout(z).cdOffset)))
        let e = await Self.error { _ = try await Archive.open(at: url, password: Self.password) }
        #expect(e == .corrupted("The archive ends unexpectedly"))
    }

    // MARK: - Damaged local header

    @Test func damagedLocalHeaderInEncryptedZipIsCorrupted() async throws {
        var z = try await Self.twoFileEngineZip(.aes256)
        z[Self.layout(z).entries[1].local + 2] = 0
        let url = Self.write(z)
        for pw in [nil, Self.password] as [String?] {
            let e = await Self.error { _ = try await Archive.open(at: url, password: pw) }
            #expect(Self.isCorrupted(e), "password \(pw ?? "nil"): \(String(describing: e))")
        }
    }

    // MARK: - Unsupported method inside an encrypted entry

    /// Five stored AES-256 files; `patched` (0-based) gets actual method 93 (zstd, not built in).
    static func method93Zip(patched: Int) async throws -> [UInt8] {
        try await method93Fixture(patched: patched).zip
    }

    static func method93Fixture(patched: Int) async throws -> (zip: [UInt8], files: [(String, Data)]) {
        let files = (1...5).map { ("f\($0).bin", randomData(3000)) }
        var z = try await engineZip(files, encryption: .aes256, method: .store)
        let e = layout(z).entries[patched]
        patchAESMethod(&z, extraStart: e.local + 30 + u16(z, e.local + 26), length: u16(z, e.local + 28), method: 93)
        patchAESMethod(&z, extraStart: e.cd + 46 + u16(z, e.cd + 28), length: u16(z, e.cd + 30), method: 93)
        return (z, files)
    }

    @Test func unsupportedMethodInEncryptedEntryIsNotAPasswordError() async throws {
        let z = try await Self.method93Zip(patched: 4)
        let url = Self.write(z)
        let before = Fixtures.sha256(url)
        let reader = try await Archive.open(at: url, password: Self.password)

        let extractAll = await Self.error { try await reader.extract(nil, to: Fixtures.tempDir(), progress: nil) }
        #expect(Self.isCorrupted(extractAll), "extract: \(String(describing: extractAll))")
        let temp = await Self.error { _ = try await reader.extractToTemporaryFile("f5.bin") }
        #expect(Self.isCorrupted(temp), "temporary file: \(String(describing: temp))")

        let out = Fixtures.tempDir().appendingPathComponent("o.zip")
        let save = await Self.error {
            try await ArchiveWriter.write(source: reader, changes: ArchiveChangeSet(), format: .zip, to: out, options: nil)
        }
        #expect(Self.isCorrupted(save), "save as: \(String(describing: save))")
        #expect(!FileManager.default.fileExists(atPath: out.path))

        let inPlace = await Self.error {
            try await ArchiveWriter.write(source: reader, changes: ArchiveChangeSet(), format: .zip, to: url, options: nil)
        }
        #expect(Self.isCorrupted(inPlace), "in-place save: \(String(describing: inPlace))")
        #expect(Fixtures.sha256(url) == before)
    }

    @Test(arguments: [0, 1])
    func unsupportedMethodInAVerifiedEntryStillOpens(_ patched: Int) async throws {
        // Open reads the first block of up to four encrypted entries, so the first and second entry
        // are checked there; corruption in one of them must not fail open, only that entry's extract.
        let (z, files) = try await Self.method93Fixture(patched: patched)
        let url = Self.write(z)
        let reader = try await Archive.open(at: url, password: Self.password)
        for (i, (name, data)) in files.enumerated() {
            if i == patched {
                let e = await Self.error { _ = try await reader.extractToTemporaryFile(name) }
                #expect(Self.isCorrupted(e), "entry \(name): \(String(describing: e))")
            } else {
                let temp = try await reader.extractToTemporaryFile(name)
                #expect(try Data(contentsOf: temp) == data, "entry \(name)")
            }
        }
    }

    /// Three deflated, compressible entries (so a flipped byte breaks the inflate stream, which libarchive
    /// reports as a fatal error), entry 0 with one data byte flipped.
    static func deflateFixture(_ enc: ArchiveEncryption) async throws -> (zip: [UInt8], files: [(String, Data)]) {
        let files = (1...3).map { n in
            ("f\(n).txt", Data((0..<4000).map { UInt8(truncatingIfNeeded: 97 + ($0 * 7 + n) % 13) }))
        }
        var z = try await engineZip(files, encryption: enc, method: .deflate)
        let e = layout(z).entries[0]
        z[dataStart(z, local: e.local) + 24] ^= 0xFF
        return (z, files)
    }

    @Test(arguments: [ArchiveEncryption.zipCrypto, .aes256])
    func fatalDeflateErrorInFirstVerifiedEntryStillOpens(_ enc: ArchiveEncryption) async throws {
        let (z, files) = try await Self.deflateFixture(enc)
        let reader = try await Archive.open(at: Self.write(z), password: Self.password)
        let bad = await Self.error { _ = try await reader.extractToTemporaryFile(files[0].0) }
        #expect(Self.isCorrupted(bad), "entry 0: \(String(describing: bad))")
        for (name, data) in files.dropFirst() {
            let temp = try await reader.extractToTemporaryFile(name)
            #expect(try Data(contentsOf: temp) == data, "\(name)")
        }
    }

    @Test func passwordErrorFromALaterEntryWinsAfterAFatalDeflateError() async throws {
        // Entry 0 is corrupted (fatal, ignored); entry 1's AES password verifier is flipped, so it gives
        // a password error that must still fail open.
        var (z, _) = try await Self.deflateFixture(.aes256)
        let e1 = Self.layout(z).entries[1]
        z[Self.dataStart(z, local: e1.local) + 16] ^= 0xFF
        let e = await Self.error { _ = try await Archive.open(at: Self.write(z), password: Self.password) }
        #expect(e == .wrongPassword, "got \(String(describing: e))")
    }

    // MARK: - PKWARE strong encryption

    static func strongEncryptionZip() throws -> [UInt8] {
        var z = try infoZip(files: ["a.txt": Data(repeating: 0x61, count: 5000),
                                    "b.txt": Data(repeating: 0x62, count: 5000)])
        for e in layout(z).entries {
            put16(&z, e.local + 6, u16(z, e.local + 6) | 0x40)
            put16(&z, e.cd + 8, u16(z, e.cd + 8) | 0x40)
        }
        return z
    }

    @Test func pkwareStrongEncryptionIsUnsupported() async throws {
        let url = Self.write(try Self.strongEncryptionZip())
        #expect(try ZipEncryptionProbe.detect(at: url).strongEncryption)

        let plain = try await Archive.open(at: url, password: nil)
        let noPassword = await Self.error { try await plain.extract(nil, to: Fixtures.tempDir(), progress: nil) }
        #expect(noPassword == .unsupportedEncryption(.zip), "extract, no password: \(String(describing: noPassword))")
        let temp = await Self.error { _ = try await plain.extractToTemporaryFile("a.txt") }
        #expect(temp == .unsupportedEncryption(.zip), "temporary file: \(String(describing: temp))")

        let withPassword: any ArchiveReading
        do {
            withPassword = try await Archive.open(at: url, password: Self.password)
        } catch let e as ArchiveError {
            #expect(e == .unsupportedEncryption(.zip), "open with password: \(e)")
            return
        }
        let extract = await Self.error { try await withPassword.extract(nil, to: Fixtures.tempDir(), progress: nil) }
        #expect(extract == .unsupportedEncryption(.zip), "extract with password: \(String(describing: extract))")
        let out = Fixtures.tempDir().appendingPathComponent("o.zip")
        let save = await Self.error {
            try await ArchiveWriter.write(source: withPassword, changes: ArchiveChangeSet(), format: .zip, to: out, options: nil)
        }
        #expect(save == .unsupportedEncryption(.zip), "save: \(String(describing: save))")
        #expect(!FileManager.default.fileExists(atPath: out.path))
        let saveNoPassword = await Self.error {
            try await ArchiveWriter.write(source: plain, changes: ArchiveChangeSet(), format: .tar, to: out, options: nil)
        }
        #expect(saveNoPassword == .unsupportedEncryption(.zip), "save, no password: \(String(describing: saveNoPassword))")
    }

    @Test func strongEncryptionWithCutCentralDirectoryIsUnsupported() async throws {
        let full = try Self.strongEncryptionZip()
        let url = Self.write(Array(full[..<Self.layout(full).cdOffset]))
        #expect(try ZipEncryptionProbe.detect(at: url).strongEncryption)
        for pw in [nil, Self.password] as [String?] {
            let e = await Self.error {
                let reader = try await Archive.open(at: url, password: pw)
                try await reader.extract(nil, to: Fixtures.tempDir(), progress: nil)
            }
            let ok = e == .unsupportedEncryption(.zip) || Self.isCorrupted(e)
            #expect(ok, "password \(pw ?? "nil"): \(String(describing: e))")
        }
    }

    // MARK: - Regression guard: real password errors stay exact

    @Test(arguments: [ArchiveEncryption.aes256, .zipCrypto])
    func undamagedEncryptedZipStillReportsPasswordErrors(_ enc: ArchiveEncryption) async throws {
        let url = Self.write(try await Self.twoFileEngineZip(enc))
        let bad = await Self.error { _ = try await Archive.open(at: url, password: "bad") }
        #expect(bad == .wrongPassword)
        let plain = try await Archive.open(at: url, password: nil)
        let none = await Self.error { try await plain.extract(nil, to: Fixtures.tempDir(), progress: nil) }
        #expect(none == .passwordRequired)
        let reader = try await Archive.open(at: url, password: Self.password)
        try await reader.extract(nil, to: Fixtures.tempDir(), progress: nil)
    }

    // MARK: - AES authentication code

    @Test func tamperedAESAuthenticationCodeIsCorrupted() async throws {
        // Four normal files, then a file under 20 bytes: libarchive writes it as AE-2 (no CRC), so only
        // the HMAC can notice tampered ciphertext.
        var files = (1...4).map { ("f\($0).bin", Self.randomData(3000)) }
        files.append(("small.txt", Data("short secret".utf8)))
        var z = try await Self.engineZip(files, encryption: .aes256, method: .store)
        let small = Self.layout(z).entries[4]
        try #require(Self.aesVendorVersion(z, cd: small.cd) == 2)
        // AES-256 data: 16-byte salt, 2-byte verifier, then ciphertext.
        z[Self.dataStart(z, local: small.local) + 18] ^= 0x01
        let url = Self.write(z)
        let before = Fixtures.sha256(url)

        let reader = try await Archive.open(at: url, password: Self.password)
        let extract = await Self.error { try await reader.extract(nil, to: Fixtures.tempDir(), progress: nil) }
        #expect(Self.isCorrupted(extract), "extract: \(String(describing: extract))")
        let temp = await Self.error { _ = try await reader.extractToTemporaryFile("small.txt") }
        #expect(Self.isCorrupted(temp), "temporary file: \(String(describing: temp))")
        let save = await Self.error {
            try await ArchiveWriter.write(source: reader, changes: ArchiveChangeSet(), format: .zip, to: url, options: nil)
        }
        #expect(Self.isCorrupted(save), "save: \(String(describing: save))")
        #expect(Fixtures.sha256(url) == before)
    }

    // MARK: - Password check over several entries

    @Test func wrongZipCryptoPasswordPassingOneCheckByteIsStillWrong() async throws {
        // Two stored ZipCrypto entries. Find a wrong password that passes the first entry's check byte
        // but fails the second's: open must call it a wrong password, not corruption.
        let z = try Self.infoZip(["-0"], files: ["a.txt": Data("hello!".utf8), "b.txt": Data("world!".utf8)])
        let url = Self.write(z)
        func passesCheck(_ pw: String, entry: Int) throws -> Bool {
            let s = try ReadSession(url: url, password: pw)
            for _ in 0..<entry { _ = try s.nextHeader() }
            guard try s.nextHeader() != nil else { return false }
            do { _ = try s.readBlock(); return true } catch {
                if case .corrupted(let m) = error, m.lowercased().contains("passphrase") { return false }
                return true
            }
        }
        var candidate: String?
        for i in 0..<100_000 {
            let pw = "wrong\(i)"
            if try passesCheck(pw, entry: 0), try !passesCheck(pw, entry: 1) { candidate = pw; break }
        }
        let pw = try #require(candidate)
        let e = await Self.error { _ = try await Archive.open(at: url, password: pw) }
        #expect(e == .wrongPassword, "\(pw): \(String(describing: e))")
    }

    // MARK: - Strongest scheme

    /// A central-directory-only zip: each entry is (flags, method, AES strength or nil).
    static func centralOnlyZip(_ entries: [(flags: UInt16, method: UInt16, strength: UInt8?)]) -> [UInt8] {
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        var cd: [UInt8] = []
        for (i, e) in entries.enumerated() {
            let name = [UInt8]("f\(i)".utf8)
            let extra: [UInt8] = e.strength.map { s in le(0x9901, 2) + le(7, 2) + le(2, 2) + [0x41, 0x45, s] + le(8, 2) } ?? []
            var h = [UInt8](repeating: 0, count: 46)
            h[0...3] = [0x50, 0x4b, 0x01, 0x02]
            h[8...9] = ArraySlice(le(Int(e.flags), 2))
            h[10...11] = ArraySlice(le(Int(e.method), 2))
            h[24...27] = ArraySlice(le(100, 4))
            h[28...29] = ArraySlice(le(name.count, 2))
            h[30...31] = ArraySlice(le(extra.count, 2))
            cd += h + name + extra
        }
        let eocd = [0x50, 0x4b, 0x05, 0x06] + le(0, 4) + le(entries.count, 2) + le(entries.count, 2)
            + le(cd.count, 4) + le(0, 4) + le(0, 2)
        return cd + eocd
    }

    @Test func probeKeepsTheStrongestScheme() throws {
        let zipCrypto: (flags: UInt16, method: UInt16, strength: UInt8?) = (1, 8, nil)
        let aes128: (flags: UInt16, method: UInt16, strength: UInt8?) = (1, 99, 1)
        let aes256: (flags: UInt16, method: UInt16, strength: UInt8?) = (1, 99, 3)
        for (list, expected) in [([zipCrypto, aes128, aes256], ArchiveEncryption.aes256),
                                 ([zipCrypto, aes128], .aes128),
                                 ([aes128, zipCrypto], .aes128),
                                 ([aes256, aes128, zipCrypto], .aes256)] {
            let r = try ZipEncryptionProbe.detect(at: Self.write(Self.centralOnlyZip(list)))
            #expect(r.encryption == expected)
            #expect(r.method == .deflate)
            #expect(!r.strongEncryption)
        }
    }

    @Test func probeFlagsStrongEncryptionOnlyOnEncryptedEntries() throws {
        let strong = try ZipEncryptionProbe.detect(at: Self.write(Self.centralOnlyZip([(1, 8, nil), (0x41, 8, nil)])))
        #expect(strong.strongEncryption)
        let bitWithoutEncryption = try ZipEncryptionProbe.detect(at: Self.write(Self.centralOnlyZip([(0x40, 8, nil)])))
        #expect(!bitWithoutEncryption.strongEncryption)
        #expect(bitWithoutEncryption.encryption == .none)
    }
}
