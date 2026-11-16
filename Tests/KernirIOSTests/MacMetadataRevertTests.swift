import Foundation
import Testing
import KernirCore
@testable import Kernir

/// A read of the file (UIDocument's revert after a change from outside) with nothing remembered for
/// it drops a Remove the session holds. Another app or iCloud replaced the file (a new file ID), so the
/// store rejects the record, and a stale Remove would strip contents the user never answered for (D4).
/// The next save keeps the Mac metadata and the next Save asks again. A Keep stays: keeping loses
/// nothing. Foundation only: the same file runs in a macOS SwiftPM mirror. `ArchiveDocument`
/// calls `adoptMacMetadataChoice(readWithFile:)` from `read(from:)` (open and revert) only.
@MainActor struct MacMetadataRevertTests {
    /// How the file was replaced from outside: either way, a new file ID.
    enum Replacement: CaseIterable, Sendable {
        /// Swapped in atomically (`replaceItemAt`, as iCloud or a safe save does): the same creation date.
        case swapped
        /// Deleted and written again: a new creation date too.
        case rewritten
    }

    private static func entry(_ path: String, isDirectory: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: isDirectory, size: isDirectory ? nil : 1,
                     compressedSize: isDirectory ? nil : 1, modificationDate: nil)
    }

    /// As Finder zips a folder: the files plus a `__MACOSX` tree of `._*` companions.
    private static let finderEntries = FakeReader.sample().entries + [
        entry("__MACOSX", isDirectory: true),
        entry("__MACOSX/._README.md"),
    ]

    /// A store in defaults of its own (`makeTestDefaults`) and an archive in a folder of its own.
    private struct Fixture {
        let suiteName: String
        let defaults: UserDefaults
        let store: MacMetadataChoiceStore
        let directory: URL
        let archive: URL

        /// `identityOfFile`: nil reads the real file's identity.
        init(identityOfFile: (@Sendable (String) -> MacMetadataChoiceStore.FileIdentity?)? = nil) throws {
            let (defaults, suiteName) = makeTestDefaults("MacMetadataRevertTests")
            (self.defaults, self.suiteName) = (defaults, suiteName)
            store = identityOfFile.map { MacMetadataChoiceStore(defaults: defaults, identityOfFile: $0) }
                ?? MacMetadataChoiceStore(defaults: defaults)
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacMetadataRevertTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            archive = directory.appendingPathComponent("finder.zip")
            try Data("zip".utf8).write(to: archive)
        }

        var isEmpty: Bool { defaults.object(forKey: MacMetadataChoiceStore.defaultsKey) == nil }

        func fileID() throws -> UInt64? {
            try URL(fileURLWithPath: archive.path).resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier
        }

        /// Another app or iCloud puts other contents at the archive's path.
        func replaceFromOutside(_ replacement: Replacement) throws {
            switch replacement {
            case .swapped:
                let written = directory.appendingPathComponent("outside-\(UUID().uuidString).zip")
                try Data("from outside".utf8).write(to: written)
                _ = try FileManager.default.replaceItemAt(archive, withItemAt: written)
            case .rewritten:
                try FileManager.default.removeItem(at: archive)
                Thread.sleep(forTimeInterval: 0.01)
                try Data("from outside".utf8).write(to: archive)
            }
        }

        func cleanUp() {
            removeTestDefaults(defaults, suite: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// A ready session over Finder entries, detected as a document does on open.
    private func openSession() -> (DocumentSession, ArchiveModel) {
        let session = DocumentSession()
        let model = ArchiveModel(reader: FakeReader(entries: Self.finderEntries), undoManager: nil)
        session.phase = .ready(model)
        session.detectMacMetadata(in: model.reader)
        return (session, model)
    }

    /// The revert: the store is read with the file, then the new reader (the replaced file, still with
    /// Mac metadata) is detected; an edit follows.
    private func revert(_ session: DocumentSession, in test: Fixture) -> ArchiveModel {
        session.adoptMacMetadataChoice(readWithFile: test.store.choice(for: test.archive))
        let model = ArchiveModel(reader: FakeReader(entries: Self.finderEntries), undoManager: nil)
        session.phase = .ready(model)
        session.detectMacMetadata(in: model.reader)
        model.remove(["notes.txt"])
        #expect(model.hasChanges)
        return model
    }

    /// The bug: Remove answered, the file replaced from outside, a revert, an edit. The save after it
    /// keeps the Mac metadata (Q-c7: nil options), the next Save asks (`needsMacMetadataAnswer`), and
    /// nothing is remembered.
    @Test(arguments: Replacement.allCases) func revertAfterAReplaceDropsTheRemove(_ replacement: Replacement) throws {
        let test = try Fixture()
        defer { test.cleanUp() }
        let (session, _) = openSession()
        session.answerMacMetadataQuestion(strips: true, for: test.archive, in: test.store)
        let answeredFileID = try #require(try test.fileID())

        try test.replaceFromOutside(replacement)
        #expect(try test.fileID() != answeredFileID)
        let model = revert(session, in: test)

        #expect(session.macMetadataChoice == nil)
        #expect(session.plainSaveChoice(for: model) == false)
        #expect(session.plainSaveOptions(for: model, default: true) == nil)
        #expect(session.needsMacMetadataAnswer(for: model))
        session.rememberMacMetadataChoiceAfterSave(of: test.archive, savedFileID: try test.fileID(), in: test.store)
        #expect(test.isEmpty)
    }

    /// A Remove the store couldn't keep (no file ID: the session's only) is dropped by a revert too:
    /// nothing tells the file read from the one answered for.
    @Test func revertDropsASessionOnlyRemove() throws {
        let test = try Fixture(identityOfFile: { _ in .init(fileID: nil, created: 1) })
        defer { test.cleanUp() }
        let (session, _) = openSession()
        session.answerMacMetadataQuestion(strips: true, for: test.archive, in: test.store)
        #expect(test.isEmpty)
        #expect(session.macMetadataChoice == true)

        let model = revert(session, in: test)

        #expect(session.macMetadataChoice == nil)
        #expect(session.plainSaveOptions(for: model, default: true) == nil)
        #expect(session.needsMacMetadataAnswer(for: model))
    }

    /// A Keep survives a revert after a replace: keeping the metadata loses nothing.
    @Test(arguments: Replacement.allCases) func revertAfterAReplaceKeepsAKeep(_ replacement: Replacement) throws {
        let test = try Fixture()
        defer { test.cleanUp() }
        let (session, _) = openSession()
        session.answerMacMetadataQuestion(strips: false, for: test.archive, in: test.store)

        try test.replaceFromOutside(replacement)
        let model = revert(session, in: test)

        #expect(session.macMetadataChoice == false)
        #expect(session.plainSaveOptions(for: model, default: true) == nil)
        #expect(!session.needsMacMetadataAnswer(for: model))
    }

    /// A read that finds the answer remembered for this file (the same file ID) takes it: a Remove stays.
    @Test(arguments: [false, true]) func readOfTheAnsweredFileKeepsTheAnswer(_ strips: Bool) throws {
        let test = try Fixture()
        defer { test.cleanUp() }
        let (session, _) = openSession()
        session.answerMacMetadataQuestion(strips: strips, for: test.archive, in: test.store)

        let model = revert(session, in: test)

        #expect(session.macMetadataChoice == strips)
        #expect(session.plainSaveChoice(for: model) == strips)
        #expect(!session.needsMacMetadataAnswer(for: model))
    }

    /// A fresh open adopts the remembered answer. A read with nothing remembered is the tests above.
    @Test(arguments: [false, true]) func openAdoptsWhatIsRemembered(_ remembered: Bool) {
        let (session, _) = openSession()
        session.adoptMacMetadataChoice(readWithFile: remembered)
        #expect(session.macMetadataChoice == remembered)
    }
}
