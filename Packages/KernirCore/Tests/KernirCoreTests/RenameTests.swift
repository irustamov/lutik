import CLibArchive
import Foundation
import Testing
@testable import KernirCore

/// Engine: `ArchiveChangeSet.renamedPaths` (a prefix map from source paths to final paths) and
/// `Addition.archiveName`. A renamed entry keeps its data, dates, permissions and zip comments; refusals throw before
/// anything is written.
@Suite("Rename entries", .timeLimit(.minutes(3)))
struct RenameTests {
    typealias Repack = WriterRepackTests

    /// The repack tree (`WriterRepackTests.files` plus the symlink `link`) written by Kernir as `format`.
    static func makeSource(_ format: ArchiveFormat, password: String? = nil) async throws -> URL {
        let tree = try Repack.makeTree()
        let out = Fixtures.tempDir().appending(path: "src.\(format.fileExtension)")
        let additions = ["a.txt", "b", "empty", "link", "run.sh", "secret.txt"].map {
            ArchiveChangeSet.Addition(sourceURL: tree.appending(path: $0), destinationDirectory: "")
        }
        try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(additions: additions), format: format,
                                      to: out, password: password)
        return out
    }

    /// Test-side oracle for the prefix map: the nearest key at or above `path` wins.
    static func mapped(_ path: String, _ renames: [String: String]) -> String {
        let key = renames.keys.filter { path == $0 || path.hasPrefix($0 + "/") }.max { $0.count < $1.count }
        guard let key, let value = renames[key] else { return path }
        return value + path.dropFirst(key.count)
    }

    /// `out` holds exactly the source's entries under their mapped paths, each with the same kind, size, date,
    /// permissions and data, and the headers come in source order (7z: the entries with data; its writer places
    /// empty entries itself). `checkOrder` false: the test-side raw header names cannot be mapped (legacy names).
    static func expectRenamed(_ source: any ArchiveReading, _ sourceURL: URL, _ out: URL, _ renames: [String: String],
                              password: String? = nil, checkOrder: Bool = true,
                              sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let result = try await Archive.open(at: out, password: password)
        let before = Repack.entryMap(source)
        let after = Repack.entryMap(result)
        #expect(Set(after.keys) == Set(before.keys.map { mapped($0, renames) }), sourceLocation: sourceLocation)
        for (path, entry) in before {
            guard let renamed = after[mapped(path, renames)] else { continue }
            #expect(renamed.isDirectory == entry.isDirectory, "\(path)", sourceLocation: sourceLocation)
            #expect(renamed.size == entry.size, "\(path)", sourceLocation: sourceLocation)
            #expect(renamed.modificationDate == entry.modificationDate, "\(path)", sourceLocation: sourceLocation)
            #expect(renamed.permissions == entry.permissions, "\(path)", sourceLocation: sourceLocation)
        }
        let data = try await Repack.contents(of: source)
        let expected = Dictionary(uniqueKeysWithValues: data.map { (mapped($0.key, renames), $0.value) })
        #expect(try await Repack.contents(of: result) == expected, sourceLocation: sourceLocation)
        guard checkOrder else { return }
        func headers(_ url: URL) throws -> [Repack.RawHeader] {
            try Repack.rawHeaders(url, password: password).filter { source.format != .sevenZip || $0.size > 0 }
        }
        let order = try headers(sourceURL).map { mapped($0.path, renames) }
        #expect(try headers(out).map(\.path) == order, sourceLocation: sourceLocation)
    }

    static func save(_ source: any ArchiveReading, _ changes: ArchiveChangeSet, _ format: ArchiveFormat,
                     options: ArchiveWriteOptions? = nil) async throws -> URL {
        let out = Repack.destination("out.\(format.fileExtension)")
        try await ArchiveWriter.write(source: source, changes: changes, format: format, to: out, options: options)
        return out
    }

    /// The write throws `expected` and writes nothing: in place the source is untouched, and a new destination
    /// does not appear.
    static func expectRefused(_ sourceURL: URL, _ changes: ArchiveChangeSet, _ format: ArchiveFormat,
                              _ matches: (ArchiveError) -> Bool,
                              sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let source = try await Archive.open(at: sourceURL)
        let before = Fixtures.sha256(sourceURL)
        let fresh = Repack.destination("new.\(format.fileExtension)")
        for destination in [sourceURL, fresh] {
            do {
                try await ArchiveWriter.write(source: source, changes: changes, format: format, to: destination,
                                              options: nil)
                Issue.record("expected a refusal for \(changes.renamedPaths)", sourceLocation: sourceLocation)
            } catch let error as ArchiveError {
                #expect(matches(error), "got \(error)", sourceLocation: sourceLocation)
            }
        }
        #expect(Fixtures.sha256(sourceURL) == before, sourceLocation: sourceLocation)
        #expect(!FileManager.default.fileExists(atPath: fresh.path), sourceLocation: sourceLocation)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fresh.deletingLastPathComponent().path) == [],
                sourceLocation: sourceLocation)
    }

    static func isIO(_ error: ArchiveError) -> Bool {
        if case .io = error { return true }
        return false
    }

    // MARK: - Renames

    @Test(arguments: ArchiveFormat.writable)
    func renamesAFile(_ format: ArchiveFormat) async throws {
        let url = try await Self.makeSource(format)
        let source = try await Archive.open(at: url)
        let renames = ["a.txt": "renamed.txt", "b/d/e.bin": "b/d/random.bin"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), format)
        try await Self.expectRenamed(source, url, out, renames)
    }

    @Test(arguments: ArchiveFormat.writable)
    func renamesAFolderWithItsSubtree(_ format: ArchiveFormat) async throws {
        let url = try await Self.makeSource(format)
        let source = try await Archive.open(at: url)
        let renames = ["b": "Bee folder", "empty": "still empty"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), format)
        try await Self.expectRenamed(source, url, out, renames)
        #expect(try await Repack.contents(of: Archive.open(at: out))["Bee folder/d/e.bin"] != nil)
    }

    /// A key that is a folder and a deeper key inside it: the deeper key wins for its own subtree.
    @Test func nestedKeysUseTheNearestOne() async throws {
        let url = try await Self.makeSource(.zip)
        let source = try await Archive.open(at: url)
        let renames = ["b": "B", "b/d": "B/D", "b/c.txt": "B/see.txt"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .zip)
        try await Self.expectRenamed(source, url, out, renames)
        #expect(Set(try await Repack.contents(of: Archive.open(at: out)).keys)
                .isSuperset(of: ["B/see.txt", "B/D/e.bin"]))
    }

    /// Zip entries `top/x.txt` and `top/sub/y.txt` with no folder headers: renaming the implicit folder moves both.
    @Test func renamesAnImplicitFolder() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let url = SyntheticZip.write(SyntheticZip.stored([
            (path: "top/x.txt", dosTime: t, data: Array("x".utf8)),
            (path: "top/sub/y.txt", dosTime: t, data: Array("y".utf8)),
            (path: "other.txt", dosTime: t, data: Array("o".utf8)),
        ]))
        let source = try await Archive.open(at: url)
        #expect(Repack.entryMap(source)["top"]?.isDirectory == true)
        for renames in [["top": "moved"], ["top/sub": "top/renamed sub"]] {
            let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .zip)
            try await Self.expectRenamed(source, url, out, renames)
        }
    }

    @Test(arguments: ArchiveFormat.writable)
    func caseOnlyRenameIsAllowed(_ format: ArchiveFormat) async throws {
        let url = try await Self.makeSource(format)
        let source = try await Archive.open(at: url)
        let renames = ["a.txt": "A.txt", "b": "B"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), format)
        try await Self.expectRenamed(source, url, out, renames)
        let paths = try await Archive.open(at: out).entries.map(\.path)
        #expect(paths.contains("A.txt") && !paths.contains("a.txt"))
    }

    /// A name that differs only in case from a sibling is a different name. (Each twin is extracted on its own: on a
    /// case-insensitive volume one would overwrite the other.)
    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .tar])
    func caseTwinOfASiblingIsAllowed(_ format: ArchiveFormat) async throws {
        let url = try await Self.makeSource(format)
        let source = try await Archive.open(at: url)
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: ["secret.txt": "A.TXT"]), format)
        let result = try await Archive.open(at: out)
        #expect(Set(result.entries.map(\.path))
                == Set(source.entries.map(\.path)).subtracting(["secret.txt"]).union(["A.TXT"]))
        func extracted(_ reader: any ArchiveReading, _ path: String) async throws -> String {
            let dir = Fixtures.tempDir()
            try await reader.extract([path], to: dir, progress: nil)
            return Fixtures.sha256(dir.appending(path: path))
        }
        #expect(try await extracted(result, "A.TXT") == extracted(source, "secret.txt"))
        #expect(try await extracted(result, "a.txt") == extracted(source, "a.txt"))
    }

    /// Two entries trading names do not collide: the check runs on final paths of kept entries.
    @Test func swappingNamesIsAllowed() async throws {
        let url = try await Self.makeSource(.sevenZip)
        let source = try await Archive.open(at: url)
        let renames = ["a.txt": "secret.txt", "secret.txt": "a.txt"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .sevenZip)
        let before = try await Repack.contents(of: source)
        let after = try await Repack.contents(of: Archive.open(at: out))
        #expect(after["a.txt"] == before["secret.txt"] && after["secret.txt"] == before["a.txt"])
    }

    /// An NFD key selects the NFC-listed entry, and an NFD value is stored NFC.
    @Test func keysAndValuesAreNormalized() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["caf\u{E9}.txt": Data("cafe".utf8), "x.txt": Data("x".utf8)], in: dir)
        let url = Fixtures.tempDir().appending(path: "src.zip")
        try await ArchiveWriter.write(source: nil, changes: WriterTests.adding(dir.appending(path: "caf\u{E9}.txt"),
                                                                                  dir.appending(path: "x.txt")),
                                      format: .zip, to: url, options: nil)
        let source = try await Archive.open(at: url)
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: ["cafe\u{301}.txt": "r\u{E9}sum\u{E9}.txt",
                                                                              "x.txt": "nai\u{308}ve.txt"]), .zip)
        let paths = Set(try await Archive.open(at: out).entries.map(\.path))
        #expect(paths == ["r\u{E9}sum\u{E9}.txt", "na\u{EF}ve.txt"])
    }

    @Test func identityRenameChangesNothing() async throws {
        let url = try await Self.makeSource(.zip)
        let source = try await Archive.open(at: url)
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: ["a.txt": "a.txt", "b": "b"]), .zip)
        try await Self.expectRenamed(source, url, out, [:])
    }

    // MARK: - Refusals

    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .tarGzip])
    func nfdSpellingOfAnExistingNameIsRefused(_ format: ArchiveFormat) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["\u{E9}t\u{E9}.txt": Data("e".utf8), "x.txt": Data("x".utf8)], in: dir)
        let url = Fixtures.tempDir().appending(path: "src.\(format.fileExtension)")
        try await ArchiveWriter.write(source: nil, changes: WriterTests.adding(dir.appending(path: "\u{E9}t\u{E9}.txt"),
                                                                                  dir.appending(path: "x.txt")),
                                      format: format, to: url, options: nil)
        try await Self.expectRefused(url, ArchiveChangeSet(renamedPaths: ["x.txt": "e\u{301}te\u{301}.txt"]), format,
                                     Self.isIO)
        try await Self.expectRefused(url, ArchiveChangeSet(renamedPaths: ["x.txt": "\u{E9}t\u{E9}.txt"]), format,
                                     Self.isIO)
    }

    /// Renaming onto a kept entry's final path, a folder onto a folder (explicit or implicit), into a file, or a
    /// folder into itself.
    @Test(arguments: [
        ["a.txt": "secret.txt"],
        ["a.txt": "b"],
        ["b": "empty"],
        ["empty": "b/d"],
        ["run.sh": "b/c.txt"],
        ["a.txt": "run.sh/a.txt"],
        ["b": "b/inner"],
        ["a.txt": "z.txt", "secret.txt": "z.txt"],
        ["b/c.txt": "b/e.txt", "b/d": "b/e.txt"],
    ])
    func renameOntoAnExistingNameIsRefused(_ renames: [String: String]) async throws {
        for format in [ArchiveFormat.zip, .sevenZip, .tar] {
            let url = try await Self.makeSource(format)
            try await Self.expectRefused(url, ArchiveChangeSet(renamedPaths: renames), format, Self.isIO)
        }
    }

    /// Two keys that land a folder and a file on one path, where only the duplicate-path check sees it: `b` goes to
    /// `q/e.bin` while `b/d` goes to `q`, so `b/d/e.bin` lands on `q/e.bin` too.
    @Test func nestedKeysLandingOnOnePathAreRefused() async throws {
        let url = try await Self.makeSource(.zip)
        try await Self.expectRefused(url, ArchiveChangeSet(removedPaths: ["b/c.txt"],
                                                           renamedPaths: ["b": "q/e.bin", "b/d": "q"]), .zip, Self.isIO)
    }

    /// The map allows a move (the 0.1.0 apps do not offer one): an entry its own key moves into a renamed folder is
    /// not a collision with that folder.
    @Test func movingIntoARenamedFolderIsAllowed() async throws {
        let url = try await Self.makeSource(.tarGzip)
        let source = try await Archive.open(at: url)
        let renames = ["b": "B", "a.txt": "B/a.txt", "empty": "B/d/empty"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .tarGzip)
        try await Self.expectRenamed(source, url, out, renames)
    }

    /// Zip `top/x.txt` + `dest/y.txt`, both folders implicit: moving `top` onto `dest` would merge them.
    @Test func renameOntoAnImplicitFolderIsRefused() async throws {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let url = SyntheticZip.write(SyntheticZip.stored([
            (path: "top/x.txt", dosTime: t, data: Array("x".utf8)),
            (path: "dest/y.txt", dosTime: t, data: Array("y".utf8)),
        ]))
        try await Self.expectRefused(url, ArchiveChangeSet(renamedPaths: ["top": "dest"]), .zip, Self.isIO)
        try await Self.expectRefused(url, ArchiveChangeSet(renamedPaths: ["top/x.txt": "dest"]), .zip, Self.isIO)
    }

    @Test(arguments: ["missing.txt", "b/missing", "", "b/c.txt/x"])
    func renamingAMissingEntryIsRefused(_ key: String) async throws {
        let url = try await Self.makeSource(.zip)
        try await Self.expectRefused(url, ArchiveChangeSet(renamedPaths: [key: "new.txt"]), .zip) {
            $0 == .entryNotFound(key)
        }
    }

    /// Two spellings of one key (Swift already folds NFC and NFD dictionary keys; "./" is the spelling left) with
    /// different values.
    @Test func oneEntryRenamedTwiceIsRefused() async throws {
        let url = try await Self.makeSource(.zip)
        try await Self.expectRefused(url, ArchiveChangeSet(renamedPaths: ["a.txt": "x.txt", "./a.txt": "y.txt"]), .zip,
                                     Self.isIO)
        // The same value twice is one rename.
        let source = try await Archive.open(at: url)
        let renames = ["a.txt": "x.txt", "./a.txt": "x.txt"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .zip)
        try await Self.expectRenamed(source, url, out, ["a.txt": "x.txt"])
    }

    @Test func renamingInANewArchiveIsRefused() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data("a".utf8)], in: dir)
        let destination = Repack.destination("new.zip")
        await WriterTests.expectThrows(.entryNotFound("a.txt")) {
            try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(
                additions: [.init(sourceURL: dir.appending(path: "a.txt"), destinationDirectory: "")],
                renamedPaths: ["a.txt": "b.txt"]), format: .zip, to: destination, options: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test(arguments: ["", "/x.txt", "x.txt/", "a//b", "./x.txt", "a/./b", "a/../b", "..", ".", "x\0y"])
    func invalidNewPathsAreRefused(_ value: String) async throws {
        let url = try await Self.makeSource(.zip)
        try await Self.expectRefused(url, ArchiveChangeSet(renamedPaths: ["a.txt": value]), .zip, Self.isIO)
    }

    // MARK: - With other edits

    /// Removals name source paths, additions final paths; a removal inside a renamed folder still drops its entry.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .tarXz])
    func renameWithAdditionsAndRemovals(_ format: ArchiveFormat) async throws {
        let url = try await Self.makeSource(format)
        let source = try await Archive.open(at: url)
        let spare = Fixtures.tempDir().appending(path: "spare.txt")
        try Data("spare".utf8).write(to: spare)
        let changes = ArchiveChangeSet(removedPaths: ["a.txt", "b/c.txt"],
                                       additions: [.init(sourceURL: spare, destinationDirectory: "Bee")],
                                       renamedPaths: ["b": "Bee", "run.sh": "start.sh"])
        let out = try await Self.save(source, changes, format)
        let result = try await Archive.open(at: out)
        #expect(Set(result.entries.map(\.path))
                == ["Bee", "Bee/d", "Bee/d/e.bin", "Bee/spare.txt", "empty", "link", "start.sh", "secret.txt"])
        let before = try await Repack.contents(of: source)
        let after = try await Repack.contents(of: result)
        #expect(after["Bee/d/e.bin"] == before["b/d/e.bin"] && after["start.sh"] == before["run.sh"])
        #expect(after["Bee/spare.txt"] == Fixtures.sha256(spare))
        // The renamed folder header serves as the addition's parent: no second "Bee" entry.
        #expect(try Repack.rawHeaders(out).filter { $0.path == "Bee" }.count == 1)
    }

    /// An addition at a renamed entry's final path replaces it, as it replaces an entry at its own path; a
    /// removal of the old name (a key at the removed path) drops the entry.
    @Test func additionAtTheNewNameReplacesTheRenamedEntry() async throws {
        let url = try await Self.makeSource(.zip)
        let source = try await Archive.open(at: url)
        let spare = Fixtures.tempDir().appending(path: "new.txt")
        try Data("spare".utf8).write(to: spare)
        let replaced = try await Self.save(source, ArchiveChangeSet(
            additions: [.init(sourceURL: spare, destinationDirectory: "")], renamedPaths: ["a.txt": "new.txt"]), .zip)
        let contents = try await Repack.contents(of: Archive.open(at: replaced))
        #expect(contents["new.txt"] == Fixtures.sha256(spare) && contents["a.txt"] == nil)
        #expect(try Repack.rawHeaders(replaced).filter { $0.path == "new.txt" }.count == 1)

        let removed = try await Self.save(source, ArchiveChangeSet(removedPaths: ["a.txt"],
                                                                   renamedPaths: ["a.txt": "z.txt"]), .zip)
        let paths = try await Archive.open(at: removed).entries.map(\.path)
        #expect(!paths.contains("a.txt") && !paths.contains("z.txt"))
    }

    // MARK: - Zip comments, hardlinks, encryption, legacy names

    @Test func zipEntryCommentsFollowTheRenamedEntries() async throws {
        let src = try ZipCommentTests.makeZip(ZipCommentTests.entries, comment: ZipCommentTests.archiveComment)
        let source = try await Archive.open(at: src)
        let renames = ["docs": "papers", "stored.bin": "kept.bin"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .zip)
        let after = try ZipCommentTests.comments(out)
        #expect(after.archive == ZipCommentTests.archiveComment)
        // Python lists a folder as "papers/".
        let expected = Dictionary(uniqueKeysWithValues: ZipCommentTests.entryComments.map { name, comment in
            let folder = name.hasSuffix("/")
            let path = Self.mapped(folder ? String(name.dropLast()) : name, renames)
            return (folder ? path + "/" : path, comment)
        })
        #expect(after.entries == expected)
        try ZipCommentTests.checkEnd(out, comment: ZipCommentTests.archiveComment)
        try await Self.expectRenamed(source, src, out, renames)
    }

    /// tar/links.tar: `hardlink-to-hello` links to `hello.txt`. Renaming the target rewrites the link's target.
    @Test(arguments: [["hello.txt": "greeting.txt"], ["hardlink-to-hello": "same bytes"],
                      ["hello.txt": "greeting.txt", "hardlink-to-hello": "same bytes"]])
    func hardlinksFollowARenamedTarget(_ renames: [String: String]) async throws {
        let fixture = try #require(Corpus.fixtures.first { $0.file == "tar/links.tar" })
        let source = try await Archive.open(at: fixture.url)
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .tar)
        let linkPath = Self.mapped("hardlink-to-hello", renames)
        let link = try #require(try Repack.rawHeaders(out).first { $0.path == linkPath })
        #expect(link.hardlink == Self.mapped("hello.txt", renames))
        let before = try await Repack.contents(of: source)
        let after = try await Repack.contents(of: Archive.open(at: out))
        #expect(after == Dictionary(uniqueKeysWithValues: before.map { (Self.mapped($0.key, renames), $0.value) }))
    }

    @Test(arguments: [ArchiveEncryption.aes256, .zipCrypto])
    func encryptedZipRenameKeepsTheScheme(_ encryption: ArchiveEncryption) async throws {
        let url = try await Repack.makeEncryptedZip(encryption)
        let source = try await Archive.open(at: url, password: "pw")
        let renames = ["b": "bee", "a.txt": "alpha.txt"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .zip)
        let result = try await Archive.open(at: out, password: "pw")
        #expect(result.encryption == source.encryption)
        try await Self.expectRenamed(source, url, out, renames, password: "pw")

        let locked = try await Archive.open(at: url)
        let destination = Repack.destination("locked.zip")
        await WriterTests.expectThrows(.passwordRequired) {
            try await ArchiveWriter.write(source: locked, changes: ArchiveChangeSet(renamedPaths: renames),
                                          format: .zip, to: destination, options: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func sevenZipAESRenameKeepsTheScheme() async throws {
        let url = try await Self.makeSource(.sevenZip, password: "pw")
        let source = try await Archive.open(at: url, password: "pw")
        let renames = ["b": "bee"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .sevenZip)
        let result = try await Archive.open(at: out, password: "pw")
        #expect(result.encryption == .aes256)
        try await Self.expectRenamed(source, url, out, renames, password: "pw")
    }

    /// zip/cp866.zip: `Документы/`, `Документы/отчёт.txt`, `Привет.txt`, stored in CP866 without bit 11. The
    /// renamed folder and its child go out as UTF-8 with bit 11; the untouched file keeps its bytes and no flag.
    @Test func legacyZipRenamedEntriesAreUTF8AndSiblingsKeepTheirBytes() async throws {
        let url = ReaderListingTests.fixture("zip/cp866.zip")
        let source = try await Archive.open(at: url)
        let renames = ["Документы": "Папка ё"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .zip)
        try await Self.expectRenamed(source, url, out, renames)
        let original = SyntheticZip.centralNames([UInt8](try Data(contentsOf: url)))
        let central = SyntheticZip.centralNames([UInt8](try Data(contentsOf: out)))
        #expect(central.map(\.nameBytes) == [Array("Папка ё/".utf8), Array("Папка ё/отчёт.txt".utf8),
                                             original[2].nameBytes])
        #expect(central.map { $0.flags & 0x0800 != 0 } == [true, true, false])
    }

    /// tar/legacy-cp932.tar (Shift-JIS, undeclared): an ASCII rename keeps the siblings' stored bytes, a non-ASCII
    /// one switches the whole save to UTF-8; either way every name reads back right.
    @Test(arguments: ["renamed.txt", "名前を変更.txt"])
    func legacyTarRenameReadsBackRight(_ name: String) async throws {
        let url = ReaderListingTests.fixture("tar/legacy-cp932.tar")
        let source = try await Archive.open(at: url)
        let file = try #require(source.entries.first { !$0.isDirectory && !$0.path.contains("/") })
        let renames = [file.path: name]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .tar)
        try await Self.expectRenamed(source, url, out, renames, checkOrder: false)
        #expect(try await Archive.open(at: out).entries.map(\.path)
                == source.entries.map { Self.mapped($0.path, renames) })
    }

    // MARK: - Addition.archiveName

    @Test(arguments: ArchiveFormat.writable)
    func archiveNameNamesAFileAndAnEmptyFolder(_ format: ArchiveFormat) async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["staged/file.txt": Data("file".utf8)], in: dir)
        let empty = dir.appending(path: "staged/batch-1")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let url = try await Self.makeSource(format)
        let source = try await Archive.open(at: url)
        let changes = ArchiveChangeSet(additions: [
            .init(sourceURL: empty, destinationDirectory: "b", archiveName: "untitled folder"),
            .init(sourceURL: dir.appending(path: "staged/file.txt"), destinationDirectory: "",
                  archiveName: "Notes ё.txt"),
        ])
        let out = try await Self.save(source, changes, format)
        let result = try await Archive.open(at: out)
        let entries = Repack.entryMap(result)
        #expect(entries["b/untitled folder"]?.isDirectory == true)
        #expect(entries["b/batch-1"] == nil && entries["file.txt"] == nil)
        #expect(try Repack.rawHeaders(out).filter { $0.path == "b/untitled folder" }.count == 1)
        #expect(try await Repack.contents(of: result)["Notes ё.txt"]
                == Fixtures.sha256(dir.appending(path: "staged/file.txt")))
    }

    /// A named folder addition keeps its contents' own names beneath the new name.
    @Test func archiveNameOfAFolderKeepsItsContentsNames() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["stage/x.txt": Data("x".utf8), "stage/sub/y.txt": Data("y".utf8)], in: dir)
        let out = Repack.destination("out.zip")
        try await ArchiveWriter.write(source: nil, changes: ArchiveChangeSet(additions: [
            .init(sourceURL: dir.appending(path: "stage"), destinationDirectory: "top", archiveName: "Named"),
        ]), format: .zip, to: out, options: nil)
        #expect(Set(try await Archive.open(at: out).entries.map(\.path))
                == ["top", "top/Named", "top/Named/x.txt", "top/Named/sub", "top/Named/sub/y.txt"])
    }

    @Test(arguments: ["", "a/b", "/x", ".", "..", "x\0y"])
    func invalidArchiveNamesAreRefused(_ name: String) async throws {
        let url = try await Self.makeSource(.zip)
        let spare = Fixtures.tempDir().appending(path: "spare.txt")
        try Data("spare".utf8).write(to: spare)
        try await Self.expectRefused(url, ArchiveChangeSet(additions: [
            .init(sourceURL: spare, destinationDirectory: "", archiveName: name),
        ]), .zip, Self.isIO)
    }

    // MARK: - Progress and Mac metadata

    /// With `excludesMacMetadata`, an entry renamed into Mac metadata is dropped like any other metadata entry,
    /// and a metadata entry (`._x.txt`) renamed to an ordinary name is still dropped.
    @Test func macMetadataFilterSeesBothPaths() async throws {
        let url = try await Self.makeSource(.zip)
        let source = try await Archive.open(at: url)
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: ["a.txt": "._a.txt", "b": "__MACOSX"]),
                                      .zip, options: ArchiveWriteOptions(excludesMacMetadata: true))
        let paths = Set(try await Archive.open(at: out).entries.map(\.path))
        #expect(paths == ["empty", "link", "run.sh", "secret.txt"])

        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let finder = SyntheticZip.write(SyntheticZip.stored([
            (path: "x.txt", dosTime: t, data: Array("x".utf8)),
            (path: "._x.txt", dosTime: t, data: Array("apple double".utf8)),
        ]))
        let metadata = try await Archive.open(at: finder)
        let renamedOut = try await Self.save(metadata, ArchiveChangeSet(renamedPaths: ["._x.txt": "y.txt"]), .zip,
                                             options: ArchiveWriteOptions(excludesMacMetadata: true))
        #expect(try await Archive.open(at: renamedOut).entries.map(\.path) == ["x.txt"])
        // Without the flag the rename is an ordinary one.
        let plain = try await Self.save(metadata, ArchiveChangeSet(renamedPaths: ["._x.txt": "y.txt"]), .zip)
        #expect(Set(try await Archive.open(at: plain).entries.map(\.path)) == ["x.txt", "y.txt"])

        // An addition named into Mac metadata by `archiveName` is dropped with the flag, kept without it.
        let spare = Fixtures.tempDir().appending(path: "spare.txt")
        try Data("spare".utf8).write(to: spare)
        let named = ArchiveChangeSet(additions: [.init(sourceURL: spare, destinationDirectory: "", archiveName: "._y")])
        let dropped = try await Self.save(metadata, named, .zip,
                                          options: ArchiveWriteOptions(excludesMacMetadata: true))
        #expect(try await Archive.open(at: dropped).entries.map(\.path) == ["x.txt"])
        let kept = try await Self.save(metadata, named, .zip)
        #expect(Set(try await Archive.open(at: kept).entries.map(\.path)) == ["x.txt", "._x.txt", "._y"])
    }

    // MARK: - Split sets (writeVolumes)

    typealias Volumes = VolumeWriterTests

    /// `VolumeWriterTests.makeInput` (2.5 MB of noise, `in/docs/readme.txt`, `in/Привет.txt`) written by Kernir
    /// as one `format` file: big enough that a 1 MB split has three volumes.
    static func makeSplitSource(_ format: ArchiveFormat) async throws -> URL {
        let out = Fixtures.tempDir().appending(path: "big.\(format.fileExtension)")
        try await ArchiveWriter.write(source: nil, changes: Volumes.adding(Volumes.makeInput()), format: format,
                                      to: out, options: ArchiveWriteOptions())
        return out
    }

    /// The volumes' bytes joined into one `format` file, which is the single-file archive.
    static func joinedFile(_ urls: [URL], _ format: ArchiveFormat) throws -> URL {
        let out = Repack.destination("joined.\(format.fileExtension)")
        try Volumes.joined(urls).write(to: out)
        return out
    }

    /// A file rename and a folder rename (with its subtree) reach the split writer: the set reopens with the new
    /// names and unchanged data, and its joined bytes pass the full check (kind, size, date, permissions, data
    /// sha256, header order).
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func writeVolumesRenamesAFileAndAFolder(_ format: ArchiveFormat) async throws {
        let url = try await Self.makeSplitSource(format)
        let source = try await Archive.open(at: url)
        let renames = ["in/noise.bin": "in/static.bin", "in/docs": "in/Документы"]
        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: source, changes: ArchiveChangeSet(renamedPaths: renames), format: format, into: folder,
            baseName: "Renamed", options: ArchiveWriteOptions(volumeSize: Volumes.mb))
        let ext = format.fileExtension
        #expect(urls.map(\.lastPathComponent) == ["Renamed.\(ext).001", "Renamed.\(ext).002", "Renamed.\(ext).003"])

        let set = try await Archive.open(at: urls[0])
        #expect(set.volumeURLs.count == 3)
        let paths = Set(set.entries.map(\.path))
        #expect(paths.isSuperset(of: ["in/static.bin", "in/Документы", "in/Документы/readme.txt", "in/Привет.txt"]))
        #expect(!paths.contains("in/noise.bin") && !paths.contains("in/docs") && !paths.contains("in/docs/readme.txt"))
        let data = try await Repack.contents(of: source)
        let expected = Dictionary(uniqueKeysWithValues: data.map { (Self.mapped($0.key, renames), $0.value) })
        let contents = try await Repack.contents(of: set)
        #expect(contents == expected)
        #expect(contents["in/static.bin"] == data["in/noise.bin"])
        #expect(contents["in/Документы/readme.txt"] == data["in/docs/readme.txt"])

        try await Self.expectRenamed(source, url, try Self.joinedFile(urls, format), renames)
    }

    /// `Addition.archiveName` in a split set: a big file and an empty folder land under their new names, once each.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func writeVolumesNamesAnAddition(_ format: ArchiveFormat) async throws {
        let input = Volumes.makeInput()
        let empty = input.deletingLastPathComponent().appending(path: "batch-1")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let folder = APIBatchTests.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: nil, changes: ArchiveChangeSet(additions: [
                .init(sourceURL: input.appending(path: "noise.bin"), destinationDirectory: "data",
                      archiveName: "Шум.bin"),
                .init(sourceURL: empty, destinationDirectory: "", archiveName: "untitled folder"),
            ]), format: format, into: folder, baseName: "Named", options: ArchiveWriteOptions(volumeSize: Volumes.mb))
        #expect(urls.count == 3)
        let set = try await Archive.open(at: urls[0])
        let entries = Repack.entryMap(set)
        #expect(Set(entries.keys) == ["data", "data/Шум.bin", "untitled folder"])
        #expect(entries["untitled folder"]?.isDirectory == true)
        #expect(try await Repack.contents(of: set)["data/Шум.bin"]
                == Fixtures.sha256(input.appending(path: "noise.bin")))
        let headers = try Repack.rawHeaders(try Self.joinedFile(urls, format)).map(\.path)
        #expect(headers.filter { $0 == "untitled folder" }.count == 1)
        #expect(!headers.contains("noise.bin") && !headers.contains("data/noise.bin") && !headers.contains("batch-1"))
    }

    /// A key that names no source entry is refused by the split writer with `.entryNotFound(key)` before any
    /// volume exists, beside valid keys too, and with no source at all. The folder stays empty, the source as it was.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func writeVolumesRefusesAMissingRenameKey(_ format: ArchiveFormat) async throws {
        let url = try await Self.makeSplitSource(format)
        let before = Fixtures.sha256(url)
        let source = try await Archive.open(at: url)
        let input = Volumes.makeInput(noiseBytes: 10)
        let cases: [(source: (any ArchiveReading)?, changes: ArchiveChangeSet)] = [
            (source, ArchiveChangeSet(renamedPaths: ["in/missing.txt": "x.txt"])),
            (source, ArchiveChangeSet(renamedPaths: ["in/noise.bin": "in/static.bin", "in/missing.txt": "x.txt"])),
            (nil, ArchiveChangeSet(additions: [.init(sourceURL: input, destinationDirectory: "")],
                                   renamedPaths: ["in/missing.txt": "x.txt"])),
        ]
        for (source, changes) in cases {
            let folder = APIBatchTests.emptyFolder()
            await WriterTests.expectThrows(.entryNotFound("in/missing.txt")) {
                _ = try await ArchiveWriter.writeVolumes(
                    source: source, changes: changes, format: format, into: folder, baseName: "Missing",
                    options: ArchiveWriteOptions(volumeSize: Volumes.mb))
            }
            #expect(APIBatchTests.contents(folder) == [])
        }
        #expect(Fixtures.sha256(url) == before)
    }

    // MARK: - Boundaries and probes

    /// A stored zip with one entry per path (each holds its own path as data).
    static func plainZip(_ paths: [String]) -> URL {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        return SyntheticZip.write(SyntheticZip.stored(paths.map { (path: $0, dosTime: t, data: Array($0.utf8)) }))
    }

    /// A key is a path prefix only at a "/" boundary: `photos` must not touch `photos 2/…` or `photos.txt`.
    @Test func keyMatchesOnlyAtASlashBoundary() async throws {
        let source = try await Archive.open(at: Self.plainZip(["photos/1.txt", "photos 2/2.txt", "photos.txt"]))
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: ["photos": "pics"]), .zip)
        #expect(Set(try await Repack.contents(of: Archive.open(at: out)).keys)
                == ["pics/1.txt", "photos 2/2.txt", "photos.txt"])
    }

    /// The prefix is cut in Unicode scalars: these folder names have fewer Characters than scalars (Devanagari,
    /// a flag emoji, a base letter with a combining mark that NFC cannot compose).
    @Test func prefixIsCutInScalars() async throws {
        let paths = ["नमस्ते/x.txt", "🇺🇦/y.txt", "q\u{301}/z.txt", "👨\u{200D}👩\u{200D}👧/w.txt"]
        let source = try await Archive.open(at: Self.plainZip(paths))
        let renames = ["नमस्ते": "hello", "🇺🇦": "flag", "q\u{301}": "queue", "👨\u{200D}👩\u{200D}👧": "family"]
        let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .zip)
        #expect(Set(try await Repack.contents(of: Archive.open(at: out)).keys)
                == ["hello/x.txt", "flag/y.txt", "queue/z.txt", "family/w.txt"])
    }

    /// An addition that needs a folder where a renamed file now sits replaces the file (matched by final path),
    /// leaving one `x` header, a folder.
    @Test func renamedFileWhereAnAdditionNeedsAFolderIsReplaced() async throws {
        let source = try await Archive.open(at: Self.plainZip(["a.txt", "keep.txt"]))
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["new.txt": Data("n".utf8)], in: dir)
        let out = try await Self.save(source, ArchiveChangeSet(
            additions: [.init(sourceURL: dir.appending(path: "new.txt"), destinationDirectory: "x")],
            renamedPaths: ["a.txt": "x"]), .zip)
        let result = try await Archive.open(at: out)
        #expect(Repack.entryMap(result)["x"]?.isDirectory == true)
        #expect(Set(try await Repack.contents(of: result).keys) == ["keep.txt", "x/new.txt"])
        #expect(result.entries.filter { $0.path == "x" }.count == 1)
    }

    /// The into-itself check works at a "/" boundary: `b` into `b/inner` is refused, `b` to `bee` and `b 2` are fine.
    @Test func intoItselfIsCheckedAtASlashBoundary() async throws {
        let url = try await Self.makeSource(.zip)
        try await Self.expectRefused(url, ArchiveChangeSet(renamedPaths: ["b": "b/inner"]), .zip, Self.isIO)
        let source = try await Archive.open(at: url)
        for value in ["bee", "b 2"] {
            let renames = ["b": value]
            let out = try await Self.save(source, ArchiveChangeSet(renamedPaths: renames), .zip)
            try await Self.expectRenamed(source, url, out, renames)
        }
    }

    /// The `.DS_Store` skip goes by the name on disk, not by `archiveName` (see `ArchiveChangeSet.Addition`).
    @Test func dsStoreSkipGoesByTheDiskName() async throws {
        let source = try await Archive.open(at: Self.plainZip(["keep.txt"]))
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles([".DS_Store": Data("d".utf8), "plain.txt": Data("p".utf8)], in: dir)
        let out = try await Self.save(source, ArchiveChangeSet(additions: [
            .init(sourceURL: dir.appending(path: ".DS_Store"), destinationDirectory: "", archiveName: "notes.txt"),
            .init(sourceURL: dir.appending(path: "plain.txt"), destinationDirectory: "", archiveName: ".DS_Store"),
        ]), .zip)
        #expect(Set(try await Repack.contents(of: Archive.open(at: out)).keys) == ["keep.txt", ".DS_Store"])
    }

    // MARK: - A removed folder keeps what is renamed out of it

    static let removeKeepFormats: [ArchiveFormat] = [.zip, .sevenZip, .tar]

    /// A stored zip of `paths` (a path ending in "/" is a folder; each file holds its own path as data), as `format`:
    /// the zip itself, or a copy Kernir writes from it.
    static func removeKeepSource(_ format: ArchiveFormat, _ paths: [String]) async throws -> URL {
        let t = SyntheticZip.dosTime(year: 2024, month: 5, day: 1, hour: 12, minute: 0, second: 0)
        let zip = SyntheticZip.write(SyntheticZip.stored(paths.map {
            (path: $0, dosTime: t, data: $0.hasSuffix("/") ? [] : Array($0.utf8))
        }))
        guard format != .zip else { return zip }
        let out = Fixtures.tempDir().appending(path: "src.\(format.fileExtension)")
        try await ArchiveWriter.write(source: Archive.open(at: zip), changes: ArchiveChangeSet(), format: format,
                                      to: out, options: nil)
        return out
    }

    /// Saves `changes` over a `removeKeepSource` as `format` and checks that the output holds exactly `expected`
    /// (final path -> source path), each file with its source data.
    static func expectKept(_ format: ArchiveFormat, _ paths: [String], _ changes: ArchiveChangeSet,
                           _ expected: [String: String],
                           sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let source = try await Archive.open(at: removeKeepSource(format, paths))
        let result = try await Archive.open(at: Self.save(source, changes, format))
        #expect(Set(result.entries.map(\.path)) == Set(expected.keys), "\(format)", sourceLocation: sourceLocation)
        let before = try await Repack.contents(of: source)
        let after = try await Repack.contents(of: result)
        let files = expected.filter { before[$0.value] != nil }
        #expect(after == files.mapValues { before[$0] ?? "" }, "\(format)", sourceLocation: sourceLocation)
    }

    /// The probe: `d/a.txt` moved to the top level, then `d` deleted, keeps `a.txt` with its data.
    @Test(arguments: removeKeepFormats)
    func removedFolderKeepsAFileRenamedOutOfIt(_ format: ArchiveFormat) async throws {
        try await Self.expectKept(format, ["d/", "d/a.txt", "d/b.txt"],
                                  ArchiveChangeSet(removedPaths: ["d"], renamedPaths: ["d/a.txt": "a.txt"]),
                                  ["a.txt": "d/a.txt"])
    }

    /// Deeper escapes: a file from a subfolder, and a whole subfolder; the rest of `d` is dropped.
    @Test(arguments: removeKeepFormats)
    func removedFolderKeepsNestedEntriesRenamedOutOfIt(_ format: ArchiveFormat) async throws {
        let paths = ["d/", "d/x/", "d/x/a.txt", "d/x/c.txt", "d/b.txt", "keep.txt"]
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d"], renamedPaths: ["d/x/a.txt": "a.txt"]),
                                  ["a.txt": "d/x/a.txt", "keep.txt": "keep.txt"])
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d"], renamedPaths: ["d/x": "y"]),
                                  ["y": "d/x", "y/a.txt": "d/x/a.txt", "y/c.txt": "d/x/c.txt", "keep.txt": "keep.txt"])
    }

    /// Nested removals: an entry escapes only when its key lies strictly beneath every removed path above it.
    @Test(arguments: removeKeepFormats)
    func nestedRemovalsKeepOnlyEntriesWhoseKeyIsBeneathAll(_ format: ArchiveFormat) async throws {
        let paths = ["d/", "d/x/", "d/x/a.txt", "d/b.txt"]
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d", "d/x"], renamedPaths: ["d/x/a.txt": "a.txt"]),
                                  ["a.txt": "d/x/a.txt"])
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d", "d/x"], renamedPaths: ["d/x": "y"]), [:])
    }

    /// An escape into another removed folder (by that folder's final path) is still dropped.
    @Test(arguments: removeKeepFormats)
    func escapeIntoAnotherRemovedFolderIsDropped(_ format: ArchiveFormat) async throws {
        let paths = ["d/", "d/a.txt", "e/", "e/b.txt", "keep.txt"]
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d", "e"], renamedPaths: ["d/a.txt": "e/a.txt"]),
                                  ["keep.txt": "keep.txt"])
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d", "e"],
                                                   renamedPaths: ["e": "f", "d/a.txt": "f/a.txt"]),
                                  ["keep.txt": "keep.txt"])
    }

    /// A target inside the removed folder's own final path is dropped, whether or not the folder is renamed too.
    @Test(arguments: removeKeepFormats)
    func escapeIntoTheRemovedFoldersOwnSubtreeIsDropped(_ format: ArchiveFormat) async throws {
        let paths = ["d/", "d/a.txt", "keep.txt"]
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d"], renamedPaths: ["d/a.txt": "d/z/a.txt"]),
                                  ["keep.txt": "keep.txt"])
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d"], renamedPaths: ["d": "q", "d/a.txt": "q/a.txt"]),
                                  ["keep.txt": "keep.txt"])
    }

    /// A key at the removed path keeps nothing: renaming `d` and removing it drops it all.
    @Test(arguments: removeKeepFormats)
    func keyAtTheRemovedPathKeepsNothing(_ format: ArchiveFormat) async throws {
        try await Self.expectKept(format, ["d/", "d/a.txt", "keep.txt"],
                                  ArchiveChangeSet(removedPaths: ["d"], renamedPaths: ["d": "q"]),
                                  ["keep.txt": "keep.txt"])
    }

    /// The collision check sees a kept escaped entry: landing on a kept name is refused; on a removed one it is not.
    @Test(arguments: removeKeepFormats)
    func escapedEntryCollidingWithAKeptNameIsRefused(_ format: ArchiveFormat) async throws {
        let paths = ["d/", "d/a.txt", "a.txt"]
        let url = try await Self.removeKeepSource(format, paths)
        try await Self.expectRefused(url, ArchiveChangeSet(removedPaths: ["d"], renamedPaths: ["d/a.txt": "a.txt"]),
                                     format, Self.isIO)
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d", "a.txt"], renamedPaths: ["d/a.txt": "a.txt"]),
                                  ["a.txt": "d/a.txt"])
    }

    /// A renamed ancestor of the escaped entry: `x` -> `y`, `x/d` removed, `x/d/a.txt` -> `a.txt` keeps `a.txt`.
    @Test(arguments: removeKeepFormats + [.tarGzip])
    func removedFolderUnderARenamedAncestorKeepsTheEscapedEntry(_ format: ArchiveFormat) async throws {
        try await Self.expectKept(format, ["x/", "x/d/", "x/d/a.txt", "x/d/b.txt", "x/c.txt"],
                                  ArchiveChangeSet(removedPaths: ["x/d"],
                                                   renamedPaths: ["x": "y", "x/d/a.txt": "a.txt"]),
                                  ["y": "x", "y/c.txt": "x/c.txt", "a.txt": "x/d/a.txt"])
    }

    /// A folder moved out of a removed folder onto a freed, removed name keeps its whole subtree: the governing key's
    /// final path decides, not each entry's own. Route 1: move `d/a` into `e` replacing `e/a`, then delete `d`.
    /// The original `e/a` and its contents are still dropped, and the kept `e/a/x.txt` does not collide with them.
    @Test(arguments: removeKeepFormats)
    func folderEscapingOntoAFreedRemovedNameKeepsItsSubtree(_ format: ArchiveFormat) async throws {
        let paths = ["d/", "d/a/", "d/a/x.txt", "d/a/b/", "d/a/b/y.txt", "d/c.txt",
                     "e/", "e/a/", "e/a/old.txt", "e/a/b/", "e/a/b/old.txt", "e/c.txt", "keep.txt"]
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d", "e/a"], renamedPaths: ["d/a": "e/a"]),
                                  ["e": "e", "e/c.txt": "e/c.txt", "e/a": "d/a", "e/a/x.txt": "d/a/x.txt",
                                   "e/a/b": "d/a/b", "e/a/b/y.txt": "d/a/b/y.txt", "keep.txt": "keep.txt"])
    }

    /// Route 2: delete `a`, move `d/a` to the top level, then delete `d`: the moved folder keeps its subtree.
    @Test(arguments: removeKeepFormats)
    func folderEscapingToTheTopLevelOntoARemovedNameKeepsItsSubtree(_ format: ArchiveFormat) async throws {
        let paths = ["a/", "a/old.txt", "a/b/", "a/b/old.txt", "d/", "d/a/", "d/a/x.txt", "d/a/b/", "d/a/b/y.txt",
                     "d/c.txt", "keep.txt"]
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d", "a"], renamedPaths: ["d/a": "a"]),
                                  ["a": "d/a", "a/x.txt": "d/a/x.txt", "a/b": "d/a/b", "a/b/y.txt": "d/a/b/y.txt",
                                   "keep.txt": "keep.txt"])
    }

    /// A folder whose key moves strictly beneath another removed folder's final path is dropped with its subtree,
    /// whether or not that folder is renamed too.
    @Test(arguments: removeKeepFormats)
    func folderEscapingIntoAnotherRemovedFolderIsDroppedWithItsSubtree(_ format: ArchiveFormat) async throws {
        let paths = ["d/", "d/a/", "d/a/x.txt", "d/a/b/", "d/a/b/y.txt", "e/", "e/c.txt", "keep.txt"]
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d", "e"], renamedPaths: ["d/a": "e/q"]),
                                  ["keep.txt": "keep.txt"])
        try await Self.expectKept(format, paths,
                                  ArchiveChangeSet(removedPaths: ["d", "e"], renamedPaths: ["e": "f", "d/a": "f/q"]),
                                  ["keep.txt": "keep.txt"])
    }

    /// A key moved onto an ancestor of the removed folder's own final path keeps its subtree, even the part that
    /// lands at or beneath that final path (`e/d/a` -> `e`, `e/d` removed: `e/d/a/d/y.txt` -> `e/d/y.txt`); the
    /// removed folder's own entries are dropped, so its name is free.
    @Test(arguments: removeKeepFormats)
    func keyMovedOntoAnAncestorOfTheRemovedFolderKeepsItsSubtree(_ format: ArchiveFormat) async throws {
        try await Self.expectKept(format, ["e/d/", "e/d/a/", "e/d/a/d/", "e/d/a/d/y.txt", "e/d/b.txt"],
                                  ArchiveChangeSet(removedPaths: ["e/d"], renamedPaths: ["e/d/a": "e"]),
                                  ["e": "e/d/a", "e/d": "e/d/a/d", "e/d/y.txt": "e/d/a/d/y.txt"])
    }

    /// An inner key overrides the outer one under a removal: `d/a` escapes to `x`, but `d/a/b` is keyed to `d/b`,
    /// which stays inside removed `d`, so nothing from `d/a/b` survives.
    @Test(arguments: removeKeepFormats)
    func innerKeyInsideTheRemovedFolderOverridesTheEscapingOuterKey(_ format: ArchiveFormat) async throws {
        try await Self.expectKept(format, ["d/", "d/a/", "d/a/f.txt", "d/a/b/", "d/a/b/g.txt"],
                                  ArchiveChangeSet(removedPaths: ["d"], renamedPaths: ["d/a": "x", "d/a/b": "d/b"]),
                                  ["x": "d/a", "x/f.txt": "d/a/f.txt"])
    }

    /// A removed path strictly beneath the escaping key stays deleted: `d/a` -> `x` keeps `x/f.txt`, not `x/b`.
    @Test(arguments: removeKeepFormats)
    func removedPathBeneathTheEscapingKeyStaysDeleted(_ format: ArchiveFormat) async throws {
        try await Self.expectKept(format, ["d/", "d/a/", "d/a/f.txt", "d/a/b/", "d/a/b/g.txt"],
                                  ArchiveChangeSet(removedPaths: ["d", "d/a/b"], renamedPaths: ["d/a": "x"]),
                                  ["x": "d/a", "x/f.txt": "d/a/f.txt"])
    }
}
