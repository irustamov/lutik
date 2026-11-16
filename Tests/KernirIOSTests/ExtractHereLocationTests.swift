import Foundation
import Testing
@testable import Kernir

/// Extract Here is off for an archive the system handed over as a copy, in the
/// app's tmp/ (tmp/<bundle>-Inbox from Mail and Share) or Documents/Inbox; everywhere else it is on.
/// Each test makes its own "tmp" and "Documents/Inbox" in a fresh folder and passes them in, so
/// nothing depends on where the host app's real tmp is (Fixture.copy puts every fixture there).
/// Mutants it kills: a string-prefix check (InboxOld, Inbox2, tmpX), a check that skips symlinks or
/// the /private/var spelling, one that needs the archive on disk, and one that ignores the list.
final class ExtractHereLocationTests {
    /// A fresh folder for this test, symlink-free spelling as FileManager gives it.
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernir-q10-\(UUID().uuidString)", isDirectory: true)
        for folder in ["tmp/com.kernir.app-Inbox", "Documents/Inbox/sub", "Documents/sub",
                       "Documents/InboxOld", "Documents/Inbox2", "tmpX", "tmpfoo", "Other"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// The folders the app would exclude, made in `root`.
    private var excluded: [URL] {
        [root.appendingPathComponent("tmp", isDirectory: true),
         root.appendingPathComponent("Documents/Inbox", isDirectory: true)]
    }

    /// `path` under `root`, created as an empty file when `exists`.
    private func archive(_ path: String, exists: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(path)
        if exists { try Data().write(to: url) }
        return url
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let path: String
        let allowed: Bool
        var exists = true
        var testDescription: String { "\(path) → \(allowed ? "on" : "off")\(exists ? "" : " (not on disk)")" }
    }

    static let cases: [Case] = [
        Case(path: "tmp/a.zip", allowed: false),
        Case(path: "tmp/com.kernir.app-Inbox/a.zip", allowed: false),
        Case(path: "Documents/Inbox/a.zip", allowed: false),
        Case(path: "Documents/Inbox/sub/a.zip", allowed: false),
        Case(path: "tmp/not-yet/a.zip", allowed: false, exists: false),
        Case(path: "Documents/Inbox/a.zip", allowed: false, exists: false),
        Case(path: "Documents/a.zip", allowed: true),
        Case(path: "Documents/sub/a.zip", allowed: true),
        Case(path: "Documents/Inbox.zip", allowed: true),
        Case(path: "Documents/InboxOld/a.zip", allowed: true),
        Case(path: "Documents/Inbox2/a.zip", allowed: true),
        Case(path: "tmpX/a.zip", allowed: true),
        Case(path: "tmpfoo/a.zip", allowed: true),
        Case(path: "Other/a.zip", allowed: true),
        Case(path: "Other/a.zip", allowed: true, exists: false),
    ]

    @Test(arguments: cases)
    func allowsExtractHere(_ entry: Case) throws {
        let url = try archive(entry.path, exists: entry.exists)
        #expect(ExtractHereLocation.allowsExtractHere(at: url, excluding: excluded) == entry.allowed)
    }

    /// Nothing excluded (what the ScreenState tests inject, since their fixtures sit in tmp): on.
    @Test func emptyListAllowsEverything() throws {
        #expect(ExtractHereLocation.allowsExtractHere(at: try archive("tmp/a.zip"), excluding: []))
        #expect(ExtractHereLocation.allowsExtractHere(at: try archive("Documents/Inbox/a.zip"), excluding: []))
    }

    /// An archive reached through a symlink into tmp is in tmp: off. So is one in Inbox when the
    /// excluded folder itself is spelled through a symlink.
    @Test func symlinksAreFollowed() throws {
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("link"),
                                           withDestinationURL: root.appendingPathComponent("tmp"))
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("inboxLink"),
                                           withDestinationURL: root.appendingPathComponent("Documents/Inbox"))
        _ = try archive("tmp/a.zip")
        #expect(!ExtractHereLocation.allowsExtractHere(at: root.appendingPathComponent("link/a.zip"), excluding: excluded))
        let inboxArchive = try archive("Documents/Inbox/b.zip")
        #expect(!ExtractHereLocation.allowsExtractHere(at: inboxArchive,
                                                      excluding: [root.appendingPathComponent("inboxLink")]))
    }

    /// A symlink in tmp that points out of it leads out: the archive is where it really is, on.
    @Test func symlinkOutOfTmpLeadsOut() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("tmp/out"),
                                                   withDestinationURL: root.appendingPathComponent("Other"))
        _ = try archive("Other/a.zip")
        #expect(ExtractHereLocation.allowsExtractHere(at: root.appendingPathComponent("tmp/out/a.zip"), excluding: excluded))
    }

    /// /var and /private/var are one folder, whichever side is spelled which way. Built by hand
    /// under /var (not on disk: the deepest existing ancestor is /var), so it runs on the simulator
    /// too, whose tmp is not under /var.
    @Test(arguments: [("/var", "/private/var"), ("/private/var", "/var")])
    func privateVarSpelling(excludedPrefix: String, archivePrefix: String) {
        let name = "kernir-q10-\(UUID().uuidString)"
        let folder = URL(fileURLWithPath: "\(excludedPrefix)/\(name)/tmp", isDirectory: true)
        #expect(!ExtractHereLocation.allowsExtractHere(at: URL(fileURLWithPath: "\(archivePrefix)/\(name)/tmp/a.zip"),
                                                      excluding: [folder]))
        #expect(ExtractHereLocation.allowsExtractHere(at: URL(fileURLWithPath: "\(archivePrefix)/\(name)/tmpX/a.zip"),
                                                     excluding: [folder]))
    }

    /// The same with this test's real folders, where the temporary folder is under /var (macOS,
    /// a device): the archive spelled with "/private" in front, then the excluded folders.
    @Test(.enabled(if: FileManager.default.temporaryDirectory.path.hasPrefix("/var/")))
    func privateVarSpellingOnDisk() throws {
        let url = try archive("tmp/a.zip")
        let privateURL = URL(fileURLWithPath: "/private" + url.path)
        #expect(!ExtractHereLocation.allowsExtractHere(at: privateURL, excluding: excluded))
        let privateExcluded = excluded.map { URL(fileURLWithPath: "/private" + $0.path, isDirectory: true) }
        #expect(!ExtractHereLocation.allowsExtractHere(at: url, excluding: privateExcluded))
        #expect(ExtractHereLocation.allowsExtractHere(at: try archive("Documents/a.zip"), excluding: privateExcluded))
    }

    /// The app's list: its temporary folder and Documents/Inbox, in that order.
    @Test func excludedFoldersAreTmpAndDocumentsInbox() throws {
        let fileManager = FileManager.default
        let documents = try #require(fileManager.urls(for: .documentDirectory, in: .userDomainMask).first)
        let folders = ExtractHereLocation.excludedFolders
        #expect(folders.map(\.standardizedFileURL.path)
                == [fileManager.temporaryDirectory, documents.appendingPathComponent("Inbox")].map(\.standardizedFileURL.path))
        let bundleInbox = fileManager.temporaryDirectory.appendingPathComponent("com.kernir.app-Inbox/a.zip")
        #expect(!ExtractHereLocation.allowsExtractHere(at: bundleInbox, excluding: folders))
        #expect(!ExtractHereLocation.allowsExtractHere(at: documents.appendingPathComponent("Inbox/a.zip"), excluding: folders))
        #expect(ExtractHereLocation.allowsExtractHere(at: documents.appendingPathComponent("a.zip"), excluding: folders))
    }

    // MARK: - Cache

    /// Counts `ExtractHereLocationCache`'s calls to its decision.
    private final class Calls {
        var urls: [URL] = []
    }

    /// The same URL and folders, asked again (every menu redraw): decided once, same answer.
    /// Mutant: a cache that decides every time (the disk read on every redraw).
    @Test func cacheDecidesOncePerURLAndFolders() throws {
        let calls = Calls()
        var cache = ExtractHereLocationCache { url, _ in
            calls.urls.append(url)
            return false
        }
        let url = try archive("tmp/a.zip")
        let first = cache.allowsExtractHere(at: url, excluding: excluded)
        let second = cache.allowsExtractHere(at: url, excluding: excluded)
        #expect(!first && !second)
        #expect(calls.urls == [url])
    }

    /// The archive moved (UIDocument's `fileURL` changed): decided again, for the new URL.
    /// Mutant: a cache keyed on the folders only, or one that never decides again.
    @Test func cacheDecidesAgainForANewURL() throws {
        var cache = ExtractHereLocationCache()
        let inTmp = try archive("tmp/a.zip")
        let inDocuments = try archive("Documents/a.zip")
        let answers = [inTmp, inDocuments, inTmp].map { cache.allowsExtractHere(at: $0, excluding: excluded) }
        #expect(answers == [false, true, false])
    }

    /// Other folders (tests set ScreenState's list): decided again, with them.
    /// Mutant: a cache keyed on the URL only.
    @Test func cacheDecidesAgainForNewFolders() throws {
        var cache = ExtractHereLocationCache()
        let url = try archive("tmp/a.zip")
        let answers = [excluded, [], excluded].map { cache.allowsExtractHere(at: url, excluding: $0) }
        #expect(answers == [false, true, false])
    }
}
