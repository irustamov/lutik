import Foundation
import Testing
@testable import KernirCore

/// A split ZIP whose end-of-central-directory record does not lie whole in the last part (SPLIT-ZIP-EOCD-STRADDLE).
/// A numbered split (`x.zip.001` ...) is a byte split of one zip: when the archive ends 1 ... 21 bytes past a volume
/// boundary the 22-byte record starts in the part before, and with a long archive comment (record + comment up to
/// 65 557 bytes) and small parts the record and its comment can span several parts. The resolver, the comment read
/// and a save's comment copy search the logical end of the set (the last 65 557 bytes across as many trailing parts
/// as they take) with the single-file rule (`VolumeProbe.exactEOCD`).
@Suite struct SplitEndRecordTests {
    typealias Z = ZipCommentTests
    static let mb = VolumeWriterTests.mb

    // MARK: - Kernir's own sets

    /// A stored zip of `target` bytes (one `in/noise.bin`), written whole to measure, then by `writeVolumes` at
    /// 1 000 000 B. Returns the volumes and the file's sha256.
    static func ownSet(target: Int64, options base: ArchiveWriteOptions = ArchiveWriteOptions(method: .store)) async throws -> (urls: [URL], sha: String) {
        let dir = Fixtures.tempDir()
        let input = dir.appending(path: "in")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let changes = ArchiveChangeSet(additions: [.init(sourceURL: input, destinationDirectory: "")])
        // Stored, so the archive grows byte for byte with the file: one write to measure, one to land on target.
        var count = Int(target) - 200
        var total: Int64 = 0
        for attempt in 0..<2 {
            try VolumeWriterTests.noise(count).write(to: input.appending(path: "noise.bin"))
            let probe = dir.appending(path: "probe-\(attempt).zip")
            try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: probe,
                                          options: base)
            total = try WriterTests.size(probe)
            count += Int(target - total)
        }
        try #require(total == target, "stored zip is \(total) B, wanted \(target)")
        let out = dir.appending(path: "out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var options = base
        options.volumeSize = mb
        let urls = try await ArchiveWriter.writeVolumes(source: nil, changes: changes, format: .zip, into: out,
                                                        baseName: "set", options: options)
        return (urls, Fixtures.sha256(input.appending(path: "noise.bin")))
    }

    /// Kernir's own split lands `past` bytes after the end of volume `full`: 1, 11 and 21 put the end record across
    /// the last boundary (it starts in the volume before), 22 leaves it alone in a 22-byte last volume, 0 puts it at
    /// the end of a full last volume. Every set opens at its first and at its last part and extracts the file.
    @Test(arguments: [(1, 1), (1, 11), (1, 21), (1, 22), (2, 0)] as [(Int64, Int64)])
    func ownSplitAroundTheBoundary(_ full: Int64, _ past: Int64) async throws {
        let (urls, sha) = try await Self.ownSet(target: full * Self.mb + past)
        let expected = Array(repeating: Self.mb, count: Int(full)) + (past > 0 ? [past] : [])
        #expect(try urls.map(WriterTests.size) == expected)
        #expect(try VolumeSetResolver.resolve(urls[urls.count - 1]) == urls)
        for opened in [urls[0], urls[urls.count - 1]] {
            let set = try await Archive.open(at: opened)
            #expect(set.format == .zip)
            #expect(set.volumeURLs == urls, "opened at \(opened.lastPathComponent)")
            #expect(Fixtures.sha256(try await set.extractToTemporaryFile("in/noise.bin")) == sha)
        }
    }

    // MARK: - Byte-split sets of other tools

    /// `whole` cut into `<name>.001`, `.002` ... of `size` bytes (the last one shorter), in a new folder.
    static func split(_ whole: URL, size: Int, name: String = "set.zip") throws -> [URL] {
        let bytes = [UInt8](try Data(contentsOf: whole))
        let dir = Fixtures.tempDir()
        var urls: [URL] = []
        for (i, start) in stride(from: 0, to: bytes.count, by: size).enumerated() {
            let url = dir.appending(path: name + String(format: ".%03d", i + 1))
            try Data(bytes[start..<min(start + size, bytes.count)]).write(to: url)
            urls.append(url)
        }
        return urls
    }

