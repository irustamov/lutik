import Foundation
import Testing
@testable import KernirCore

/// How a comment's bytes become `ArchiveComment.text`, one rule for every reader (`ArchiveCommentDecoder`).
@Suite struct ArchiveCommentDecoderTests {
    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
    static let privet = "Привет"
    static func bytes(_ text: String, _ encoding: String.Encoding) -> [UInt8] {
        [UInt8](text.data(using: encoding)!)
    }

    static func text(_ bytes: [UInt8], _ requested: ArchiveNameEncoding = .automatic,
                     legacy: String.Encoding? = nil) -> String {
        ArchiveCommentDecoder.text(of: bytes, decoding: NameDecoding(requested: requested, legacy: legacy))
    }

    /// Valid UTF-8 reads as UTF-8 whatever the names use or the caller chose: the scalars are kept as stored (no
    /// NFC), with NUL and CR LF.
    @Test(arguments: [ArchiveNameEncoding.automatic, .specific(.windowsCP1251), .specific(.cp437)])
    func validUTF8IsUTF8(_ requested: ArchiveNameEncoding) {
        for s in ["plain ASCII", "Привет из Kernir 🎉\n", "a\u{0}b\r\nc", "Cafe\u{301} (NFD)", "日本語"] {
            #expect(Array(Self.text(Array(s.utf8), requested, legacy: .cp866).unicodeScalars)
                    == Array(s.unicodeScalars), "\(s)")
        }
    }

    /// One leading UTF-8 BOM is left out of the text (a second stays, as U+FEFF).
    @Test func leadingBOMIsDropped() {
        #expect(Self.text(Self.bom + Array("abc".utf8)) == "abc")
        #expect(Array(Self.text(Self.bom + Self.bom + Array("abc".utf8)).unicodeScalars)
                == Array("\u{FEFF}abc".unicodeScalars))
        #expect(Array(Self.text(Array("a".utf8) + Self.bom).unicodeScalars) == Array("a\u{FEFF}".unicodeScalars))
        #expect(Self.text(Self.bom) == "")
    }

    /// Bytes that are not UTF-8 decode with the caller's `.specific` choice, else the names' legacy encoding, else
    /// CP437; an encoding the bytes are not valid in falls back to CP437.
    @Test func legacyBytesFollowTheNameEncoding() {
        let cp866 = Self.bytes(Self.privet, .cp866)
        let cp1251 = Self.bytes(Self.privet, .windowsCP1251)
        #expect(String(bytes: cp866, encoding: .utf8) == nil && String(bytes: cp1251, encoding: .utf8) == nil)
        let cp437 = { (b: [UInt8]) in String(bytes: b, encoding: .cp437)! }
        #expect(Self.text(cp866) == cp437(cp866))
        #expect(Self.text(cp866, legacy: .cp866) == Self.privet)
        #expect(Self.text(cp1251, legacy: .windowsCP1251) == Self.privet)
        #expect(Self.text(cp1251, .specific(.windowsCP1251)) == Self.privet)
        #expect(Self.text(cp1251, .specific(.windowsCP1251), legacy: .cp866) == Self.privet)
        #expect(Self.text(cp866, .specific(.cp866), legacy: .windowsCP1251) == Self.privet)
        #expect(Self.text(cp866, .specific(.utf8)) == cp437(cp866))
        #expect(Self.text(cp866, legacy: .utf8) == cp437(cp866))
        // A BOM in front of bytes that are not UTF-8 is not a BOM: every byte is decoded.
        #expect(Self.text(Self.bom + [0xFF]) == cp437(Self.bom + [0xFF]))
    }

    /// CP437 maps every byte, so box drawing and the DOS control bytes decode.
    @Test func cp437BoxDrawing() {
        #expect(Self.text([0xC9, 0xCD, 0xBB, 0x0D, 0x0A, 0xB0, 0xB1, 0xB2, 0xDB]) == "╔═╗\r\n░▒▓█")
    }
}

