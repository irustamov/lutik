import CLibArchive
import Foundation
import Testing
@testable import KernirCore

#if os(macOS)
/// A zip -> zip save keeps the archive comment (EOCD) and every kept entry's central-directory comment, byte for
/// byte. Sources are made by Python's zipfile (or by Kernir and annotated by Python), and every output is checked by
/// readers that are not libarchive: Python's zipfile (comments), zipinfo -z and unzip -t.
@Suite("Zip comments survive a save", .timeLimit(.minutes(3)))
struct ZipCommentTests {
    struct Entry {
        let name: String
        let data: [UInt8]
        let comment: [UInt8]
        var deflate = false
    }

    /// What an independent reader sees: the archive comment and each entry's comment, in central-directory order.
    struct Comments: Equatable {
        let archive: [UInt8]
        let entries: [String: [UInt8]]
        let names: [String]
    }

    // MARK: - Python helpers

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    static func unhex(_ s: Substring) -> [UInt8] {
        let digits = Array(s.utf8).map { UInt8(Character(Unicode.Scalar($0)).hexDigitValue!) }
        return stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
    }

    static func python(_ script: String, _ args: [String], sourceLocation: SourceLocation = #_sourceLocation) throws
        -> String {
        let python3 = try #require(Tool.python3, "python3 is needed to build and read comment zips",
                                   sourceLocation: sourceLocation)
        let run = try Tool.run(python3, ["-I", "-c", script] + args)
        try #require(run.status == 0, "python3: \(run.stderr)", sourceLocation: sourceLocation)
        return String(decoding: run.stdout, as: UTF8.self)
    }

    /// A zip written by Python's zipfile. `zip64`: the end records are rewritten as zip64 (a zip64 EOCD record and
    /// locator, and a 32-bit EOCD whose counts and offsets are 0xFFFF / 0xFFFFFFFF), as large-archive tools write.
    static func makeZip(_ entries: [Entry], comment: [UInt8], zip64: Bool = false) throws -> URL {
        let script = """
            import sys, zipfile, struct
            out, archive_comment, zip64 = sys.argv[1], bytes.fromhex(sys.argv[2]), sys.argv[3] == "1"
            with zipfile.ZipFile(out, "w") as z:
                for spec in sys.argv[4:]:
                    name, data, comment, method = spec.split(":")
                    i = zipfile.ZipInfo(bytes.fromhex(name).decode("utf-8"), date_time=(2024, 3, 9, 10, 20, 30))
                    i.compress_type = zipfile.ZIP_DEFLATED if method == "d" else zipfile.ZIP_STORED
                    i.external_attr = (0o40755 << 16 | 0x10) if i.filename.endswith("/") else (0o100644 << 16)
                    i.comment = bytes.fromhex(comment)
                    z.writestr(i, bytes.fromhex(data))
                z.comment = archive_comment
            if zip64:
                b = open(out, "rb").read()
                eocd = len(b) - 22 - len(archive_comment)
                assert b[eocd:eocd + 4] == b"PK\\x05\\x06"
                count, cd_size, cd_offset = struct.unpack("<HII", b[eocd + 10:eocd + 20])
                rec = struct.pack("<IQHHIIQQQQ", 0x06064b50, 44, 45, 45, 0, 0, count, count, cd_size, cd_offset)
                loc = struct.pack("<IIQI", 0x07064b50, 0, eocd, 1)
                end = struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF,
                                  len(archive_comment))
                open(out, "wb").write(b[:eocd] + rec + loc + end + archive_comment)
            """
        let url = Fixtures.tempDir().appending(path: "src.zip")
        let specs = entries.map { "\(hex(Array($0.name.utf8))):\(hex($0.data)):\(hex($0.comment)):\($0.deflate ? "d" : "s")" }
        _ = try python(script, [url.path, hex(comment), zip64 ? "1" : "0"] + specs)
        return url
    }

    /// Sets the archive comment and entry comments (by name) of an existing zip with Python's zipfile in append mode,
    /// which rewrites only the central directory and end records (entry data, encrypted or not, is left as is).
    static func annotate(_ url: URL, comment: [UInt8], entries: [String: [UInt8]]) throws {
        let script = """
            import sys, zipfile
            with zipfile.ZipFile(sys.argv[1], "a") as z:
                for spec in sys.argv[3:]:
                    name, comment = spec.split(":")
                    z.getinfo(bytes.fromhex(name).decode("utf-8")).comment = bytes.fromhex(comment)
                z.comment = bytes.fromhex(sys.argv[2])
            """
        _ = try python(script, [url.path, hex(comment)] + entries.map { "\(hex(Array($0.key.utf8))):\(hex($0.value))" })
    }

