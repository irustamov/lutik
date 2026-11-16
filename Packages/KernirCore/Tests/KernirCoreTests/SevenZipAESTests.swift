import Testing
import Foundation
import CryptoKit
import CLibArchive
@testable import KernirCore

/// Encrypted 7z through the public API. A password opens it (verified at open by the encrypted header
/// when there is one, otherwise by decoding the first encrypted non-empty entry), a missing one is
/// `.passwordRequired`, a wrong one `.wrongPassword`, and data damage under the right password stays
/// `.corrupted`. RAR keeps `.unsupportedEncryption(.rar)`.
@Suite("7z AES engine semantics", .timeLimit(.minutes(2)))
struct SevenZipAESTests {
    // MARK: - Mapping (no 7-Zip needed)

    @Test func unsupportedCryptoCodecStaysUnsupported() {
        #expect(readFailure(.corrupted("Crypto codec not supported yet (ID: 0x6F10303)"), format: .sevenZip,
                            encrypted: true, hasPassphrase: true, zipStrongEncryption: false)
                == .unsupportedEncryption(.sevenZip))
        // AES folders past the supported coder graph cannot be decrypted by any password either.
        #expect(readFailure(.corrupted("Unsupported form of 7zAES streams"), format: .sevenZip,
                            encrypted: true, hasPassphrase: true, zipStrongEncryption: false)
                == .unsupportedEncryption(.sevenZip))
    }

    @Test func sevenZipMappingTable() {
        func data(_ message: String, encrypted: Bool = true, pass: Bool) -> ArchiveError {
            readFailure(.corrupted(message), format: .sevenZip, encrypted: encrypted, hasPassphrase: pass,
                        zipStrongEncryption: false)
        }
        #expect(encryptionError(format: .sevenZip, hasPassphrase: false) == .passwordRequired)
        #expect(encryptionError(format: .sevenZip, hasPassphrase: true) == .wrongPassword)
        #expect(undecryptableError(format: .sevenZip, zipStrongEncryption: false) == nil)
        #expect(data("Passphrase required for this entry", pass: false) == .passwordRequired)
        #expect(data("Malformed 7zAES coder properties", pass: true)
                == .corrupted("Malformed 7zAES coder properties"))
        // Patch 0004's text for a key cost past the supported limit.
        #expect(data("Unsupported 7zAES coder properties (key cost 2^30)", pass: true)
                == .corrupted("Unsupported 7zAES coder properties (key cost 2^30)"))
        #expect(data("CRC error", pass: true) == .corrupted("CRC error"))
        #expect(readFailure(.io("gone"), format: .sevenZip, encrypted: true, hasPassphrase: true,
                            zipStrongEncryption: false) == .io("gone"))

        // The header path: the same codec checks first; then, with encrypted folders, no passphrase
        // is .passwordRequired, the -mhe header decode is .wrongPassword, and any later failure is nil
        // (the walk arbitrates it with verifySevenZipPassword).
        func header(_ message: String, headerDecode: Bool = false, encrypted: Bool, pass: Bool) -> ArchiveError? {
            sevenZipHeaderFailure(.corrupted(message), message: message, isEncryptedHeaderDecode: headerDecode,
                                  hasEncryptedEntries: encrypted, hasPassphrase: pass)
        }
        #expect(header("Crypto codec not supported yet (ID: 0x6F10303)", encrypted: true, pass: true)
                == .unsupportedEncryption(.sevenZip))
        #expect(header("Unsupported form of 7zAES streams", headerDecode: true, encrypted: true, pass: false)
                == .unsupportedEncryption(.sevenZip))
        #expect(header("Malformed 7zAES coder properties", headerDecode: true, encrypted: true, pass: true)
                == .corrupted("Malformed 7zAES coder properties"))
        #expect(header("Passphrase required for this entry", headerDecode: true, encrypted: true, pass: false)
                == .passwordRequired)
        #expect(header("Passphrase required for this entry", encrypted: true, pass: false) == .passwordRequired)
        #expect(header("Damaged 7-Zip archive", headerDecode: true, encrypted: true, pass: true) == .wrongPassword)
        #expect(header("Damaged 7-Zip archive", encrypted: true, pass: true) == nil)
        #expect(header("Damaged 7-Zip archive", encrypted: true, pass: false) == .passwordRequired)
        #expect(header("Damaged 7-Zip archive", encrypted: false, pass: true) == .corrupted("Damaged 7-Zip archive"))
        #expect(header("Damaged 7-Zip archive", encrypted: false, pass: false) == .corrupted("Damaged 7-Zip archive"))
    }

    /// The 7z writer encrypts (patch 0005), so 7z offers AES-256.
    @Test func sevenZipCapabilityListsAES256() {
        #expect(ArchiveFormat.sevenZip.supportedEncryptions == [.none, .aes256])
    }

    /// Patch 0005's option contract: only aes256 is known, and asking to encrypt without a passphrase
    /// fails the first header instead of writing plaintext.
    @Test func sevenZipWriterEncryptionOption() throws {
        let a = try #require(archive_write_new())
        defer { archive_write_free(a) }
        #expect(archive_write_set_format_7zip(a) == ARCHIVE_OK)
        for unknown in ["aes128", "zipcrypt", "aes"] {
            #expect(archive_write_set_option(a, "7zip", "encryption", unknown) == ARCHIVE_FAILED, "\(unknown)")
        }
        #expect(archive_write_set_option(a, "7zip", "encryption", "aes256") == ARCHIVE_OK)
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.7z")
        #expect(archive_write_open_filename(a, url.path) == ARCHIVE_OK)
        let e = try #require(archive_entry_new())
        defer { archive_entry_free(e) }
        archive_entry_set_pathname(e, "x.txt")
        archive_entry_set_mode(e, S_IFREG | 0o644)
        archive_entry_set_size(e, 1)
        #expect(archive_write_header(a, e) == ARCHIVE_FATAL)
        #expect(archive_error_string(a).map { String(cString: $0) } == "Encryption needs passphrase")
    }

    @Test func rarEncryptionStillUnsupported() {
        #expect(encryptionError(format: .rar, hasPassphrase: true) == .unsupportedEncryption(.rar))
        #expect(encryptionError(format: .rar, hasPassphrase: false) == .unsupportedEncryption(.rar))
        #expect(undecryptableError(format: .rar, zipStrongEncryption: false) == .unsupportedEncryption(.rar))
    }

    // MARK: - Interop (7-Zip builds the fixtures)

    #if os(macOS)
    static let inputs = SevenZipAESReadTests.inputs

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func dest() -> URL { Fixtures.tempDir().appendingPathComponent("out", isDirectory: true) }

    static func expectExtracts(_ r: any ArchiveReading, _ expected: [String: Data] = inputs,
                               sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let out = dest()
        try await r.extract(nil, to: out, progress: nil)
        for (path, data) in expected where !path.hasSuffix("/") {
            let got = try? Data(contentsOf: out.appending(path: path))
            #expect(got.map(sha) == sha(data), "\(path)", sourceLocation: sourceLocation)
        }
    }

    @Test func dataOnlyListsWithoutPassword() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw"])
        let r = try await Archive.open(at: url)
        #expect(r.format == .sevenZip && r.isEncrypted)
        #expect(r.encryption == .aes256)
        let files = r.entries.filter { !$0.isDirectory }
        #expect(Set(files.map(\.path)) == Set(Self.inputs.keys))
        #expect(files.allSatisfy { $0.isEncrypted })
        await #expect(throws: ArchiveError.passwordRequired) {
            try await r.extract(nil, to: Self.dest(), progress: nil)
        }
        await #expect(throws: ArchiveError.passwordRequired) { _ = try await r.extractToTemporaryFile("a.txt") }
        let preview = try await Archive.previewListing(at: url, limit: 10)
        #expect(preview.isEncrypted && preview.visibleEntryCount == 4)
    }

    @Test func dataOnlyWithRightPasswordExtracts() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw"])
        let r = try await Archive.open(at: url, password: "pw")
        #expect(r.encryption == .aes256)
        try await Self.expectExtracts(r)
        let tmp = try await r.extractToTemporaryFile("b.bin")
        #expect(Self.sha(try Data(contentsOf: tmp)) == Self.sha(Self.inputs["b.bin"]!))
        _ = try await Archive.previewListing(at: url, password: "pw", limit: 10)
    }

    @Test func dataOnlyWrongPasswordFailsOpen() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw"])
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "nope") }
        await #expect(throws: ArchiveError.wrongPassword) {
            _ = try await Archive.previewListing(at: url, password: "nope", limit: 10)
        }
    }

    @Test func headerEncryptedNeedsPasswordToList() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("he.7z", files: Self.inputs, args: ["-ppw", "-mhe=on"])
        await #expect(throws: ArchiveError.passwordRequired) { _ = try await Archive.open(at: url) }
        await #expect(throws: ArchiveError.passwordRequired) { _ = try await Archive.previewListing(at: url, limit: 10) }
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "nope") }
        await #expect(throws: ArchiveError.wrongPassword) {
            _ = try await Archive.previewListing(at: url, password: "nope", limit: 10)
        }
        let r = try await Archive.open(at: url, password: "pw")
        #expect(r.format == .sevenZip && r.isEncrypted && r.encryption == .aes256)
        // Patch 0004 flags header-encrypted entries data-encrypted (not metadata-encrypted): files only.
        #expect(r.entries.filter { !$0.isDirectory }.allSatisfy { $0.isEncrypted })
        #expect(Set(r.entries.filter { !$0.isDirectory }.map(\.path)) == Set(Self.inputs.keys))
        try await Self.expectExtracts(r)
    }

    @Test func storedWrongPasswordFailsOpen() async throws {
        guard try SevenZip.required() != nil else { return }
        let small = ["a.txt": Data("alpha\n".utf8), "b.txt": Data("beta".utf8)]
        let url = try SevenZip.make("s.7z", files: small, args: ["-ppw", "-mx0"])
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "nope") }
        let r = try await Archive.open(at: url, password: "pw")
        try await Self.expectExtracts(r, small)
    }

    /// The 7z header sits at the end, so cutting the tail would remove it. Damage 4 KiB of b.bin's packed
    /// stream in place instead (ending 4 KiB before the stream's end), leaving both headers intact.
    @Test func truncatedWithRightPasswordIsCorrupted() async throws {
        guard let tool = try SevenZip.required() else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw", "-ms=off"])

        // Folder order as 7-Zip wrote it: each non-empty file is its own block; pack streams follow the
        // 32-byte signature header in block order.
        let listing = try Tool.run(tool.path, ["l", "-slt", "-ppw", url.path])
        #expect(listing.status == 0, "\(listing.stderr)")
        var packed: [Int: Int] = [:]
        var blockOf: [String: Int] = [:]
        var path: String?, packedSize: Int?
        for line in String(decoding: listing.stdout, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("Path = ") { path = String(line.dropFirst(7)); packedSize = nil }
            if line.hasPrefix("Packed Size = ") { packedSize = Int(line.dropFirst(14)) }
            if line.hasPrefix("Block = "), let p = path, let b = Int(line.dropFirst(8)), let s = packedSize {
                #expect(packed[b] == nil, "block \(b) holds more than one file")
                packed[b] = s
                blockOf[p] = b
            }
        }
        let bBlock = try #require(blockOf["b.bin"])
        #expect(packed.count == 3)
        let start = 32 + (0..<bBlock).reduce(0) { $0 + (packed[$1] ?? 0) }
        let end = start + (packed[bBlock] ?? 0)
        try #require(end - start > 3 * 4096)

        var d = try Data(contentsOf: url)
        let headerOffset = 32 + d[12..<20].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(end <= headerOffset)
        for i in (end - 8192)..<(end - 4096) { d[i] ^= 0x5A }
        try d.write(to: url)

        let r = try await Archive.open(at: url, password: "pw")
        // Verification decodes the first encrypted non-empty entry in header order, which must not be b.bin.
        let verified = r.entries.first { $0.isEncrypted && $0.size != 0 }
        #expect(verified != nil && verified?.path != "b.bin", "\(verified?.path ?? "-")")
        do {
            _ = try await r.extractToTemporaryFile("b.bin")
            Issue.record("b.bin served from damaged data")
        } catch let e as ArchiveError {
            guard case .corrupted = e else { Issue.record("b.bin: \(e)"); return }
        }
        do {
            try await r.extract(["b.bin"], to: Self.dest(), progress: nil)
            Issue.record("b.bin extracted from damaged data")
        } catch let e as ArchiveError {
            guard case .corrupted = e else { Issue.record("extract b.bin: \(e)"); return }
        }
        // The other entries still extract with the right password.
        let a = try await r.extractToTemporaryFile("a.txt")
        #expect(try Data(contentsOf: a) == Self.inputs["a.txt"])
    }

    @Test func emptyEntriesInEncryptedArchive() async throws {
        guard try SevenZip.required() != nil else { return }
        let files = ["empty.txt": Data(), "dir/": Data(), "a.txt": Data("alpha\n".utf8)]
        let url = try SevenZip.make("e.7z", files: files, args: ["-ppw"])
        let r = try await Archive.open(at: url)
        #expect(Set(r.entries.map(\.path)) == ["empty.txt", "dir", "a.txt"])
        #expect(r.entries.first { $0.path == "a.txt" }?.isEncrypted == true)
        let empty = try await r.extractToTemporaryFile("empty.txt")
        #expect(try Data(contentsOf: empty).isEmpty)
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "nope") }
        let right = try await Archive.open(at: url, password: "pw")
        try await Self.expectExtracts(right, files)
    }

    /// Damaged 7zAES properties with the right password are corruption, never a password error (no loop).
    @Test func badCoderPropertiesAreCorruptedNotWrongPassword() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw", "-mhc=off"])
        var d = try Data(contentsOf: url)
        let nextHeader = 32 + d[12..<20].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        let id: [UInt8] = [0x24, 0x06, 0xF1, 0x07, 0x01]
        let at = try #require((nextHeader..<d.count - id.count).first { d[$0..<$0 + id.count].elementsEqual(id) })
        let props = at + id.count + 1
        d[props] = (d[props] & 0xC0) | 30   // key cost 2^30: past the supported limit
        withUnsafeBytes(of: SevenZipAESReadTests.crc32(Data(d[nextHeader...])).littleEndian) {
            d.replaceSubrange(28..<32, with: $0)
        }
        withUnsafeBytes(of: SevenZipAESReadTests.crc32(d[12..<32]).littleEndian) { d.replaceSubrange(8..<12, with: $0) }
        try d.write(to: url)
        do {
            _ = try await Archive.open(at: url, password: "pw")
            Issue.record("opened with unusable coder properties")
        } catch let e as ArchiveError {
            guard case .corrupted(let m) = e, m.contains("AES coder properties") else {
                Issue.record("\(e)"); return
            }
        }
    }

    // MARK: Header failures after the header decode

    /// A solid `-snl` 7z: a.txt, b.bin, c.txt and a symlink `linkName` -> a.txt in one encrypted folder.
    /// libarchive reads a symlink's target from the folder while it lists, so listing decodes the folder.
    /// 7-Zip orders the names, so "link" comes last and "0link" first.
    static func makeWithSymlink(linkName: String, args: [String] = ["-ppw"]) throws -> URL {
        guard let tool = SevenZip.tool else { throw Fixtures.ToolFailure(description: "7-Zip is not installed") }
        let dir = Fixtures.tempDir()
        var files = inputs.filter { !$0.key.hasPrefix("d/") }
        files["c.txt"] = Data(String(repeating: "gamma delta epsilon\n", count: 12_000).utf8)
        Fixtures.makeFiles(files, in: dir)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent(linkName).path,
                                                   withDestinationPath: "a.txt")
        try Fixtures.run(tool.path, ["a", "-t7z", "-bd", "-y", "-snl"] + args
                         + ["t.7z", "a.txt", "b.bin", "c.txt", linkName], cwd: dir, env: ["LC_ALL": "en_US.UTF-8"])
        return dir.appendingPathComponent("t.7z")
    }

    /// Where the encoded header's packed stream starts (7-Zip's default `-mhc=on`, and `-mhe`): the
    /// header block is kEncodedHeader, kPackInfo, packPos (a 7z NUMBER), relative to the end of the
    /// 32-byte signature header. The data folders' packed streams end there.
    static func encodedHeaderPackStart(_ d: Data, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int {
        let headerOffset = 32 + d[12..<20].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        try #require(d[headerOffset] == 0x17 && d[headerOffset + 1] == 0x06, sourceLocation: sourceLocation)
        var at = headerOffset + 2
        let first = d[at]; at += 1
        var mask: UInt8 = 0x80, value = 0
        for i in 0..<8 {
            if first & mask == 0 { value |= Int(first & (mask &- 1)) << (8 * i); break }
            value |= Int(d[at]) << (8 * i); at += 1
            mask >>= 1
        }
        return 32 + value
    }

    /// XORs the last 32 bytes of the (single) data folder's packed stream: the end of the solid folder
    /// (c.txt's tail and the last link target) is damaged; a.txt and both headers are intact.
    static func damageFolderTail(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        var d = try Data(contentsOf: url)
        let end = try encodedHeaderPackStart(d, sourceLocation: sourceLocation)
        try #require(end - 32 > 32 + 1024, sourceLocation: sourceLocation)
        for i in (end - 32)..<end { d[i] ^= 0x5A }
        try d.write(to: url)
        // 7-Zip agrees the data is bad; its listing still works, so the headers are intact.
        if let tool = SevenZip.tool {
            #expect(try Tool.run(tool.path, ["t", "-ppw", url.path]).status != 0, "7-Zip tests the damage clean",
                    sourceLocation: sourceLocation)
            #expect(try Tool.run(tool.path, ["l", "-ppw", url.path]).status == 0, sourceLocation: sourceLocation)
        }
    }

    /// The right password on a damaged archive: `.corrupted` wherever it fails (open or extract), never a
    /// password error.
    static func expectCorruptedWithRightPassword(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            let r = try await Archive.open(at: url, password: "pw")
            try await r.extract(nil, to: dest(), progress: nil)
            Issue.record("damaged archive extracted", sourceLocation: sourceLocation)
        } catch let e as ArchiveError {
            guard case .corrupted = e else { Issue.record("open/extract: \(e)", sourceLocation: sourceLocation); return }
        } catch { Issue.record("\(error)", sourceLocation: sourceLocation) }
    }

    static func expectCorruptedPreviewWithRightPassword(_ url: URL,
                                                        sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            _ = try await Archive.previewListing(at: url, password: "pw", limit: 10)
            // A preview that lists is fine (it reads no data); it must not ask for the password again.
        } catch let e as ArchiveError {
            guard case .corrupted = e else { Issue.record("preview: \(e)", sourceLocation: sourceLocation); return }
        } catch { Issue.record("\(error)", sourceLocation: sourceLocation) }
    }

    /// The undamaged fixture: the listing decodes the link, so even plain headers need the password.
    @Test func encryptedSymlinkListsOnlyWithPassword() async throws {
        guard try SevenZip.required() != nil else { return }
        for name in ["link", "0link"] {
            let url = try Self.makeWithSymlink(linkName: name)
            await #expect(throws: ArchiveError.passwordRequired) { _ = try await Archive.open(at: url) }
            await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "nope") }
            let r = try await Archive.open(at: url, password: "pw")
            #expect(r.entries.first { $0.isEncrypted && $0.size != 0 }?.path == "a.txt", "\(name)")
            let tmp = try await r.extractToTemporaryFile(name)
            #expect(try Data(contentsOf: tmp) == Self.inputs["a.txt"], "\(name)")
        }
    }

    /// The link is decoded after a.txt is listed; damage at the folder's end fails that decode. With the
    /// right password the verified first entry (a.txt) decodes, so the failure is damage, not the password.
    @Test func damagedSymlinkFolderWithRightPasswordIsCorrupted() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try Self.makeWithSymlink(linkName: "link")
        try Self.damageFolderTail(url)
        await Self.expectCorruptedWithRightPassword(url)
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "nope") }
        await #expect(throws: ArchiveError.passwordRequired) { _ = try await Archive.open(at: url) }
    }

    @Test func damagedSymlinkFolderPreviewWithRightPasswordIsCorrupted() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try Self.makeWithSymlink(linkName: "link")
        try Self.damageFolderTail(url)
        await Self.expectCorruptedPreviewWithRightPassword(url)
        await #expect(throws: ArchiveError.wrongPassword) {
            _ = try await Archive.previewListing(at: url, password: "nope", limit: 10)
        }
        await #expect(throws: ArchiveError.passwordRequired) { _ = try await Archive.previewListing(at: url, limit: 10) }
    }

    /// The link is the first header: its decode is the archive's first header read after the plain header,
    /// which must not count as the `-mhe` header decode. The damage at the end fails a later skip.
    @Test func damagedFolderAfterLeadingSymlink() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try Self.makeWithSymlink(linkName: "0link")
        try Self.damageFolderTail(url)
        await Self.expectCorruptedWithRightPassword(url)
        await Self.expectCorruptedPreviewWithRightPassword(url)
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "nope") }
        await #expect(throws: ArchiveError.wrongPassword) {
            _ = try await Archive.previewListing(at: url, password: "nope", limit: 10)
        }
        await #expect(throws: ArchiveError.passwordRequired) { _ = try await Archive.open(at: url) }
        await #expect(throws: ArchiveError.passwordRequired) { _ = try await Archive.previewListing(at: url, limit: 10) }
    }

    /// The wrong-password rule still holds for the header decode itself: a damaged `-mhe` header answers like a
    /// wrong password.
    @Test func damagedEncryptedHeaderStaysWrongPassword() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("he.7z", files: Self.inputs, args: ["-ppw", "-mhe=on"])
        var d = try Data(contentsOf: url)
        // The first AES block of the encrypted header stream: the header decodes to garbage.
        let start = try Self.encodedHeaderPackStart(d)
        for i in start..<(start + 16) { d[i] ^= 0x5A }
        try d.write(to: url)
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "pw") }
        await #expect(throws: ArchiveError.wrongPassword) {
            _ = try await Archive.previewListing(at: url, password: "pw", limit: 10)
        }
        await #expect(throws: ArchiveError.passwordRequired) { _ = try await Archive.open(at: url) }
    }

    // MARK: - Early data damage

    /// XORs 32 bytes at file offset 8000: inside the data folder's packed stream (b.bin's random bytes),
    /// within the decoder's read-ahead of the first entry, so the open-time data verify would see it. Both
    /// headers stay intact.
    static func damageEarlyData(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        var d = try Data(contentsOf: url)
        let end = try encodedHeaderPackStart(d, sourceLocation: sourceLocation)
        try #require(8000 + 32 < end, "offset 8000 is past the data folder", sourceLocation: sourceLocation)
        for i in 8000..<(8000 + 32) { d[i] ^= 0x5A }
        try d.write(to: url)
        // 7-Zip agrees the data is bad; its listing still works, so the headers are intact.
        if let tool = SevenZip.tool {
            #expect(try Tool.run(tool.path, ["t", "-ppw", url.path]).status != 0, "7-Zip tests the damage clean",
                    sourceLocation: sourceLocation)
            #expect(try Tool.run(tool.path, ["l", "-ppw", url.path]).status == 0, sourceLocation: sourceLocation)
        }
    }

    /// The header was decrypted, decoded and CRC-checked with "pw", which proves the password, so open
    /// does not verify the data: it opens, the damage is `.corrupted` at extract with no output kept, and a
    /// wrong or missing password still fails at the header.
    static func expectEarlyDamageOpensThenCorrupted(_ url: URL,
                                                    sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try damageEarlyData(url, sourceLocation: sourceLocation)
        let r = try await Archive.open(at: url, password: "pw")
        #expect(r.isEncrypted && r.encryption == .aes256, sourceLocation: sourceLocation)
        #expect(Set(r.entries.filter { !$0.isDirectory }.map(\.path)) == Set(inputs.keys),
                sourceLocation: sourceLocation)
        _ = try await Archive.previewListing(at: url, password: "pw", limit: 10)

        func expectCorrupted(_ what: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                Issue.record("\(what): damaged data extracted", sourceLocation: sourceLocation)
            } catch let e as ArchiveError {
                if case .corrupted = e { return }
                Issue.record("\(what): \(e)", sourceLocation: sourceLocation)
            } catch { Issue.record("\(what): \(error)", sourceLocation: sourceLocation) }
        }
        let out = dest()
        await expectCorrupted("extract") { try await r.extract(nil, to: out, progress: nil) }
        #expect(!FileManager.default.fileExists(atPath: out.appending(path: "b.bin").path),
                "damaged b.bin kept", sourceLocation: sourceLocation)
        await expectCorrupted("extract b.bin") { try await r.extract(["b.bin"], to: dest(), progress: nil) }
        await expectCorrupted("temporary b.bin") { _ = try await r.extractToTemporaryFile("b.bin") }

        await #expect(throws: ArchiveError.wrongPassword, sourceLocation: sourceLocation) {
            _ = try await Archive.open(at: url, password: "nope")
        }
        await #expect(throws: ArchiveError.wrongPassword, sourceLocation: sourceLocation) {
            _ = try await Archive.previewListing(at: url, password: "nope", limit: 10)
        }
        await #expect(throws: ArchiveError.passwordRequired, sourceLocation: sourceLocation) {
            _ = try await Archive.open(at: url)
        }
    }

    /// Every Kernir-written encrypted 7z is header-encrypted.
    @Test func kernirWrittenEarlyDataDamageIsCorrupted() async throws {
        let url = try await Self.writeSevenZip(options: .init(method: .lzma2, encryption: .aes256, password: "pw"))
        try await Self.expectEarlyDamageOpensThenCorrupted(url)
    }

    @Test func headerEncryptedEarlyDataDamageIsCorrupted() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("he.7z", files: Self.inputs, args: ["-ppw", "-mhe=on", "-m0=LZMA2"])
        try await Self.expectEarlyDamageOpensThenCorrupted(url)
    }

    /// The listing decodes the link (after the header) and fails on the damage. With an encrypted header the
    /// The open-time arbitration does not verify the data either: the failure is damage, `.corrupted`.
    @Test func headerEncryptedSymlinkEarlyDataDamageIsCorrupted() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try Self.makeWithSymlink(linkName: "link", args: ["-ppw", "-mhe=on", "-m0=LZMA2"])
        try Self.damageEarlyData(url)
        await Self.expectCorruptedWithRightPassword(url)
        await Self.expectCorruptedPreviewWithRightPassword(url)
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "nope") }
        await #expect(throws: ArchiveError.passwordRequired) { _ = try await Archive.open(at: url) }
    }

    /// Plain headers prove nothing about the password, so a data-only 7z still verifies at open and
    /// the same damage answers `.wrongPassword` there. The fix must not widen to it.
    @Test func dataOnlyEarlyDataDamageStaysWrongPassword() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw", "-m0=LZMA2"])
        try Self.damageEarlyData(url)
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "pw") }
        await #expect(throws: ArchiveError.wrongPassword) {
            _ = try await Archive.previewListing(at: url, password: "pw", limit: 10)
        }
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await Archive.open(at: url, password: "nope") }
        // Data-only lists without a password.
        _ = try await Archive.open(at: url)
    }

    @Test func repackEncryptedSevenZipSourceToZip() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: ["-ppw"])
        let source = try await Archive.open(at: url, password: "pw")
        let zip = Fixtures.tempDir().appendingPathComponent("out.zip")
        try await ArchiveWriter.write(source: source, changes: .init(), format: .zip, to: zip,
                                      options: ArchiveWriteOptions(encryption: .aes256, password: "pw"))
        await #expect(throws: ArchiveError.passwordRequired) {
            let plain = try await Archive.open(at: zip)
            try await plain.extract(nil, to: Self.dest(), progress: nil)
        }
        let back = try await Archive.open(at: zip, password: "pw")
        #expect(back.format == .zip && back.encryption == .aes256)
        try await Self.expectExtracts(back)

        // The same source saves to 7z with AES-256 (patch 0005), and only the password reopens it.
        let seven = Fixtures.tempDir().appendingPathComponent("out.7z")
        try await ArchiveWriter.write(source: source, changes: .init(), format: .sevenZip, to: seven,
                                      options: ArchiveWriteOptions(encryption: .aes256, password: "pw"))
        try await Self.expectOpensOnlyWithPassword(seven)
    }

    // MARK: - The 7z writer encrypts (patch 0005)

    /// Opening `url` needs the password (the header is encrypted, so names are hidden too): none is
    /// `.passwordRequired`, "nope" `.wrongPassword`, and "pw" reads `expected` back byte for byte.
    static func expectOpensOnlyWithPassword(_ url: URL, _ expected: [String: Data] = inputs,
                                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        await #expect(throws: ArchiveError.passwordRequired, sourceLocation: sourceLocation) {
            _ = try await Archive.open(at: url)
        }
        await #expect(throws: ArchiveError.passwordRequired, sourceLocation: sourceLocation) {
            _ = try await Archive.previewListing(at: url, limit: 10)
        }
        await #expect(throws: ArchiveError.wrongPassword, sourceLocation: sourceLocation) {
            _ = try await Archive.open(at: url, password: "nope")
        }
        let r = try await Archive.open(at: url, password: "pw")
        #expect(r.format == .sevenZip && r.isEncrypted && r.encryption == .aes256, sourceLocation: sourceLocation)
        #expect(Set(r.entries.filter { !$0.isDirectory }.map(\.path)) == Set(expected.keys.filter { !$0.hasSuffix("/") }),
                sourceLocation: sourceLocation)
        try await expectExtracts(r, expected, sourceLocation: sourceLocation)
    }

    /// 7-Zip agrees: `t` passes with "pw", fails with "nope" and with no password, and with the header
    /// encrypted even listing needs the password. `l -slt` names the 7zAES coder and flags entries encrypted.
    static func expect7zzAcceptsOnlyPassword(_ url: URL, tool: URL,
                                             sourceLocation: SourceLocation = #_sourceLocation) throws {
        let test = try Tool.run(tool.path, ["t", "-ppw", url.path])
        #expect(test.status == 0, "7zz t -ppw: \(test.stderr)", sourceLocation: sourceLocation)
        let listing = try Tool.run(tool.path, ["l", "-slt", "-ppw", url.path])
        let text = String(decoding: listing.stdout, as: UTF8.self)
        #expect(listing.status == 0 && text.contains("7zAES") && text.contains("Encrypted = +"), "\(text)",
                sourceLocation: sourceLocation)
        #expect(try Tool.run(tool.path, ["t", "-pnope", url.path]).status != 0, "7zz t passes a wrong password",
                sourceLocation: sourceLocation)
        #expect(try Tool.run(tool.path, ["t", url.path]).status != 0, "7zz t passes without a password",
                sourceLocation: sourceLocation)
        #expect(try Tool.run(tool.path, ["l", url.path]).status != 0, "7zz lists names without a password",
                sourceLocation: sourceLocation)
    }

    /// Writes `files` as a new 7z (no source) with `options`.
    static func writeSevenZip(_ files: [String: Data] = inputs, options: ArchiveWriteOptions) async throws -> URL {
        let dir = Fixtures.tempDir().appendingPathComponent("in", isDirectory: true)
        Fixtures.makeFiles(files, in: dir)
        let top = Set(files.keys.map { $0.split(separator: "/").first.map(String.init) ?? $0 }).sorted()
        let changes = ArchiveChangeSet(additions: top.map {
            .init(sourceURL: dir.appendingPathComponent($0), destinationDirectory: "")
        })
        let out = Fixtures.tempDir().appendingPathComponent("out.7z")
        try await ArchiveWriter.write(source: nil, changes: changes, format: .sevenZip, to: out, options: options)
        return out
    }

    /// Every 7z method (.lzma2, .store and .deflate, and the rest): the data folder and the
    /// header each get a 7zAES coder, so 7-Zip tests it with the password and refuses it without.
    @Test func writeAES256InteropWith7zz() async throws {
        guard let tool = try SevenZip.required() else { return }
        for method in ArchiveFormat.sevenZip.supportedMethods {
            let url = try await Self.writeSevenZip(options: ArchiveWriteOptions(method: method, encryption: .aes256,
                                                                                password: "pw"))
            try Self.expect7zzAcceptsOnlyPassword(url, tool: tool)
            // Names are hidden: neither the UTF-16LE nor the UTF-8 spelling of a name is in the file.
            let raw = try Data(contentsOf: url)
            for name in ["a.txt", "b.bin", "c.txt"] {
                #expect(raw.range(of: Data(name.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })) == nil,
                        "\(method): \(name) in clear")
                #expect(raw.range(of: Data(name.utf8)) == nil, "\(method): \(name) in clear")
            }
            #expect(raw.range(of: Self.inputs["a.txt"]!.prefix(64)) == nil, "\(method): a.txt data in clear")
        }
    }

    /// Our reader (patch 0004) is the in-process oracle: without a password the names are not even listed.
    @Test func writtenArchiveHidesNames() async throws {
        for method in [ArchiveCompressionMethod.lzma2, .store] {
            let url = try await Self.writeSevenZip(options: ArchiveWriteOptions(method: method, encryption: .aes256,
                                                                                password: "pw"))
            try await Self.expectOpensOnlyWithPassword(url)
        }
    }

    /// Edge shapes of the writer's folder bookkeeping: one entry (upstream leaves a lone entry's header
    /// unencoded; encrypted, it is encoded anyway), and only empty entries (no data folder; the header is
    /// still encrypted, so the names stay hidden).
    @Test func writeAES256EdgeShapes() async throws {
        let one = ["solo.txt": Data("solo\n".utf8)]
        let onlyEmpty = ["empty.txt": Data(), "dir/": Data()]
        for files in [one, onlyEmpty] {
            for method in [ArchiveCompressionMethod.lzma2, .store] {
                let url = try await Self.writeSevenZip(files, options: ArchiveWriteOptions(
                    method: method, encryption: .aes256, password: "pw"))
                await #expect(throws: ArchiveError.passwordRequired, "\(files.keys) \(method)") {
                    _ = try await Archive.open(at: url)
                }
                await #expect(throws: ArchiveError.wrongPassword, "\(files.keys) \(method)") {
                    _ = try await Archive.open(at: url, password: "nope")
                }
                let r = try await Archive.open(at: url, password: "pw")
                #expect(Set(r.entries.map(\.path))
                        == Set(files.keys.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }))
                try await Self.expectExtracts(r, files)
                if let tool = try SevenZip.required() {
                    let test = try Tool.run(tool.path, ["t", "-ppw", url.path])
                    #expect(test.status == 0, "\(files.keys) \(method): \(test.stderr)")
                    #expect(try Tool.run(tool.path, ["l", url.path]).status != 0, "\(files.keys) \(method)")
                    #expect(try Tool.run(tool.path, ["t", "-pnope", url.path]).status != 0, "\(files.keys) \(method)")
                }
            }
        }
    }

    /// Cmd-S on an unlocked 7z with the reader's own encryption keeps it encrypted.
    @Test func cmdSKeepsEncryptionOn7z() async throws {
        guard let tool = try SevenZip.required() else { return }
        for args in [["-ppw"], ["-ppw", "-mhe=on"]] {
            let url = try SevenZip.make("t.7z", files: Self.inputs, args: args)
            let r = try await Archive.open(at: url, password: "pw")
            let out = Fixtures.tempDir().appendingPathComponent("saved.7z")
            try await ArchiveWriter.write(source: r, changes: .init(), format: .sevenZip, to: out,
                                          options: ArchiveWriteOptions(encryption: r.encryption, password: "pw"))
            try Self.expect7zzAcceptsOnlyPassword(out, tool: tool)
            try await Self.expectOpensOnlyWithPassword(out)
        }
    }

    // A plain save (nil options) of an encrypted 7z back to 7z keeps AES-256:
    // the apps unlock an encrypted 7z and then save it with nil options. The plain-save guard itself stays in
    // ResolvedWriteOptions; 7z simply lists .aes256 now.
    static func expectPlainSevenZipSaveKeepsAES256(args: [String],
                                                   sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: args)
        let source = try await Archive.open(at: url, password: "pw")
        #expect(source.encryption == .aes256, sourceLocation: sourceLocation)
        let seven = Fixtures.tempDir().appendingPathComponent("out.7z")
        try await ArchiveWriter.write(source: source, changes: .init(), format: .sevenZip, to: seven, options: nil)
        try await expectOpensOnlyWithPassword(seven, sourceLocation: sourceLocation)
        if let tool = SevenZip.tool {
            try expect7zzAcceptsOnlyPassword(seven, tool: tool, sourceLocation: sourceLocation)
        }
        // Saving over the original (the document save) keeps it encrypted too.
        try await ArchiveWriter.write(source: source, changes: .init(), format: .sevenZip, to: url, options: nil)
        try await expectOpensOnlyWithPassword(url, sourceLocation: sourceLocation)
    }

    @Test func plainSaveOfHeaderEncryptedSevenZipKeepsAES256() async throws {
        guard try SevenZip.required() != nil else { return }
        try await Self.expectPlainSevenZipSaveKeepsAES256(args: ["-ppw", "-mhe=on"])
    }

    @Test func plainSaveOfDataEncryptedSevenZipKeepsAES256() async throws {
        guard try SevenZip.required() != nil else { return }
        try await Self.expectPlainSevenZipSaveKeepsAES256(args: ["-ppw"])
    }

    /// The guard keys on the source's encryption: an unencrypted 7z still saves to 7z with nil options.
    @Test func plainSaveOfUnencryptedSevenZipStillWorks() async throws {
        guard try SevenZip.required() != nil else { return }
        let url = try SevenZip.make("t.7z", files: Self.inputs, args: [])
        let source = try await Archive.open(at: url)
        #expect(source.encryption == .none)
        let seven = Fixtures.tempDir().appendingPathComponent("out.7z")
        try await ArchiveWriter.write(source: source, changes: .init(), format: .sevenZip, to: seven, options: nil)
        let back = try await Archive.open(at: seven)
        #expect(back.format == .sevenZip && back.encryption == .none)
        try await Self.expectExtracts(back)
    }
    #endif
}
