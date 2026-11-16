import Testing
import Foundation
@testable import KernirCore

/// Extract never replaces anything that existed before the call: a silent
/// overwrite on Extract is a data-loss bug.
struct ExtractNoOverwriteTests {
    static func dest() -> URL { Fixtures.tempDir().appendingPathComponent("out", isDirectory: true) }

    static func reader(_ files: [String: Data], args: [String] = []) async throws -> LibArchiveReader {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(files, in: dir)
        try Fixtures.bsdtar(["-cf", "t.tar"] + args + files.keys.sorted(), cwd: dir)
        return try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    @Test func existingFileIsKeptAndNothingIsWritten() async throws {
        let r = try await Self.reader(["a.txt": Data("new a".utf8), "top.txt": Data("new top".utf8)])
        let out = Self.dest()
        try Self.write("mine", to: out.appendingPathComponent("top.txt"))
        await #expect(throws: ExtractionConflictError(paths: ["top.txt"])) {
            try await r.extract(nil, to: out, progress: nil)
        }
        #expect(Self.text(out.appendingPathComponent("top.txt")) == "mine")
        // Checked before any write: the non-conflicting entry is not there either.
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("a.txt").path))
    }

    @Test func everyConflictIsReportedSorted() async throws {
        let r = try await Self.reader(["b.txt": Data("b".utf8), "a.txt": Data("a".utf8), "c.txt": Data("c".utf8)])
        let out = Self.dest()
        try Self.write("mine b", to: out.appendingPathComponent("b.txt"))
        try Self.write("mine a", to: out.appendingPathComponent("a.txt"))
        await #expect(throws: ExtractionConflictError(paths: ["a.txt", "b.txt"])) {
            try await r.extract(nil, to: out, progress: nil)
        }
        #expect(Self.text(out.appendingPathComponent("a.txt")) == "mine a")
        #expect(Self.text(out.appendingPathComponent("b.txt")) == "mine b")
    }

    @Test func existingFolderWhereArchiveHasFileIsAConflict() async throws {
        let r = try await Self.reader(["f": Data("file".utf8)])
        let out = Self.dest()
        try Self.write("kept", to: out.appendingPathComponent("f/inside.txt"))
        await #expect(throws: ExtractionConflictError(paths: ["f"])) {
            try await r.extract(nil, to: out, progress: nil)
        }
        #expect(Self.text(out.appendingPathComponent("f/inside.txt")) == "kept")
    }

    @Test func existingFileWhereArchiveHasFolderIsAConflict() async throws {
        let r = try await Self.reader(["d/x.txt": Data("x".utf8)])
        let out = Self.dest()
        try Self.write("mine", to: out.appendingPathComponent("d"))
        await #expect(throws: ExtractionConflictError(paths: ["d"])) {
            try await r.extract(nil, to: out, progress: nil)
        }
        #expect(Self.text(out.appendingPathComponent("d")) == "mine")
    }

    @Test func fileInTheWayOfAPartialSelectionsParentIsAConflict() async throws {
        let r = try await Self.reader(["a/b/c.txt": Data("c".utf8)])
        let out = Self.dest()
        try Self.write("mine", to: out.appendingPathComponent("a"))
        await #expect(throws: ExtractionConflictError(paths: ["a"])) {
            try await r.extract(["a/b/c.txt"], to: out, progress: nil)
        }
        #expect(Self.text(out.appendingPathComponent("a")) == "mine")
    }

    @Test func existingSymlinkIsNotReplacedNorFollowed() async throws {
        let r = try await Self.reader(["link.txt": Data("archive".utf8)])
        let out = Self.dest()
        let target = Fixtures.tempDir().appendingPathComponent("target.txt")
        try Self.write("target", to: target)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("link.txt"), withDestinationURL: target)
        await #expect(throws: ExtractionConflictError(paths: ["link.txt"])) {
            try await r.extract(nil, to: out, progress: nil)
        }
        #expect(Self.text(target) == "target")
        let type = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("link.txt").path)[.type]
        #expect(type as? FileAttributeType == .typeSymbolicLink)
    }

    @Test func existingFolderIsMergedAndItsFilesKept() async throws {
        let r = try await Self.reader(["d/new.txt": Data("new".utf8)])
        let out = Self.dest()
        try Self.write("mine", to: out.appendingPathComponent("d/mine.txt"))
        try await r.extract(nil, to: out, progress: nil)
        #expect(Self.text(out.appendingPathComponent("d/mine.txt")) == "mine")
        #expect(Self.text(out.appendingPathComponent("d/new.txt")) == "new")
    }

    @Test func fileOutsideTheSelectionIsNoConflict() async throws {
        let r = try await Self.reader(["a.txt": Data("a".utf8), "b.txt": Data("b".utf8)])
        let out = Self.dest()
        try Self.write("mine", to: out.appendingPathComponent("b.txt"))
        try await r.extract(["a.txt"], to: out, progress: nil)
        #expect(Self.text(out.appendingPathComponent("a.txt")) == "a")
        #expect(Self.text(out.appendingPathComponent("b.txt")) == "mine")
    }

    @Test func conflictCarriesNormalizedEntryPaths() async throws {
        let r = try await Self.reader(["d/x.txt": Data("x".utf8)])
        let out = Self.dest()
        try Self.write("mine", to: out.appendingPathComponent("d/x.txt"))
        await #expect(throws: ExtractionConflictError(paths: ["d/x.txt"])) {
            try await r.extract(["d/"], to: out, progress: nil)
        }
        #expect(Self.text(out.appendingPathComponent("d/x.txt")) == "mine")
    }

    /// Two entries that land on one name on a case-insensitive volume: the later one replaces the file
    /// this same extraction wrote (as before), since nothing that existed before the call is touched.
    @Test func caseCollisionInsideOneExtractionKeepsLaterWins() async throws {
        let out = Self.dest()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let caseSensitive = try out.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? true
        try #require(!caseSensitive, "needs a case-insensitive temporary volume")
        let r = try await Self.reader(["A.txt": Data("first".utf8), "b.txt": Data("second".utf8)],
                                      args: ["--no-mac-metadata", "-s", ",^b.txt$,a.txt,"])
        #expect(Set(r.entries.map(\.path)) == ["A.txt", "a.txt"])
        try await r.extract(nil, to: out, progress: nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path)
        #expect(names.count == 1)
        #expect(Self.text(out.appendingPathComponent("a.txt")) == "second")
    }

    /// NO_OVERWRITE is set for non-folders only: in an archive that lists a folder after its files,
    /// the folder already exists when its header comes, and its date and mode must still be applied.
    @Test func folderListedAfterItsFilesKeepsItsDateAndMode() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["d/f.txt": Data("f".utf8)], in: dir)
        let mtime = Date(timeIntervalSince1970: 981_158_400)
        try FileManager.default.setAttributes([.modificationDate: mtime, .posixPermissions: 0o750],
                                              ofItemAtPath: dir.appendingPathComponent("d").path)
        try Fixtures.bsdtar(["-cf", "t.tar", "--no-mac-metadata", "-n", "d/f.txt", "d"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        #expect(r.headerOrdinalByPath["d"] == 1 && r.headerOrdinalByPath["d/f.txt"] == 0)
        let out = Self.dest()
        try await r.extract(nil, to: out, progress: nil)
        let attrs = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("d").path)
        let m = try #require(attrs[.modificationDate] as? Date)
        #expect(abs(m.timeIntervalSince(mtime)) <= 2, "\(m)")
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o750)
    }

    // MARK: - Items that appear during the run

    static let foreignMtime = Date(timeIntervalSince1970: 981_158_400)

    /// A foreign file, with its own mode and date so a metadata write would show.
    static func writeForeign(at url: URL) {
        try? write("mine", to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: foreignMtime],
                                               ofItemAtPath: url.path)
    }

    static func expectForeignUntouched(at url: URL) throws {
        #expect(text(url) == "mine")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attrs[.type] as? FileAttributeType == .typeRegular)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let m = try #require(attrs[.modificationDate] as? Date)
        #expect(abs(m.timeIntervalSince(foreignMtime)) < 1, "\(m)")
    }

    /// a.txt, b.txt (data), e.txt (empty), s (symlink to a.txt), in that header order.
    static func mixedReader() async throws -> LibArchiveReader {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data(repeating: 0x61, count: 4096), "b.txt": Data(repeating: 0x62, count: 4096),
                            "e.txt": Data()], in: dir)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("s").path, withDestinationPath: "a.txt")
        try Fixtures.bsdtar(["-cf", "t.tar", "--no-mac-metadata", "a.txt", "b.txt", "e.txt", "s"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        #expect(r.headerOrdinalByPath == ["a.txt": 0, "b.txt": 1, "e.txt": 2, "s": 3])
        return r
    }

    /// Claim path: the item is already there when the entry's write-time check runs. It appears from
    /// the progress callback once a.txt is written; b.txt is still written, then c.txt conflicts.
    @Test func itemAppearingBeforeAnEntrysWriteIsAConflict() async throws {
        let r = try await Self.reader(["a.txt": Data(repeating: 0x61, count: 4096),
                                       "b.txt": Data(repeating: 0x62, count: 4096),
                                       "c.txt": Data(repeating: 0x63, count: 4096)], args: ["--no-mac-metadata"])
        #expect(r.headerOrdinalByPath == ["a.txt": 0, "b.txt": 1, "c.txt": 2])
        let out = Self.dest()
        let foreign = out.appendingPathComponent("c.txt")
        await #expect(throws: ExtractionConflictError(paths: ["c.txt"])) {
            try await r.extract(nil, to: out, progress: { _, path in
                if path == "a.txt", !FileManager.default.fileExists(atPath: foreign.path) { Self.writeForeign(at: foreign) }
            })
        }
        try Self.expectForeignUntouched(at: foreign)
        // Finished entries stay; nothing else is there.
        #expect(Self.text(out.appendingPathComponent("a.txt")) == String(repeating: "a", count: 4096))
        #expect(Self.text(out.appendingPathComponent("b.txt")) == String(repeating: "b", count: 4096))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: out.path)) == ["a.txt", "b.txt", "c.txt"])
    }

    /// Race path: the item appears after the entry's write-time check passed, right before the entry is
    /// created (a regular file with data, an empty file, a symlink). It is reported as the same conflict,
    /// and is neither removed nor given the entry's mode or date.
    @Test(arguments: ["b.txt", "e.txt", "s"])
    func itemAppearingAfterTheWriteTimeCheckIsAConflict(_ victim: String) async throws {
        let r = try await Self.mixedReader()
        let out = Self.dest()
        let foreign = out.appendingPathComponent(victim)
        #expect(throws: ExtractionConflictError(paths: [victim])) {
            try r.extractEntries(selection: nil, to: out, progress: nil, afterClaim: { dest in
                if dest == victim { Self.writeForeign(at: foreign) }
            })
        }
        try Self.expectForeignUntouched(at: foreign)
        let order = ["a.txt", "b.txt", "e.txt", "s"]
        let before = order.prefix(while: { $0 != victim })
        // Entries finished before the conflict stay; later ones are not written.
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: out.path)) == Set(before + [victim]))
        #expect(Self.text(out.appendingPathComponent("a.txt")) == String(repeating: "a", count: 4096))
    }

    /// Race path through a parent: a file appears where a later entry's (not yet created) folder goes.
    /// Reported in the pre-check's form, the topmost item in the way.
    @Test func fileAppearingWhereAParentFolderGoesIsAConflict() async throws {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(["a.txt": Data("a".utf8), "d/f.txt": Data("f".utf8)], in: dir)
        // -n with the folder after its file: "d" is created implicitly while d/f.txt is written.
        try Fixtures.bsdtar(["-cf", "t.tar", "--no-mac-metadata", "-n", "a.txt", "d/f.txt", "d"], cwd: dir)
        let r = try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
        #expect(r.headerOrdinalByPath == ["a.txt": 0, "d/f.txt": 1, "d": 2])
        let out = Self.dest()
        let foreign = out.appendingPathComponent("d")
        #expect(throws: ExtractionConflictError(paths: ["d"])) {
            try r.extractEntries(selection: nil, to: out, progress: nil, afterClaim: { dest in
                if dest == "d/f.txt" { Self.writeForeign(at: foreign) }
            })
        }
        try Self.expectForeignUntouched(at: foreign)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: out.path)) == ["a.txt", "d"])
    }

    @Test func temporaryFileExtractionStillWorksTwice() async throws {
        let r = try await Self.reader(["a.txt": Data("a".utf8)])
        let first = try await r.extractToTemporaryFile("a.txt")
        try FileManager.default.removeItem(at: first)
        let second = try await r.extractToTemporaryFile("a.txt")
        #expect(Self.text(second) == "a")
    }

    /// A volume without RENAME_EXCL may say ENOTSUP or EOPNOTSUPP (separate numbers on Darwin) or EINVAL: each
    /// gets the check-then-rename fallback. Any other error is the move's own.
    @Test(arguments: [(ENOTSUP, true), (EOPNOTSUPP, true), (EINVAL, true), (EEXIST, false), (EACCES, false),
                      (EXDEV, false)])
    func aVolumeWithoutExclusiveRenamesGetsTheFallback(_ code: Int32, _ lacks: Bool) {
        #expect(LibArchiveReader.lacksExclusiveRename(code) == lacks, "errno \(code)")
    }
}