#if os(macOS)
/// `ArchiveReading.comment` (ZIP's end-of-central-directory comment) and `ArchiveChangeSet.comment` on save.
@Suite("Archive comments read and written", .timeLimit(.minutes(3)))
struct ArchiveCommentTests {
    typealias Z = ZipCommentTests

    static func open(_ url: URL, password: String? = nil,
                     nameEncoding: ArchiveNameEncoding = .automatic) async throws -> any ArchiveReading {
        try await Archive.open(at: url, password: password, nameEncoding: nameEncoding)
    }

    /// A copy of a corpus zip whose 22-byte end record (comment length 0) gets `comment`, byte for byte: its names
    /// and flags stay as stored (Python's zipfile would rewrite legacy names as UTF-8).
    static func corpusZip(_ rel: String, comment: [UInt8]) throws -> URL {
        var bytes = [UInt8](try Data(contentsOf: Corpus.root.appending(path: rel)))
        let eocd = bytes.count - 22
        try #require(eocd > 0 && Array(bytes[eocd..<eocd + 4]) == [0x50, 0x4B, 0x05, 0x06])
        try #require(bytes[eocd + 20] == 0 && bytes[eocd + 21] == 0)
        bytes[eocd + 20] = UInt8(comment.count & 0xFF)
        bytes[eocd + 21] = UInt8(comment.count >> 8)
        let url = Fixtures.tempDir().appending(path: (rel as NSString).lastPathComponent)
        try Data(bytes + comment).write(to: url)
        return url
    }

    // MARK: - Read

    @Test(arguments: ["Kernir ASCII comment\r\nsecond line", "Привет из Kernir 🎉\nКомментарий архива", "x"])
    func zipCommentIsRead(_ text: String) async throws {
        let src = try Z.makeZip(Z.entries, comment: Array(text.utf8))
        let comment = try #require(try await Self.open(src).comment)
        #expect(comment == ArchiveComment(bytes: Array(text.utf8), text: text, isWritable: true))
    }

    /// The stored bytes keep the BOM, the text drops it.
    @Test func bomIsInTheBytesOnly() async throws {
        let bytes = ArchiveCommentDecoderTests.bom + Array("Привет".utf8)
        let src = try Z.makeZip(Z.entries, comment: bytes)
        let comment = try #require(try await Self.open(src).comment)
        #expect(comment.bytes == bytes)
        #expect(comment.text == "Привет")
    }

    /// Raw bytes (NUL, CR LF, CP437, invalid UTF-8) come back verbatim; the text is their CP437 reading, since the
    /// names are ASCII.
    @Test func rawBytesAreKeptVerbatim() async throws {
        let src = try Z.makeZip(Z.entries, comment: Z.archiveComment)
        let reader = try await Self.open(src)
        #expect(reader.legacyNameEncoding == nil)
        let comment = try #require(reader.comment)
        #expect(comment.bytes == Z.archiveComment)
        #expect(comment.text == String(bytes: Z.archiveComment, encoding: .cp437))
        #expect(comment.text.hasPrefix("Kernir ZIP: scene release readme\r\nREAD\u{0}\r\n╔═╗"))
    }

    @Test func noCommentIsNil() async throws {
        #expect(try await Self.open(try Z.makeZip(Z.entries, comment: [])).comment == nil)
        // Entry comments alone are no archive comment.
        #expect(try await Self.open(Corpus.root.appending(path: "zip/entry-comments.zip")).comment == nil)
        // An end record followed by other data: the comment does not reach EOF, so none is reported.
        #expect(try await Self.open(try Z.zipWithTrailingData(100)).comment == nil)
    }

    /// The archive comment and the entry comments are separate: only the archive's is reported.
    @Test func entryCommentsStayOutOfTheArchiveComment() async throws {
        let src = try Z.makeZip(Z.entries, comment: Array("archive".utf8))
        #expect(try await Self.open(src).comment?.bytes == Array("archive".utf8))
    }

