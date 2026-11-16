import Foundation
import os
import Testing
import KernirCore
import UIKit
@testable import Kernir

/// `ArchiveDocument`'s Mac metadata choice: the remembered answer
/// is read with the file, Mac metadata is detected once per reader, saves that can't ask keep it, and an
/// answer is remembered and follows the file through its saves. The rules themselves are
/// `DocumentSessionMacMetadataTests`. Each test has a choice store in defaults of its own
/// (`ChoiceStoreFixture`) whose archive file is the document's.
///
/// Serialized: `ArchiveDocument.engine` is a process-wide test seam.
@MainActor @Suite(.serialized) struct KeepMacMetadataTests {
    nonisolated private static func entry(_ path: String, isDirectory: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: isDirectory, size: isDirectory ? nil : 1,
                     compressedSize: isDirectory ? nil : 1, modificationDate: nil)
    }

    /// As Finder zips a folder: the files plus a `__MACOSX` tree of `._*` companions.
    nonisolated private static let finderEntries = FakeReader.sample().entries + [
        entry("__MACOSX", isDirectory: true),
        entry("__MACOSX/._README.md"),
    ]

    private static let stripOptions = ArchiveWriteOptions(excludesMacMetadata: true)

    private static func finderEngine(format: ArchiveFormat = .zip) -> FakeEngine {
        FakeEngine { FakeReader(entries: finderEntries, format: format, url: $0) }
    }

    private func makeDocument(_ fake: FakeEngine, _ test: ChoiceStoreFixture,
                              url: URL? = nil) -> ArchiveDocument {
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        let doc = ArchiveDocument(fileURL: url ?? test.archive, keychainService: KeychainPasswordStore.service,
                                  macMetadataChoices: test.store)
        // The app's default, pinned: a keep below is the choice's, not the default's.
        doc.plainSaveDefaultExcludesMacMetadata = true
        return doc
    }

    /// Opens a ready document and removes README.md from it.
    private func openWithRemoval(_ doc: ArchiveDocument) async throws -> ArchiveModel {
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model, "expected .ready, got \(doc.session.phase)")
        model.remove(["README.md"])
        try await waitUntil { doc.hasUnsavedChanges }
        #expect(doc.hasUnsavedChanges)
        return model
    }

    /// Waits up to 10 s for `condition`, letting the main run loop turn.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func snapshotOptions(_ doc: ArchiveDocument) throws -> ArchiveWriteOptions? {
        try #require(try doc.contents(forType: "public.zip-archive") as? ArchiveDocument.SaveSnapshot).options
    }

    // MARK: - Unanswered (Q-c3)

    @Test func openDetectsMacMetadataInTheSource() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let finder = makeDocument(Self.finderEngine(), test)
        #expect(await finder.openOnMain())
        #expect(finder.session.sourceHasMacMetadata)
        #expect(finder.session.macMetadataChoice == nil)
        await finder.closeOnMain()

        let plain = makeDocument(FakeEngine(), test)
        #expect(await plain.openOnMain())
        #expect(!plain.session.sourceHasMacMetadata)
        await plain.closeOnMain()
    }

    /// U3: closing before any answer keeps the Mac metadata (nil options) and records nothing.
    @Test func closeBeforeAnAnswerKeepsAndRecordsNothing() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let fake = Self.finderEngine()
        let doc = makeDocument(fake, test)
        _ = try await openWithRemoval(doc)

        #expect(await doc.closeOnMain())

        let write = try #require(fake.writeCalls.last)
        // The removal takes README.md's own `._README.md` companion along (`ArchiveModel.edit`, older than this
        // test); the rest of the Mac metadata (here `__MACOSX` itself) is kept,
        // which `options == nil` checks.
        #expect(write.changes.removedPaths == ["README.md", "__MACOSX/._README.md"])
        #expect(write.options == nil)
        #expect(test.isEmpty)
    }

    /// U4: a background save before any answer keeps it too.
    @Test func backgroundSaveBeforeAnAnswerKeeps() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let fake = Self.finderEngine()
        let doc = makeDocument(fake, test)
        _ = try await openWithRemoval(doc)

        doc.saveForBackground()
        try await waitUntil { !fake.writeCalls.isEmpty && !doc.hasUnsavedChanges && doc.session.saveFraction == nil }

        #expect(fake.writeCalls.count == 1)
        #expect(fake.writeCalls.first?.options == nil)
        #expect(test.isEmpty)
        await doc.closeOnMain()
    }

    /// U5: no Mac metadata in the source: the app's default, as before (c).
    @Test func unansweredWithoutMetadataFollowsTheDefault() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let fake = FakeEngine()
        let doc = makeDocument(fake, test)
        _ = try await openWithRemoval(doc)

        #expect(await doc.commitSave())

        #expect(fake.writeCalls.last?.options == Self.stripOptions)
        #expect(test.isEmpty)
        await doc.closeOnMain()
    }

    // MARK: - Answered

    /// The answer reaches the save snapshot at once, without another edit, and is remembered; after
    /// the save the record follows the new file (UIDocument's safe save gives it a new file ID). The hosted
    /// check that UIKit's swap keeps the ID of the file `writeContents` wrote: otherwise the remember after
    /// the save drops the Remove, as for a file replaced from outside, and this fails.
    @Test func answerRefreshesTheSnapshotAndFollowsTheSavedFile() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let fake = Self.finderEngine()
        let doc = makeDocument(fake, test)
        _ = try await openWithRemoval(doc)
        #expect(try snapshotOptions(doc) == nil)

        doc.setMacMetadataChoice(true)

        #expect(doc.session.macMetadataChoice == true)
        #expect(try snapshotOptions(doc) == Self.stripOptions)
        #expect(test.store.choice(for: doc.fileURL) == true)
        let answeredFileID = test.store.fileID(of: test.archive)
        #expect(await doc.commitSave())
        #expect(fake.writeCalls.last?.options == Self.stripOptions)
        // `commitSave()` returns once the remember after the save has run.
        #expect(test.store.fileID(of: test.archive) != answeredFileID)
        #expect(doc.session.macMetadataChoice == true)
        #expect(test.store.choice(for: test.archive) == true)
        await doc.closeOnMain()
        #expect(test.reloaded().choice(for: test.archive) == true)
    }

    /// Answering changes no entry: no unsaved changes, nothing to undo.
    @Test func answeringDoesNotDirtyOrRegisterUndo() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let fake = Self.finderEngine()
        let doc = makeDocument(fake, test)
        #expect(await doc.openOnMain())

        doc.setMacMetadataChoice(false)
        try await Task.sleep(for: .milliseconds(100))

        #expect(!doc.hasUnsavedChanges)
        #expect(doc.undoManager?.canUndo == false)
        await doc.closeOnMain()
        #expect(fake.writeCalls.isEmpty)
    }

    /// Keep on an unlocked encrypted 7z: nil options keep its encryption and password. Remove: its
    /// encryption with the password that unlocked it.
    @Test(arguments: [false, true]) func answerOnAnEncryptedSevenZip(_ strips: Bool) async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let fake = FakeEngine(password: "kernir", listsWithoutPassword: true) {
            FakeReader(entries: Self.finderEntries, format: .sevenZip, url: $0, isEncrypted: true)
        }
        let doc = makeDocument(fake, test)
        #expect(await doc.openOnMain())
        await doc.unlock(password: "kernir", remember: false)
        let model = try #require(doc.session.model)
        model.remove(["README.md"])
        try await waitUntil { doc.hasUnsavedChanges }

        doc.setMacMetadataChoice(strips)
        #expect(await doc.commitSave())

        #expect(fake.writeCalls.last?.options
            == (strips ? ArchiveWriteOptions(encryption: .aes256, password: "kernir", excludesMacMetadata: true) : nil))
        await doc.closeOnMain()
    }

    // MARK: - Remembered

    /// The answer is per file and remembered: a new document on the answered file reads it (a remembered
    /// Remove strips on a close, and stays remembered for the file that close wrote); another file stays
    /// unanswered.
    @Test func choiceIsPerFileAndRememberedOnReopen() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let first = makeDocument(Self.finderEngine(), test)
        #expect(await first.openOnMain())
        first.setMacMetadataChoice(true)
        await first.closeOnMain()

        let fake = Self.finderEngine()
        let again = makeDocument(fake, test)
        _ = try await openWithRemoval(again)
        #expect(again.session.macMetadataChoice == true)
        #expect(await again.closeOnMain())
        #expect(fake.writeCalls.last?.options == Self.stripOptions)
        // The safe save gave the file a new ID, which a Remove matches by. `save(to:for:completionHandler:)`
        // remembers the answer for the new file before it calls the completion that ends the close. The
        // bounded wait is a backstop, in case UIKit closes through its private path without calling the
        // override and ends the close before the remember.
        try await waitUntil { test.reloaded().choice(for: test.archive) == true }
        #expect(test.reloaded().choice(for: test.archive) == true)

        let other = test.directory.appendingPathComponent("other.zip")
        try Data("zip".utf8).write(to: other)
        let otherDocument = makeDocument(Self.finderEngine(), test, url: other)
        #expect(await otherDocument.openOnMain())
        #expect(otherDocument.session.macMetadataChoice == nil)
        await otherDocument.closeOnMain()
    }

    /// U8: a revert reads the remembered answer again. After the file was replaced from outside (a new file
    /// ID) the store has none, and the session's Remove goes: the next Save asks. The hosted check
    /// that `read(from:)` reads through `adoptMacMetadataChoice(readWithFile:)`.
    @Test func revertReadsTheRememberedChoice() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let doc = makeDocument(Self.finderEngine(), test)
        #expect(await doc.openOnMain())
        #expect(doc.session.macMetadataChoice == nil)

        test.store.remember(false, for: test.archive)
        #expect(await doc.revertOnMain(toContentsOf: doc.fileURL))
        try await waitUntil { doc.session.macMetadataChoice != nil }
        #expect(doc.session.macMetadataChoice == false)

        doc.setMacMetadataChoice(true)
        #expect(test.store.choice(for: test.archive) == true)
        // Another app or iCloud swaps in other contents, as a safe save does: a new file ID.
        try test.safeSave()
        let before = try #require(doc.session.model)
        #expect(await doc.revertOnMain(toContentsOf: doc.fileURL))
        // The revert's read gives the session a new model: wait for it, not for any model.
        try await waitUntil { doc.session.model.map { $0 !== before } ?? false }
        let reverted = try #require(doc.session.model)
        #expect(reverted !== before, "the revert read the file again")
        #expect(doc.session.macMetadataChoice == nil)
        #expect(doc.session.sourceHasMacMetadata)
        #expect(doc.session.needsMacMetadataAnswer(for: reverted))
        await doc.closeOnMain()
    }

    /// After a Remove is saved, the reopened archive holds no Mac metadata any more: detected again.
    @Test func detectionIsRedoneAfterASave() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let opens = OSAllocatedUnfairLock(initialState: 0)
        let fake = FakeEngine { url in
            let first = opens.withLock { count -> Bool in
                count += 1
                return count == 1
            }
            return FakeReader(entries: first ? Self.finderEntries : FakeReader.sample().entries, url: url)
        }
        let doc = makeDocument(fake, test)
        _ = try await openWithRemoval(doc)
        #expect(doc.session.sourceHasMacMetadata)

        doc.setMacMetadataChoice(true)
        #expect(await doc.commitSave())

        #expect(opens.withLock { $0 } == 2)
        #expect(!doc.session.sourceHasMacMetadata)
        #expect(doc.session.macMetadataChoice == true)
        await doc.closeOnMain()
    }

    // MARK: - Save's question (ScreenState)

    /// Save asks first and writes nothing; the answer is remembered and the save writes with it.
    @Test(arguments: [false, true]) func saveAsksThenWritesTheAnswer(_ remove: Bool) async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let fake = Self.finderEngine()
        let doc = makeDocument(fake, test)
        let state = ScreenState(document: doc)
        _ = try await openWithRemoval(doc)

        await state.save()
        #expect(state.macMetadataQuestion)
        #expect(fake.writeCalls.isEmpty)
        #expect(doc.hasUnsavedChanges)

        await state.answerMacMetadataQuestion(remove: remove)

        #expect(!state.macMetadataQuestion)
        #expect(fake.writeCalls.count == 1)
        #expect(fake.writeCalls.last?.options == (remove ? Self.stripOptions : nil))
        #expect(test.store.choice(for: doc.fileURL) == remove)
        await doc.closeOnMain()
    }

    /// Q-c5a: after the answer, Save As Copy's "Exclude Mac metadata" starts from it, and the copy is
    /// written with it. The copy records nothing: the store holds the original's record only.
    @Test(arguments: [false, true]) func saveAsCopyStartsFromTheAnswerAndRecordsNothing(_ remove: Bool) async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let fake = Self.finderEngine()
        let doc = makeDocument(fake, test)
        let state = ScreenState(document: doc)
        _ = try await openWithRemoval(doc)
        await state.save()
        await state.answerMacMetadataQuestion(remove: remove)
        #expect(fake.writeCalls.count == 1)
        try await waitUntil { doc.session.saveFraction == nil }

        state.beginSaveAsCopy()
        let request = try #require(state.saveAsCopyRequest)
        #expect(request.settings.options.excludesMacMetadata == remove)

        state.confirmSaveAsCopy(request.settings)
        await state.saveOptionsSheetDidDismiss()
        let copy = try #require(state.movingCopy)
        #expect(fake.writeCalls.count == 2)
        #expect(fake.writeCalls.last?.url == copy)
        #expect(fake.writeCalls.last?.options?.excludesMacMetadata == remove)
        state.copyMoveDidFinish()

        #expect(test.recordedPaths == [test.archivePath])
        #expect(test.reloaded().choice(for: test.archive) == remove)
        await doc.closeOnMain()
    }

    /// Cancel writes and remembers nothing; the edits stay unsaved.
    @Test func cancelSavesNothingAndRemembersNothing() async throws {
        let test = try ChoiceStoreFixture()
        defer { test.cleanUp() }
        let fake = Self.finderEngine()
        let doc = makeDocument(fake, test)
        let state = ScreenState(document: doc)
        _ = try await openWithRemoval(doc)

        await state.save()
        state.cancelMacMetadataQuestion()
        try await Task.sleep(for: .milliseconds(100))

        #expect(!state.macMetadataQuestion)
        #expect(fake.writeCalls.isEmpty)
        #expect(doc.hasUnsavedChanges)
        #expect(test.isEmpty)
        await doc.closeOnMain()
    }
}