    /// `bytes` as `<name>.001` with all but the last `tail.reduce(0, +)` bytes, then one part for each `tail` size in
    /// order (0 makes an empty part), in a new folder.
    static func split(_ bytes: [UInt8], tail: [Int], name: String = "set.zip") throws -> [URL] {
        var start = bytes.count - tail.reduce(0, +)
        try #require(start >= 0, "tail \(tail) is longer than \(bytes.count) B")
        var contents = [bytes[..<start]]
        for size in tail {
            contents.append(bytes[start..<(start + size)])
            start += size
        }
        let dir = Fixtures.tempDir()
        return try contents.enumerated().map { i, part in
            let url = dir.appending(path: name + String(format: ".%03d", i + 1))
            try Data(part).write(to: url)
            return url
        }
    }

    /// Where the end record of `whole` starts (its comment is `commentLength` bytes and ends at EOF).
    static func endRecord(_ whole: URL, commentLength: Int) throws -> Int {
        Int(try WriterTests.size(whole)) - 22 - commentLength
    }

    static func pattern(_ count: Int, _ seed: Int = 0) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: ($0 + seed) &* 13 &+ 1) }
    }

    /// A 40 000-byte archive comment in parts of 16 KiB, 4 KiB, and sizes that cut the record's signature and its
    /// comment length: the record and comment span three parts or more. The set opens at its first part with the
    /// whole comment (not writable), the same entries as the single zip, and a save as one zip keeps the comment.
    @Test func longCommentAcrossSeveralParts() async throws {
        let comment = Self.pattern(40_000)
        let whole = try Z.makeZip(Z.entries, comment: comment)
        let eocd = try Self.endRecord(whole, commentLength: comment.count)
        let data = try await Z.contents(whole)
        for size in [16_384, 4_096, eocd + 2, eocd + 21] {
            let urls = try Self.split(whole, size: size)
            let label = "parts of \(size) B"
            try #require(urls.count >= 3, "\(label)")
            let set = try await Archive.open(at: urls[0])
            #expect(set.volumeURLs == urls, "\(label)")
            let read = try #require(set.comment, "\(label)")
            #expect(read.bytes == comment && !read.isWritable, "\(label)")
            #expect(try await WriterRepackTests.contents(of: set) == data, "\(label)")

            let out = Z.destination()
            try await ArchiveWriter.write(source: set, changes: ArchiveChangeSet(), format: .zip, to: out,
                                          options: nil)
            #expect(try Z.comments(out).archive == comment, "\(label)")
        }
    }

    /// The longest comment (65 535 bytes): the record is the first byte of the 65 557-byte window. Parts of 1 000 B
    /// put it 66 parts from the end.
    @Test func longestCommentAtTheWindowEdge() async throws {
        let comment = Self.pattern(65_535, 7)
        let whole = try Z.makeZip(Z.entries, comment: comment)
        let urls = try Self.split(whole, size: 1_000)
        #expect(try VolumeProbe.zipComment(parts: urls) == comment)
        let set = try await Archive.open(at: urls[0])
        #expect(set.volumeURLs == urls)
        #expect(set.comment?.bytes == comment)
    }

    /// A zip64 end (zip64 record, locator, 32-bit record) cut through the zip64 record, the locator and the record:
    /// the set opens with its comment and entries.
    @Test(arguments: [-20 - 56 + 5, -20 + 1, -10, 3])
    func zip64EndAcrossTheBoundary(_ cut: Int) async throws {
        let comment = Self.pattern(20_000, 3)
        let whole = try Z.makeZip(Z.entries, comment: comment, zip64: true)
        let eocd = try Self.endRecord(whole, commentLength: comment.count)
        let urls = try Self.split(whole, size: eocd + cut)
        #expect(try VolumeProbe.zipEOCD(parts: urls) == VolumeProbe.zipEOCD(at: whole))
        let set = try await Archive.open(at: urls[0])
        #expect(set.volumeURLs == urls)
        #expect(set.comment?.bytes == comment)
        #expect(try await WriterRepackTests.contents(of: set) == (try await Z.contents(whole)))
    }

    /// The set is missing its last part (it held the end of the comment): no record ends at the set's end, so the
    /// next part is reported missing, as for a record that sits in the last part.
    @Test func missingLastPartOfALongComment() async throws {
        let whole = try Z.makeZip(Z.entries, comment: Self.pattern(40_000))
        let urls = try Self.split(whole, size: 16_384)
        try FileManager.default.removeItem(at: urls[urls.count - 1])
        do {
            _ = try await Archive.open(at: urls[0])
            Issue.record("a set without its last part opened")
        } catch let error as ArchiveVolumeError {
            #expect(error.reason == .missing && error.part == urls.count)
        }
    }

    // MARK: - The single-file rule, across parts

    /// Zips the probe must judge as it judges the joined file: plain and long comments, a non-matching signature in
    /// the comment (skipped), a matching one (taken: the nearest record whose comment reaches EOF), trailing data
    /// (none), and zip64. Each name maps to the comment `zipComment` must return for the joined file.
    static func probeCases() throws -> [(name: String, whole: URL, comment: [UInt8]?)] {
        var skipped = Self.pattern(40_000)
        skipped.replaceSubrange(100..<122, with: [0x50, 0x4B, 5, 6] + Array(repeating: 0, count: 18))
        var taken = Self.pattern(40_000)
        let at = 20_000, length = (40_000 - at) - 22
        taken.replaceSubrange(at..<(at + 22), with: [0x50, 0x4B, 5, 6] + Array(repeating: 0, count: 16)
                              + [UInt8(length & 0xff), UInt8(length >> 8)])
        return [
            ("none", try Z.makeZip(Z.entries, comment: []), []),
            ("short", try Z.makeZip(Z.entries, comment: Z.archiveComment), Z.archiveComment),
            ("longest", try Z.makeZip(Z.entries, comment: Self.pattern(65_535)), Self.pattern(65_535)),
            ("skipped", try Z.makeZip(Z.entries, comment: skipped), skipped),
            ("taken", try Z.makeZip(Z.entries, comment: taken), Array(taken[(at + 22)...])),
            ("trailing", try Z.zipWithTrailingData(10_000), nil),
            ("zip64", try Z.makeZip(Z.entries, comment: Self.pattern(300), zip64: true), Self.pattern(300)),
        ]
    }

    /// Every case cut at many part sizes (cuts through the record, its comment and the zip64 locator included):
    /// `zipEOCD` and `zipComment` over the parts answer what they answer for the joined file, and the comment is the
    /// expected one.
    @Test func partsAnswerAsTheJoinedFile() throws {
        for (name, whole, comment) in try Self.probeCases() {
            #expect(try VolumeProbe.zipComment(at: whole) == comment, "\(name), joined")
            let size = Int(try WriterTests.size(whole))
            for partSize in [100, 1_000, 4_096, 16_384, 65_536, size - 23, size - 22, size - 21, size - 11, size - 1, size] {
                let urls = try Self.split(whole, size: partSize)
                let label = "\(name) in parts of \(partSize) B"
                #expect(try VolumeProbe.zipEOCD(parts: urls) == VolumeProbe.zipEOCD(at: whole), "\(label)")
                #expect(try VolumeProbe.zipComment(parts: urls) == comment, "\(label)")
                try? FileManager.default.removeItem(at: urls[0].deletingLastPathComponent())
            }
        }
    }

    /// Every cut of a short-comment zip's last 64 bytes (the record, its comment, and the last part of the central
    /// directory) into a last part of 1 ... 64 bytes: the resolver takes the two parts as the whole set.
    @Test func everyCutOfTheEndRecord() throws {
        let whole = try Z.makeZip(Z.entries, comment: Array("abc".utf8))
        let bytes = [UInt8](try Data(contentsOf: whole))
        for tail in 1...64 {
            let dir = Fixtures.tempDir()
            let first = dir.appending(path: "t.zip.001"), second = dir.appending(path: "t.zip.002")
            try Data(bytes[..<(bytes.count - tail)]).write(to: first)
            try Data(bytes[(bytes.count - tail)...]).write(to: second)
            #expect(try VolumeSetResolver.resolve(first) == [first, second], "last part of \(tail) B")
            #expect(try VolumeProbe.zipComment(parts: [first, second]) == Array("abc".utf8), "last part of \(tail) B")
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// The fake end record of a comment (`taken` above) is judged on the set as on the joined file: Kernir opens the
    /// split set with the comment it reads from the joined zip.
    @Test func fakeRecordInTheCommentReadsAsTheJoinedFile() async throws {
        let (_, whole, comment) = try #require(try Self.probeCases().first { $0.name == "taken" })
        let joined = try await Archive.open(at: whole).comment?.bytes
        #expect(joined == comment)
        let urls = try Self.split(whole, size: 4_096)
        let set = try await Archive.open(at: urls[0])
        #expect(set.comment?.bytes == joined)
    }

    /// Encryption and method of a split whose central directory is not whole in the last part (the record across
    /// the boundary, or alone in a 22-byte last part): read from the joined parts, as for the single zip, not taken
    /// from the header flag (which would say AES-256 for ZipCrypto and AES-128, and no method). 2 000 B past: the
    /// directory is in the last part. The password extracts the file.
    @Test(arguments: [Int64(11), 22, 2_000])
    func encryptionAndMethodOfASplit(_ past: Int64) async throws {
        for encryption in [ArchiveEncryption.none, .zipCrypto, .aes128] {
            let password = encryption == .none ? nil : "pw"
            let options = ArchiveWriteOptions(method: .store, encryption: encryption, password: password)
            let (urls, sha) = try await Self.ownSet(target: Self.mb + past, options: options)
            let set = try await Archive.open(at: urls[0], password: password)
            #expect(set.encryption == encryption, "\(encryption), \(past) B past")
            #expect(set.compressionMethod == .store, "\(encryption), \(past) B past")
            #expect(Fixtures.sha256(try await set.extractToTemporaryFile("in/noise.bin")) == sha)
        }
    }

    // MARK: - Empty parts

    /// A byte split with empty parts at its end (a tool that cuts on a boundary, or a set put together by hand):
    /// right before the 11-byte tail that ends the record, two in a row, between the two halves of the record, and
    /// as the last part. The end of the set still reads as the joined zip, and the set resolves with every part.
    @Test(arguments: [[0, 11], [0, 0, 11], [5, 0, 6], [11, 0]])
    func zipWithEmptyPartsResolvesEndRecord(_ tail: [Int]) throws {
        let comment = Array("abc".utf8)
        let whole = try Z.makeZip(Z.entries, comment: comment)
        let urls = try Self.split([UInt8](try Data(contentsOf: whole)), tail: tail, name: "e.zip")
        let label = "tail parts of \(tail) B"
        #expect(try VolumeProbe.zipEOCD(parts: urls) == VolumeProbe.zipEOCD(at: whole), "\(label)")
        #expect(try VolumeProbe.zipComment(parts: urls) == comment, "\(label)")
        #expect(try VolumeSetResolver.resolve(urls[0]) == urls, "\(label)")
    }

    // MARK: - PKWARE strong encryption

    typealias D = DamagedEncryptedZipTests

    /// Strong encryption (no password decrypts it) in a split whose central directory is not whole in the last part
    /// (last parts of 11, 22 and 80 bytes) or is cut in half (nil): the joined probe sees it, and extracting without
    /// or with a password is `.unsupportedEncryption`, never a password error.
    @Test(arguments: [11, 22, 80, nil] as [Int?])
    func strongEncryptionInAStraddlingSplit(_ tail: Int?) async throws {
        let bytes = try D.strongEncryptionZip()
        let urls = try Self.split(bytes, tail: [tail ?? bytes.count / 2])
        let label = "last part of \(tail.map { "\($0) B" } ?? "half")"
        #expect(try ZipEncryptionProbe.detect(parts: urls).strongEncryption, "\(label)")

        let plain = try await Archive.open(at: urls[0], password: nil)
        #expect(plain.volumeURLs == urls, "\(label)")
        let noPassword = await D.error { try await plain.extract(nil, to: Fixtures.tempDir(), progress: nil) }
        #expect(noPassword == .unsupportedEncryption(.zip), "\(label), no password: \(String(describing: noPassword))")
        let withPassword = await D.error {
            let set = try await Archive.open(at: urls[0], password: D.password)
            try await set.extract(nil, to: Fixtures.tempDir(), progress: nil)
        }
        #expect(withPassword == .unsupportedEncryption(.zip),
                "\(label), password: \(String(describing: withPassword))")
    }

    /// The strong-encryption check of a failed header read (`LibArchiveReader.headerFailure`) on a split. The second
    /// entry's local header is damaged, so the listing walk fails before the open-time probe runs; the joined
    /// central directory still says strong encryption, so the open is `.unsupportedEncryption` with and without a
    /// password, as for the single file. (The last part alone holds no directory: it would read as damage.)
    @Test(arguments: [11, 22])
    func strongEncryptionBehindADamagedHeader(_ tail: Int) async throws {
        var bytes = try D.strongEncryptionZip()
        bytes[D.layout(bytes).entries[1].local + 2] = 0
        let single = D.write(bytes)
        let urls = try Self.split(bytes, tail: [tail])
        for password in [nil, D.password] as [String?] {
            for (opened, label) in [(single, "single file"), (urls[0], "last part of \(tail) B")] {
                let e = await D.error { _ = try await Archive.open(at: opened, password: password) }
                #expect(e == .unsupportedEncryption(.zip),
                        "\(label), password \(password ?? "nil"): \(String(describing: e))")
            }
        }
    }
}