    /// A 48 000-byte UTF-8 comment, past libarchive's old 16 KiB search, with entry comments.
    @Test func longUTF8CommentFixture() async throws {
        let url = Corpus.root.appending(path: "zip/comment-long-utf8-entries.zip")
        let reader = try await Self.open(url)
        let comment = try #require(reader.comment)
        #expect(comment.bytes.count == 48_000)
        #expect(comment.bytes == (try Z.comments(url).archive))
        #expect(comment.text == String(decoding: comment.bytes, as: UTF8.self))
        #expect(comment.text.contains("Привет") && comment.isWritable)
        #expect(try Z.readerHook(url).kinds == [1])
    }

    /// A legacy comment decodes with the encoding the archive's names use, or the one the caller picked.
    @Test func legacyCommentFollowsTheNames() async throws {
        let text = "Комментарий к архиву"
        let src = try Self.corpusZip("zip/legacy-cp866.zip", comment: ArchiveCommentDecoderTests.bytes(text, .cp866))
        let automatic = try await Self.open(src)
        #expect(automatic.legacyNameEncoding == .cp866)
        #expect(automatic.comment?.text == text)
        let chosen = try await Self.open(src, nameEncoding: .specific(.windowsCP1251))
        #expect(chosen.comment?.text == String(bytes: ArchiveCommentDecoderTests.bytes(text, .cp866),
                                                encoding: .windowsCP1251))
        #expect(chosen.comment?.bytes == automatic.comment?.bytes)

        // ASCII names: no legacy encoding, so CP437, unless the caller picks one.
        let ascii = try Z.makeZip(Z.entries, comment: ArchiveCommentDecoderTests.bytes(text, .windowsCP1251))
        #expect(try await Self.open(ascii).comment?.text
                == String(bytes: ArchiveCommentDecoderTests.bytes(text, .windowsCP1251), encoding: .cp437))
        #expect(try await Self.open(ascii, nameEncoding: .specific(.windowsCP1251)).comment?.text == text)
    }

    /// A split set's comment is in its last part; opening any part reports it, not writable.
    @Test(arguments: ["sz-comment.zip.001", "sz-comment.zip.002", "sz-comment.zip.003"])
    func splitSetComment(_ part: String) async throws {
        let reader = try await Self.open(Corpus.root.appending(path: "multivolume/\(part)"))
        #expect(reader.volumeURLs.count == 3)
        #expect(reader.comment == ArchiveComment(
            bytes: Array("Kernir split-volume fixture.\nThis comment lives in the last part.".utf8),
            text: "Kernir split-volume fixture.\nThis comment lives in the last part.", isWritable: false))
    }

    /// A long comment in a split set's last part, cut so no other part holds the end record.
    @Test func splitSetLongComment() async throws {
        let bytes = Array(String(repeating: "Комментарий 0123456789\n", count: 1_000).utf8)
        let (first, _) = try Z.splitSet(comment: bytes)
        let comment = try #require(try await Self.open(first).comment)
        #expect(comment.bytes == bytes && !comment.isWritable)
    }

    /// A spanned `.z01 .z02 .zip` set: the comment is in the `.zip`, whichever part is opened; not writable.
    @Test(arguments: ["span.z01", "span.z02", "span.zip"])
    func spannedSetComment(_ part: String) async throws {
        let dir = Fixtures.tempDir()
        for name in ["span.z01", "span.z02"] {
            try FileManager.default.copyItem(at: Corpus.root.appending(path: "multivolume/\(name)"),
                                             to: dir.appending(path: name))
        }
        let text = "Spanned comment, last part only"
        let last = try Self.corpusZip("multivolume/span.zip", comment: Array(text.utf8))
        try FileManager.default.moveItem(at: last, to: dir.appending(path: "span.zip"))
        let reader = try await Self.open(dir.appending(path: part))
        #expect(reader.volumeURLs.count == 3)
        #expect(reader.comment == ArchiveComment(bytes: Array(text.utf8), text: text, isWritable: false))
    }

    /// A self-extractor's stub in front of the zip does not hide the comment, which is read from the file's end.
    @Test func commentBehindAnSFXStub() async throws {
        let src = try Z.makeZip(Z.entries, comment: Array("after a stub".utf8))
        let sfx = Fixtures.tempDir().appending(path: "sfx.zip")
        try Data([UInt8](repeating: 0x4D, count: 4096) + [UInt8](try Data(contentsOf: src))).write(to: sfx)
        #expect(try await Self.open(sfx).comment?.text == "after a stub")
    }

    /// A 65 535-byte comment (the field's maximum) is read whole, and a `.keep` save with an edit keeps every byte.
    @Test func longestFieldComment() async throws {
        let bytes = (0..<65_535).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }
        let reader = try await Self.open(try Z.makeZip(Z.entries, comment: bytes))
        #expect(reader.comment?.bytes == bytes)
        let out = Z.destination()
        try await ArchiveWriter.write(source: reader, changes: ArchiveChangeSet(removedPaths: ["gone.txt"]),
                                      format: .zip, to: out, options: nil)
        #expect(try await Self.open(out).comment?.bytes == bytes)
    }

    /// Only ZIP comments are read in 0.1.0: 7z and tar have none, gzip's FCOMMENT and RAR's are not read yet.
    @Test(arguments: ["7z/lzma2.7z", "7z/encrypted-data.7z", "tar/basic.tar", "tar/basic.tar.gz", "single/comment.txt.gz",
                      "third-party/rar/rar5-stored.rar", "third-party/rar/rar4-best.rar",
                      "third-party/rar-multivolume/rar5-multi.part01.rar"])
    func otherFormatsHaveNone(_ rel: String) async throws {
        let reader = try await Self.open(Corpus.root.appending(path: rel))
        #expect(reader.format != .zip)
        #expect(reader.comment == nil)
    }

    // MARK: - Write

    static func writeError(_ source: (any ArchiveReading)?, _ changes: ArchiveChangeSet, format: ArchiveFormat = .zip,
                           to url: URL, options: ArchiveWriteOptions? = nil) async -> ArchiveError? {
        do {
            try await ArchiveWriter.write(source: source, changes: changes, format: format, to: url, options: options)
            return nil
        } catch let error as ArchiveError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }

    /// set → ⌘S → read: the new text, as UTF-8; entry comments and contents stay; other readers agree.
    @Test(arguments: ["New ASCII comment", "Новый комментарий ✓ 🎉\r\nвторая строка", "a\u{0}b"])
    func setSaveRead(_ text: String) async throws {
        let src = try Z.makeZip(Z.entries, comment: Z.archiveComment)
        let before = try await Z.contents(src)
        let source = try await Self.open(src)
        try await ArchiveWriter.write(source: source, changes: ArchiveChangeSet(comment: .set(text)), format: .zip,
                                      to: src, options: nil)
        let bytes = Array(text.utf8)
        #expect(try await Self.open(src).comment == ArchiveComment(bytes: bytes, text: text, isWritable: true))
        let after = try Z.comments(src)
        #expect(after.archive == bytes)
        #expect(after.entries == Z.entryComments)
        try Z.checkEnd(src, comment: bytes)
        #expect(try await Z.contents(src) == before)
    }

    /// `.set` on a Zip64 source, in place: the new comment reads back; contents and entry comments stay.
    @Test func setOnAZip64Source() async throws {
        let src = try Z.makeZip(Z.entries, comment: Array("old".utf8), zip64: true)
        let before = try await Z.contents(src)
        try await ArchiveWriter.write(source: try await Self.open(src), changes: ArchiveChangeSet(comment: .set("новый")),
                                      format: .zip, to: src, options: nil)
        #expect(try await Self.open(src).comment?.text == "новый")
        #expect(try await Z.contents(src) == before)
        #expect(try Z.comments(src).entries == Z.entryComments)
    }

    /// `.remove` and `.set("")` write no comment; entry comments stay.
    @Test(arguments: [ArchiveChangeSet.CommentChange.remove, .set("")])
    func removeWritesNone(_ change: ArchiveChangeSet.CommentChange) async throws {
        let src = try Z.makeZip(Z.entries, comment: Z.archiveComment)
        let out = Z.destination()
        try await ArchiveWriter.write(source: try await Self.open(src), changes: ArchiveChangeSet(comment: change),
                                      format: .zip, to: out, options: nil)
        #expect(try await Self.open(out).comment == nil)
        #expect(try Z.comments(out).entries == Z.entryComments)
        try Z.checkEnd(out, comment: [])
    }

    /// A comment on a new zip, and on a zip converted from 7z, together with other edits.
    @Test func setOnNewAndConvertedArchives() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data("a".utf8)], in: dir)
        let add = ArchiveChangeSet.Addition(sourceURL: dir.appending(path: "a.txt"), destinationDirectory: "")
        let fresh = Z.destination()
        try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(additions: [add], comment: .set("new")),
                                      format: .zip, to: fresh, options: nil)
        #expect(try await Self.open(fresh).comment?.text == "new")
        try Z.checkEnd(fresh, comment: Array("new".utf8))

        let sevenZip = try await Self.open(Corpus.root.appending(path: "7z/lzma2.7z"))
        let converted = Z.destination()
        try await ArchiveWriter.write(source: sevenZip, changes: ArchiveChangeSet(additions: [add], comment: .set("из 7z")),
                                      format: .zip, to: converted, options: nil)
        let reader = try await Self.open(converted)
        #expect(reader.comment?.text == "из 7z")
        #expect(reader.entries.contains { $0.path == "a.txt" })
    }

    /// An encrypted source keeps its encryption and gets the new comment, which reads without the password.
    @Test(arguments: [ArchiveEncryption.zipCrypto, .aes256])
    func setOnAnEncryptedZip(_ encryption: ArchiveEncryption) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["secret.txt": Data("secret".utf8)], in: dir)
        let src = dir.appending(path: "enc.zip")
        try await ArchiveWriter.write(
            source: nil, changes: ArchiveChangeSet(additions: [.init(sourceURL: dir.appending(path: "secret.txt"),
                                                                     destinationDirectory: "")]),
            format: .zip, to: src, options: ArchiveWriteOptions(encryption: encryption, password: "pw"))
        try await ArchiveWriter.write(source: try await Self.open(src, password: "pw"),
                                      changes: ArchiveChangeSet(comment: .set("Пароль: спросить")),
                                      format: .zip, to: src, options: nil)
        let plain = try await Self.open(src)
        #expect(plain.comment?.text == "Пароль: спросить")
        #expect(plain.encryption == encryption)
        #expect(try await Z.contents(src, password: "pw")["secret.txt"] != nil)
    }

    /// `maximumWritableLength` UTF-8 bytes are written (and the output still opens through the seekable reader, so
    /// entry comments survive); one byte more is refused before anything is written.
    @Test func lengthLimit() async throws {
        let max = ArchiveComment.maximumWritableLength
        let src = try Z.makeZip(Z.entries, comment: Z.archiveComment)
        let fits = String(repeating: "ж", count: max / 2)
        #expect(fits.utf8.count == max)
        let out = Z.destination()
        try await ArchiveWriter.write(source: try await Self.open(src), changes: ArchiveChangeSet(comment: .set(fits)),
                                      format: .zip, to: out, options: nil)
        #expect(try await Self.open(out).comment?.text == fits)
        #expect(try Z.readerHook(out).kinds == [1])
        #expect(try Z.comments(out).entries == Z.entryComments)

        let before = Fixtures.sha256(src)
        for tooLong in [fits + "a", String(repeating: "a", count: max + 1), String(repeating: "🎉", count: max / 4 + 1)] {
            let error = await Self.writeError(try await Self.open(src), ArchiveChangeSet(comment: .set(tooLong)), to: src)
            guard case .io(let message)? = error else { Issue.record("expected .io, got \(String(describing: error))"); continue }
            #expect(message.contains("long"), "\(message)")
            #expect(Fixtures.sha256(src) == before)
            let fresh = Z.destination()
            #expect(await Self.writeError(nil, ArchiveChangeSet(comment: .set(tooLong)), to: fresh) != nil)
            #expect(!FileManager.default.fileExists(atPath: fresh.path))
        }
    }

    /// Text holding a ZIP end-record signature (end of central directory, Zip64 end record, Zip64 locator) is
    /// refused before anything is written: "PK\u{5}\u{6}" and 18 NULs would end the file with a fake end record that
    /// every reader takes first, listing the archive as empty. Anywhere in the text, alone or not.
    @Test(arguments: ["PK\u{5}\u{6}", "PK\u{6}\u{6}", "PK\u{6}\u{7}"])
    func endRecordSignaturesAreRefused(_ signature: String) async throws {
        let src = try Z.makeZip(Z.entries, comment: Z.archiveComment)
        let before = Fixtures.sha256(src)
        let nuls = String(repeating: "\u{0}", count: 18)
        for text in ["readme " + signature + nuls, signature, "a" + signature + "b", signature + nuls] {
            let error = await Self.writeError(try await Self.open(src), ArchiveChangeSet(comment: .set(text)), to: src)
            #expect(error == .io("The comment contains bytes a ZIP archive cannot hold"), "\(Array(text.utf8))")
            #expect(Fixtures.sha256(src) == before)
            let fresh = Z.destination()
            #expect(await Self.writeError(nil, ArchiveChangeSet(comment: .set(text)), to: fresh)
                    == .io("The comment contains bytes a ZIP archive cannot hold"))
            #expect(!FileManager.default.fileExists(atPath: fresh.path))
        }
    }

    /// The whole text is searched, not only its last 22 bytes: a fake end record followed by more text (its own
    /// comment length counts that text, so it still reaches EOF) lists the archive as empty in every reader too.
    @Test func endRecordEarlierInTheTextIsRefused() async throws {
        let src = try Z.makeZip(Z.entries, comment: Z.archiveComment)
        let before = Fixtures.sha256(src)
        let nuls = String(repeating: "\u{0}", count: 16)
        let shapes = [("PK\u{5}\u{6}" + nuls + "\u{5}\u{0}hello", 27),
                      ("x PK\u{5}\u{6}" + nuls + "\u{1E}\u{0}" + String(repeating: "a", count: 30), 52)]
        for (text, fromEnd) in shapes {
            let bytes = Array(text.utf8)
            let start = bytes.indices.first { bytes[$0...].starts(with: [0x50, 0x4B, 0x05, 0x06]) }
            #expect(start.map { bytes.count - $0 } == fromEnd, "the signature is \(fromEnd) bytes from the end")
            let error = await Self.writeError(try await Self.open(src), ArchiveChangeSet(comment: .set(text)), to: src)
            #expect(error == .io("The comment contains bytes a ZIP archive cannot hold"), "\(bytes)")
            #expect(Fixtures.sha256(src) == before)
            let fresh = Z.destination()
            #expect(await Self.writeError(nil, ArchiveChangeSet(comment: .set(text)), to: fresh)
                    == .io("The comment contains bytes a ZIP archive cannot hold"))
            #expect(!FileManager.default.fileExists(atPath: fresh.path))
        }
    }

    /// The signature check runs in planning, first: with a missing addition in the same save, the comment refusal
    /// is what is reported (in place and for a new archive), not the addition's, and nothing is written.
    @Test func endRecordRefusalComesBeforeTheAdditions() async throws {
        let src = try Z.makeZip(Z.entries, comment: Z.archiveComment)
        let before = Fixtures.sha256(src)
        let missing = ArchiveChangeSet.Addition(sourceURL: Fixtures.tempDir().appending(path: "missing.txt"),
                                                destinationDirectory: "")
        let text = "readme PK\u{5}\u{6}" + String(repeating: "\u{0}", count: 18)
        let changes = ArchiveChangeSet(additions: [missing], comment: .set(text))

        // Control: without the signature, the missing addition is refused, with another message.
        let plain = await Self.writeError(try await Self.open(src),
                                          ArchiveChangeSet(additions: [missing], comment: .set("readme")), to: src)
        #expect(plain != nil)
        #expect(plain != .io("The comment contains bytes a ZIP archive cannot hold"))
        #expect(Fixtures.sha256(src) == before)

        let inPlace = await Self.writeError(try await Self.open(src), changes, to: src)
        #expect(inPlace == .io("The comment contains bytes a ZIP archive cannot hold"))
        #expect(Fixtures.sha256(src) == before)
        let fresh = Z.destination()
        #expect(await Self.writeError(nil, changes, to: fresh)
                == .io("The comment contains bytes a ZIP archive cannot hold"))
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
    }

    /// "PK" and the other ZIP signatures (local header, central directory) are ordinary comment text.
    @Test(arguments: ["PK", "readme PK\u{5}" + String(repeating: "\u{0}", count: 18), "PK\u{3}\u{4}", "PK\u{1}\u{2}",
                      "PK\u{6}", "P K\u{5}\u{6}"])
    func otherPKTextIsKept(_ text: String) async throws {
        let src = try Z.makeZip(Z.entries, comment: [])
        let before = try await Self.open(src)
        let out = Z.destination()
        try await ArchiveWriter.write(source: before, changes: ArchiveChangeSet(comment: .set(text)), format: .zip,
                                      to: out, options: nil)
        let after = try await Self.open(out)
        #expect(after.entries.map(\.path).sorted() == before.entries.map(\.path).sorted())
        #expect(after.comment?.bytes == Array(text.utf8))
        try Z.checkEnd(out, comment: Array(text.utf8))
    }

    /// A format without `supportsComments` refuses `.set` up front (Kernir's own check, before the additions are
    /// walked: a missing addition is not what is reported) and writes nothing; `.remove` and `.set("")` just write it.
    @Test(arguments: [ArchiveFormat.sevenZip, .tar, .tarGzip])
    func formatsWithoutComments(_ format: ArchiveFormat) async throws {
        let src = try Z.makeZip(Z.entries, comment: Z.archiveComment)
        let source = try await Self.open(src)
        let out = Fixtures.tempDir().appending(path: "out.\(format.fileExtension)")
        let missing = ArchiveChangeSet.Addition(sourceURL: Fixtures.tempDir().appending(path: "missing.txt"),
                                                destinationDirectory: "")
        for changes in [ArchiveChangeSet(comment: .set("x")), ArchiveChangeSet(additions: [missing], comment: .set("x"))] {
            let error = await Self.writeError(source, changes, format: format, to: out)
            guard case .io(let message)? = error else {
                Issue.record("expected .io, got \(String(describing: error))"); return
            }
            #expect(message == "\(format.displayName) archives cannot have a comment")
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }
        for change in [ArchiveChangeSet.CommentChange.remove, .set("")] {
            try? FileManager.default.removeItem(at: out)
            #expect(await Self.writeError(source, ArchiveChangeSet(comment: change), format: format, to: out) == nil)
            #expect(try await Self.open(out).comment == nil)
        }
    }

    /// `.keep` still writes the source's bytes when other edits come with it, and the reader agrees.
    @Test func keepWithEditsKeepsTheBytes() async throws {
        let src = try Z.makeZip(Z.entries, comment: Z.archiveComment)
        let out = Z.destination()
        try await ArchiveWriter.write(source: try await Self.open(src),
                                      changes: ArchiveChangeSet(removedPaths: ["gone.txt"]), format: .zip, to: out,
                                      options: nil)
        #expect(try await Self.open(out).comment?.bytes == Z.archiveComment)
    }
}
#endif