    /// The comments Python's zipfile reads.
    static func comments(_ url: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> Comments {
        let script = """
            import sys, zipfile
            z = zipfile.ZipFile(sys.argv[1])
            print(z.comment.hex())
            for i in z.infolist():
                print(i.filename.encode("utf-8").hex() + ":" + i.comment.hex())
            """
        let lines = try python(script, [url.path], sourceLocation: sourceLocation).split(separator: "\n",
                                                                                          omittingEmptySubsequences: false)
        var entries: [String: [UInt8]] = [:]
        var names: [String] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            let name = String(decoding: unhex(parts[0]), as: UTF8.self)
            names.append(name)
            entries[name] = unhex(parts[1])
        }
        return Comments(archive: unhex(lines.first ?? ""), entries: entries, names: names)
    }

    /// The file ends with an end-of-central-directory record whose comment is exactly `comment` and reaches EOF, and
    /// unzip -t passes (with `password` for ZipCrypto; `aes`: unzip cannot decrypt AES, so zipinfo -v only lists
    /// it). zipinfo -z prints an ASCII comment.
    static func checkEnd(_ url: URL, comment: [UInt8], password: String? = nil, aes: Bool = false,
                         sourceLocation: SourceLocation = #_sourceLocation) throws {
        let bytes = [UInt8](try Data(contentsOf: url))
        let eocd = bytes.count - 22 - comment.count
        try #require(eocd >= 0, sourceLocation: sourceLocation)
        #expect(Array(bytes[eocd..<eocd + 4]) == [0x50, 0x4B, 0x05, 0x06], "no EOCD where the comment begins",
                sourceLocation: sourceLocation)
        #expect(Int(bytes[eocd + 20]) | Int(bytes[eocd + 21]) << 8 == comment.count, sourceLocation: sourceLocation)
        #expect(Array(bytes[(eocd + 22)...]) == comment, sourceLocation: sourceLocation)
        if aes, let zipinfo = try Tool.optional(Tool.zipinfo, "zipinfo", sourceLocation: sourceLocation) {
            let run = try Tool.run(zipinfo, ["-v", url.path])
            #expect(run.status == 0, "zipinfo -v: \(run.stderr)", sourceLocation: sourceLocation)
        } else if let unzip = try Tool.optional(Tool.unzip, "unzip", sourceLocation: sourceLocation) {
            let run = try Tool.run(unzip, (password.map { ["-P", $0] } ?? []) + ["-t", url.path])
            #expect(run.status == 0, "unzip -t: \(run.stderr)\(String(decoding: run.stdout, as: UTF8.self))",
                    sourceLocation: sourceLocation)
        }
        if !comment.isEmpty, comment.allSatisfy({ (0x20..<0x7F).contains($0) }),
           let zipinfo = try Tool.optional(Tool.zipinfo, "zipinfo", sourceLocation: sourceLocation) {
            let run = try Tool.run(zipinfo, ["-z", url.path])
            #expect(String(decoding: run.stdout, as: UTF8.self).contains(String(decoding: comment, as: UTF8.self)),
                    "zipinfo -z does not show the comment", sourceLocation: sourceLocation)
        }
    }

    /// sha256 of every regular file Kernir extracts.
    static func contents(_ url: URL, password: String? = nil) async throws -> [String: String] {
        try await WriterRepackTests.contents(of: try await Archive.open(at: url, password: password))
    }

    static func destination() -> URL { WriterRepackTests.destination("out.zip") }

    // MARK: - Sample data

    /// Raw bytes no text codec round-trips: NUL, CR LF, CP437 box drawing, invalid UTF-8.
    static let rawComment: [UInt8] = [0x52, 0x45, 0x41, 0x44, 0x00, 0x0D, 0x0A, 0xC9, 0xCD, 0xBB, 0xFF, 0xFE, 0x80, 0x20]
    static let archiveComment = Array("Kernir ZIP: scene release readme\r\n".utf8) + rawComment
    static let stamp = Array(repeating: Array("0123456789abcdef".utf8), count: 64).flatMap { $0 }

    static let entries: [Entry] = [
        Entry(name: "docs/", data: [], comment: Array("folder comment".utf8)),
        Entry(name: "docs/readme.txt", data: Array("read me\n".utf8), comment: rawComment, deflate: true),
        Entry(name: "docs/plain.txt", data: Array("no comment here\n".utf8), comment: []),
        Entry(name: "stored.bin", data: stamp, comment: Array("stored entry".utf8)),
        Entry(name: "deflated.bin", data: stamp, comment: Array("deflated entry \u{263A}".utf8), deflate: true),
        Entry(name: "gone.txt", data: Array("removed\n".utf8), comment: Array("goes away with its entry".utf8)),
    ]

    static var entryComments: [String: [UInt8]] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.comment) })
    }

    // MARK: - Repack

    /// The bug: removing one entry wrote an EOCD with comment length 0 and no entry comments.
    @Test func removingAnEntryKeepsTheComments() async throws {
        let src = try Self.makeZip(Self.entries, comment: Self.archiveComment)
        let before = try Self.comments(src)
        #expect(before.archive == Self.archiveComment && before.entries == Self.entryComments)
        let source = try await Archive.open(at: src)
        let out = Self.destination()
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["gone.txt"]),
                                      format: .zip, to: out, options: nil)

        let after = try Self.comments(out)
        var expected = Self.entryComments
        expected["gone.txt"] = nil
        #expect(after.archive == Self.archiveComment)
        #expect(after.entries == expected)
        try Self.checkEnd(out, comment: Self.archiveComment)
        var data = try await Self.contents(src)
        data["gone.txt"] = nil
        #expect(try await Self.contents(out) == data)
    }

    /// An added file gets no comment; kept entries and the archive keep theirs. A file added over an existing
    /// entry replaces it, comment included.
    @Test func addingFilesKeepsTheComments() async throws {
        let src = try Self.makeZip(Self.entries, comment: Self.archiveComment)
        let source = try await Archive.open(at: src)
        let disk = Fixtures.tempDir()
        Fixtures.makeFiles(["new.txt": Data("added\n".utf8), "stored.bin": Data("replaced\n".utf8)], in: disk)
        let out = Self.destination()
        let additions = ["new.txt", "stored.bin"].map { WriterRepackTests.adding(disk.appending(path: $0), into: "") }
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(additions: additions),
                                      format: .zip, to: out, options: nil)

        let after = try Self.comments(out)
        var expected = Self.entryComments
        expected["new.txt"] = []
        expected["stored.bin"] = []
        #expect(after.archive == Self.archiveComment)
        #expect(after.entries == expected)
        try Self.checkEnd(out, comment: Self.archiveComment)
    }

    /// Save As with no changes, and a ⌘S over the source file itself.
    @Test(arguments: [false, true])
    func plainRepackKeepsTheComments(inPlace: Bool) async throws {
        let src = try Self.makeZip(Self.entries, comment: Self.archiveComment)
        let data = try await Self.contents(src)
        let source = try await Archive.open(at: src)
        let out = inPlace ? src : Self.destination()
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(), format: .zip, to: out, options: nil)

        let after = try Self.comments(out)
        #expect(after.archive == Self.archiveComment)
        #expect(after.entries == Self.entryComments)
        #expect(after.names == Self.entries.map(\.name))
        try Self.checkEnd(out, comment: Self.archiveComment)
        #expect(try await Self.contents(out) == data)
    }

    /// Saving the output again (and again) changes nothing in the comments.
    @Test func secondSaveKeepsTheComments() async throws {
        let src = try Self.makeZip(Self.entries, comment: Self.archiveComment)
        let once = Self.destination()
        try await ArchiveWriter.write(source: try await Archive.open(at: src), changes: ArchiveChangeSet(),
                                      format: .zip, to: once, options: nil)
        let twice = Self.destination()
        try await ArchiveWriter.write(source: try await Archive.open(at: once), changes: ArchiveChangeSet(),
                                      format: .zip, to: twice, options: nil)
        #expect(try Self.comments(twice) == Self.comments(src))
        #expect(Fixtures.sha256(once) == Fixtures.sha256(twice))
    }

    /// A save that changes the compression (store <-> deflate) or adds encryption keeps the comments too.
    @Test(arguments: [ArchiveWriteOptions(method: .store), ArchiveWriteOptions(method: .deflate, compressionLevel: 9),
                      ArchiveWriteOptions(encryption: .zipCrypto, password: "pw")])
    func saveWithOptionsKeepsTheComments(_ options: ArchiveWriteOptions) async throws {
        let src = try Self.makeZip(Self.entries, comment: Self.archiveComment)
        let out = Self.destination()
        try await ArchiveWriter.write(source: try await Archive.open(at: src), changes: ArchiveChangeSet(),
                                      format: .zip, to: out, options: options)
        let after = try Self.comments(out)
        #expect(after.archive == Self.archiveComment)
        #expect(after.entries == Self.entryComments)
        try Self.checkEnd(out, comment: Self.archiveComment, password: options.password)
    }

    // MARK: - Encrypted sources

    /// ZipCrypto and AES sources (Kernir-written, then annotated): ⌘S re-encrypts every kept entry and keeps the
    /// comments, which are never encrypted.
    @Test(arguments: WriterRepackTests.encryptions)
    func encryptedSourceKeepsTheComments(_ encryption: ArchiveEncryption) async throws {
        let src = try await WriterRepackTests.makeEncryptedZip(encryption)
        let comments: [String: [UInt8]] = ["a.txt": Array("alpha note".utf8), "b/c.txt": Self.rawComment,
                                           "b/": Array("folder".utf8), "secret.txt": Array("removed".utf8)]
        try Self.annotate(src, comment: Self.archiveComment, entries: comments)
        let source = try await Archive.open(at: src, password: "pw")
        #expect(source.encryption == encryption)
        var data = try await WriterRepackTests.contents(of: source)
        data["secret.txt"] = nil
        let out = Self.destination()
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["secret.txt"]),
                                      format: .zip, to: out, options: nil)

        let after = try Self.comments(out)
        #expect(after.archive == Self.archiveComment)
        var expected = comments
        expected["secret.txt"] = nil
        #expect(after.entries.filter { !$0.value.isEmpty } == expected)
        try Self.checkEnd(out, comment: Self.archiveComment, password: encryption == .zipCrypto ? "pw" : nil,
                          aes: encryption != .zipCrypto)
        let reopened = try await Archive.open(at: out, password: "pw")
        #expect(reopened.encryption == encryption)
        #expect(try await WriterRepackTests.contents(of: reopened) == data)
    }

    // MARK: - Sizes and zip64

    /// The largest comments a zip holds: a 65 535-byte comment on an entry, and a 16 000-byte archive comment
    /// (edited comments are capped there).
    @Test func maximumEntryCommentAndLargeArchiveComment() async throws {
        let big = (0..<65_535).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
        let archive = Array(Array(repeating: Array("Zip archive comment 0123456789\n".utf8), count: 520).joined().prefix(16_000))
        var entries = Self.entries
        entries[3] = Entry(name: "stored.bin", data: Self.stamp, comment: big)
        let src = try Self.makeZip(entries, comment: archive)
        let out = Self.destination()
        try await ArchiveWriter.write(source: try await Archive.open(at: src), changes: ArchiveChangeSet(),
                                      format: .zip, to: out, options: nil)
        let after = try Self.comments(out)
        #expect(after.archive == archive)
        #expect(after.entries["stored.bin"] == big)
        #expect(after.entries == Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.comment) }))
        try Self.checkEnd(out, comment: archive)
        // The output still reopens through the seekable reader: the central-directory facts are there.
        #expect(try await Archive.open(at: out).compressionMethod == .deflate)
    }

    /// What libarchive's zip reader (both bidders, as Kernir opens zips) reports per entry: the reader hook's result
    /// (1 seekable, 0 streaming) and, for 1, the entry's comment, by entry name.
    static func readerHook(_ url: URL) throws -> (kinds: Set<Int32>, comments: [String: [UInt8]]) {
        let bytes = [UInt8](try Data(contentsOf: url))
        let a = archive_read_new()
        defer { archive_read_free(a) }
        #expect(archive_read_support_format_zip(a) == ARCHIVE_OK)
        return bytes.withUnsafeBytes { buf in
            #expect(archive_read_open_memory(a, buf.baseAddress, buf.count) == ARCHIVE_OK)
            var kinds: Set<Int32> = []
            var comments: [String: [UInt8]] = [:]
            var entry: OpaquePointer?
            while archive_read_next_header(a, &entry) == ARCHIVE_OK {
                var p: UnsafeRawPointer?
                var n = 0
                let r = kernir_read_zip_entry_comment(a, &p, &n)
                kinds.insert(r)
                let name = String(cString: archive_entry_pathname(entry))
                comments[name] = p.map { Array(UnsafeRawBufferPointer(start: $0, count: n)) } ?? []
            }
            return (kinds, comments)
        }
    }

    /// Archive comments longer than libarchive's 16 KiB end-record search, up to the format's maximum: the seekable
    /// reader still finds the end record (Kernir patch 0012 widens the search to 20 + 22 + 65 535 bytes for an end
    /// record whose comment reaches EOF exactly), so the entry comments are read and kept by a save.
    @Test(arguments: [16_385, 40_000, 65_535])
    func longArchiveCommentKeepsEntryComments(_ length: Int) async throws {
        let archive = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) }
        try await Self.checkLongComment(try Self.makeZip(Self.entries, comment: archive), archive)
    }

    /// The same behind zip64 end records (zip64 EOCD record and locator, 20 bytes before the end record). 16 350: the
    /// end record is in the last 16 KiB but its locator is not (upstream missed the locator there); 65 535 puts the
    /// locator at the first byte of the widened search window.
    @Test(arguments: [16_350, 20_000, 65_535])
    func zip64LongArchiveCommentKeepsEntryComments(_ length: Int) async throws {
        let archive = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 5) }
        try await Self.checkLongComment(try Self.makeZip(Self.entries, comment: archive, zip64: true), archive)
    }

    /// The source is read by the seekable reader with every entry comment, and a save that removes one entry keeps
    /// the archive comment and the other entry comments (Python, the end record, unzip -t, the output's reader).
    static func checkLongComment(_ src: URL, _ archive: [UInt8], sourceLocation: SourceLocation = #_sourceLocation)
        async throws {
        let read = try readerHook(src)
        #expect(read.kinds == [1], "the source is not read by the seekable reader", sourceLocation: sourceLocation)
        #expect(read.comments == entryComments, sourceLocation: sourceLocation)
        let data = try await contents(src)
        let out = destination()
        try await ArchiveWriter.write(source: try await Archive.open(at: src),
                                      changes: ArchiveChangeSet(removedPaths: ["gone.txt"]),
                                      format: .zip, to: out, options: nil)
        var expected = entryComments
        expected["gone.txt"] = nil
        let after = try comments(out, sourceLocation: sourceLocation)
        #expect(after.archive == archive, sourceLocation: sourceLocation)
        #expect(after.entries == expected, sourceLocation: sourceLocation)
        try checkEnd(out, comment: archive, sourceLocation: sourceLocation)
        var kept = data
        kept["gone.txt"] = nil
        #expect(try await contents(out) == kept, sourceLocation: sourceLocation)
        let reread = try readerHook(out)
        #expect(reread.kinds == [1], "the output is not read by the seekable reader", sourceLocation: sourceLocation)
        #expect(reread.comments == expected, sourceLocation: sourceLocation)
    }

    /// Data after an end record with no comment: within the last 16 KiB libarchive's rule is unchanged (the seekable
    /// reader takes the end record); further from EOF an end record is taken only when its comment reaches EOF, so
    /// 20 KiB of trailing junk keeps the streaming reader (no central directory, the hook returns 0), as before.
    @Test(arguments: [(10_000, Int32(1)), (20_480, Int32(0))])
    func trailingDataAfterTheEndRecord(_ junk: Int, _ kind: Int32) throws {
        let read = try Self.readerHook(try Self.zipWithTrailingData(junk))
        #expect(read.kinds == [kind])
        #expect(Set(read.comments.keys) == Set(Self.entries.map(\.name)))
        if kind == 1 { #expect(read.comments == Self.entryComments) }
    }

    /// A comment-less zip followed by `junk` bytes of trailing data.
    static func zipWithTrailingData(_ junk: Int) throws -> URL {
        let src = try makeZip(entries, comment: [])
        let handle = try FileHandle(forWritingTo: src)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((0..<junk).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 0x31) }))
        try handle.close()
        return src
    }

    /// The edge of the 16 KiB rule, to the byte. 16 362 bytes of trailing data put the end record exactly 16 384
    /// bytes from EOF (upstream's search reaches it, so it is taken); one byte more puts it in the far region, where
    /// its comment (0) does not reach EOF, so it is not taken.
    @Test(arguments: [(16_362, Int32(1)), (16_363, Int32(0))])
    func endRecordAtTheSixteenKiBBoundary(_ junk: Int, _ kind: Int32) throws {
        #expect(try Self.readerHook(try Self.zipWithTrailingData(junk)).kinds == [kind])
    }

    /// In the far region (more than 16 KiB from EOF) a signature that does not match (its comment length does not
    /// reach EOF) is skipped and the backward search goes on to the real end record.
    @Test func farSignatureThatDoesNotMatchIsSkipped() throws {
        var comment = (0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) }
        comment.replaceSubrange(100..<122, with: [0x50, 0x4B, 5, 6] + Array(repeating: 0, count: 18))
        let read = try Self.readerHook(try Self.makeZip(Self.entries, comment: comment))
        #expect(read.kinds == [1])
        #expect(read.comments == Self.entryComments)
    }

    /// Two end records in the far region whose comments both reach EOF: the one nearest EOF (the first found
    /// scanning backwards) is taken, as VolumeProbe.exactEOCD does, so the real record further back is not.
    @Test func nearestMatchingFarEndRecordWins() throws {
        var comment = (0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) }
        let at = 20_000
        let length = (40_000 - at) - 22
        comment.replaceSubrange(at..<(at + 22), with: [0x50, 0x4B, 5, 6] + Array(repeating: 0, count: 16)
                                + [UInt8(length & 0xff), UInt8(length >> 8)])
        let src = try Self.makeZip(Self.entries, comment: comment)
        #expect(try Self.readerHook(src).comments != Self.entryComments)
        #expect(try VolumeProbe.zipComment(at: src)?.count == length)
    }

    /// A zip64 source (zip64 EOCD record and locator before the EOCD) keeps its comments; the output's end records
    /// are valid for Python, zipinfo and unzip.
    @Test func zip64SourceKeepsTheComments() async throws {
        let src = try Self.makeZip(Self.entries, comment: Self.archiveComment, zip64: true)
        #expect(try Self.comments(src).entries == Self.entryComments)
        let source = try await Archive.open(at: src)
        let out = Self.destination()
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["gone.txt"]),
                                      format: .zip, to: out, options: nil)
        var expected = Self.entryComments
        expected["gone.txt"] = nil
        let after = try Self.comments(out)
        #expect(after.archive == Self.archiveComment)
        #expect(after.entries == expected)
        try Self.checkEnd(out, comment: Self.archiveComment)
    }

    // MARK: - Unchanged behaviour

    /// No comments in the source: the output has none either, and its end record is libarchive's plain 22 bytes.
    @Test func sourceWithoutCommentsStaysWithout() async throws {
        let plain = Self.entries.map { Entry(name: $0.name, data: $0.data, comment: [], deflate: $0.deflate) }
        let src = try Self.makeZip(plain, comment: [])
        let out = Self.destination()
        try await ArchiveWriter.write(source: try await Archive.open(at: src), changes: ArchiveChangeSet(),
                                      format: .zip, to: out, options: nil)
        let after = try Self.comments(out)
        #expect(after.archive.isEmpty && after.entries.values.allSatisfy(\.isEmpty))
        try Self.checkEnd(out, comment: [])
        #expect(Self.centralCommentLengths(out).allSatisfy { $0 == 0 })
    }

    /// A new archive (no source) has no comments.
    @Test func newArchiveHasNoComments() async throws {
        let tree = try WriterRepackTests.makeTree()
        let out = Self.destination()
        let additions = ["a.txt", "b"].map { WriterRepackTests.adding(tree.appending(path: $0), into: "") }
        try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(additions: additions), format: .zip,
                                      to: out, options: nil)
        let after = try Self.comments(out)
        #expect(after.archive.isEmpty && after.entries.values.allSatisfy(\.isEmpty))
        try Self.checkEnd(out, comment: [])
    }

    /// Saving a commented zip as 7z or tar works as before (those formats have nowhere to put the comments).
    @Test(arguments: [ArchiveFormat.sevenZip, .tar, .tarGzip])
    func otherOutputFormatsAreUnaffected(_ format: ArchiveFormat) async throws {
        let src = try Self.makeZip(Self.entries, comment: Self.archiveComment)
        let data = try await Self.contents(src)
        let out = WriterRepackTests.destination("out.\(format.fileExtension)")
        try await ArchiveWriter.write(source: try await Archive.open(at: src), changes: ArchiveChangeSet(),
                                      format: format, to: out, options: nil)
        let reopened = try await Archive.open(at: out)
        #expect(reopened.format == format)
        #expect(try await WriterRepackTests.contents(of: reopened) == data)
    }

    /// The comment length of every central-directory record, read straight from the bytes.
    static func centralCommentLengths(_ url: URL) -> [Int] {
        guard let bytes = try? [UInt8](Data(contentsOf: url)), bytes.count >= 22 else { return [] }
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        let eocd = bytes.count - 22
        var p = u32(eocd + 16)
        var result: [Int] = []
        for _ in 0..<u16(eocd + 10) {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4b50 else { return result + [-1] }
            result.append(u16(p + 32))
            p += 46 + u16(p + 28) + u16(p + 30) + u16(p + 32)
        }
        return result
    }

    // MARK: - Split sets

    /// A single zip cut into `x.zip.001`...`.003` (the numbered split of 7-Zip and others): the end record, with the
    /// archive comment, is in the last part only. Returns the set's first part and the unsplit zip.
    static func splitSet(comment: [UInt8]) throws -> (first: URL, whole: URL) {
        let whole = try makeZip(entries, comment: comment)
        let bytes = [UInt8](try Data(contentsOf: whole))
        // Both cuts fall before the end record, so only the last part has it.
        let body = bytes.count - 22 - comment.count
        let cuts = [0, body / 3, 2 * body / 3, bytes.count]
        let dir = Fixtures.tempDir()
        for part in 0..<3 {
            try Data(bytes[cuts[part]..<cuts[part + 1]]).write(to: dir.appending(path: "set.zip.00\(part + 1)"))
        }
        return (dir.appending(path: "set.zip.001"), whole)
    }

    /// The comment is read from the last part of a split set (RepackCopier uses `volumeURLs.last`, not the first
    /// part): a save as a single zip keeps the archive comment and the entry comments, a short one and one over
    /// 16 KiB (the seekable bid of patch 0012 on a set's last part).
    @Test(arguments: [17, 40_000])
    func splitSetSaveKeepsTheComments(_ length: Int) async throws {
        let archive = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) }
        let (first, whole) = try Self.splitSet(comment: archive)
        let source = try await Archive.open(at: first)
        #expect(source.format == .zip)
        let out = Self.destination()
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(removedPaths: ["gone.txt"]),
                                      format: .zip, to: out, options: nil)
        var expected = Self.entryComments
        expected["gone.txt"] = nil
        let after = try Self.comments(out)
        #expect(after.archive == archive)
        #expect(after.entries == expected)
        try Self.checkEnd(out, comment: archive)
        var data = try await Self.contents(whole)
        data["gone.txt"] = nil
        #expect(try await Self.contents(out) == data)
    }
}

