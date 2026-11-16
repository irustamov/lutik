import Testing
import Foundation
@testable import KernirCore

/// Extraction splits entry and destination paths on the scalar "/", as `EntryPath` does, never on Characters. A
/// "/" followed by a combining mark (U+0301) or a ZWJ, or preceded by a Prepend scalar (U+0600), is part of one
/// Character that is not "/", so a Character split hides the separator: the no-overwrite pre-check missed the
/// implied parent folder `d` of `d/\u{301}x`, the staging file went to the folder above the destination's (from
/// where the final rename could pass through a symlink the archive had just made), and a failure was blamed on no
/// item at all.
struct ExtractHiddenSlashTests {
    static let mark = "\u{301}"

    /// A tar of exactly these files (no folder headers), in this order.
    static func reader(_ files: [String: Data], order: [String]) async throws -> LibArchiveReader {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(files, in: dir)
        try Fixtures.bsdtar(["-cf", "t.tar", "--no-mac-metadata", "-n"] + order, cwd: dir)
        return try await LibArchiveReader.open(at: dir.appendingPathComponent("t.tar"), password: nil)
    }

    struct Hidden: Sendable, CustomTestStringConvertible {
        let entry: String
        let blocker: String
        let label: String
        var testDescription: String { label }
    }

    /// An entry whose parent folder is implied by a "/" that is not a Character of its own.
    static let hidden = [
        Hidden(entry: "d/\(mark)x", blocker: "d", label: "combining mark after /"),
        Hidden(entry: "a/\(mark)b/c.txt", blocker: "a", label: "combining mark after the first /"),
        Hidden(entry: "d/\u{200D}x", blocker: "d", label: "ZWJ after /"),
        Hidden(entry: "d\u{600}/x", blocker: "d\u{600}", label: "Prepend before /"),
    ]

    /// Pre-check: a file where a partial selection's implied parent folder goes is the topmost conflict, and
    /// nothing is written.
    @Test(arguments: hidden)
    func fileInTheWayOfAHiddenParentIsAConflict(_ c: Hidden) async throws {
        let r = try await Self.reader([c.entry: Data("new".utf8)], order: [c.entry])
        #expect(r.entries.contains { $0.path == c.entry })
        let out = ExtractNoOverwriteTests.dest()
        try ExtractNoOverwriteTests.write("mine", to: out.appendingPathComponent(c.blocker))
        #expect(LibArchiveReader.conflicts(of: r.entries.filter { $0.path == c.entry }, under: out.path)
                == [c.blocker])
        await #expect(throws: ExtractionConflictError(paths: [c.blocker])) {
            try await r.extract([c.entry], to: out, progress: nil)
        }
        #expect(ExtractNoOverwriteTests.text(out.appendingPathComponent(c.blocker)) == "mine")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [c.blocker])
    }

    /// The staging file goes next to its destination, under the folder the hidden "/" separates.
    @Test(arguments: [("/r/d/\(mark)x", "/r/d/"), ("/r/d/\u{200D}x", "/r/d/"), ("/r/d\u{600}/x", "/r/d\u{600}/"),
                      ("/r/a/\(mark)b/c", "/r/a/\(mark)b/"), ("/r/x", "/r/")])
    func stagingIsInTheDestinationsFolder(_ destination: String, _ folder: String) {
        let staging = LibArchiveReader.stagingPath(for: destination)
        let name = Array(staging.unicodeScalars.dropFirst(folder.unicodeScalars.count))
        #expect(staging.unicodeScalars.starts(with: folder.unicodeScalars), "\(staging.debugDescription)")
        #expect(String(String.UnicodeScalarView(name)).hasPrefix(".kernir-"), "\(staging.debugDescription)")
        #expect(!name.contains("/"), "\(staging.debugDescription)")
    }

    /// A folder listed after its file (tar -n) does not exist when the file is moved into place: the file's own
    /// write creates it, which only works when the staging file is inside it.
    @Test func folderListedAfterItsHiddenSlashFileExtracts() async throws {
        let path = "d/\(Self.mark)f.txt"
        let r = try await Self.reader([path: Data("f".utf8)], order: [path, "d"])
        #expect(r.headerOrdinalByPath == [path: 0, "d": 1])
        let out = ExtractNoOverwriteTests.dest()
        try await r.extract(nil, to: out, progress: nil)
        #expect(ExtractNoOverwriteTests.text(out.appendingPathComponent(path)) == "f")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["d"])
        let inside = try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("d").path)
        #expect(inside.map { Array($0.unicodeScalars) } == [Array("\(Self.mark)f.txt".unicodeScalars)])
    }

    /// `link -> outside` then `link/\u{301}pwn.txt`: the file must not land in `outside`. With the staging file in
    /// the folder above, libarchive's symlink check passed and the final rename followed `link`.
    @Test func fileBehindASymlinkAndAHiddenSlashIsRefused() async throws {
        let root = Fixtures.tempDir()
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let one = root.appendingPathComponent("one")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: one.appendingPathComponent("link").path,
                                                   withDestinationPath: outside.path)
        try Fixtures.bsdtar(["-cf", "../t.tar", "--no-mac-metadata", "link"], cwd: one)
        let two = root.appendingPathComponent("two")
        let pwn = "link/\(Self.mark)pwn.txt"
        Fixtures.makeFiles([pwn: Data("pwn".utf8)], in: two)
        try Fixtures.bsdtar(["-rf", "../t.tar", "--no-mac-metadata", pwn], cwd: two)
        let r = try await LibArchiveReader.open(at: root.appendingPathComponent("t.tar"), password: nil)
        #expect(r.headerOrdinalByPath == ["link": 0, pwn: 1])
        let out = ExtractNoOverwriteTests.dest()
        do {
            try await r.extract(nil, to: out, progress: nil)
            Issue.record("expected throw")
        } catch let e as ArchiveError {
            guard case .io = e else { Issue.record("unexpected \(e)"); return }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == [])
        // Nothing but the symlink is left in the destination (no staging file either).
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["link"])
    }

    /// Race path through a hidden parent: a file appears where `d` goes after `d/\u{301}f.txt` passed its check.
    /// Reported in the pre-check's form, the topmost item in the way.
    @Test func fileAppearingWhereAHiddenParentGoesIsAConflict() async throws {
        let path = "d/\(Self.mark)f.txt"
        let r = try await Self.reader(["a.txt": Data("a".utf8), path: Data("f".utf8)], order: ["a.txt", path, "d"])
        #expect(r.headerOrdinalByPath == ["a.txt": 0, path: 1, "d": 2])
        let out = ExtractNoOverwriteTests.dest()
        let foreign = out.appendingPathComponent("d")
        #expect(throws: ExtractionConflictError(paths: ["d"])) {
            try r.extractEntries(selection: nil, to: out, progress: nil, afterClaim: { dest in
                if dest == path { ExtractNoOverwriteTests.writeForeign(at: foreign) }
            })
        }
        try ExtractNoOverwriteTests.expectForeignUntouched(at: foreign)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: out.path)) == ["a.txt", "d"])
    }
}
