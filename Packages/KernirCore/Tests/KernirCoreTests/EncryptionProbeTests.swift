import Testing
import Foundation
@testable import KernirCore

struct EncryptionProbeTests {
    static let password = "pw"

    /// Writes a zip through the engine's writer. `files` are created in a fresh folder in sorted order.
    static func writeZip(_ files: [(String, Data)], options: ArchiveWriteOptions = ArchiveWriteOptions()) async throws -> URL {
        let dir = Fixtures.tempDir()
        var urls: [URL] = []
        for (name, data) in files {
            Fixtures.makeFiles([name: data], in: dir)
            urls.append(dir.appendingPathComponent(name))
        }
        let dest = Fixtures.tempDir().appendingPathComponent("t.zip")
        let changes = ArchiveChangeSet(additions: urls.map { .init(sourceURL: $0, destinationDirectory: "") })
        try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: dest, options: options)
        return dest
    }

    static func write(_ bytes: [UInt8]) -> URL {
        let url = Fixtures.tempDir().appendingPathComponent("m.zip")
        FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
        return url
    }

    static let body = Data(repeating: 0x61, count: 4000)

    @Test(arguments: [ArchiveEncryption.aes128, .aes256, .zipCrypto])
    func writerEncryptionIsReported(_ enc: ArchiveEncryption) async throws {
        let url = try await Self.writeZip([("a.txt", Self.body)],
                                          options: ArchiveWriteOptions(encryption: enc, password: Self.password))
        let r = try ZipEncryptionProbe.detect(at: url)
        #expect(r.encryption == enc)
        #expect(r.method == .deflate)
        let reader = try await LibArchiveReader.open(at: url, password: Self.password)
        #expect(reader.encryption == enc)
        #expect(reader.compressionMethod == .deflate)
    }

    @Test func storeIsReportedUnderAES() async throws {
        let url = try await Self.writeZip([("a.txt", Self.body)],
                                          options: ArchiveWriteOptions(method: .store, encryption: .aes256, password: Self.password))
        let r = try ZipEncryptionProbe.detect(at: url)
        #expect(r.encryption == .aes256)
        #expect(r.method == .store)
    }

    @Test func plainZipIsNone() async throws {
        let url = try await Self.writeZip([("a.txt", Self.body)])
        let r = try ZipEncryptionProbe.detect(at: url)
        #expect(r.encryption == .none)
        #expect(r.method == .deflate)
        let reader = try await LibArchiveReader.open(at: url, password: nil)
        #expect(reader.encryption == .none)
    }

    @Test func storeLevelZeroIsStore() async throws {
        let url = try await Self.writeZip([("a.txt", Self.body)],
                                          options: ArchiveWriteOptions(method: .deflate, compressionLevel: 0))
        #expect(try ZipEncryptionProbe.detect(at: url).method == .store)
    }

    @Test func infoZipPasswordIsZipCrypto() throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Self.body], in: dir)
        try Fixtures.run("/usr/bin/zip", ["-q", "-P", "pw", "out.zip", "a.txt"], cwd: dir)
        let r = try ZipEncryptionProbe.detect(at: dir.appendingPathComponent("out.zip"))
        #expect(r.encryption == .zipCrypto)
        #expect(r.method == .deflate)
    }

    @Test func zeroByteAndDirectoryEntriesDoNotHideEncryption() async throws {
        // Sorted first, the empty file and the folder stay unencrypted; the AES entry comes later.
        let url = try await Self.writeZip([("a-empty", Data()), ("b-dir/", Data()), ("c.txt", Self.body)],
                                          options: ArchiveWriteOptions(encryption: .aes128, password: Self.password))
        let r = try ZipEncryptionProbe.detect(at: url)
        #expect(r.encryption == .aes128)
        #expect(r.method == .deflate)
    }

    /// Runs /usr/bin/zip with stdin from /dev/null so a prompt can never hang the suite.
    static func infoZip(_ args: [String], files: [String: Data]) throws -> URL {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(files, in: dir)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q"] + args
        p.currentDirectoryURL = dir
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ArchiveError.io("zip exited \(p.terminationStatus)") }
        return dir.appendingPathComponent(args[args.firstIndex { $0.hasSuffix(".zip") } ?? 0])
    }

    // MARK: - Method over non-empty entries

    @Test func infoZipLeadingEmptyFileDoesNotDecideMethod() throws {
        // Info-ZIP stores empty files (method 0); the method comes from the non-empty deflated file.
        let url = try Self.infoZip(["plain.zip", "a-empty", "c.txt"], files: ["a-empty": Data(), "c.txt": Self.body])
        let r = try ZipEncryptionProbe.detect(at: url)
        #expect(r.encryption == .none)
        #expect(r.method == .deflate)
    }

    @Test func allStoredZipIsStore() throws {
        let url = try Self.infoZip(["-0", "s.zip", "a-empty", "c.txt"], files: ["a-empty": Data(), "c.txt": Self.body])
        #expect(try ZipEncryptionProbe.detect(at: url).method == .store)
    }

    @Test func onlyEmptyFilesUseFirstNonDirectoryEntry() async throws {
        let infoZip = try Self.infoZip(["e.zip", "a-empty"], files: ["a-empty": Data()])
        #expect(try ZipEncryptionProbe.detect(at: infoZip).method == .store)
        // The engine deflates empty files.
        let engine = try await Self.writeZip([("a-empty", Data())])
        #expect(try ZipEncryptionProbe.detect(at: engine).method == .deflate)
    }

    @Test func sevenZipFixturesWithStoredFirstFileProbeDeflate() throws {
        // 7-Zip stores the incompressible first file and deflates the later ones.
        for (file, enc) in [("zip/aes256.zip", ArchiveEncryption.aes256), ("zip/aes128.zip", .aes128),
                            ("zip/mixed-encryption.zip", .aes256)] {
            let url = Corpus.root.appending(path: file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let r = try ZipEncryptionProbe.detect(at: url)
            #expect(r.encryption == enc, "\(file)")
            #expect(r.method == .deflate, "\(file)")
        }
    }

    @Test func zip64SizedEntryCountsAsNonEmpty() throws {
        // An empty stored file, then a deflated file whose 32-bit size is the ZIP64 marker.
        let empty = Self.centralEntry(name: "a", method: 0, uncompressedSize: 0)
        let big = Self.centralEntry(name: "b", method: 8, uncompressedSize: 0xFFFF_FFFF)
        let cd = empty + big
        let b = cd + Self.eocd(entries: 2, size: UInt32(cd.count), offset: 0)
        #expect(try ZipEncryptionProbe.detect(at: Self.write(b)).method == .deflate)
    }

    @Test func storedDirectoryDoesNotDecideMethod() throws {
        let dir = Self.centralEntry(name: "d/", method: 0, uncompressedSize: 0)
        let file = Self.centralEntry(name: "a", method: 8, uncompressedSize: 0)
        let cd = dir + file
        let b = cd + Self.eocd(entries: 2, size: UInt32(cd.count), offset: 0)
        #expect(try ZipEncryptionProbe.detect(at: Self.write(b)).method == .deflate)
    }

    // MARK: - Prefixed (SFX) and trailing data

    static func fixtureBytes(_ file: String) throws -> [UInt8]? {
        let url = Corpus.root.appending(path: file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return [UInt8](try Data(contentsOf: url))
    }

    @Test func prefixedZipIsProbedAndOpened() async throws {
        guard let zip = try Self.fixtureBytes("zip/aes256.zip") else { return }
        let stub = [UInt8]("#!/bin/sh\necho self-extracting stub\nexit 0\n".utf8) + [UInt8](repeating: 0x90, count: 4000)
        let url = Self.write(stub + zip)
        let r = try ZipEncryptionProbe.detect(at: url)
        #expect(r.encryption == .aes256)
        #expect(r.method == .deflate)
        let reader = try await Archive.open(at: url, password: Corpus.password)
        #expect(reader.encryption == .aes256)
        #expect(reader.compressionMethod == .deflate)
    }

    @Test func trailingDataZipIsProbedAndOpened() async throws {
        guard let zip = try Self.fixtureBytes("zip/aes256.zip") else { return }
        let url = Self.write(zip + [UInt8]("TRAILER".utf8))
        let r = try ZipEncryptionProbe.detect(at: url)
        #expect(r.encryption == .aes256)
        #expect(r.method == .deflate)
        let reader = try await Archive.open(at: url, password: Corpus.password)
        #expect(reader.encryption == .aes256)
        #expect(reader.compressionMethod == .deflate)
    }

    @Test func prefixedEngineZipIsProbed() async throws {
        let url = try await Self.writeZip([("a.txt", Self.body)],
                                          options: ArchiveWriteOptions(encryption: .aes128, password: Self.password))
        let prefixed = Self.write([UInt8](repeating: 0x4D, count: 777) + [UInt8](try Data(contentsOf: url)))
        let r = try ZipEncryptionProbe.detect(at: prefixed)
        #expect(r.encryption == .aes128)
        #expect(r.method == .deflate)
    }

    // MARK: - Reader fallback never downgrades

    @Test func readerFallbackForUnprobeableEncryptedZipIsAES() async throws {
        // The end-of-central-directory record is cut off: the probe cannot locate the directory, while
        // libarchive streams the local headers and stops cleanly at the first central header.
        guard let zip = try Self.fixtureBytes("zip/aes256.zip") else { return }
        let url = Self.write(Array(zip.prefix(zip.count - 22)))
        do { _ = try ZipEncryptionProbe.detect(at: url); Issue.record("expected the probe to reject it") } catch {
            guard case .corrupted = error else { Issue.record("expected .corrupted, got \(error)"); return }
        }
        let reader = try await Archive.open(at: url, password: Corpus.password)
        #expect(reader.isEncrypted)
        #expect(reader.encryption == .aes256)
        #expect(reader.compressionMethod == nil)
    }

    @Test func readerUpgradesProbeNoneWhenLibarchiveSeesEncryption() async throws {
        // Clear the encryption flag in every central entry; the local headers stay encrypted.
        guard var zip = try Self.fixtureBytes("zip/aes256.zip") else { return }
        let eocd = zip.count - 22
        func u32(_ i: Int) -> Int { Int(UInt32(zip[i]) | UInt32(zip[i + 1]) << 8 | UInt32(zip[i + 2]) << 16 | UInt32(zip[i + 3]) << 24) }
        func u16(_ i: Int) -> Int { Int(zip[i]) | Int(zip[i + 1]) << 8 }
        var p = u32(eocd + 16)
        let end = p + u32(eocd + 12)
        while p + 46 <= end {
            zip[p + 8] &= 0xFE
            p += 46 + u16(p + 28) + u16(p + 30) + u16(p + 32)
        }
        let url = Self.write(zip)
        #expect(try ZipEncryptionProbe.detect(at: url).encryption == .none)
        let reader = try await Archive.open(at: url, password: Corpus.password)
        #expect(reader.isEncrypted)
        #expect(reader.encryption == .aes256)
    }

    @Test func corpusFixtures() throws {
        let expected: [(String, ArchiveEncryption)] = [
            ("zip/aes128.zip", .aes128), ("zip/aes256.zip", .aes256), ("zip/aes256-store.zip", .aes256),
            ("zip/aes128-store.zip", .aes128), ("zip/zipcrypto.zip", .zipCrypto),
            ("zip/zipcrypto-store.zip", .zipCrypto), ("zip/deflate.zip", .none), ("zip/store.zip", .none),
            ("zip/zip64.zip", .none), ("zip/empty.zip", .none), ("zip/mixed-encryption.zip", .aes256),
        ]
        for (file, enc) in expected {
            let url = Corpus.root.appending(path: file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            #expect(try ZipEncryptionProbe.detect(at: url).encryption == enc, "\(file)")
        }
        let store = Corpus.root.appending(path: "zip/store.zip")
        if FileManager.default.fileExists(atPath: store.path) {
            #expect(try ZipEncryptionProbe.detect(at: store).method == .store)
        }
        let bz = Corpus.root.appending(path: "zip/bzip2-method.zip")
        if FileManager.default.fileExists(atPath: bz.path) {
            #expect(try ZipEncryptionProbe.detect(at: bz).method == nil)
        }
    }

    // MARK: - Malformed input

    @Test func truncatedZipIsCorrupted() async throws {
        let url = try await Self.writeZip([("a.txt", Self.body)],
                                          options: ArchiveWriteOptions(encryption: .aes256, password: Self.password))
        let data = try Data(contentsOf: url)
        let cut = Self.write([UInt8](data.prefix(data.count - 10)))
        #expect(throws: ArchiveError.self) { try ZipEncryptionProbe.detect(at: cut) }
        do { _ = try ZipEncryptionProbe.detect(at: cut) } catch {
            guard case .corrupted = error else { Issue.record("expected .corrupted, got \(error)"); return }
        }
    }

    @Test func tinyAndEmptyFilesAreCorrupted() {
        for bytes in [[], [0x50], [UInt8](repeating: 0, count: 21)] as [[UInt8]] {
            do { _ = try ZipEncryptionProbe.detect(at: Self.write(bytes)); Issue.record("expected error") } catch {
                guard case .corrupted = error else { Issue.record("expected .corrupted, got \(error)"); return }
            }
        }
    }

    @Test func missingFileIsIOError() {
        let url = Fixtures.tempDir().appendingPathComponent("nope.zip")
        do { _ = try ZipEncryptionProbe.detect(at: url); Issue.record("expected error") } catch {
            guard case .io = error else { Issue.record("expected .io, got \(error)"); return }
        }
    }

    /// Every prefix and a sweep of single-byte corruptions must return or throw, never trap or hang.
    @Test func fuzzedZipNeverCrashes() async throws {
        let url = try await Self.writeZip([("a-empty", Data()), ("b.txt", Self.body)],
                                          options: ArchiveWriteOptions(encryption: .aes256, password: Self.password))
        let original = [UInt8](try Data(contentsOf: url))
        for n in 0..<original.count {
            _ = try? ZipEncryptionProbe.detect(at: Self.write(Array(original.prefix(n))))
        }
        // Corrupt the tail (EOCD and central directory) with extreme values.
        let start = max(0, original.count - 220)
        for i in start..<original.count {
            for v: UInt8 in [0x00, 0xFF, 0x7F] {
                var b = original
                b[i] = v
                _ = try? ZipEncryptionProbe.detect(at: Self.write(b))
            }
        }
    }

    private static func centralEntry(name: String, method: UInt16, uncompressedSize: UInt32, flags: UInt16 = 0) -> [UInt8] {
        func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
        let nameBytes = [UInt8](name.utf8)
        var e = [UInt8](repeating: 0, count: 46)
        e[0...3] = [0x50, 0x4b, 0x01, 0x02]
        e[8...9] = ArraySlice(le(UInt64(flags), 2))
        e[10...11] = ArraySlice(le(UInt64(method), 2))
        e[24...27] = ArraySlice(le(UInt64(uncompressedSize), 4))
        e[28...29] = ArraySlice(le(UInt64(nameBytes.count), 2))
        return e + nameBytes
    }

    private static func eocd(entries: UInt16, size: UInt32, offset: UInt32, comment: UInt16 = 0) -> [UInt8] {
        func le(_ v: UInt64, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }
        return [0x50, 0x4b, 0x05, 0x06] + le(0, 2) + le(0, 2) + le(UInt64(entries), 2) + le(UInt64(entries), 2)
            + le(UInt64(size), 4) + le(UInt64(offset), 4) + le(UInt64(comment), 2)
    }

    @Test func centralDirectoryOutOfRangeIsCorrupted() {
        for (size, offset) in [(UInt32(100), UInt32(0)), (0xFFFF_FFF0, 0), (10, 0xFFFF_FFF0), (0xFFFF_FFFF, 0xFFFF_FFFF)] {
            do { _ = try ZipEncryptionProbe.detect(at: Self.write(Self.eocd(entries: 1, size: size, offset: offset))); Issue.record("expected error") } catch {
                guard case .corrupted = error else { Issue.record("expected .corrupted, got \(error)"); return }
            }
        }
    }

    @Test func zip64LocatorPointingOutsideIsCorrupted() {
        var b = [UInt8](repeating: 0, count: 8)
        // ZIP64 locator: signature, disk, huge EOCD64 offset, disks.
        b += [0x50, 0x4b, 0x06, 0x07, 0, 0, 0, 0] + [UInt8](repeating: 0xFF, count: 8) + [1, 0, 0, 0]
        b += Self.eocd(entries: 0xFFFF, size: 0xFFFF_FFFF, offset: 0xFFFF_FFFF)
        do { _ = try ZipEncryptionProbe.detect(at: Self.write(b)); Issue.record("expected error") } catch {
            guard case .corrupted = error else { Issue.record("expected .corrupted, got \(error)"); return }
        }
    }

    @Test func entryLengthsOverrunningDirectoryAreCorrupted() {
        // One central entry claiming 65535-byte name, extra and comment inside a 46-byte directory.
        var entry = [UInt8](repeating: 0, count: 46)
        entry[0...3] = [0x50, 0x4b, 0x01, 0x02]
        entry[28] = 0xFF; entry[29] = 0xFF; entry[30] = 0xFF; entry[31] = 0xFF; entry[32] = 0xFF; entry[33] = 0xFF
        let b = entry + Self.eocd(entries: 1, size: 46, offset: 0)
        do { _ = try ZipEncryptionProbe.detect(at: Self.write(b)); Issue.record("expected error") } catch {
            guard case .corrupted = error else { Issue.record("expected .corrupted, got \(error)"); return }
        }
    }

    @Test func badCentralSignatureIsCorrupted() {
        let b = [UInt8](repeating: 0x41, count: 46) + Self.eocd(entries: 1, size: 46, offset: 0)
        do { _ = try ZipEncryptionProbe.detect(at: Self.write(b)); Issue.record("expected error") } catch {
            guard case .corrupted = error else { Issue.record("expected .corrupted, got \(error)"); return }
        }
    }

    @Test func emptyCentralDirectoryIsNone() throws {
        let r = try ZipEncryptionProbe.detect(at: Self.write(Self.eocd(entries: 0, size: 0, offset: 0)))
        #expect(r.encryption == .none)
        #expect(r.method == nil)
    }

    @Test func aesEntryWithoutAESExtraFieldIsCorrupted() {
        var entry = [UInt8](repeating: 0, count: 46 + 1)
        entry[0...3] = [0x50, 0x4b, 0x01, 0x02]
        entry[8] = 1; entry[10] = 99; entry[28] = 1
        entry[46] = UInt8(ascii: "a")
        let b = entry + Self.eocd(entries: 1, size: 47, offset: 0)
        do { _ = try ZipEncryptionProbe.detect(at: Self.write(b)); Issue.record("expected error") } catch {
            guard case .corrupted = error else { Issue.record("expected .corrupted, got \(error)"); return }
        }
    }
}