/// Kernir patch 0012 at the libarchive level: the zip writer's entry-comment request and archive comment, and the
/// zip reader's entry-comment accessor.
struct ZipCommentPatchTests {
    typealias C = CLibArchiveTests

    /// The central-directory records' comments, parsed from the bytes (32-bit end record only).
    static func centralComments(_ bytes: [UInt8]) -> [[UInt8]] {
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var eocd = bytes.count - 22
        while eocd > 0, u32(eocd) != 0x0605_4b50 { eocd -= 1 }
        var p = u32(eocd + 16)
        var result: [[UInt8]] = []
        for _ in 0..<u16(eocd + 10) {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4b50 else { return result }
            let start = p + 46 + u16(p + 28) + u16(p + 30)
            result.append(Array(bytes[start..<start + u16(p + 32)]))
            p = start + u16(p + 32)
        }
        return result
    }

    /// Writes one entry, arming `comment` first when given.
    static func add(_ a: OpaquePointer?, _ name: String, comment: [UInt8]? = nil, type: mode_t = S_IFREG) {
        if let comment {
            #expect(comment.withUnsafeBytes { kernir_write_zip_next_comment(a, $0.baseAddress, $0.count) } == ARCHIVE_OK)
        }
        #expect(C.add(a, Array(name.utf8), type: type) == ARCHIVE_OK)
    }

