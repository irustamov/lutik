import Foundation
import Testing
import KernirCore
import UIKit
@testable import Kernir

/// Serialized: `ArchiveDocument.engine` is a process-wide test seam.
@MainActor @Suite(.serialized) struct ArchiveDocumentTests {
    let fixture: URL

    init() throws {
        fixture = try Fixture.copy("zip/deflate.zip")
    }

    private func makeDocument(_ fake: FakeEngine) -> ArchiveDocument {
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        return ArchiveDocument(fileURL: fixture)
    }

    /// Opens a document whose model is ready and removes README.md from it.
    private func openWithRemoval(_ fake: FakeEngine) async throws -> ArchiveDocument {
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model)
        model.remove(["README.md"])
        #expect(model.hasChanges)
        // UIDocument counts the edit when the undo group closes, at the end of this run loop turn.
        try await waitForUnsavedChanges(doc)
        return doc
    }

    @Test func openReadsByURLOnly() async throws {
        let fake = FakeEngine()
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        #expect(fake.openCalls == [.init(url: doc.fileURL, password: nil)])
        let model = try #require(doc.session.model)
        #expect(model.items.count == FakeReader.sample().topLevelCount)
        await doc.closeOnMain()
    }

    @Test func passwordRequiredLocks() async {
        let doc = makeDocument(FakeEngine(password: "kernir"))
        #expect(await doc.openOnMain())
        guard case .locked(let error) = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            return
        }
        #expect(error == nil)
        await doc.closeOnMain()
    }

    @Test func wrongPasswordStaysLocked() async {
        let fake = FakeEngine(password: "kernir")
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        await doc.unlock(password: "x", remember: false)
        guard case .locked(let error) = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            return
        }
        #expect(error == ArchiveError.wrongPassword.localizedDescription)
        #expect(fake.openCalls.last == .init(url: doc.fileURL, password: "x"))
        await doc.closeOnMain()
    }

    @Test func unlockOpens() async throws {
        let doc = makeDocument(FakeEngine(password: "kernir"))
        #expect(await doc.openOnMain())
        await doc.unlock(password: "kernir", remember: false)
        let model = try #require(doc.session.model)
        #expect(model.password == "kernir")
        #expect(model.items.count == FakeReader.sample().topLevelCount)
        await doc.closeOnMain()
    }

    /// An encrypted ZIP lists without a password, but the spec asks for the password on open.
    @Test func encryptedArchiveLocksUntilPassword() async throws {
        let fake = FakeEngine(password: "kernir", listsWithoutPassword: true)
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        guard case .locked(let error) = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            return
        }
        #expect(error == nil)
        await doc.unlock(password: "nope", remember: false)
        guard case .locked(let wrong) = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            return
        }
        #expect(wrong == ArchiveError.wrongPassword.localizedDescription)
        await doc.unlock(password: "kernir", remember: false)
        let model = try #require(doc.session.model)
        #expect(model.password == "kernir")
        await doc.closeOnMain()
    }

    /// A 7z with encrypted data and plain headers lists without a password, but like
    /// ZIP it stays locked until one is given; the engine checks it on open.
    @Test func encryptedSevenZipLocksUntilPassword() async throws {
        let fake = FakeEngine(password: "kernir", listsWithoutPassword: true, reader: { url in
            FakeReader(entries: FakeReader.sample().entries, format: .sevenZip, url: url, isEncrypted: true)
        })
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        guard case .locked(let error) = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            return
        }
        #expect(error == nil)
        await doc.unlock(password: "nope", remember: false)
        guard case .locked(let wrong) = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            return
        }
        #expect(wrong == ArchiveError.wrongPassword.localizedDescription)
        await doc.unlock(password: "kernir", remember: false)
        let model = try #require(doc.session.model, "expected .ready, got \(doc.session.phase)")
        #expect(model.format == .sevenZip)
        #expect(model.password == "kernir")
        await doc.closeOnMain()
    }

    /// A 7z with encrypted headers can't list without a password, so the engine throws
    /// `.passwordRequired` and the document locks; the right password opens it.
    @Test func headerEncryptedSevenZipLocksUntilPassword() async throws {
        let fake = FakeEngine(password: "kernir", reader: { url in
            FakeReader(entries: FakeReader.sample().entries, format: .sevenZip, url: url, isEncrypted: true)
        })
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        guard case .locked(let error) = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            return
        }
        #expect(error == nil)
        await doc.unlock(password: "kernir", remember: false)
        let model = try #require(doc.session.model, "expected .ready, got \(doc.session.phase)")
        #expect(model.format == .sevenZip)
        #expect(model.password == "kernir")
        await doc.closeOnMain()
    }

    /// For RAR, one with encrypted data lists and opens ready (read-only),
    /// never locked.
    @Test func encryptedRarNeverLocks() async throws {
        let fake = FakeEngine(reader: { url in
            FakeReader(entries: FakeReader.sample().entries, format: .rar, url: url, isEncrypted: true)
        })
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model, "expected .ready, got \(doc.session.phase)")
        #expect(model.format == .rar)
        #expect(model.password == nil)
        #expect(fake.openCalls == [.init(url: doc.fileURL, password: nil)])
        await doc.closeOnMain()
    }

    /// A RAR with encrypted headers can't be opened at all, so it fails with the alert.
    @Test func unsupportedEncryptionFails() async {
        let doc = makeDocument(FakeEngine(openError: .unsupportedEncryption(.rar)))
        #expect(await doc.openOnMain())
        guard case .failed(let message) = doc.session.phase else {
            Issue.record("expected .failed, got \(doc.session.phase)")
            return
        }
        #expect(message == ArchiveError.unsupportedEncryption(.rar).localizedDescription)
        #expect(message.contains("RAR"))
        await doc.closeOnMain()
    }

    @Test func timerAutosaveSkipped() async throws {
        let fake = FakeEngine()
        let doc = try await openWithRemoval(fake)
        #expect(doc.hasUnsavedChanges)
        #expect(await doc.autosaveOnMain() == false)
        #expect(fake.writeCalls.isEmpty)
        #expect(doc.hasUnsavedChanges)
        await doc.closeOnMain()
    }

    @Test func commitSaveWritesInPlaceAndReopens() async throws {
        let fake = FakeEngine()
        let doc = try await openWithRemoval(fake)
        // No sheet saved it: the shared plain-save options.
        let plainSaveOptions = ArchiveSaveSettings.writeOptions(for: try #require(doc.session.model))
        #expect(await doc.commitSave())
        #expect(fake.writeCalls.count == 1)
        let write = try #require(fake.writeCalls.first)
        #expect(write.options == plainSaveOptions)
        #expect(write.changes.removedPaths == ["README.md"])
        #expect(write.format == .zip)
        #expect(fake.openCalls.count == 2)
        #expect(fake.openCalls.last?.url == doc.fileURL)
        let model = try #require(doc.session.model)
        #expect(model.hasChanges == false)
        #expect(doc.hasUnsavedChanges == false)
        #expect(doc.session.saveFraction == nil)
        #expect(doc.session.saveError == nil)
        await doc.closeOnMain()
        #expect(fake.writeCalls.count == 1)
    }

    /// A new archive made with "Exclude Mac metadata" on keeps the choice (its creation
    /// settings), so every plain save of its document passes the flag (it strips on
    /// every save), the save after a reopen too.
    @Test func newArchiveWithExcludeOnPassesFlagOnPlainSave() async throws {
        let fake = FakeEngine(reader: { FakeReader(entries: [], url: $0) })
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var settings = NewArchiveFlow.defaultSettings()
        settings.options.excludesMacMetadata = true
        let created = try await NewArchiveFlow.create(with: settings)
        #expect(fake.writeCalls.last?.options?.excludesMacMetadata == true, "the empty archive")
        let destination = folder.appendingPathComponent(created.lastPathComponent)
        try FileManager.default.moveItem(at: created, to: destination)
        NewArchiveFlow.didImport(from: created, to: destination)

        let doc = ArchiveDocument(fileURL: destination)
        #expect(await doc.openOnMain())
        for name in ["a.txt", "b.txt"] {
            let model = try #require(doc.session.model)
            #expect(model.saveOptions?.excludesMacMetadata == true)
            let file = folder.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            model.add([file], to: "")
            try await waitForUnsavedChanges(doc)
            #expect(await doc.commitSave())
            let write = try #require(fake.writeCalls.last)
            #expect(write.options?.excludesMacMetadata == true, "plain save adding \(name)")
        }
        #expect(fake.writeCalls.count == 3)
        await doc.closeOnMain()
    }

    @Test func failedSaveKeepsOriginalAndChanges() async throws {
        let original = try Data(contentsOf: fixture)
        let fake = FakeEngine(writeError: .io("disk full"))
        let doc = try await openWithRemoval(fake)
        #expect(await doc.commitSave() == false)
        #expect(try Data(contentsOf: fixture) == original)
        let model = try #require(doc.session.model)
        #expect(model.hasChanges)
        #expect(doc.session.saveError != nil)
        #expect(doc.session.saveFraction == nil)
        #expect(fake.openCalls.count == 1)
        await doc.closeOnMain()
        #expect(try Data(contentsOf: fixture) == original)
    }

    @Test func closeWithPendingChangesSavesOnce() async throws {
        let fake = FakeEngine()
        let doc = try await openWithRemoval(fake)
        #expect(await doc.closeOnMain())
        #expect(fake.writeCalls.count == 1)
        #expect(fake.writeCalls.first?.changes.removedPaths == ["README.md"])
        #expect(fake.openCalls.count == 1)
    }

    @Test func contentsOffMainUsesLatestSnapshot() async throws {
        let doc = try await openWithRemoval(FakeEngine())
        let box = SendableDocument(document: doc)
        // The main actor is suspended in `await`, not blocked, while UIKit-style code runs elsewhere.
        let (onMain, contents) = try await Task.detached {
            try Self.contentsOnCurrentThread(of: box)
        }.value
        #expect(onMain == false)
        let snapshot = try #require(contents)
        #expect(snapshot.changes.removedPaths == ["README.md"])
        #expect(snapshot.format == .zip)
        #expect(snapshot.options == ArchiveSaveSettings.writeOptions(for: try #require(doc.session.model)))
        await doc.closeOnMain()
    }

    private nonisolated static func contentsOnCurrentThread(
        of box: SendableDocument
    ) throws -> (Bool, ArchiveDocument.SaveSnapshot?) {
        (Thread.isMainThread, try box.document.contents(forType: "public.zip-archive") as? ArchiveDocument.SaveSnapshot)
    }

    /// Waits up to 1 s for UIDocument to count an edit (when its undo group closes).
    private func waitForUnsavedChanges(_ doc: ArchiveDocument) async throws {
        for _ in 0..<100 where !doc.hasUnsavedChanges {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(doc.hasUnsavedChanges)
    }

    /// A plain save (the Save button, closing, backgrounding: no options sheet)
    /// writes with the shared plain-save options, `ArchiveSaveSettings.writeOptions(for:)`, as the
    /// Mac's ⌘S does, following the document's `plainSaveDefaultExcludesMacMetadata` (the app's
    /// default; forced here either way). Default on: they carry the password that unlocked the
    /// archive, so a save that strips Mac metadata keeps the source's encryption. Default off: nil.
    @Test(arguments: [false, true]) func plainSaveWritesTheSharedPlainSaveOptions(_ excludesByDefault: Bool) async throws {
        let fake = FakeEngine(password: "kernir", listsWithoutPassword: true, reader: { url in
            FakeReader(entries: FakeReader.sample().entries, format: .sevenZip, url: url, isEncrypted: true)
        })
        let doc = makeDocument(fake)
        doc.plainSaveDefaultExcludesMacMetadata = excludesByDefault
        #expect(await doc.openOnMain())
        await doc.unlock(password: "kernir", remember: false)
        let model = try #require(doc.session.model)
        #expect(model.saveOptions == nil)
        model.remove(["README.md"])
        try await waitForUnsavedChanges(doc)

        #expect(await doc.commitSave())
        let write = try #require(fake.writeCalls.last)
        #expect(fake.writeCalls.count == 1)
        #expect(write.format == .sevenZip)
        #expect(write.changes.removedPaths == ["README.md"])
        #expect(write.options == (excludesByDefault
            ? ArchiveWriteOptions(encryption: .aes256, password: "kernir", excludesMacMetadata: true) : nil))
        await doc.closeOnMain()
    }

    /// The same for an unencrypted archive: default on, explicit options that strip, with the
    /// source's method (the fake reader has none) and no encryption or password. Default off: nil.
    @Test(arguments: [false, true]) func plainSaveOfAPlainArchiveFollowsTheDefault(_ excludesByDefault: Bool) async throws {
        let fake = FakeEngine()
        let doc = makeDocument(fake)
        doc.plainSaveDefaultExcludesMacMetadata = excludesByDefault
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model)
        #expect(model.saveOptions == nil)
        #expect(model.reader?.compressionMethod == nil)
        model.remove(["README.md"])
        try await waitForUnsavedChanges(doc)

        #expect(await doc.commitSave())
        let write = try #require(fake.writeCalls.last)
        #expect(fake.writeCalls.count == 1)
        #expect(write.format == .zip)
        #expect(write.options == (excludesByDefault ? ArchiveWriteOptions(excludesMacMetadata: true) : nil))
        await doc.closeOnMain()
    }

    /// Options a sheet saved with the document (`ArchiveModel.apply`) keep their "Exclude Mac
    /// metadata" choice, either way, on every plain save, whatever the app's default.
    @Test(arguments: [false, true]) func plainSaveKeepsTheSavedChoice(_ excludes: Bool) async throws {
        let fake = FakeEngine()
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model)
        let saved = ArchiveWriteOptions(method: .store, excludesMacMetadata: excludes)
        model.apply(ArchiveSaveSettings(format: .zip, options: saved))
        model.remove(["README.md"])
        try await waitForUnsavedChanges(doc)

        #expect(await doc.commitSave())
        #expect(fake.writeCalls.last?.options == saved)
        await doc.closeOnMain()
    }

    @Test func revertKeepsPassword() async throws {
        let fake = FakeEngine(password: "kernir")
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        await doc.unlock(password: "kernir", remember: false)
        #expect(await doc.revertOnMain(toContentsOf: doc.fileURL))
        #expect(doc.session.model != nil, "expected .ready, got \(doc.session.phase)")
        #expect(fake.openCalls.count == 3)
        #expect(fake.openCalls.last?.password == "kernir")
        await doc.closeOnMain()
    }

    /// Waits up to 10 s for `condition`, letting the main run loop turn.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A window going to the background (its scene's `sceneDidEnterBackground`) saves its own
    /// document's pending edits, once, even while the app as a whole stays active.
    @Test func sceneBackgroundSavesPendingEdits() async throws {
        let fake = FakeEngine()
        let doc = try await openWithRemoval(fake)
        doc.saveForBackground()
        try await waitUntil { !fake.writeCalls.isEmpty && !doc.hasUnsavedChanges && doc.session.saveFraction == nil }
        // Room for a second, duplicate save to show up.
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.writeCalls.count == 1)
        #expect(fake.writeCalls.first?.changes.removedPaths == ["README.md"])
        #expect(doc.hasUnsavedChanges == false)
        #expect(doc.session.saveError == nil)
        await doc.closeOnMain()
        #expect(fake.writeCalls.count == 1)
    }

    /// UIKit's own background save may still be writing when the scene goes to the background.
    @Test func backgroundingDuringSaveDoesNotSaveAgain() async throws {
        let fake = FakeEngine(writeDelay: .milliseconds(300))
        let doc = try await openWithRemoval(fake)
        let saving = Task { await doc.commitSave() }
        try await waitUntil { !fake.writeCalls.isEmpty }
        #expect(doc.hasUnsavedChanges)
        doc.saveForBackground()
        #expect(await saving.value)
        try await Task.sleep(for: .milliseconds(600))
        #expect(fake.writeCalls.count == 1)
        #expect(doc.hasUnsavedChanges == false)
        await doc.closeOnMain()
        #expect(fake.writeCalls.count == 1)
    }

    @Test func backgroundingWithoutChangesDoesNotWrite() async throws {
        let fake = FakeEngine()
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        doc.saveForBackground()
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.writeCalls.isEmpty)
        await doc.closeOnMain()
    }

    /// Production closes the document from a background thread.
    @Test func closeOffMainSavesOnce() async throws {
        let fake = FakeEngine()
        let doc = try await openWithRemoval(fake)
        let box = SendableDocument(document: doc)
        let (onMain, ok) = await Task.detached {
            await withCheckedContinuation { continuation in
                let onMain = Thread.isMainThread
                box.document.close { continuation.resume(returning: (onMain, $0)) }
            }
        }.value
        #expect(onMain == false)
        #expect(ok)
        #expect(fake.writeCalls.count == 1)
        #expect(fake.writeCalls.first?.changes.removedPaths == ["README.md"])
        #expect(fake.openCalls.count == 1)
    }

    /// The undo manager may post its notifications off main (e.g. from UIKit's save path).
    @Test func undoNotificationOffMainRefreshesOnMain() async throws {
        let doc = try await openWithRemoval(FakeEngine())
        let box = SendableDocument(document: doc)
        await Task.detached {
            Self.postCheckpoint(for: box)
        }.value
        try await Task.sleep(for: .milliseconds(50))
        let snapshot = try #require(try doc.contents(forType: "public.zip-archive") as? ArchiveDocument.SaveSnapshot)
        #expect(snapshot.changes.removedPaths == ["README.md"])
        await doc.closeOnMain()
    }

    private nonisolated static func postCheckpoint(for box: SendableDocument) {
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: box.document.undoManager)
    }

    // MARK: - Keychain

    /// A copy of the AES-256 ZIP (password "kernir") opened with KernirCore's real reader, with a
    /// Keychain service of its own so tests never see the app's remembered passwords.
    private func makeEncryptedDocument() throws -> (ArchiveDocument, service: String) {
        let url = try Fixture.copy("zip/aes256.zip")
        let service = "com.kernir.app.tests.\(UUID().uuidString)"
        ArchiveDocument.engine = .live
        return (ArchiveDocument(fileURL: url, keychainService: service), service)
    }

    private func isLocked(_ doc: ArchiveDocument) -> Bool {
        if case .locked = doc.session.phase { true } else { false }
    }

    @Test func rememberedPasswordOpensWithoutPrompt() async throws {
        let (doc, service) = try makeEncryptedDocument()
        defer { KeychainPasswordStore.remove(for: doc.fileURL, service: service) }
        KeychainPasswordStore.save("kernir", for: doc.fileURL, service: service)
        #expect(KeychainPasswordStore.password(for: doc.fileURL, service: service) == "kernir")
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model, "expected .ready, got \(doc.session.phase)")
        #expect(model.password == "kernir")
        #expect(model.items.contains { $0.name == "hello.txt" })
        // The remembered password is the document's password from now on (a revert keeps it).
        #expect(await doc.revertOnMain(toContentsOf: doc.fileURL))
        #expect(doc.session.model?.password == "kernir", "expected .ready, got \(doc.session.phase)")
        await doc.closeOnMain()
    }

    @Test func stalePasswordLocksWithoutError() async throws {
        let (doc, service) = try makeEncryptedDocument()
        defer { KeychainPasswordStore.remove(for: doc.fileURL, service: service) }
        KeychainPasswordStore.save("nope", for: doc.fileURL, service: service)
        #expect(KeychainPasswordStore.password(for: doc.fileURL, service: service) == "nope")
        #expect(await doc.openOnMain())
        guard case .locked(let error) = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            return
        }
        #expect(error == nil)
        await doc.closeOnMain()
    }

    @Test func unlockWithRememberSavesPassword() async throws {
        let (rejected, rejectedService) = try makeEncryptedDocument()
        defer { KeychainPasswordStore.remove(for: rejected.fileURL, service: rejectedService) }
        #expect(await rejected.openOnMain())
        await rejected.unlock(password: "nope", remember: true)
        #expect(isLocked(rejected), "expected .locked, got \(rejected.session.phase)")
        #expect(KeychainPasswordStore.password(for: rejected.fileURL, service: rejectedService) == nil)
        await rejected.closeOnMain()

        let (forgotten, forgottenService) = try makeEncryptedDocument()
        defer { KeychainPasswordStore.remove(for: forgotten.fileURL, service: forgottenService) }
        #expect(await forgotten.openOnMain())
        await forgotten.unlock(password: "kernir", remember: false)
        #expect(forgotten.session.model != nil, "expected .ready, got \(forgotten.session.phase)")
        #expect(KeychainPasswordStore.password(for: forgotten.fileURL, service: forgottenService) == nil)
        await forgotten.closeOnMain()

        let (remembered, rememberedService) = try makeEncryptedDocument()
        defer { KeychainPasswordStore.remove(for: remembered.fileURL, service: rememberedService) }
        #expect(await remembered.openOnMain())
        #expect(isLocked(remembered), "expected .locked, got \(remembered.session.phase)")
        await remembered.unlock(password: "kernir", remember: true)
        #expect(remembered.session.model != nil, "expected .ready, got \(remembered.session.phase)")
        #expect(KeychainPasswordStore.password(for: remembered.fileURL, service: rememberedService) == "kernir")
        await remembered.closeOnMain()
    }

    @Test func unlockWhileReadyIsIgnored() async throws {
        let fake = FakeEngine()
        let doc = try await openWithRemoval(fake)
        let model = try #require(doc.session.model)
        await doc.unlock(password: "x", remember: false)
        #expect(fake.openCalls.count == 1)
        #expect(doc.session.model === model)
        #expect(model.hasChanges)
        #expect(model.password == nil)
        #expect(doc.hasUnsavedChanges)
        await doc.closeOnMain()
    }

    // MARK: - Text Encoding

    /// DOS Russian; KernirCore keeps its own constant internal.
    private static let cp866 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosRussian.rawValue)))

    /// A store in a defaults suite of its own, so tests leave the app's choices alone; `remove`
    /// deletes the suite.
    private func scratchStore() throws -> (store: ArchiveNameEncodingStore, remove: () -> Void) {
        let (defaults, suiteName) = makeTestDefaults("KernirIOSTests.ArchiveDocument")
        return (ArchiveNameEncodingStore(defaults: defaults), { removeTestDefaults(defaults, suite: suiteName) })
    }

    /// A fake archive whose names are stored in CP1251, so Text Encoding applies to it.
    private func legacyFake() -> FakeEngine {
        FakeEngine(reader: { FakeReader.sample(url: $0, legacyNameEncoding: .windowsCP1251) })
    }

    /// Text Encoding reads the file through the document's engine (`openWithNameEncoding`), as the
    /// reopen after a save does, so a test engine or `-KernirSlowExtract`'s wrapper still applies
    /// after it.
    @Test func textEncodingReopensThroughTheEngine() async throws {
        let fake = legacyFake()
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model)
        let scratch = try scratchStore()
        defer { scratch.remove() }
        model.nameEncodingStore = scratch.store

        try await doc.reopen(nameEncoding: .specific(Self.cp866))

        #expect(fake.nameEncodingCalls == [.init(url: doc.fileURL, password: nil, nameEncoding: .specific(Self.cp866))])
        #expect(model.reader?.nameEncoding == .specific(Self.cp866))
        #expect(scratch.store.nameEncoding(for: doc.fileURL) == .specific(Self.cp866))
        await doc.closeOnMain()
    }

    /// A save after a manual choice reads the saved file automatically first and then, since names
    /// in a code page survived the save, with the choice again (`ArchiveModel.openSaved`): both through
    /// the engine's `openWithNameEncoding`, and the choice stays.
    @Test func saveAfterAnEncodingChoiceReadsWithItAgain() async throws {
        let fake = legacyFake()
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model)
        let scratch = try scratchStore()
        defer { scratch.remove() }
        model.nameEncodingStore = scratch.store
        try await doc.reopen(nameEncoding: .specific(Self.cp866))

        model.remove(["README.md"])
        // UIDocument counts the edit when the undo group closes, at the end of this run loop turn.
        for _ in 0..<100 where !doc.hasUnsavedChanges {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await doc.commitSave())

        #expect(fake.writeCalls.count == 1)
        #expect(fake.nameEncodingCalls.map(\.nameEncoding) == [.specific(Self.cp866), .automatic, .specific(Self.cp866)])
        #expect(fake.nameEncodingCalls.allSatisfy { $0.url == doc.fileURL })
        #expect(doc.session.model?.reader?.nameEncoding == .specific(Self.cp866))
        #expect(scratch.store.nameEncoding(for: doc.fileURL) == .specific(Self.cp866))
        #expect(doc.session.model?.hasChanges == false)
        await doc.closeOnMain()
    }

    /// The document read its file again while Text Encoding read it (UIDocument reverting after a
    /// change from outside) and shows another model now: the old model takes nothing from the reopen
    /// and the choice isn't remembered, since the model on screen still reads Automatic.
    @Test func reopenForAReplacedModelKeepsNothing() async throws {
        ArchiveDocument.engine = .live
        let doc = ArchiveDocument(fileURL: try Fixture.copy("zip/legacy-cp1251.zip"))
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model)
        let (defaults, suiteName) = makeTestDefaults("KernirIOSTests.ReplacedModel")
        defer { removeTestDefaults(defaults, suite: suiteName) }
        let store = ArchiveNameEncodingStore(defaults: defaults)
        model.nameEncodingStore = store

        await #expect(throws: CancellationError.self) {
            try await doc.reopen(nameEncoding: .specific(Self.cp866)) { url, password, encoding in
                let reader = try await Archive.open(at: url, password: password, nameEncoding: encoding)
                doc.session.phase = .loading  // the revert, replacing the model
                return reader
            }
        }
        #expect(model.reader?.nameEncoding == .automatic)
        #expect(model.item(at: "Отчёт за май.docx") != nil)
        #expect(store.nameEncoding(for: doc.fileURL) == .automatic)

        doc.session.phase = .ready(model)
        await doc.closeOnMain()
    }

    #if DEBUG
    /// `-KernirSlowExtract`'s reader keeps the name encoding it was opened with and the one stored
    /// in the archive, so Text Encoding shows and works under it too.
    @Test func slowReaderKeepsTheNameEncoding() async throws {
        let url = try Fixture.copy("zip/legacy-cp1251.zip")
        let open: @Sendable (URL, String?) async throws -> any ArchiveReading = { url, password in
            try await Archive.open(at: url, password: password, nameEncoding: .specific(Self.cp866))
        }
        let direct = try await open(url, nil)
        #expect(direct.nameEncoding == .specific(Self.cp866))
        #expect(direct.legacyNameEncoding != nil)

        let slow = try await DocumentEngine(open: open, write: DocumentEngine.live.write)
            .slowingExtraction(by: .zero).open(url, nil)
        #expect(slow.nameEncoding == .specific(Self.cp866))
        #expect(slow.legacyNameEncoding == direct.legacyNameEncoding)
    }
    #endif

    // MARK: - Multi-volume sets

    private func volumeError(_ reason: ArchiveVolumeError.Reason, part: Int) -> ArchiveVolumeError {
        ArchiveVolumeError(reason: reason, part: part, fileName: "Photos.part\(part).rar",
                           setName: "Photos.part1.rar", folder: fixture.deletingLastPathComponent(), openedPart: 1)
    }

    /// The folder that holds the parts (`volumeError`'s).
    private var grantedFolder: URL { fixture.deletingLastPathComponent() }

    @Test func volumeErrorKeepsTheDocumentOpen() async {
        let error = volumeError(.noAccess, part: 2)
        let doc = makeDocument(FakeEngine(openFailures: [error]))
        #expect(await doc.openOnMain())
        guard case .volume(let shown) = doc.session.phase else {
            Issue.record("expected .volume, got \(doc.session.phase)")
            return
        }
        #expect(shown == error)
        #expect(!doc.documentState.contains(.closed))
        await doc.closeOnMain()
    }

    @Test func grantFolderOpensTheSetReadOnly() async throws {
        let fake = FakeEngine(openFailures: [volumeError(.noAccess, part: 2)], volumeCount: 2)
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        await doc.grantFolder(grantedFolder)
        let model = try #require(doc.session.model)
        #expect(model.reader?.volumeURLs.count == 2)
        #expect(!model.isEditable)
        #expect(fake.openCalls.count == 2)
        await doc.closeOnMain()
    }

    /// The right folder, but the same part fails again: it stays on screen, and the result says
    /// so, so the screen can tell the user (not a silent no-op).
    @Test func repeatedMissingPartStaysOnScreen() async {
        let error = volumeError(.missing, part: 3)
        let fake = FakeEngine(openFailures: [error, error])
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        #expect(await doc.grantFolder(grantedFolder) == .stillUnreadable(error))
        #expect(!doc.session.isGrantingFolder)
        guard case .volume(let shown) = doc.session.phase else {
            Issue.record("expected .volume, got \(doc.session.phase)")
            return
        }
        #expect(shown.part == 3)
        // One open for the document, one for the retry.
        #expect(fake.openCalls.count == 2)
        await doc.closeOnMain()
    }

    @Test func grantFolderFollowsANewPartAndThenOpens() async {
        let fake = FakeEngine(openFailures: [volumeError(.noAccess, part: 2), volumeError(.noAccess, part: 3)])
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        await doc.grantFolder(grantedFolder)
        #expect(doc.session.model != nil)
        // One open for the document, two for the retry.
        #expect(fake.openCalls.count == 3)
        await doc.closeOnMain()
    }

    @Test func grantFolderLocksAnEncryptedSet() async {
        let fake = FakeEngine(password: "kernir", openFailures: [volumeError(.noAccess, part: 2)])
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        await doc.grantFolder(grantedFolder)
        guard case .locked = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            return
        }
        await doc.closeOnMain()
    }

    /// Another folder can't reach the parts: no retry, no grant kept, and the error comes back
    /// so the screen can ask for the right folder.
    @Test func grantingAnotherFolderDoesNotRetry() async throws {
        let error = volumeError(.noAccess, part: 2)
        let fake = FakeEngine(openFailures: [error], volumeCount: 2)
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        let other = FileManager.default.temporaryDirectory
        #expect(await doc.grantFolder(other) == .wrongFolder(error))
        #expect(fake.openCalls.count == 1)
        #expect(!doc.session.isGrantingFolder)
        guard case .volume(let shown) = doc.session.phase else {
            Issue.record("expected .volume, got \(doc.session.phase)")
            return
        }
        #expect(shown == error)
        // The right folder still works afterwards.
        #expect(await doc.grantFolder(grantedFolder) == nil)
        #expect(doc.session.model != nil)
        await doc.closeOnMain()
    }

    @Test func grantFolderIgnoredUnlessVolumePhase() async {
        let fake = FakeEngine()
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        await doc.grantFolder(grantedFolder)
        #expect(fake.openCalls.count == 1)
        await doc.closeOnMain()
    }

    @Test(.timeLimit(.minutes(1))) func overlappingGrantsRunOneRetry() async throws {
        let fake = FakeEngine(openFailures: [volumeError(.noAccess, part: 2)])
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        let gate = OpenGate()
        fake.gate = gate
        let box = SendableDocument(document: doc)
        let folder = grantedFolder
        let first = Task { @MainActor in await box.document.grantFolder(folder) }
        // The first grant's reopen is inside the engine, held by the gate.
        try await waitUntil { gate.arrivals == 1 }
        #expect(gate.arrivals == 1)
        #expect(doc.session.isGrantingFolder)
        // A second grant returns without opening anything.
        await doc.grantFolder(folder)
        #expect(gate.arrivals == 1)
        #expect(doc.session.isGrantingFolder)
        gate.open()
        _ = await first.value
        #expect(!doc.session.isGrantingFolder)
        // One open for the document, one for the first retry; the second call did nothing.
        #expect(fake.openCalls.count == 2)
        #expect(doc.session.model != nil)
        await doc.closeOnMain()
    }

    @Test func grantFolderStopsWhenTheDocumentCloses() async throws {
        let fake = FakeEngine(openFailures: [volumeError(.noAccess, part: 2)])
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        let gate = OpenGate()
        fake.gate = gate
        let box = SendableDocument(document: doc)
        let folder = grantedFolder
        let retry = Task { @MainActor in await box.document.grantFolder(folder) }
        // The reopen is inside the engine, held by the gate, when the document closes.
        try await waitUntil { gate.arrivals == 1 }
        #expect(gate.arrivals == 1)
        await doc.closeOnMain()
        gate.open()
        _ = await retry.value
        guard case .volume = doc.session.phase else {
            Issue.record("expected .volume, got \(doc.session.phase)")
            return
        }
    }

    @Test func grantFolderAfterCloseDoesNothing() async {
        let fake = FakeEngine(openFailures: [volumeError(.noAccess, part: 2)])
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        await doc.closeOnMain()
        await doc.grantFolder(grantedFolder)
        #expect(fake.openCalls.count == 1)
        #expect(!doc.session.isGrantingFolder)
    }

    /// A revert that lands while a grant's reopen runs wins: the grant drops its own result.
    @Test func grantFolderDropsItsResultAfterTheScreenMovedOn() async throws {
        let fake = FakeEngine(openFailures: [volumeError(.noAccess, part: 2)])
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        let gate = OpenGate()
        fake.gate = gate
        let box = SendableDocument(document: doc)
        let folder = grantedFolder
        let retry = Task { @MainActor in await box.document.grantFolder(folder) }
        try await waitUntil { gate.arrivals == 1 }
        #expect(gate.arrivals == 1)
        // What a revert's apply does to the phase, while the grant's reopen is held.
        doc.session.phase = .locked(error: nil)
        gate.open()
        _ = await retry.value
        #expect(fake.openCalls.count == 2)
        guard case .locked = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            return
        }
        #expect(doc.session.model == nil)
        await doc.closeOnMain()
    }

    @Test func aSetIsNeverWrittenInPlace() async throws {
        let doc = makeDocument(FakeEngine(volumeCount: 2))
        #expect(await doc.openOnMain())
        #expect(doc.session.model?.reader?.volumeURLs.count == 2)
        do {
            _ = try doc.contents(forType: "public.zip-archive")
            Issue.record("expected contents(forType:) to throw")
        } catch {
            #expect((error as? CocoaError)?.code == .fileWriteUnknown)
        }
        await doc.closeOnMain()
    }

    /// A dirty set saved through UIDocument (the Save button's path): nothing is written, and the
    /// user gets the backstop's words, not "unknown error".
    @Test(.timeLimit(.minutes(1))) func savingADirtySetWritesNothing() async throws {
        let fake = FakeEngine(volumeCount: 2)
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        #expect(doc.session.model?.reader?.volumeURLs.count == 2)
        doc.updateChangeCount(.done)
        try await waitUntil { doc.hasUnsavedChanges }
        #expect(doc.hasUnsavedChanges)
        #expect(await doc.commitSave() == false)
        #expect(doc.refusedSaves == 1, "refused before UIKit's save, which iOS 17 never ends")
        #expect(fake.writeCalls.isEmpty)
        #expect(doc.session.saveError == ArchiveVolumeError.saveInPlaceError.localizedDescription)
        #expect(doc.session.saveError == "A split archive can't be saved in place. Use Save As Copy.")
        #expect(doc.session.saveFraction == nil)
        // One open, no reopen after the failed save.
        #expect(fake.openCalls.count == 1)
        // Closing must not write the set either (the close may try to save the pending change).
        await doc.closeOnMain()
        #expect(fake.writeCalls.isEmpty)
        #expect(doc.refusedSaves == 2, "the refused save kept the change, so the close's save is refused too")
    }

    /// No snapshot (here locked): a dirty document's save is refused before UIKit's save, which iOS 17 never
    /// ends, and writes nothing.
    @Test(.timeLimit(.minutes(1))) func savingWithoutASnapshotWritesNothing() async throws {
        let fake = FakeEngine(password: "kernir")
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        guard case .locked = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            await doc.closeOnMain()
            return
        }
        doc.updateChangeCount(.done)
        try await waitUntil { doc.hasUnsavedChanges }
        #expect(doc.hasUnsavedChanges)
        #expect(await doc.commitSave() == false)
        #expect(doc.refusedSaves == 1)
        #expect(fake.writeCalls.isEmpty)
        #expect(doc.session.saveError == CocoaError(.fileWriteUnknown).localizedDescription)
        await doc.closeOnMain()
        #expect(fake.writeCalls.isEmpty)
        #expect(doc.refusedSaves == 2)
    }

    // MARK: - Plain save with the iOS default on (Part B)

    /// With the iOS default on: a plain save of an archive no sheet saved strips
    /// Mac metadata, keeping the source's settings (no encryption here, so no password).
    @Test func plainSaveStripsMacMetadataByDefault() async throws {
        #expect(ArchiveSaveSettings.excludesMacMetadataByDefault, "Part B: iOS default on")
        let fake = FakeEngine()
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model)
        #expect(model.saveOptions == nil)
        model.remove(["README.md"])
        try await waitForUnsavedChanges(doc)

        #expect(await doc.commitSave())
        #expect(fake.writeCalls.last?.options == ArchiveWriteOptions(excludesMacMetadata: true))
        await doc.closeOnMain()
    }

    /// The same for an encrypted 7z: the source's encryption and the password that unlocked it.
    @Test func plainSaveOfAnEncryptedArchiveStripsAndKeepsItsEncryption() async throws {
        #expect(ArchiveSaveSettings.excludesMacMetadataByDefault, "Part B: iOS default on")
        let fake = FakeEngine(password: "kernir", listsWithoutPassword: true, reader: { url in
            FakeReader(entries: FakeReader.sample().entries, format: .sevenZip, url: url, isEncrypted: true)
        })
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        await doc.unlock(password: "kernir", remember: false)
        let model = try #require(doc.session.model)
        model.remove(["README.md"])
        try await waitForUnsavedChanges(doc)

        #expect(await doc.commitSave())
        #expect(fake.writeCalls.last?.options
            == ArchiveWriteOptions(encryption: .aes256, password: "kernir", excludesMacMetadata: true))
        await doc.closeOnMain()
    }

    /// An encrypted zip (it lists without a password, then locks until one is given): the plain
    /// save keeps the zip's encryption and the unlock password while it strips.
    @Test func plainSaveOfAnEncryptedZipStripsAndKeepsItsEncryption() async throws {
        #expect(ArchiveSaveSettings.excludesMacMetadataByDefault, "Part B: iOS default on")
        let fake = FakeEngine(password: "kernir", listsWithoutPassword: true)
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        guard case .locked = doc.session.phase else {
            Issue.record("expected .locked, got \(doc.session.phase)")
            return
        }
        await doc.unlock(password: "kernir", remember: false)
        let model = try #require(doc.session.model)
        #expect(model.reader?.format == .zip)
        #expect(model.reader?.encryption == .aes256)
        model.remove(["README.md"])
        try await waitForUnsavedChanges(doc)

        #expect(await doc.commitSave())
        let write = try #require(fake.writeCalls.last)
        #expect(write.format == .zip)
        #expect(write.options
            == ArchiveWriteOptions(encryption: .aes256, password: "kernir", excludesMacMetadata: true))
        await doc.closeOnMain()
    }

    /// End to end with the real engine: a `._*` file and a `__MACOSX` folder added on their own are
    /// left out of the archive a plain save writes, with the app's default (Part B: on). With the
    /// default forced off (the document's seam) they are written, so the test can tell.
    @Test(arguments: [false, true]) func plainSaveLeavesAddedMacMetadataOutOfTheArchive(_ excludesByDefault: Bool) async throws {
        #expect(ArchiveSaveSettings.excludesMacMetadataByDefault, "Part B: iOS default on")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let appleDouble = folder.appendingPathComponent("._note.txt")
        try Data([0x00, 0x05, 0x16, 0x07]).write(to: appleDouble)
        let macosx = folder.appendingPathComponent("__MACOSX", isDirectory: true)
        try FileManager.default.createDirectory(at: macosx, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: macosx.appendingPathComponent("x.txt"))
        let kept = folder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: kept)

        ArchiveDocument.engine = .live
        let doc = ArchiveDocument(fileURL: fixture)
        if !excludesByDefault { doc.plainSaveDefaultExcludesMacMetadata = false }
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model, "expected .ready, got \(doc.session.phase)")
        model.add([appleDouble, macosx, kept], to: "")
        try await waitForUnsavedChanges(doc)
        #expect(await doc.commitSave())
        await doc.closeOnMain()

        let paths = try await Archive.open(at: fixture).entries.map(\.path)
        #expect(paths.contains("keep.txt"))
        #expect(paths.contains("._note.txt") == !excludesByDefault)
        #expect(paths.contains { $0.hasPrefix("__MACOSX") } == !excludesByDefault)
    }

    /// Two plain saves in a row: the second, after the reopen (`ArchiveModel.didSave`), writes the
    /// same options as the first, password included; the model never adopts them as saved options.
    @Test func twoPlainSavesInARowWriteTheSameOptions() async throws {
        #expect(ArchiveSaveSettings.excludesMacMetadataByDefault, "Part B: iOS default on")
        let fake = FakeEngine(password: "kernir", listsWithoutPassword: true, reader: { url in
            FakeReader(entries: FakeReader.sample().entries, format: .sevenZip, url: url, isEncrypted: true)
        })
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        await doc.unlock(password: "kernir", remember: false)
        let model = try #require(doc.session.model)
        let expected = ArchiveWriteOptions(encryption: .aes256, password: "kernir", excludesMacMetadata: true)

        model.remove(["README.md"])
        try await waitForUnsavedChanges(doc)
        #expect(await doc.commitSave())
        #expect(fake.writeCalls.count == 1)
        #expect(fake.writeCalls.last?.options == expected)
        #expect(fake.openCalls.last?.password == "kernir", "the reopen after the first save")
        #expect(model.saveOptions == nil)

        model.remove(["notes.txt"])
        try await waitForUnsavedChanges(doc)
        #expect(await doc.commitSave())
        let second = try #require(fake.writeCalls.last)
        #expect(fake.writeCalls.count == 2)
        #expect(second.changes.removedPaths == ["notes.txt"])
        #expect(second.options == expected)
        #expect(model.saveOptions == nil)
        await doc.closeOnMain()
    }

    /// A revert re-reads the archive with the password that opened it; a plain save
    /// after it still carries that password.
    @Test func plainSaveAfterARevertKeepsThePassword() async throws {
        #expect(ArchiveSaveSettings.excludesMacMetadataByDefault, "Part B: iOS default on")
        let fake = FakeEngine(password: "kernir")
        let doc = makeDocument(fake)
        #expect(await doc.openOnMain())
        await doc.unlock(password: "kernir", remember: false)
        #expect(await doc.revertOnMain(toContentsOf: doc.fileURL))
        let model = try #require(doc.session.model, "expected .ready, got \(doc.session.phase)")
        #expect(model.password == "kernir")
        model.remove(["README.md"])
        try await waitForUnsavedChanges(doc)

        #expect(await doc.commitSave())
        #expect(fake.writeCalls.last?.options
            == ArchiveWriteOptions(encryption: .aes256, password: "kernir", excludesMacMetadata: true))
        await doc.closeOnMain()
    }

    /// A password the user chose to remember opens the archive with no prompt (the Keychain retry
    /// in `openOutcome`); a plain save carries it like a typed one.
    @Test func plainSaveWithARememberedPasswordKeepsIt() async throws {
        #expect(ArchiveSaveSettings.excludesMacMetadataByDefault, "Part B: iOS default on")
        let fake = FakeEngine(password: "kernir")
        let service = "com.kernir.app.tests.\(UUID().uuidString)"
        ArchiveDocument.engine = fake.engine
        let doc = ArchiveDocument(fileURL: fixture, keychainService: service)
        ArchiveDocument.engine = .live
        defer { KeychainPasswordStore.remove(for: doc.fileURL, service: service) }
        KeychainPasswordStore.save("kernir", for: doc.fileURL, service: service)
        #expect(await doc.openOnMain())
        #expect(fake.openCalls.map(\.password) == [nil, "kernir"])
        let model = try #require(doc.session.model, "expected .ready, got \(doc.session.phase)")
        #expect(model.password == "kernir")
        model.remove(["README.md"])
        try await waitForUnsavedChanges(doc)

        #expect(await doc.commitSave())
        #expect(fake.writeCalls.last?.options
            == ArchiveWriteOptions(encryption: .aes256, password: "kernir", excludesMacMetadata: true))
        await doc.closeOnMain()
    }

}