    static let big = (0..<65_535).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }

    /// Forced zip64 end records (zip64 EOCD record + locator) with entry comments up to 65 535 bytes and an archive
    /// comment: Python, zipinfo and unzip read the file, and the zip64 records stay where readers look for them.
    @Test func forcedZip64OutputWithComments() async throws {
        let url = Fixtures.tempDir().appending(path: "z64.zip")
        let archive = ZipCommentTests.archiveComment
        withUTF8CType {
            let a = archive_write_new()
            defer { archive_write_free(a) }
            #expect(C.utf8Zip(a) == ARCHIVE_OK)
            #expect(archive_write_set_format_option(a, "zip", "zip64", "1") == ARCHIVE_OK)
            #expect(archive_write_open_filename(a, url.path) == ARCHIVE_OK)
            #expect(archive.withUnsafeBytes { kernir_write_zip_archive_comment(a, $0.baseAddress, $0.count) } == ARCHIVE_OK)
            Self.add(a, "a.txt", comment: ZipCommentTests.rawComment)
            Self.add(a, "d", comment: Array("folder".utf8), type: S_IFDIR)
            Self.add(a, "b.txt")
            Self.add(a, "c.txt", comment: Self.big)
            #expect(archive_write_close(a) == ARCHIVE_OK)
        }
        let after = try ZipCommentTests.comments(url)
        #expect(after.archive == archive)
        #expect(after.names == ["a.txt", "d/", "b.txt", "c.txt"])
        #expect(after.entries == ["a.txt": ZipCommentTests.rawComment, "d/": Array("folder".utf8), "b.txt": [],
                                  "c.txt": Self.big])
        try ZipCommentTests.checkEnd(url, comment: archive)

        let bytes = [UInt8](try Data(contentsOf: url))
        func u32(_ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[i + $1]) << (8 * $1) } }
        func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
        let eocd = bytes.count - 22 - archive.count
        let locator = eocd - 20
        #expect(u32(locator) == 0x0706_4b50)
        let record = Int(u64(locator + 8))
        #expect(record + 56 == locator && u32(record) == 0x0606_4b50)
        #expect(u64(record + 32) == 4)  // entries in the directory
        #expect(Int(u64(record + 48)) + Int(u64(record + 40)) == record)  // directory offset + size

        // Kernir reads it back (seekable: the end record is in the last 16 KiB) and the reader hook sees the comments.
        let session = try ReadSession(url: url, password: nil)
        var seen: [[UInt8]?] = []
        while try session.nextHeader() != nil { seen.append(session.zipEntryComment) }
        #expect(seen == [ZipCommentTests.rawComment, Array("folder".utf8), [], Self.big])
    }

    /// A request covers exactly the next archive_write_header, which takes it even when the header fails; entries
    /// written without one get no comment; a later request replaces an unused one.
    @Test func requestCoversTheNextHeaderOnly() {
        let zip = C.written(format: C.utf8Zip) { a in
            #expect(kernir_write_zip_next_comment(a, "lost", 4) == ARCHIVE_OK)
            let nameless = archive_entry_new()
            defer { archive_entry_free(nameless) }
            archive_entry_set_filetype(nameless, UInt32(S_IFREG))
            #expect(archive_write_header(a, nameless) == ARCHIVE_FAILED)
            Self.add(a, "one.txt")
            Self.add(a, "two.txt", comment: Array("two".utf8))
            Self.add(a, "three.txt")
            #expect(kernir_write_zip_next_comment(a, "replaced", 8) == ARCHIVE_OK)
            Self.add(a, "four.txt", comment: Array("four".utf8))
            Self.add(a, "five.txt", comment: [])
        }
        #expect(Self.centralComments(zip) == [[], Array("two".utf8), [], Array("four".utf8), []])
        // Nothing but the comment changes: the end record is still the last 22 bytes.
        #expect(Array(zip.suffix(22).prefix(4)) == [0x50, 0x4B, 0x05, 0x06] && zip.suffix(2) == [0, 0])
    }

    /// The hooks refuse another format's writer and a comment longer than the 16-bit length field.
    @Test func hooksRefuseOtherWritersAndOverlongComments() {
        let tar = archive_write_new()
        defer { archive_write_free(tar) }
        #expect(archive_write_set_format_pax_restricted(tar) == ARCHIVE_OK)
        #expect(kernir_write_zip_next_comment(tar, "x", 1) == ARCHIVE_FATAL)
        #expect(kernir_write_zip_archive_comment(tar, "x", 1) == ARCHIVE_FATAL)

        let zip = archive_write_new()
        defer { archive_write_free(zip) }
        #expect(archive_write_set_format_zip(zip) == ARCHIVE_OK)
        let tooLong = [UInt8](repeating: 0x41, count: 65_536)
        #expect(tooLong.withUnsafeBytes { kernir_write_zip_next_comment(zip, $0.baseAddress, $0.count) } == ARCHIVE_FATAL)
        #expect(tooLong.withUnsafeBytes { kernir_write_zip_archive_comment(zip, $0.baseAddress, $0.count) } == ARCHIVE_FATAL)
        #expect(kernir_write_zip_next_comment(zip, nil, 0) == ARCHIVE_OK)
        #expect(kernir_write_zip_archive_comment(zip, nil, 0) == ARCHIVE_OK)
    }

    /// The reader hook: comments from the central directory with the seekable reader, 0 with the streaming reader
    /// (no central directory), -1 for another format.
    @Test func readerHookFollowsTheReader() {
        let zip = C.written(format: C.utf8Zip) { a in
            Self.add(a, "one.txt", comment: ZipCommentTests.rawComment)
            Self.add(a, "two.txt")
        }
        let tar = C.written(format: archive_write_set_format_pax_restricted) { C.add($0, Array("a.txt".utf8)) }
        func hook(_ bytes: [UInt8], _ support: (OpaquePointer?) -> Int32) -> [Int32: [[UInt8]]] {
            let a = archive_read_new()
            defer { archive_read_free(a) }
            #expect(support(a) == ARCHIVE_OK)
            return bytes.withUnsafeBytes { buf in
                #expect(archive_read_open_memory(a, buf.baseAddress, buf.count) == ARCHIVE_OK)
                var result: [Int32: [[UInt8]]] = [:]
                var entry: OpaquePointer?
                while archive_read_next_header(a, &entry) == ARCHIVE_OK {
                    var p: UnsafeRawPointer?
                    var n = 0
                    let r = kernir_read_zip_entry_comment(a, &p, &n)
                    result[r, default: []].append(p.map { Array(UnsafeRawBufferPointer(start: $0, count: n)) } ?? [])
                }
                return result
            }
        }
        #expect(hook(zip, archive_read_support_format_zip_seekable) == [1: [ZipCommentTests.rawComment, []]])
        #expect(hook(zip, archive_read_support_format_zip_streamable) == [0: [[], []]])
        #expect(hook(tar, archive_read_support_format_all) == [-1: [[]]])
    }
}
#endif
