import Foundation
import os
import Testing
import UIKit
import UniformTypeIdentifiers
import KernirCore
@testable import Kernir

/// Serialized: `ArchiveDocument.engine` is a process-wide test seam.
@MainActor @Suite(.serialized) final class ScreenStateTests {
    /// After each test: the fake reader's temporary files (previews) go. Only this suite
    /// previews through `FakeReader`, and it runs one test at a time.
    deinit {
        FakeReader.removeTemporaryFiles()
    }

    /// Opens `fixture` (copied, optionally renamed) with a fake engine listing `reader`'s entries.
    /// With a `password`, the archive lists without one but is locked until it is unlocked with it.
    private func open(_ fixture: String = "zip/deflate.zip", as name: String? = nil,
                      reader: FakeReader = FakeReader(entries: SampleArchive().entries),
                      password: String? = nil) async throws -> ScreenState {
        let url = try Fixture.copy(fixture, as: name)
        ArchiveDocument.engine = FakeEngine(password: password, listsWithoutPassword: password != nil, reader: { url in
            FakeReader(entries: reader.entries, format: reader.format, url: url, isEncrypted: reader.isEncrypted,
                       failure: reader.failure, failureAfter: reader.failureAfter,
                       extractDelay: reader.extractDelay)
        }).engine
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        if let password { await document.unlock(password: password, remember: false) }
        #expect(document.session.model != nil)
        return quickQuestions(ScreenState(document: document))
    }

    /// Extract's next conflict question comes as soon as the test signals the alert gone, with no
    /// fallback: tests that look at the wait set their own.
    private func quickQuestions(_ state: ScreenState) -> ScreenState {
        state.extractionAlertSettle = .zero
        state.extractionAlertFallback = nil
        return state
    }

    /// The conflict alert's condition going false, as `FolderScreen`'s `onChange` reports it, and the
    /// hand-off it schedules run to its end: the next question, or the extraction.
    private func alertGoes(_ state: ScreenState) async {
        state.extractionAlertDidGo()
        await state.nextQuestion?.value
    }

    /// The sleep of Extract's hand-offs (`extractionQuestions.sleep`), or of the progress sheet's
    /// fallback (`progressSheetSleep`), driven by the test: each sleep waits until `wake`, or ends with
    /// `CancellationError` once its task is cancelled. No real time passes, so a test that looks at the
    /// settle or a fallback neither waits for it nor races it.
    @MainActor private final class ManualSleep {
        private var sleepers: [(id: Int, duration: Duration, wake: CheckedContinuation<Void, any Error>)] = []
        private var count = 0
        /// Every duration asked for, in order.
        private(set) var asked: [Duration] = []
        /// How many sleeps their task's cancel cut short.
        private(set) var cancelled = 0
        /// The durations of the sleeps waiting now.
        var waiting: [Duration] { sleepers.map(\.duration) }

        init(_ state: ScreenState) {
            state.extractionQuestions.sleep = { [self] in try await sleep(for: $0) }
        }

        /// Drives the progress sheet's fallback instead (`progressSheetSleep`).
        init(sheetOf state: ScreenState) {
            state.progressSheetSleep = { [self] in try await sleep(for: $0) }
        }

        private func sleep(for duration: Duration) async throws {
            let id = count
            count += 1
            asked.append(duration)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    sleepers.append((id, duration, continuation))
                }
            } onCancel: {
                Task { @MainActor in self.cancel(id) }
            }
        }

        private func cancel(_ id: Int) {
            guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return }
            cancelled += 1
            sleepers.remove(at: i).wake.resume(throwing: CancellationError())
        }

        /// Lets the hand-off just scheduled reach its sleep: its task runs on the main actor once
        /// the test yields. Bounded, so a test never hangs here.
        func untilAsleep() async {
            for _ in 0..<100 where sleepers.isEmpty { await Task.yield() }
        }

        /// Ends every sleep waiting now, as if its time had passed.
        func wake() {
            let woken = sleepers
            sleepers = []
            for sleeper in woken { sleeper.wake.resume() }
        }
    }

    /// Opens a copy of `fixture` with KernirCore's real engine.
    /// With a `password`, the archive must open locked and is then unlocked with it.
    private func openLive(_ fixture: String, password: String? = nil) async throws -> ScreenState {
        ArchiveDocument.engine = .live
        let document = ArchiveDocument(fileURL: try Fixture.copy(fixture))
        #expect(await document.openOnMain())
        if let password {
            let isLocked = if case .locked(error: nil) = document.session.phase { true } else { false }
            #expect(isLocked, "expected .locked, got \(document.session.phase)")
            await document.unlock(password: password, remember: false)
        }
        #expect(document.session.model != nil)
        return ScreenState(document: document)
    }

    @Test func rowDetailFolderCountsChildren() async throws {
        let state = try await open()
        let model = try #require(state.model)
        #expect(state.rowDetail(for: try #require(model.item(at: "src"))) == "2 objects")
        #expect(state.rowDetail(for: try #require(model.item(at: "assets"))) == "1 object")
        #expect(state.rowDetail(for: try #require(model.item(at: "brief.pdf"))) == KernirFormat.size(340_000))
        await state.document.closeOnMain()
    }

    @Test func rootSubtitleSummarizesArchive() async throws {
        let state = try await open()
        let model = try #require(state.model)
        #expect(model.itemCount == 7)
        #expect(state.subtitle(for: "").contains("\(model.itemCount)"))
        let totalSize = try #require(model.totalSize)
        #expect(state.subtitle(for: "").contains(KernirFormat.size(totalSize)))
        // A folder's subtitle covers its subtree: src holds 2 files, 6,144 bytes.
        #expect(state.subtitle(for: "src") == KernirFormat.summary(itemCount: 2, size: 6_144,
                                                                   compressedSize: nil, format: nil))
        // Compact width (iPhone): no "uncompressed", so "14 items · 415 KB" fits the bar.
        #expect(state.subtitle(for: "", compact: true) == "7 items · \(KernirFormat.size(totalSize))")
        #expect(state.subtitle(for: "src", compact: true) == "2 items · \(KernirFormat.size(6_144))")
        #expect(state.subtitle(for: "").contains("uncompressed"))
        await state.document.closeOnMain()
    }

    @Test func readOnlyDisablesEditing() async throws {
        let rar = try await open(reader: FakeReader(entries: SampleArchive().entries, format: .rar))
        #expect(rar.canEdit == false)
        await rar.document.closeOnMain()

        let apk = try await open(as: "app.apk")
        #expect(apk.document.fileType == "com.android.package-archive")
        #expect(apk.model?.isEditable == true)
        #expect(apk.canEdit == false)
        await apk.document.closeOnMain()

        let zip = try await open()
        #expect(zip.document.fileType == "public.zip-archive")
        #expect(zip.canEdit)
        #expect(zip.allowsEditing)
        await zip.document.closeOnMain()
    }

    /// UIDocument types `x.tar.gz` by its last extension (gzip, not the tar.gz type),
    /// so the gate goes by the model's format; only developer packages are viewer-only.
    @Test func tarballIsEditable() async throws {
        let tarball = try await open("tar/basic.tar.gz", as: "x.tar.gz",
                                     reader: FakeReader(entries: SampleArchive().entries, format: .tarGzip))
        #expect(tarball.model?.format == .tarGzip)
        #expect(tarball.canEdit)
        #expect(tarball.allowsEditing)
        await tarball.document.closeOnMain()
    }

    /// An encrypted 7z asks for its password. Once unlocked it is editable: the engine
    /// writes 7z AES-256, so a save keeps the encryption and the password.
    @Test func encryptedSevenZipIsEditableAfterUnlock() async throws {
        let sevenZip = try await open("7z/encrypted-data.7z", reader: FakeReader(
            entries: SampleArchive().entries, format: .sevenZip, isEncrypted: true), password: "kernir")
        #expect(sevenZip.model?.password == "kernir")
        #expect(sevenZip.canEdit)
        #expect(sevenZip.allowsEditing)
        await sevenZip.document.closeOnMain()
    }

    /// An encrypted-data RAR opens without a prompt and stays read-only (RAR is never
    /// written).
    @Test func encryptedRarIsReadOnly() async throws {
        let state = try await openLive("third-party/rar/rar5-encrypted-mixed.rar")
        #expect(state.model?.format == .rar)
        #expect(state.model?.reader?.isEncrypted == true)
        #expect(state.canEdit == false)
        #expect(state.allowsEditing == false)
        await state.document.closeOnMain()
    }

    /// An unlocked encrypted 7z saves in place with the live engine: the removal is written, the
    /// document stays ready with its password, and the saved file is AES-256 with an encrypted
    /// header, so it needs the password even to list.
    @Test(arguments: ["7z/encrypted-data.7z", "7z/encrypted-headers.7z"])
    func encryptedSevenZipSaveRoundTrip(_ fixture: String) async throws {
        let state = try await openLive(fixture, password: "kernir")
        let model = try #require(state.model)
        #expect(model.format == .sevenZip)
        #expect(state.allowsEditing)
        #expect(model.item(at: "hello.txt") != nil)

        state.delete(["hello.txt"])
        #expect(model.item(at: "hello.txt") == nil)
        #expect(model.hasChanges)
        // UIDocument counts the edit when the undo group closes, at the end of this run loop turn.
        try await waitUntil { state.document.hasUnsavedChanges }
        #expect(state.document.hasUnsavedChanges)
        #expect(await state.document.commitSave())

        // Still ready, with the same password, on the reopened archive.
        let saved = try #require(state.model, "expected .ready, got \(state.session.phase)")
        #expect(saved.password == "kernir")
        #expect(saved.hasChanges == false)
        #expect(saved.item(at: "hello.txt") == nil)
        #expect(saved.item(at: "docs/readme.md") != nil)
        #expect(state.session.saveError == nil)
        #expect(state.allowsEditing)

        // A fresh open without the password can't list it: the header is encrypted now.
        let url = state.document.fileURL
        await #expect(throws: ArchiveError.passwordRequired) {
            _ = try await Archive.open(at: url, password: nil)
        }
        let reader = try await Archive.open(at: url, password: "kernir")
        let paths = Set(reader.entries.map(\.path))
        #expect(reader.format == .sevenZip)
        #expect(reader.isEncrypted)
        #expect(!paths.contains("hello.txt"))
        #expect(paths.isSuperset(of: ["docs/readme.md", "docs/notes.txt", "docs/nested/deep/data.bin", "empty.txt"]))
        await state.document.closeOnMain()
    }

    // MARK: - Damage hint

    private static let damageHint = "If the password is right, the archive may be damaged."

    /// Opens `fixture` (copied) with `engine` and returns its state while it is still locked.
    private func openLocked(_ fixture: String, engine: FakeEngine) async throws -> ScreenState {
        let url = try Fixture.copy(fixture)
        ArchiveDocument.engine = engine.engine
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        let state = ScreenState(document: document)
        #expect(state.isLocked)
        return state
    }

    /// A header-encrypted 7z: the engine can't list it without the password, so only the file
    /// type says it is a 7z.
    private func openLockedSevenZip() async throws -> ScreenState {
        try await openLocked("7z/encrypted-headers.7z", engine: FakeEngine(password: "kernir", reader: { url in
            FakeReader(entries: SampleArchive().entries, format: .sevenZip, url: url, isEncrypted: true)
        }))
    }

    /// 7z can't tell a wrong password from damage in its first encrypted entry, so
    /// from the second wrong password in a row the prompt says the archive may be damaged.
    @Test func sevenZipHintsDamageFromSecondWrongPassword() async throws {
        let state = try await openLockedSevenZip()
        #expect(state.document.fileType == "org.7-zip.7-zip-archive")
        #expect(state.passwordHint == nil)

        await state.unlock(password: "nope", remember: false)
        #expect(state.passwordError == "The password is incorrect.")
        #expect(state.passwordHint == nil)

        await state.unlock(password: "nope2", remember: false)
        #expect(state.passwordError == "The password is incorrect.")
        #expect(state.passwordHint == Self.damageHint)

        await state.unlock(password: "kernir", remember: false)
        #expect(state.model?.format == .sevenZip)
        #expect(state.passwordHint == nil)
        await state.document.closeOnMain()
    }

    /// A split 7z opened at its first part is typed as a part, not as 7z: it hints too.
    @Test func sevenZipSetHintsDamageFromSecondWrongPassword() async throws {
        let state = try await openLocked("multivolume/s7e.7z.001", engine: FakeEngine(password: "kernir", reader: { url in
            FakeReader(entries: SampleArchive().entries, format: .sevenZip, url: url, isEncrypted: true)
        }))
        await state.unlock(password: "nope", remember: false)
        #expect(state.passwordHint == nil)
        await state.unlock(password: "nope2", remember: false)
        #expect(state.passwordHint == Self.damageHint)
        await state.document.closeOnMain()
    }

    /// Cancel closes the document and starts the count over.
    @Test func sevenZipCancelResetsDamageHint() async throws {
        let state = try await openLockedSevenZip()
        var closed = 0
        state.closeDocument = { closed += 1 }
        await state.unlock(password: "nope", remember: false)
        await state.unlock(password: "nope2", remember: false)
        #expect(state.passwordHint == Self.damageHint)

        state.cancelUnlock()
        #expect(closed == 1)
        #expect(state.passwordHint == nil)
        await state.unlock(password: "nope3", remember: false)
        #expect(state.passwordHint == nil)
        await state.document.closeOnMain()
    }

    /// The hint only goes with the wrong-password error: when UIKit re-reads the locked document
    /// (`.locked(error: nil)`) the error line goes, and the hint with it.
    @Test func sevenZipHintNeedsErrorLine() async throws {
        let state = try await openLockedSevenZip()
        await state.unlock(password: "nope", remember: false)
        await state.unlock(password: "nope2", remember: false)
        #expect(state.passwordHint == Self.damageHint)

        state.session.phase = .locked(error: nil)
        #expect(state.passwordError == nil)
        #expect(state.passwordHint == nil)
        await state.document.closeOnMain()
    }

    /// ZIP stores a password check, so a wrong password is just wrong: no damage hint.
    @Test func zipNeverHintsDamage() async throws {
        let state = try await openLocked("zip/aes256.zip", engine: FakeEngine(password: "kernir"))
        await state.unlock(password: "nope", remember: false)
        await state.unlock(password: "nope2", remember: false)
        await state.unlock(password: "nope3", remember: false)
        #expect(state.passwordError == "The password is incorrect.")
        #expect(state.passwordHint == nil)
        await state.document.closeOnMain()
    }

    /// Edits made while a save is in flight would be dropped, so none are allowed.
    @Test func savingDisablesEditing() async throws {
        let state = try await open()
        let model = try #require(state.model)
        model.remove(["README.md"])
        for _ in 0..<100 where !state.canUndo {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.canUndo)
        state.isSelecting = true
        state.selection = ["brief.pdf"]
        #expect(state.canDeleteSelection)

        state.session.saveFraction = 0.5
        #expect(state.isSaving)
        #expect(state.canEdit)
        #expect(!state.allowsEditing)
        #expect(!state.canDeleteSelection)
        #expect(!state.canUndo)
        #expect(!state.canRedo)
        state.delete(state.deleteTargets())
        state.delete(["assets"])
        state.add([try sourceFile("late.txt")], to: "")
        state.undo()
        #expect(model.item(at: "brief.pdf") != nil)
        #expect(model.item(at: "assets") != nil)
        #expect(model.item(at: "late.txt") == nil)
        #expect(model.item(at: "README.md") == nil)

        state.session.saveFraction = nil
        #expect(state.allowsEditing)
        state.delete(state.deleteTargets())
        #expect(model.item(at: "brief.pdf") == nil)
        #expect(state.selection.isEmpty)
        #expect(!state.isSelecting)
        await state.document.closeOnMain()
    }

    @Test func undoAndRedoFollowTheUndoManager() async throws {
        let state = try await open()
        let model = try #require(state.model)
        #expect(!state.canUndo)
        model.remove(["README.md"])
        for _ in 0..<100 where !state.canUndo {
            try await Task.sleep(for: .milliseconds(10))
        }
        state.undo()
        #expect(model.item(at: "README.md") != nil)
        #expect(state.canRedo)
        state.redo()
        #expect(model.item(at: "README.md") == nil)
        await state.document.closeOnMain()
    }

    /// The bar's pinned Undo/Redo show while editing is allowed or a save writes pending edits;
    /// Save joins them while there are changes. A read-only archive shows none.
    @Test func barEditItemsFollowEditingGate() async throws {
        let rar = try await open(reader: FakeReader(entries: SampleArchive().entries, format: .rar))
        #expect(!rar.showsUndoRedo)
        #expect(!rar.hasChanges)
        await rar.document.closeOnMain()

        let state = try await open()
        let model = try #require(state.model)
        #expect(state.showsUndoRedo)
        #expect(!state.hasChanges)
        model.remove(["README.md"])
        #expect(state.hasChanges)
        state.session.saveFraction = 0.5
        #expect(!state.allowsEditing)
        #expect(state.showsUndoRedo, "pending edits keep Undo/Redo on the bar while saving")
        state.session.saveFraction = nil
        await state.document.closeOnMain()
    }

    // MARK: - Adding and deleting

    /// A file in a fresh temporary folder, standing in for one picked in Files.
    private func sourceFile(_ name: String, contents: String = "new") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Picked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func addTargetsCurrentFolder() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let source = try sourceFile("notes.txt")

        state.add([source], to: "src")

        #expect(model.item(at: "src/notes.txt")?.isPendingAddition == true)
        #expect(state.pendingReplacement == nil)
        // The archive adds the staged copy, not the picked file, whose access ends.
        let added = try #require(model.changes.additions.first?.sourceURL)
        #expect(added != source)
        #expect(added.path.hasPrefix(FileManager.default.temporaryDirectory.appendingPathComponent("Staging").path))
        await state.document.closeOnMain()
    }

    @Test func addConflictAsksBeforeReplacing() async throws {
        let state = try await open()
        let model = try #require(state.model)

        state.add([try sourceFile("README.md")], to: "")

        let replacement = try #require(state.pendingReplacement)
        #expect(replacement.title == "Replace “README.md”?")
        #expect(model.item(at: "README.md")?.isPendingAddition == false)
        state.confirmReplacement()
        #expect(state.pendingReplacement == nil)
        #expect(model.item(at: "README.md")?.isPendingAddition == true)
        await state.document.closeOnMain()
    }

    @Test func addConflictCancelKeepsArchive() async throws {
        let state = try await open()
        let model = try #require(state.model)

        state.add([try sourceFile("README.md"), try sourceFile("new.txt")], to: "")
        #expect(state.pendingReplacement != nil)
        state.cancelReplacement()

        #expect(state.pendingReplacement == nil)
        #expect(model.item(at: "README.md")?.isPendingAddition == false)
        #expect(model.item(at: "new.txt") == nil)
        #expect(!model.hasChanges)
        await state.document.closeOnMain()
    }

    @Test func addSeveralConflictsCountsThem() async throws {
        let state = try await open()
        state.add([try sourceFile("README.md"), try sourceFile("brief.pdf")], to: "")
        #expect(state.pendingReplacement?.title == "Replace 2 objects?")
        await state.document.closeOnMain()
    }

    @Test func deleteRemovesAndUndoRestores() async throws {
        let state = try await open()
        let model = try #require(state.model)

        state.delete(["README.md"])
        #expect(model.item(at: "README.md") == nil)

        state.document.undoManager.undo()
        #expect(model.item(at: "README.md") != nil)
        await state.document.closeOnMain()
    }

    @Test func deleteTargetsAreTheSelectionWhileSelecting() async throws {
        let state = try await open()
        state.selection = ["README.md"]
        #expect(state.deleteTargets().isEmpty)
        state.isSelecting = true
        state.selection = ["README.md", "src"]
        #expect(state.deleteTargets() == ["README.md", "src"])
        await state.document.closeOnMain()
    }

    @Test func deleteLeavesSelectionModeWhenSelectionEmpties() async throws {
        let state = try await open()
        let model = try #require(state.model)
        state.isSelecting = true
        state.selection = ["src/main.swift", "brief.pdf"]

        // Deleting src takes src/main.swift with it; brief.pdf stays selected.
        state.delete(["src"])
        #expect(state.isSelecting)
        #expect(state.selection == ["brief.pdf"])

        state.delete(state.deleteTargets())
        #expect(model.item(at: "brief.pdf") == nil)
        #expect(!state.isSelecting)
        #expect(state.selection.isEmpty)
        await state.document.closeOnMain()
    }

    @Test func readOnlyIgnoresAddAndDelete() async throws {
        let state = try await open(reader: FakeReader(entries: SampleArchive().entries, format: .rar))
        let model = try #require(state.model)
        state.delete(["README.md"])
        state.add([try sourceFile("new.txt")], to: "")
        #expect(model.item(at: "README.md") != nil)
        #expect(model.item(at: "new.txt") == nil)
        await state.document.closeOnMain()
    }

    // MARK: - A save starting mid-flow

    @Test func replaceAfterSaveStartedTellsUser() async throws {
        let state = try await open()
        let model = try #require(state.model)
        state.add([try sourceFile("README.md")], to: "")
        #expect(state.pendingReplacement != nil)

        // The save starts while the Replace alert is up.
        state.session.saveFraction = 0.5
        state.confirmReplacement()

        #expect(state.pendingReplacement == nil)
        #expect(model.item(at: "README.md")?.isPendingAddition == false)
        let alert = try #require(state.alert)
        #expect(alert.title == "Couldn't add “README.md”")
        #expect(alert.message == "The archive is being saved. Try again.")
        state.session.saveFraction = nil
        await state.document.closeOnMain()
    }

    @Test func addWhileSavingTellsUser() async throws {
        let state = try await open()
        let model = try #require(state.model)
        state.session.saveFraction = 0.5

        state.add([try sourceFile("a.txt"), try sourceFile("b.txt")], to: "")

        #expect(model.item(at: "a.txt") == nil)
        #expect(state.alert?.title == "Couldn't add 2 items")
        #expect(state.alert?.message == "The archive is being saved. Try again.")
        state.session.saveFraction = nil
        await state.document.closeOnMain()
    }

    @Test func addPhotosWhileSavingTellsUser() async throws {
        let state = try await open()
        let item = FakePickedItem(types: [.jpeg], data: Data("pixels".utf8))
        state.session.saveFraction = 0.5

        await state.addPhotos([item], to: "")

        #expect(item.loads.count == 0)
        #expect(state.alert?.title == "Couldn't add 1 item")
        #expect(state.progress == nil)
        state.session.saveFraction = nil
        await state.document.closeOnMain()
    }

    @Test func readOnlyAddPhotosSaysNothing() async throws {
        let state = try await open(reader: FakeReader(entries: SampleArchive().entries, format: .rar))
        await state.addPhotos([FakePickedItem(types: [.jpeg], data: Data("pixels".utf8))], to: "")
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    // MARK: - Photos

    @Test func addPhotosNamesFilesFromPhotos() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let items = [
            FakePickedItem(types: [.heic], fileName: "IMG_0001"),
            FakePickedItem(types: [.quickTimeMovie], fileName: "3F2504E0-4F89-11D3-9A0C-0305E82C3301.mov"),
            FakePickedItem(types: [.jpeg], data: Data("pixels".utf8)),
        ]

        await state.addPhotos(items, to: "src")

        #expect(model.item(at: "src/IMG_0001.heic")?.isPendingAddition == true)
        #expect(model.item(at: "src/Video.mov")?.isPendingAddition == true)
        #expect(model.item(at: "src/Photo.jpeg")?.isPendingAddition == true)
        #expect(state.alert == nil)
        #expect(state.progress == nil)
        await state.document.closeOnMain()
    }

    /// A video Photos offers no file for is left out, never loaded as data, and the user told.
    @Test func addPhotosSkipsVideoWithoutFile() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let video = FakePickedItem(types: [.mpeg4Movie], data: Data("frames".utf8))
        let photo = FakePickedItem(types: [.png], data: Data("pixels".utf8))

        await state.addPhotos([video, photo], to: "")

        #expect(video.loads.count == 1, "only the file was asked for")
        #expect(model.item(at: "Photo.png")?.isPendingAddition == true)
        #expect(model.item(at: "Video.mp4") == nil)
        #expect(state.alert?.title == "Couldn't add 1 item")
        #expect(state.alert?.message == "The item from Photos didn't provide a file to copy.")
        await state.document.closeOnMain()
    }

    // MARK: - Preview, extract, share

    /// A fresh empty folder, standing in for one picked in Files.
    private func destinationFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Destination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Every path under `folder`, relative to it.
    private func contents(of folder: URL) -> Set<String> {
        let enumerator = FileManager.default.enumerator(atPath: folder.path)
        return Set((enumerator?.allObjects as? [String]) ?? [])
    }

    @Test func extractTargetsNilWhenNotSelecting() async throws {
        let state = try await open()
        state.selection = ["src"]
        #expect(state.extractTargets() == nil)
        state.isSelecting = true
        state.selection = ["src"]
        #expect(state.extractTargets() == ["src"])
        state.selection = ["src", "README.md"]
        #expect(state.extractTargets() == ["README.md", "src"])
        await state.document.closeOnMain()
    }

    @Test func extractWritesIntoChosenFolder() async throws {
        let state = try await open()
        let folder = try destinationFolder()

        await state.extract(nil, to: folder)

        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("src/main.swift").path))
        #expect(state.progress == nil)
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    @Test func extractSelectionWritesOnlySelection() async throws {
        let state = try await open()
        let folder = try destinationFolder()
        state.isSelecting = true
        state.selection = ["src"]

        await state.extract(state.extractTargets(), to: folder)

        #expect(contents(of: folder) == ["src", "src/main.swift", "src/utils.swift"])
        await state.document.closeOnMain()
    }

    /// Cancel on the progress sheet: the engine stops with `.cancelled`, and nothing is said.
    @Test func extractCancelledSaysNothing() async throws {
        let state = try await open(reader: FakeReader(entries: SampleArchive().entries, failure: .cancelled))
        await state.extract(nil, to: try destinationFolder())
        #expect(state.alert == nil)
        #expect(state.progress == nil)
        await state.document.closeOnMain()
    }

    @Test func extractFailureShowsAlert() async throws {
        let state = try await open(reader: FakeReader(entries: SampleArchive().entries, failure: .io("")))
        await state.extract(["README.md"], to: try destinationFolder())
        #expect(state.alert?.title == "Couldn't extract “README.md”")
        #expect(state.alert?.message == ArchiveError.io("").localizedDescription)
        #expect(state.progress == nil)
        await state.document.closeOnMain()
    }

    /// The progress sheet's Cancel stops the extraction.
    @Test func extractProgressCancels() async throws {
        let state = try await open(reader: FakeReader(entries: SampleArchive().entries, extractDelay: .seconds(30)))
        let folder = try destinationFolder()
        let extraction = Task { await state.extract(nil, to: folder) }
        for _ in 0..<100 where state.progress == nil {
            await Task.yield()
        }
        #expect(state.progress?.title == "Extracting “\(state.name)”…")
        let cancel = try #require(state.progress?.cancel)
        let started = ContinuousClock.now
        cancel()
        await extraction.value
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path))
        #expect(state.alert == nil)
        #expect(state.progress == nil)
        await state.document.closeOnMain()
    }

    // MARK: - Extract never replaces without asking (X1)

    /// Puts a file of the user's at `name` in `folder`.
    @discardableResult
    private func existing(_ name: String, in folder: URL, contents: String = "mine") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A file's text; `FakeReader` writes each entry's path as its contents.
    private func text(_ name: String, in folder: URL) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    private static let askMessage = "Do you want to replace it with the one you’re extracting?"

    /// Answers the question on screen as its alert does: the answer goes with the question's
    /// index and takes the question away at once; the alert going away then asks the next one, or
    /// after the last answer extracts.
    private func answer(_ state: ScreenState, _ resolution: ExtractionConflictResolution,
                        forAll: Bool = false) async throws {
        let question = try #require(state.extractionQuestion)
        state.answerExtractionConflict(resolution, forAll: forAll, at: question.index)
        #expect(state.extractionQuestion == nil)
        await alertGoes(state)
    }

    /// Review I-1: the next question comes only after the answered one's alert has gone, so each
    /// alert is presented afresh; the question's data never changes while its alert is up.
    @Test func extractConflictNextQuestionWaitsForTheAlertToGo() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)

        state.answerExtractionConflict(.keepBoth, at: 0)
        #expect(state.extractionQuestion == nil)
        #expect(state.pendingExtraction?.index == 1)
        #expect(contents(of: folder) == ["README.md", "brief.pdf", "src", "src/mine.txt"])

        await alertGoes(state)
        let question = try #require(state.extractionQuestion)
        #expect(question.index == 1)
        #expect(question.message == Self.askMessage + "\n2 of 3")
        await state.document.closeOnMain()
    }

    /// Review I-1: an answer from a question that is no longer the one asked is dropped, so it can
    /// never land on the next item.
    @Test func extractConflictStaleAnswerIsIgnored() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)

        state.answerExtractionConflict(.keepBoth, at: 0)
        state.answerExtractionConflict(.replace, forAll: true, at: 0)
        await alertGoes(state)
        #expect(state.extractionQuestion?.index == 1)
        state.answerExtractionConflict(.replace, forAll: true, at: 0)
        #expect(state.extractionQuestion?.index == 1)

        #expect(state.pendingExtraction?.resolutions == ["README.md": .keepBoth])
        #expect(contents(of: folder) == ["README.md", "brief.pdf", "src", "src/mine.txt"])
        await state.document.closeOnMain()
    }

    /// The alert going away without an answer (something else took the screen) asks the same
    /// question again; nothing moves on.
    @Test func extractConflictAlertGoneWithoutAnswerAsksAgain() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)

        state.extractionAlertDidGo()

        #expect(state.nextQuestion == nil, "nothing scheduled")
        #expect(state.extractionQuestion?.index == 0)
        #expect(state.pendingExtraction?.resolutions.isEmpty == true)
        #expect(contents(of: folder) == ["README.md", "brief.pdf", "src", "src/mine.txt"])
        await state.document.closeOnMain()
    }

    /// Review m-4: a second Extract while a question is open is ignored; the open question and its
    /// answers stay, and the second folder is left alone.
    @Test func extractWhileAskingIgnoresTheSecondExtract() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()
        let other = try destinationFolder()
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)
        try await answer(state, .replace)

        await state.extract(["README.md"], to: other)

        #expect(state.pendingExtraction?.folder == folder)
        #expect(state.pendingExtraction?.resolutions == ["README.md": .replace])
        #expect(state.extractionQuestion?.index == 1)
        #expect(contents(of: other).isEmpty)
        await state.document.closeOnMain()
    }

    /// Review m-6: "Keep Both for All" after a single answer applies to the rest only.
    @Test func extractSeveralConflictsForAllAfterOneAnswer() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()

        await state.extract(["README.md", "brief.pdf", "src"], to: folder)
        try await answer(state, .replace)
        try await answer(state, .keepBoth, forAll: true)

        #expect(state.pendingExtraction == nil)
        #expect(state.extractionQuestion == nil)
        #expect(state.alert == nil)
        #expect(contents(of: folder) == ["README.md", "brief.pdf", "brief 2.pdf", "src", "src/mine.txt",
                                         "src 2", "src 2/main.swift", "src 2/utils.swift"])
        #expect(text("README.md", in: folder) == "README.md")
        #expect(text("brief.pdf", in: folder) == "mine")
        #expect(text("brief 2.pdf", in: folder) == "brief.pdf")
        await state.document.closeOnMain()
    }

    @Test func extractWithoutConflictsDoesNotAsk() async throws {
        let state = try await open()
        let folder = try destinationFolder()
        try existing("other.txt", in: folder)

        await state.extract(["README.md", "src"], to: folder)

        #expect(state.pendingExtraction == nil)
        #expect(state.alert == nil)
        #expect(contents(of: folder) == ["other.txt", "README.md", "src", "src/main.swift", "src/utils.swift"])
        #expect(text("other.txt", in: folder) == "mine")
        #expect(text("README.md", in: folder) == "README.md")
        await state.document.closeOnMain()
    }

    @Test func extractConflictAsksBeforeWriting() async throws {
        let state = try await open()
        let folder = try destinationFolder()
        try existing("README.md", in: folder)

        await state.extract(["README.md", "brief.pdf"], to: folder)

        let pending = try #require(state.pendingExtraction)
        #expect(pending.conflicts == ["README.md"])
        let question = try #require(state.extractionQuestion)
        #expect(question.index == 0)
        #expect(question.title == "An item named “README.md” already exists in “\(folder.lastPathComponent)”.")
        #expect(question.message == Self.askMessage)
        #expect(!question.offersApplyToAll)
        #expect(state.progress == nil)
        #expect(state.alert == nil)
        #expect(contents(of: folder) == ["README.md"])
        #expect(text("README.md", in: folder) == "mine")
        await state.document.closeOnMain()
    }

    /// A case-only twin from the archive, on a destination that folds case, is not on disk yet: the
    /// question names both items. An item that is on disk keeps the "already exists" question.
    @Test func extractCaseTwinAsksWithBothNames() async throws {
        let entries = [ArchiveEntry(path: "README", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
                       ArchiveEntry(path: "Readme", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
                       ArchiveEntry(path: "other.txt", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)]
        let state = try await open(reader: FakeReader(entries: entries))
        let model = try #require(state.model)
        model.caseSensitivity = DestinationCaseSensitivity(exists: { _ in true }, supportsCaseSensitiveNames: { _ in false })
        let folder = try destinationFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try existing("other.txt", in: folder)

        await state.extract(nil, to: folder)

        let pending = try #require(state.pendingExtraction)
        #expect(pending.conflicts == ["other.txt", "Readme"])
        #expect(pending.twins == ["Readme": "README"])
        let first = try #require(state.extractionQuestion)
        #expect(first.title == "An item named “other.txt” already exists in “\(folder.lastPathComponent)”.")
        #expect(first.message == Self.askMessage + "\n1 of 2")
        try await answer(state, .skip)
        let question = try #require(state.extractionQuestion)
        #expect(question.index == 1)
        #expect(question.title == "“Readme” and “README” would get the same name in “\(folder.lastPathComponent)”.")
        #expect(question.message == "Do you want to replace “README” with “Readme”?\n2 of 2")
        #expect(contents(of: folder) == ["other.txt"])
        state.cancelExtraction()
        await state.document.closeOnMain()
    }

    /// With three twins on one name, each question names the twin holding the name after the
    /// answers so far, as extract replaces it: Readme once Readme was answered Replace.
    @Test func extractThirdTwinAsksAboutTheTwinHoldingTheName() async throws {
        let entries = ["README", "Readme", "readme"].map {
            ArchiveEntry(path: $0, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
        }
        let state = try await open(reader: FakeReader(entries: entries))
        let model = try #require(state.model)
        model.caseSensitivity = DestinationCaseSensitivity(exists: { _ in true }, supportsCaseSensitiveNames: { _ in false })
        let folder = try destinationFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        await state.extract(nil, to: folder)

        #expect(state.pendingExtraction?.conflicts == ["Readme", "readme"])
        let first = try #require(state.extractionQuestion)
        #expect(first.title == "“Readme” and “README” would get the same name in “\(folder.lastPathComponent)”.")
        #expect(first.message == "Do you want to replace “README” with “Readme”?\n1 of 2")
        try await answer(state, .replace)
        let second = try #require(state.extractionQuestion)
        #expect(second.index == 1)
        #expect(second.title == "“readme” and “Readme” would get the same name in “\(folder.lastPathComponent)”.")
        #expect(second.message == "Do you want to replace “Readme” with “readme”?\n2 of 2")
        #expect(contents(of: folder).isEmpty)
        state.cancelExtraction()
        await state.document.closeOnMain()
    }

    /// Twins whose names alone read the same (`d/x` and `D/x`, their folders merged) are named by
    /// their paths in the question.
    @Test func extractTwinsWithTheSameNameAskByPath() async throws {
        let entries = ["D/x", "d/x"].map {
            ArchiveEntry(path: $0, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
        }
        let state = try await open(reader: FakeReader(entries: entries))
        let model = try #require(state.model)
        model.caseSensitivity = DestinationCaseSensitivity(exists: { _ in true }, supportsCaseSensitiveNames: { _ in false })
        let folder = try destinationFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        await state.extract(nil, to: folder)

        #expect(state.pendingExtraction?.conflicts == ["d/x"])
        let question = try #require(state.extractionQuestion)
        #expect(question.title == "“d/x” and “D/x” would get the same name in “\(folder.lastPathComponent)”.")
        #expect(question.message == "Do you want to replace “D/x” with “d/x”?")
        #expect(contents(of: folder).isEmpty)
        state.cancelExtraction()
        await state.document.closeOnMain()
    }

    /// Stop, even after answering some conflicts: nothing is written and nothing more is asked.
    @Test func extractConflictStopWritesNothing() async throws {
        let state = try await open()
        let folder = try destinationFolder()
        try existing("README.md", in: folder)
        try existing("brief.pdf", in: folder)

        await state.extract(["README.md", "brief.pdf", "src"], to: folder)
        #expect(state.pendingExtraction?.conflicts == ["README.md", "brief.pdf"])
        try await answer(state, .replace)
        #expect(state.pendingExtraction?.index == 1)
        state.stopExtraction()

        #expect(state.pendingExtraction == nil)
        #expect(state.extractionQuestion == nil)
        #expect(state.alert == nil)
        #expect(contents(of: folder) == ["README.md", "brief.pdf"])
        #expect(text("README.md", in: folder) == "mine")
        #expect(text("brief.pdf", in: folder) == "mine")
        await state.document.closeOnMain()
    }

    /// iPad "no question 4 of 4": the next question waits for the alert's going and the settle after
    /// it, never published at the answer or at the signal itself, while UIKit still takes the old
    /// alert down. The settle is the production one, on a sleep the test ends.
    @Test(.timeLimit(.minutes(1))) func extractConflictNextQuestionWaitsForTheSignalAndTheSettle() async throws {
        let state = try await open()
        let sleep = ManualSleep(state)
        state.extractionAlertSettle = .milliseconds(350)
        let folder = try folderWithThreeConflicts()
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)

        state.answerExtractionConflict(.keepBoth, at: 0)
        #expect(state.nextQuestion == nil, "no fallback: nothing before the signal")
        await Task.yield()
        #expect(state.extractionQuestion == nil)
        state.extractionAlertDidGo()
        #expect(state.extractionQuestion == nil, "not at the signal")
        let handOff = try #require(state.nextQuestion)
        await sleep.untilAsleep()
        #expect(sleep.waiting == [.milliseconds(350)])
        #expect(state.extractionQuestion == nil, "not before the settle has passed")
        sleep.wake()
        await handOff.value
        #expect(state.extractionQuestion?.index == 1)
        #expect(sleep.asked == [.milliseconds(350)])
        await state.document.closeOnMain()
    }

    /// A duplicate signal, while settling or after the next question is up, asks nothing more. Settle
    /// zero: the second signal comes before the first one's hand-off has run.
    @Test func extractConflictDuplicateSignalAsksOnce() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)

        state.answerExtractionConflict(.keepBoth, at: 0)
        state.extractionAlertDidGo()
        let handOff = try #require(state.nextQuestion)
        state.extractionAlertDidGo()
        #expect(state.nextQuestion == handOff)
        await handOff.value
        #expect(state.extractionQuestion?.index == 1)
        await alertGoes(state)
        #expect(state.extractionQuestion?.index == 1)
        #expect(state.pendingExtraction?.index == 1)
        #expect(state.pendingExtraction?.resolutions == ["README.md": .keepBoth])
        await state.document.closeOnMain()
    }

    /// Stop, or the document closing, while the last answer's hand-off settles: the settle is cut
    /// short and nothing is asked or written. The close is the real one: the document view
    /// controller's `document = nil`, as Close does, which reaches `removeContent`. The controller is
    /// given a document of its own first (never opened, no scene session, so nothing is registered):
    /// the setter ignores nil → nil.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func extractConflictEndedDuringTheSettleWritesNothing(closing: Bool) async throws {
        let state = try await open()
        let sleep = ManualSleep(state)
        state.extractionAlertSettle = .milliseconds(350)
        let folder = try destinationFolder()
        try existing("README.md", in: folder)
        await state.extract(["README.md", "brief.pdf"], to: folder)
        var shown: ArchiveDocument?
        var controller: ArchiveDocumentViewController?
        if closing {
            let document = ArchiveDocument(fileURL: state.document.fileURL)
            let host = ArchiveDocumentViewController(document: nil)
            host.document = document
            #expect(host.document === document)
            host.screenState = state
            (shown, controller) = (document, host)
        }

        state.answerExtractionConflict(.replace, at: 0)
        state.extractionAlertDidGo()
        let handOff = try #require(state.nextQuestion)
        await sleep.untilAsleep()
        #expect(sleep.waiting == [.milliseconds(350)])
        if let controller {
            controller.document = nil
            #expect(controller.screenState == nil)
        } else {
            state.stopExtraction()
        }
        await handOff.value
        #expect(sleep.cancelled == 1, "the settle was cut short")
        #expect(sleep.waiting.isEmpty)

        #expect(state.pendingExtraction == nil)
        #expect(state.extractionQuestion == nil)
        #expect(state.alert == nil)
        #expect(state.progress == nil)
        #expect(contents(of: folder) == ["README.md"])
        #expect(text("README.md", in: folder) == "mine")
        if let shown, !shown.documentState.contains(.closed) { await shown.closeOnMain() }
        await state.document.closeOnMain()
    }

    /// The fallback: should the alert's going never be reported, the next question comes anyway once
    /// the fallback has passed after the answer, and the last answer extracts. The fallback is the
    /// production one, on a sleep the test ends.
    @Test(.timeLimit(.minutes(1))) func extractConflictFallbackGoesOnWithoutTheSignal() async throws {
        let state = try await open()
        let sleep = ManualSleep(state)
        state.extractionAlertFallback = .seconds(2)
        let folder = try destinationFolder()
        try existing("README.md", in: folder)
        try existing("brief.pdf", in: folder)
        await state.extract(["README.md", "brief.pdf"], to: folder)

        state.answerExtractionConflict(.keepBoth, at: 0)
        let first = try #require(state.nextQuestion)
        await sleep.untilAsleep()
        #expect(sleep.waiting == [.seconds(2)])
        #expect(state.extractionQuestion == nil, "not before the fallback has passed")
        sleep.wake()
        await first.value
        #expect(state.extractionQuestion?.index == 1)
        state.answerExtractionConflict(.replace, at: 1)
        let last = try #require(state.nextQuestion)
        await sleep.untilAsleep()
        sleep.wake()
        await last.value

        #expect(sleep.asked == [.seconds(2), .seconds(2)])
        #expect(state.pendingExtraction == nil)
        #expect(state.alert == nil)
        #expect(contents(of: folder) == ["README.md", "README 2.md", "brief.pdf"])
        #expect(text("brief.pdf", in: folder) == "brief.pdf")
        await state.document.closeOnMain()
    }

    /// The document view controller swapping to another document ends the shown one's
    /// questions at once, as a close does: the settle is cut short and nothing is asked or written. Its
    /// content goes only once the new document has opened (`installContent`), or never if that open
    /// fails. The controller is given a document of its own first, as in the closing arm above.
    @Test(.timeLimit(.minutes(1))) func swappingTheDocumentEndsItsExtraction() async throws {
        let state = try await open()
        let sleep = ManualSleep(state)
        state.extractionAlertSettle = .milliseconds(350)
        let folder = try destinationFolder()
        try existing("README.md", in: folder)
        await state.extract(["README.md", "brief.pdf"], to: folder)
        let shown = ArchiveDocument(fileURL: state.document.fileURL)
        let next = ArchiveDocument(fileURL: try Fixture.copy("zip/deflate.zip"))
        let controller = ArchiveDocumentViewController(document: nil)
        controller.document = shown
        #expect(controller.document === shown)
        controller.screenState = state

        state.answerExtractionConflict(.replace, at: 0)
        state.extractionAlertDidGo()
        let handOff = try #require(state.nextQuestion)
        await sleep.untilAsleep()
        #expect(sleep.waiting == [.milliseconds(350)])
        controller.document = next
        #expect(controller.document === next)
        #expect(state.pendingExtraction == nil, "ended at the swap, before the new document opens")
        await handOff.value
        #expect(sleep.cancelled == 1, "the settle was cut short")
        #expect(sleep.waiting.isEmpty)

        #expect(state.extractionQuestion == nil)
        #expect(state.alert == nil)
        #expect(state.progress == nil)
        #expect(contents(of: folder) == ["README.md"])
        #expect(text("README.md", in: folder) == "mine")
        controller.document = nil
        for document in [shown, next] where !document.documentState.contains(.closed) {
            await document.closeOnMain()
        }
        await state.document.closeOnMain()
    }

    /// While the conflict questions are open, between them too, nothing edits the archive: Delete,
    /// ＋ and drops are off; Stop turns them back on.
    @Test func extractConflictPendingTurnsEditingOff() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()
        #expect(state.allowsEditing)
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)

        #expect(!state.allowsEditing)
        #expect(!state.canAdd)
        #expect(state.dropProposal(isFromThisDocument: false).operation == .forbidden)
        state.isSelecting = true
        state.selection = ["brief.pdf"]
        #expect(!state.canDeleteSelection)
        state.delete(["brief.pdf"])
        #expect(state.model?.item(at: "brief.pdf") != nil)
        state.answerExtractionConflict(.keepBoth, at: 0)
        #expect(!state.allowsEditing, "between two questions")
        #expect(state.dropProposal(isFromThisDocument: false).operation == .forbidden)

        state.stopExtraction()
        #expect(state.allowsEditing)
        #expect(state.canDeleteSelection)
        #expect(state.dropProposal(isFromThisDocument: false).operation == .copy)
        await state.document.closeOnMain()
    }

    /// What arrives once Extract asks its conflict questions, between them too, adds
    /// nothing and says nothing, as on a read-only archive: Replace on an alert already up, files
    /// from a picker answered late or a drop that was still loading (both land in `add`), photos.
    /// `add` refuses before copying anything in. Stop lets them in again.
    @Test func extractConflictPendingRefusesLateAdds() async throws {
        let state = try await open()
        let model = try #require(state.model)
        state.add([try sourceFile("README.md")], to: "")
        #expect(state.pendingReplacement != nil)
        let staged = stagedBatches(state)
        let folder = try folderWithThreeConflicts()
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)
        #expect(state.extractionQuestion?.index == 0)

        state.confirmReplacement()
        #expect(state.pendingReplacement == nil)
        state.add([try sourceFile("new.txt")], to: "")
        let photo = FakePickedItem(types: [.jpeg], data: Data("pixels".utf8))
        await state.addPhotos([photo], to: "")
        #expect(photo.loads.count == 0)
        state.answerExtractionConflict(.keepBoth, at: 0)
        state.add([try sourceFile("between.txt")], to: "")

        #expect(model.item(at: "README.md")?.isPendingAddition == false)
        #expect(model.item(at: "new.txt") == nil)
        #expect(model.item(at: "between.txt") == nil)
        #expect(!model.hasChanges)
        #expect(stagedBatches(state) == staged, "nothing copied in")
        #expect(state.alert == nil)
        #expect(state.progress == nil)
        #expect(state.pendingReplacement == nil)

        state.stopExtraction()
        state.add([try sourceFile("new.txt")], to: "")
        #expect(model.item(at: "new.txt")?.isPendingAddition == true)
        await state.document.closeOnMain()
    }

    /// Photos still loading when an Extract starts and asks (`addStaged`, after the
    /// load): they are let go, silently, and the question stays.
    @Test func extractStartingWhilePhotosLoadAddsNothing() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let gate = OpenGate()
        let photo = FakePickedItem(types: [.jpeg], data: Data("pixels".utf8), gate: gate)
        let adding = Task { await state.addPhotos([photo], to: "") }
        try await waitUntil { gate.arrivals == 1 }
        let folder = try folderWithThreeConflicts()
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)
        #expect(state.pendingExtraction != nil)
        gate.open()
        await adding.value

        #expect(photo.loads.count == 2, "loaded: a file first, then the data")
        #expect(!model.hasChanges)
        #expect(state.alert == nil)
        #expect(state.pendingReplacement == nil)
        #expect(state.progress == nil)
        #expect(state.extractionQuestion?.index == 0)
        state.stopExtraction()
        await state.document.closeOnMain()
    }

    /// While the conflict questions are open, between two of them too, nothing brings
    /// up a sheet the next question would be published under, and lost: Preview, Share, Extract and
    /// Save As Copy are off, and a preview, share or Extract asked for anyway (a row tapped) does
    /// nothing. Stop turns them back on.
    @Test func extractConflictPendingHoldsBackSheets() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()
        let other = try destinationFolder()
        #expect(state.allowsPresenting)
        #expect(state.canSaveAsCopy)
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)
        #expect(!state.allowsPresenting)
        #expect(!state.canSaveAsCopy)
        state.answerExtractionConflict(.keepBoth, at: 0)
        #expect(state.extractionQuestion == nil)
        #expect(!state.allowsPresenting, "between two questions")
        #expect(!state.canSaveAsCopy)

        await state.preview("brief.pdf")
        await state.share(["README.md"], from: .row("README.md"))
        state.beginSaveAsCopy()
        await state.extract(["README.md"], to: other)

        #expect(state.previewURL == nil)
        #expect(state.shareRequest == nil)
        #expect(state.saveAsCopyRequest == nil)
        #expect(state.runningOperations == 0, "nothing was prepared")
        #expect(state.progress == nil)
        #expect(state.alert == nil)
        #expect(contents(of: other).isEmpty)
        #expect(state.pendingExtraction?.folder == folder)
        #expect(state.pendingExtraction?.index == 1)

        state.stopExtraction()
        #expect(state.allowsPresenting)
        #expect(state.canSaveAsCopy)
        await state.preview("brief.pdf")
        #expect(state.previewURL?.lastPathComponent == "brief.pdf")
        await state.document.closeOnMain()
    }

    /// A question asked, or asked again, while the progress sheet is up or still going
    /// away (a save that started meanwhile) can't show until the sheet has gone: published then,
    /// SwiftUI would drop the alert and never retry it. The condition is observed, so the alert's
    /// binding is read again once the sheet has gone.
    @Test func extractConflictQuestionWaitsForTheProgressSheetToGo() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)
        #expect(state.canShowExtractionQuestion)

        state.session.saveFraction = 0
        #expect(!state.canShowExtractionQuestion, "the save's sheet is asked for")
        state.progressSheetDidAppear()
        state.session.saveFraction = nil
        #expect(state.activeProgress == nil)
        #expect(state.extractionQuestion?.index == 0)
        #expect(!state.canShowExtractionQuestion, "the sheet is still going away")
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.canShowExtractionQuestion
        } onChange: {
            changed.withLock { $0 = true }
        }
        state.progressSheetDidDismiss()
        #expect(changed.withLock { $0 }, "the sheet's going is observed")
        #expect(state.canShowExtractionQuestion)

        // The next question, published while a sheet goes away, waits for it too.
        state.answerExtractionConflict(.keepBoth, at: 0)
        state.session.saveFraction = 0
        state.progressSheetDidAppear()
        state.session.saveFraction = nil
        await alertGoes(state)
        #expect(state.extractionQuestion?.index == 1)
        #expect(!state.canShowExtractionQuestion)
        state.progressSheetDidDismiss()
        #expect(state.canShowExtractionQuestion)

        // Another alert in the way.
        state.alert = AlertContent(title: "Other", message: "")
        #expect(!state.canShowExtractionQuestion)
        state.dismissAlert()
        #expect(state.canShowExtractionQuestion)
        state.stopExtraction()
        #expect(!state.canShowExtractionQuestion)
        await state.document.closeOnMain()
    }

    /// The progress sheet's `onDismiss` lost (a save's sheet sent away while
    /// still coming up). Once its operation has ended, its fallback takes the sheet as gone, and the
    /// question held back for it comes up. `lateAppear`: the sheet reports coming up only after its
    /// operation has ended; the fallback starts then. The fallback is the production one, on a sleep
    /// the test ends.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func progressSheetFallbackTakesALostDismissalAsGone(lateAppear: Bool) async throws {
        let state = try await open()
        let sleep = ManualSleep(sheetOf: state)
        let folder = try folderWithThreeConflicts()
        await state.extract(["README.md", "brief.pdf", "src"], to: folder)
        #expect(state.canShowExtractionQuestion)

        state.session.saveFraction = 0
        if !lateAppear { state.progressSheetDidAppear() }
        #expect(state.progressSheetFallbackTask == nil, "the save is running")
        state.session.saveFraction = nil
        state.progressDidEnd()
        if lateAppear {
            #expect(state.progressSheetFallbackTask == nil, "the sheet hasn't come up")
            state.progressSheetDidAppear()
        }
        let fallback = try #require(state.progressSheetFallbackTask)
        state.progressDidEnd()
        #expect(state.progressSheetFallbackTask == fallback, "another level's report starts no second one")
        await sleep.untilAsleep()
        #expect(sleep.waiting == [.seconds(2)])
        #expect(!state.canShowExtractionQuestion, "the sheet may still be going away")
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.canShowExtractionQuestion
        } onChange: {
            changed.withLock { $0 = true }
        }
        sleep.wake()
        await fallback.value

        #expect(changed.withLock { $0 }, "the sheet taken as gone is observed")
        #expect(!state.isProgressSheetShown)
        #expect(state.progressSheetFallbackTask == nil)
        #expect(state.canShowExtractionQuestion)
        #expect(state.extractionQuestion?.index == 0)
        // The dismissal reported late changes nothing.
        state.progressSheetDidDismiss()
        #expect(state.canShowExtractionQuestion)
        #expect(sleep.asked == [.seconds(2)])
        state.stopExtraction()
        await state.document.closeOnMain()
    }

    /// The fallback stops, and doesn't take the sheet as gone, once the sheet's going is reported, when
    /// another operation's sheet is asked for (a save, or an operation under `perform`), and when the
    /// document closes (the document view controller's `document = nil`, as Close does, which reaches
    /// `removeContent`; the controller is given a document of its own first, as in
    /// `extractConflictEndedDuringTheSettleWritesNothing`).
    @Test(.timeLimit(.minutes(1))) func progressSheetFallbackStops() async throws {
        let state = try await open()
        let sleep = ManualSleep(sheetOf: state)

        // Reported.
        var fallback = try await saveSheetEnds(state, sleep)
        state.progressSheetDidDismiss()
        await fallback.value
        #expect(sleep.cancelled == 1)
        #expect(state.progressSheetFallbackTask == nil)
        #expect(!state.isProgressSheetShown)

        // Another save.
        fallback = try await saveSheetEnds(state, sleep)
        state.session.saveFraction = 0.5
        await fallback.value
        #expect(sleep.cancelled == 2)
        #expect(state.progressSheetFallbackTask == nil)
        #expect(state.isProgressSheetShown, "not taken as gone")
        state.session.saveFraction = nil
        state.progressSheetDidDismiss()

        // Another operation.
        fallback = try await saveSheetEnds(state, sleep)
        state.progress = OperationProgress(title: "Other")
        await fallback.value
        #expect(sleep.cancelled == 3)
        #expect(state.progressSheetFallbackTask == nil)
        #expect(state.isProgressSheetShown, "not taken as gone")
        state.progress = nil
        state.progressSheetDidDismiss()

        // The document closing.
        fallback = try await saveSheetEnds(state, sleep)
        let shown = ArchiveDocument(fileURL: state.document.fileURL)
        let controller = ArchiveDocumentViewController(document: nil)
        controller.document = shown
        #expect(controller.document === shown)
        controller.screenState = state
        controller.document = nil
        #expect(controller.screenState == nil)
        await fallback.value
        #expect(sleep.cancelled == 4)
        #expect(state.progressSheetFallbackTask == nil)
        #expect(state.isProgressSheetShown, "not taken as gone")
        #expect(sleep.waiting.isEmpty)
        if !shown.documentState.contains(.closed) { await shown.closeOnMain() }
        await state.document.closeOnMain()
    }

    /// Swapping to another document leaves the shown one's progress sheet
    /// fallback waiting. Should the new document's open fail, the content stays, and a lost dismissal
    /// must still be taken as gone (`closing` false). It stops once the content goes (`removeContent`:
    /// here by the close that follows, as Close does; on an open that succeeds, by `installContent`).
    /// The new document is never opened; the controller is given a document of its own first, as in
    /// `swappingTheDocumentEndsItsExtraction`.
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func swappingTheDocumentKeepsTheProgressSheetFallback(closing: Bool) async throws {
        let state = try await open()
        let sleep = ManualSleep(sheetOf: state)
        let shown = ArchiveDocument(fileURL: state.document.fileURL)
        let next = ArchiveDocument(fileURL: try Fixture.copy("zip/deflate.zip"))
        let controller = ArchiveDocumentViewController(document: nil)
        controller.document = shown
        #expect(controller.document === shown)
        controller.screenState = state

        let fallback = try await saveSheetEnds(state, sleep)
        controller.document = next
        #expect(controller.document === next)
        #expect(controller.screenState === state, "the new document hasn't opened: the content stays")
        #expect(state.progressSheetFallbackTask == fallback, "not cancelled by the swap")
        #expect(sleep.cancelled == 0)
        #expect(sleep.waiting == [.seconds(2)])

        if closing {
            controller.document = nil
            #expect(controller.screenState == nil)
            await fallback.value
            #expect(sleep.cancelled == 1, "cancelled once the content goes")
            #expect(state.progressSheetFallbackTask == nil)
            #expect(state.isProgressSheetShown, "not taken as gone")
        } else {
            sleep.wake()
            await fallback.value
            #expect(sleep.cancelled == 0)
            #expect(state.progressSheetFallbackTask == nil)
            #expect(!state.isProgressSheetShown, "the lost dismissal taken as gone")
            controller.document = nil
            #expect(controller.screenState == nil)
        }
        #expect(sleep.waiting.isEmpty)
        for document in [shown, next] where !document.documentState.contains(.closed) {
            await document.closeOnMain()
        }
        await state.document.closeOnMain()
    }

    /// A save's progress sheet comes up, and the save ends: the sheet's fallback waits, on `sleep`.
    private func saveSheetEnds(_ state: ScreenState, _ sleep: ManualSleep) async throws -> Task<Void, Never> {
        state.session.saveFraction = 0
        state.progressSheetDidAppear()
        state.session.saveFraction = nil
        state.progressDidEnd()
        let fallback = try #require(state.progressSheetFallbackTask)
        await sleep.untilAsleep()
        #expect(sleep.waiting == [.seconds(2)])
        return fallback
    }

    /// An alert, or Add's Replace question, set while the progress sheet is up
    /// or still going away waits until the sheet has gone. Published then, it would be dropped, and a
    /// dropped alert still set holds back the conflict question. The condition is observed, so the
    /// alert's binding is read again once the sheet has gone.
    @Test func alertsWaitForTheProgressSheetToGo() async throws {
        let state = try await open()
        state.alert = AlertContent(title: "Other", message: "")
        #expect(state.canShowAlert, "no sheet: at once")
        state.dismissAlert()

        state.session.saveFraction = 0
        state.progressSheetDidAppear()
        state.alert = AlertContent(title: "Other", message: "")
        #expect(!state.canShowAlert, "the save's sheet is up")
        state.session.saveFraction = nil
        #expect(!state.canShowAlert, "the sheet is still going away")
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.canShowAlert
        } onChange: {
            changed.withLock { $0 = true }
        }
        state.progressSheetDidDismiss()
        #expect(changed.withLock { $0 }, "the sheet's going is observed")
        #expect(state.canShowAlert)
        state.dismissAlert()
        #expect(!state.canShowAlert)

        state.session.saveFraction = 0
        state.progressSheetDidAppear()
        state.pendingReplacement = PendingReplacement(urls: [], directory: "", conflicts: ["README.md"])
        #expect(!state.canShowReplacement, "the save's sheet is up")
        state.session.saveFraction = nil
        #expect(!state.canShowReplacement, "the sheet is still going away")
        state.progressSheetDidDismiss()
        #expect(state.canShowReplacement)
        state.alert = AlertContent(title: "Other", message: "")
        #expect(!state.canShowReplacement, "after the alert")
        state.dismissAlert()
        #expect(state.canShowReplacement)
        state.pendingReplacement = nil
        await state.document.closeOnMain()
    }

    @Test func extractConflictReplaceReplaces() async throws {
        let state = try await open()
        let folder = try destinationFolder()
        try existing("README.md", in: folder)

        await state.extract(["README.md", "brief.pdf"], to: folder)
        try await answer(state, .replace)

        #expect(state.pendingExtraction == nil)
        #expect(state.alert == nil)
        #expect(state.progress == nil)
        #expect(contents(of: folder) == ["README.md", "brief.pdf"])
        #expect(text("README.md", in: folder) == "README.md")
        #expect(text("brief.pdf", in: folder) == "brief.pdf")
        await state.document.closeOnMain()
    }

    @Test func extractConflictKeepBothKeepsBoth() async throws {
        let state = try await open()
        let folder = try destinationFolder()
        try existing("README.md", in: folder)

        await state.extract(["README.md"], to: folder)
        try await answer(state, .keepBoth)

        #expect(state.pendingExtraction == nil)
        #expect(state.alert == nil)
        #expect(contents(of: folder) == ["README.md", "README 2.md"])
        #expect(text("README.md", in: folder) == "mine")
        #expect(text("README 2.md", in: folder) == "README.md")
        await state.document.closeOnMain()
    }

    /// The user's README.md, brief.pdf and src/mine.txt: three conflicts for README.md, brief.pdf, src.
    private func folderWithThreeConflicts() throws -> URL {
        let folder = try destinationFolder()
        try existing("README.md", in: folder)
        try existing("brief.pdf", in: folder)
        try existing("src/mine.txt", in: folder)
        return folder
    }

    @Test func extractSeveralConflictsReplaceForAll() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()

        await state.extract(["README.md", "brief.pdf", "src"], to: folder)
        #expect(state.pendingExtraction?.conflicts == ["README.md", "brief.pdf", "src"])
        let question = try #require(state.extractionQuestion)
        #expect(question.message == Self.askMessage + "\n1 of 3")
        #expect(question.offersApplyToAll)
        try await answer(state, .replace, forAll: true)

        #expect(state.pendingExtraction == nil)
        #expect(state.alert == nil)
        // Replace swaps a folder whole, as in Finder: the user's src/mine.txt goes with it.
        #expect(contents(of: folder) == ["README.md", "brief.pdf", "src", "src/main.swift", "src/utils.swift"])
        #expect(text("README.md", in: folder) == "README.md")
        #expect(text("brief.pdf", in: folder) == "brief.pdf")
        await state.document.closeOnMain()
    }

    @Test func extractSeveralConflictsKeepBothForAll() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()

        await state.extract(["README.md", "brief.pdf", "src"], to: folder)
        try await answer(state, .keepBoth, forAll: true)

        #expect(state.pendingExtraction == nil)
        #expect(state.alert == nil)
        #expect(contents(of: folder) == ["README.md", "brief.pdf", "src", "src/mine.txt",
                                         "README 2.md", "brief 2.pdf", "src 2", "src 2/main.swift",
                                         "src 2/utils.swift"])
        #expect(text("README.md", in: folder) == "mine")
        #expect(text("brief.pdf", in: folder) == "mine")
        #expect(text("src/mine.txt", in: folder) == "mine")
        #expect(text("README 2.md", in: folder) == "README.md")
        await state.document.closeOnMain()
    }

    /// One answer per conflict, in order; "for All" is offered only while 2+ remain; nothing is
    /// written until the last answer.
    @Test func extractSeveralConflictsOneByOne() async throws {
        let state = try await open()
        let folder = try folderWithThreeConflicts()

        await state.extract(["README.md", "brief.pdf", "src"], to: folder)
        try await answer(state, .keepBoth)
        var question = try #require(state.extractionQuestion)
        #expect(question.title == "An item named “brief.pdf” already exists in “\(folder.lastPathComponent)”.")
        #expect(question.message == Self.askMessage + "\n2 of 3")
        #expect(question.offersApplyToAll)
        try await answer(state, .replace)
        question = try #require(state.extractionQuestion)
        #expect(question.title == "An item named “src” already exists in “\(folder.lastPathComponent)”.")
        #expect(question.message == Self.askMessage + "\n3 of 3")
        #expect(!question.offersApplyToAll)
        #expect(contents(of: folder) == ["README.md", "brief.pdf", "src", "src/mine.txt"])
        try await answer(state, .keepBoth)

        #expect(state.pendingExtraction == nil)
        #expect(state.alert == nil)
        #expect(contents(of: folder) == ["README.md", "README 2.md", "brief.pdf", "src", "src/mine.txt",
                                         "src 2", "src 2/main.swift", "src 2/utils.swift"])
        #expect(text("README.md", in: folder) == "mine")
        #expect(text("README 2.md", in: folder) == "README.md")
        #expect(text("brief.pdf", in: folder) == "brief.pdf")
        await state.document.closeOnMain()
    }

    /// A file where a folder above the picked item goes is the conflict: the alert names it, and
    /// the answer for it is keyed by it.
    @Test func extractConflictAboveThePickedItemNamesIt() async throws {
        let state = try await open()
        let folder = try destinationFolder()
        try existing("src", in: folder)

        await state.extract(["src/main.swift"], to: folder)
        #expect(state.pendingExtraction?.conflicts == ["src"])
        #expect(state.extractionQuestion?.title == "An item named “src” already exists in “\(folder.lastPathComponent)”.")
        #expect(contents(of: folder) == ["src"])
        try await answer(state, .keepBoth)

        #expect(state.pendingExtraction == nil)
        #expect(state.alert == nil)
        #expect(contents(of: folder) == ["src", "src 2", "src 2/main.swift"])
        #expect(text("src", in: folder) == "mine")
        #expect(text("src 2/main.swift", in: folder) == "src/main.swift")
        await state.document.closeOnMain()
    }

    /// A damaged entry midway shows the engine's error, and the picked folder stays as it
    /// was: the user's file byte for byte, no half-written items, no staging folder.
    @Test func extractFailureMidwayLeavesFolderUntouched() async throws {
        let damage = ArchiveError.corrupted("CRC mismatch in assets/cover.png")
        let state = try await open(reader: FakeReader(entries: SampleArchive().entries, failure: damage,
                                                      failureAfter: 3))
        let folder = try destinationFolder()
        try existing("README.md", in: folder)

        await state.extract(nil, to: folder)
        #expect(state.pendingExtraction?.conflicts == ["README.md"])
        try await answer(state, .replace)

        #expect(state.pendingExtraction == nil)
        #expect(state.alert?.title == "Couldn't extract “\(state.name)”")
        #expect(state.alert?.message == damage.localizedDescription)
        #expect(state.progress == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names == ["README.md"])
        #expect(!names.contains { $0.hasPrefix(".kernir-") })
        #expect(text("README.md", in: folder) == "mine")
        await state.document.closeOnMain()
    }

    /// An item that appears between the question and the extraction is never replaced: the model
    /// refuses, and the "Couldn't extract" alert says so.
    @Test func extractConflictAppearingAfterAskingIsNotReplaced() async throws {
        let state = try await open()
        let folder = try destinationFolder()
        try existing("README.md", in: folder)

        await state.extract(["README.md", "brief.pdf"], to: folder)
        try existing("brief.pdf", in: folder, contents: "late")
        try await answer(state, .replace)

        #expect(state.pendingExtraction == nil)
        #expect(state.alert?.title == "Couldn't extract 2 items")
        #expect(state.alert?.message == "“brief.pdf” already exists.")
        #expect(contents(of: folder) == ["README.md", "brief.pdf"])
        #expect(text("README.md", in: folder) == "mine")
        #expect(text("brief.pdf", in: folder) == "late")
        await state.document.closeOnMain()
    }

    /// As with Replace on Add: a save starting keeps the question (its alert waits for
    /// the save's progress sheet); an answer that lands while the save writes extracts nothing and
    /// tells the user.
    @Test func extractConflictAnsweredWhileSavingTellsUser() async throws {
        let state = try await open()
        let folder = try destinationFolder()
        try existing("README.md", in: folder)
        await state.extract(["README.md"], to: folder)
        state.previewURL = folder.appendingPathComponent("README.md")

        // saveFraction going non-nil fires the session's save-start hook (it clears the preview).
        state.session.saveFraction = 0.5
        #expect(state.previewURL == nil, "the save-start hook did not run")
        #expect(state.pendingExtraction != nil)
        #expect(state.extractionQuestion?.index == 0)
        try await answer(state, .replace)

        #expect(state.pendingExtraction == nil)
        #expect(state.extractionQuestion == nil)
        #expect(state.alert?.title == "Couldn't extract “README.md”")
        #expect(state.alert?.message == "The archive is being saved. Try again.")
        #expect(contents(of: folder) == ["README.md"])
        #expect(text("README.md", in: folder) == "mine")
        state.session.saveFraction = nil
        await state.document.closeOnMain()
    }

    /// Brief 5: `ArchiveModel.extract` leaves Finder metadata (`._*`) behind, and extraction
    /// goes through it.
    @Test func extractSkipsAppleDouble() async throws {
        let state = try await openLive("tar/macos-bsdtar.tar")
        let folder = try destinationFolder()

        await state.extract(nil, to: folder)

        #expect(state.alert == nil)
        let written = contents(of: folder)
        #expect(written == ["hello.txt", "plain.txt", "docs", "docs/readme.md"])
        #expect(!written.contains { ($0 as NSString).lastPathComponent.hasPrefix("._") })
        await state.document.closeOnMain()
    }

    /// Sharing extracts through the same path, so no `._*` files are shared either.
    @Test func shareSkipsAppleDouble() async throws {
        let state = try await openLive("tar/macos-bsdtar.tar")

        let urls = try await state.shareURLs(for: ["hello.txt", "docs"])

        #expect(urls.map(\.lastPathComponent) == ["hello.txt", "docs"])
        #expect(try String(contentsOf: urls[0], encoding: .utf8).isEmpty == false)
        #expect(contents(of: urls[1]) == ["readme.md"])
        let folder = urls[0].deletingLastPathComponent()
        #expect(!contents(of: folder).contains { ($0 as NSString).lastPathComponent.hasPrefix("._") })
        await state.document.closeOnMain()
    }

    /// Shared copies live in the document's scratch folder until the document closes.
    @Test func shareFilesRemovedOnClose() async throws {
        let state = try await open()

        let urls = try await state.shareURLs(for: ["README.md", "src/main.swift"])

        #expect(urls.map(\.lastPathComponent) == ["README.md", "main.swift"])
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(try String(contentsOf: urls[1], encoding: .utf8) == "src/main.swift")
        await state.document.closeOnMain()
        #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    /// Sharing case-only twins (README, Readme) keeps both without
    /// asking; on a case-insensitive scratch volume the later one goes as Keep Both's "Readme 2".
    @Test func shareKeepsBothCaseTwins() async throws {
        let state = try await openLive("zip/case-twins.zip")

        let urls = try await state.shareURLs(for: ["README", "Readme", "other.txt"])

        let folder = urls[0].deletingLastPathComponent()
        let foldsCase = (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames == false
        #expect(urls.map(\.lastPathComponent) == ["README", foldsCase ? "Readme 2" : "Readme", "other.txt"])
        #expect(try urls.map { try String(contentsOf: $0, encoding: .utf8) }
                == ["README, upper case\n", "Readme, mixed case, longer\n", "other\n"])
        // Only the three copies: no staging left behind.
        #expect(contents(of: folder) == ["README", foldsCase ? "Readme 2" : "Readme", "other.txt"])
        await state.document.closeOnMain()
    }

    /// Folder twins (Docs, docs) aren't twins to ask about. Where the scratch volume folds
    /// case they extract as one folder holding both, which is shared once, not once per twin.
    /// A known issue only on a mixed-case scratch volume (`scratchVolumeIsMixedCase`); elsewhere it runs plainly.
    @Test func shareFolderTwinsOnce() async throws {
        guard scratchVolumeIsMixedCase() else {
            try await shareFolderTwinsOnceBody()
            return
        }
        print("mixed-case scratch volume detected")
        // No isIntermittent: once the Simulator is fixed, "known issue not recorded" says so.
        await withKnownIssue("iOS 27.2 Simulator scratch volume: lookups match exact case, creates collide") {
            try await shareFolderTwinsOnceBody()
        }
    }

    private func shareFolderTwinsOnceBody() async throws {
        func entry(_ path: String, isDirectory: Bool = false) -> ArchiveEntry {
            ArchiveEntry(path: path, isDirectory: isDirectory, size: isDirectory ? nil : 1,
                         compressedSize: isDirectory ? nil : 1, modificationDate: nil)
        }
        let state = try await open(reader: FakeReader(entries: [
            entry("Docs", isDirectory: true), entry("Docs/a.txt"),
            entry("docs", isDirectory: true), entry("docs/b.txt"), entry("other.txt"),
        ]))
        // The document closes on every path, the known issue's throw too. `defer` can't await
        // (Swift 6.3), so a catch closes it before rethrowing.
        let urls: [URL]
        do {
            urls = try await state.shareURLs(for: ["Docs", "docs", "other.txt"])
        } catch {
            await state.document.closeOnMain()
            throw error
        }

        let folder = urls[0].deletingLastPathComponent()
        let foldsCase = (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames == false
        if foldsCase {
            #expect(urls.map(\.lastPathComponent) == ["Docs", "other.txt"])
            #expect(contents(of: urls[0]) == ["a.txt", "b.txt"])
        } else {
            #expect(urls.map(\.lastPathComponent) == ["Docs", "docs", "other.txt"])
        }
        await state.document.closeOnMain()
    }

    @Test func shareSetsRequestWithAnchor() async throws {
        let state = try await open()

        await state.share(["README.md"], from: .row("README.md"))

        let request = try #require(state.shareRequest)
        #expect(request.anchor == .row("README.md"))
        #expect(request.urls.map(\.lastPathComponent) == ["README.md"])
        #expect(state.progress == nil)
        await state.document.closeOnMain()
    }

    @Test func shareCancelledSaysNothing() async throws {
        let state = try await open(reader: FakeReader(entries: SampleArchive().entries, failure: .cancelled))
        await state.share(["README.md"], from: .toolbar(""))
        #expect(state.shareRequest == nil)
        #expect(state.alert == nil)
        #expect(state.progress == nil)
        await state.document.closeOnMain()
    }

    // MARK: - Share: no link out of the archive (`ExportLinkSweep`)

    /// A temporary folder holding `secret`, the user's own file a crafted link reaches for; the test removes the
    /// folder.
    func outsideSecret() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareLinks-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let secret = folder.appendingPathComponent("secret")
        try Data("the user's own secret".utf8).write(to: secret)
        return secret
    }

    /// A ustar archive in a temporary folder: a folder ("d/"), a file with `text`, or a symlink to `link`. A
    /// link target longer than ustar's 100 bytes (the Simulator's temporary folder is deep) goes in a pax
    /// "linkpath" record before its entry.
    func linkArchive(_ entries: [(path: String, text: String?, link: String?)]) throws -> URL {
        var data = Data()
        func append(_ path: String, flag: Character, link: String, body: Data) {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at offset: Int) {
                for (index, byte) in text.utf8.enumerated() { header[offset + index] = byte }
            }
            put(path, at: 0)
            put(flag == "5" ? "0000755" : "0000644", at: 100)
            put("0000000", at: 108)
            put("0000000", at: 116)
            put(String(format: "%011o", body.count), at: 124)
            put("00000000000", at: 136)
            header[156] = flag.asciiValue!
            put(link, at: 157)
            put("ustar", at: 257)
            put("00", at: 263)
            put("        ", at: 148)
            put(String(format: "%06o", header.reduce(0) { $0 + Int($1) }), at: 148)
            header[154] = 0
            data += header + body + Data(count: (512 - body.count % 512) % 512)
        }
        for entry in entries {
            let flag: Character = entry.path.hasSuffix("/") ? "5" : entry.link == nil ? "0" : "2"
            var link = entry.link ?? ""
            if link.utf8.count >= 100 {
                // "<length> linkpath=<target>\n", the length counting its own digits.
                let rest = " linkpath=\(link)\n".utf8.count
                var length = rest + 1
                while String(length).count + rest != length { length = String(length).count + rest }
                append("PaxHeader", flag: "x", link: "", body: Data("\(length) linkpath=\(link)\n".utf8))
                link = ""
            }
            append(entry.path, flag: flag, link: link, body: Data((entry.text ?? "").utf8))
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareLinks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("links.tar")
        try (data + Data(count: 1024)).write(to: url)
        return url
    }

    /// Opens the archive at `url` with KernirCore's real engine.
    func openLive(at url: URL) async throws -> ScreenState {
        ArchiveDocument.engine = .live
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        #expect(document.session.model != nil)
        return ScreenState(document: document)
    }

    /// Sharing only links: nothing goes to the share sheet, the share fails with `ExportedLinksError`, and
    /// no batch folder is left. The outside file is untouched.
    @Test func shareOfOnlyLinksFailsAndLeavesNoCopies() async throws {
        let secret = try outsideSecret()
        defer { try? FileManager.default.removeItem(at: secret.deletingLastPathComponent()) }
        let archive = try linkArchive([
            (path: "photo.jpg", text: nil, link: secret.path),
            (path: "up", text: nil, link: "../../../secret"),
        ])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let state = try await openLive(at: archive)

        await #expect(throws: ExportedLinksError(names: ["photo.jpg", "up"])) {
            try await state.shareURLs(for: ["photo.jpg", "up"])
        }

        #expect(shareBatches(state).isEmpty)
        #expect(try String(contentsOf: secret, encoding: .utf8) == "the user's own secret")
        await state.document.closeOnMain()
    }

    /// A mixed selection shares the regular file and the folder; the link item and the folder's link out are
    /// dropped, its link to its own file stays.
    @Test func shareDropsEscapingLinks() async throws {
        let secret = try outsideSecret()
        defer { try? FileManager.default.removeItem(at: secret.deletingLastPathComponent()) }
        let archive = try linkArchive([
            (path: "photo.jpg", text: nil, link: secret.path),
            (path: "a.txt", text: "A", link: nil),
            (path: "d/", text: nil, link: nil),
            (path: "d/f", text: "F", link: nil),
            (path: "d/abs", text: nil, link: secret.path),
            (path: "d/cur", text: nil, link: "f"),
        ])
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let state = try await openLive(at: archive)

        let urls = try await state.shareURLs(for: ["photo.jpg", "a.txt", "d"])

        #expect(urls.map(\.lastPathComponent) == ["a.txt", "d"])
        #expect(try String(contentsOf: urls[0], encoding: .utf8) == "A")
        #expect(contents(of: urls[0].deletingLastPathComponent()) == ["a.txt", "d", "d/f", "d/cur"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: urls[1].appendingPathComponent("cur").path)
                == "f")
        #expect(try String(contentsOf: secret, encoding: .utf8) == "the user's own secret")
        await state.document.closeOnMain()
    }

    @Test func previewSetsURL() async throws {
        let state = try await open()

        await state.preview("brief.pdf")

        let url = try #require(state.previewURL)
        #expect(url.lastPathComponent == "brief.pdf")
        #expect(try String(contentsOf: url, encoding: .utf8) == "brief.pdf")
        #expect(state.alert == nil)
        #expect(state.progress == nil)
        await state.document.closeOnMain()
    }

    /// A file waiting to be added previews from its staged copy.
    @Test func previewPendingFileUsesStagedCopy() async throws {
        let state = try await open()
        state.add([try sourceFile("new.txt", contents: "fresh")], to: "")

        await state.preview("new.txt")

        let url = try #require(state.previewURL)
        #expect(try String(contentsOf: url, encoding: .utf8) == "fresh")
        await state.document.closeOnMain()
    }

    /// An encrypted-data 7z asks for its password like ZIP; once unlocked its entries
    /// preview with that password, and it is editable (the engine writes 7z AES-256).
    @Test func previewEncryptedSevenZipAfterUnlock() async throws {
        let state = try await openLive("7z/encrypted-data.7z", password: "kernir")
        #expect(state.model?.format == .sevenZip)
        #expect(state.model?.password == "kernir")
        #expect(state.model?.item(at: "hello.txt") != nil)
        #expect(state.canEdit)
        #expect(state.allowsEditing)

        await state.preview("hello.txt")

        let url = try #require(state.previewURL, "alert: \(String(describing: state.alert))")
        #expect(url.lastPathComponent == "hello.txt")
        #expect(state.alert == nil)
        #expect(!state.isLocked)
        await state.document.closeOnMain()
    }

    /// An encrypted-data RAR is browsable, but its encrypted entries can't be read:
    /// an alert, never a password prompt.
    @Test func previewEncryptedRarShowsAlert() async throws {
        let state = try await openLive("third-party/rar/rar5-encrypted-mixed.rar")
        #expect(state.model?.format == .rar)
        #expect(state.model?.item(at: "b.txt") != nil)

        await state.preview("b.txt")

        #expect(state.previewURL == nil)
        #expect(!state.isLocked)
        #expect(state.alert?.title == "Couldn't preview “b.txt”")
        #expect(state.alert?.message == ArchiveError.unsupportedEncryption(.rar).localizedDescription)
        #expect(state.alert?.message.contains("aren't supported yet") == true)
        await state.document.closeOnMain()
    }

    @Test func previewCancelledSaysNothing() async throws {
        let state = try await open(reader: FakeReader(entries: SampleArchive().entries, failure: .cancelled))
        await state.preview("README.md")
        #expect(state.previewURL == nil)
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    /// A model replaced other than by a save or Text Encoding (read again after a change elsewhere)
    /// takes the preview with it: its swipe could extract nothing more, leaving blank pages.
    @Test func modelReplacementEndsThePreview() async throws {
        let state = try await open()
        let model = try #require(state.model)
        await state.preview("brief.pdf")
        #expect(state.previewURL != nil)
        #expect(state.previewQueue(listing: model.children(of: "", matching: "")) != nil)

        state.session.phase = .ready(model)
        #expect(state.previewURL != nil, "the same model: the preview stays")

        state.session.phase = .ready(ArchiveModel(reader: FakeReader(entries: SampleArchive().entries),
                                                  undoManager: nil))
        #expect(state.previewURL == nil)
        #expect(state.previewFolder == nil)
        #expect(state.previewQueue(listing: model.children(of: "", matching: "")) == nil)
        state.session.phase = .ready(model)
        await state.document.closeOnMain()
    }

    /// Swiping in the preview (`previewQueue`): the level's other files extract as `preview`'s does,
    /// only when asked for; once a save has replaced the reader, nothing more is, and nothing is said
    /// (the preview goes with the save).
    @Test func previewQueueExtractsSwipedFilesUntilSave() async throws {
        let state = try await open()
        let listing = try #require(state.model).children(of: "", matching: "")
        #expect(state.previewQueue(listing: listing) == nil, "no preview up")

        await state.preview("brief.pdf")
        let queue = try #require(state.previewQueue(listing: listing))
        #expect(queue.files.map(\.path) == listing.filter { !$0.isDirectory }.map(\.path))
        #expect(queue.files[queue.startIndex].path == "brief.pdf")
        #expect(queue.item(at: queue.startIndex) == state.previewURL)
        let readme = try #require(queue.files.firstIndex { $0.path == "README.md" })
        #expect(queue.item(at: readme) == nil)
        await queue.settle()
        let url = try #require(queue.url(at: readme), "alert: \(String(describing: queue.failureAlert(at: readme)))")
        #expect(url.lastPathComponent == "README.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == "README.md")
        #expect(state.progress == nil, "no progress sheet for a swipe")

        let saved = try #require(state.previewQueue(listing: listing))
        state.session.saveFraction = 0.5
        #expect(state.previewURL == nil)
        #expect(saved.item(at: readme) == nil)
        await saved.settle()
        #expect(saved.url(at: readme) == nil)
        #expect(saved.failureAlert(at: readme) == nil)
        state.session.saveFraction = nil
        await state.document.closeOnMain()
    }

    @Test func extractTargetsKeepOnlyTopmost() async throws {
        let state = try await open()
        state.isSelecting = true
        state.selection = ["src", "src/main.swift", "README.md", "assets/cover.png"]
        #expect(state.extractTargets() == ["README.md", "assets/cover.png", "src"])
        await state.document.closeOnMain()
    }

    /// Like macOS `ArchiveActions.topmost`, a path is dropped only under a selected folder,
    /// not under a sibling whose name merely starts the same.
    @Test func topmostDropsOnlyDescendants() {
        #expect(ScreenState.topmost(["a", "a/b", "a/b/c", "ab", "ab/c", "x/y", "x/yz"]) == ["a", "ab", "x/y", "x/yz"])
        #expect(ScreenState.topmost(["a", "a/b/c"]) == ["a"])
        #expect(ScreenState.topmost([]) == [])
    }

    /// A path whose "/" a combining mark or a joiner follows (one Character with the "/") is still
    /// inside the folder before that "/": topmost splits on the "/" scalar, as the core and
    /// `ArchiveModel` do, so the folder alone is extracted or shared.
    @Test func topmostDropsPathsBehindAMarkedSlash() {
        #expect(ScreenState.topmost(["a", "a/\u{301}b"]) == ["a"])
        #expect(ScreenState.topmost(["a", "a/\u{200D}b", "a/\u{200D}b/c"]) == ["a"])
        #expect(ScreenState.topmost(["a/\u{301}b", "a/\u{301}b/c"]) == ["a/\u{301}b"])
        #expect(ScreenState.topmost(["a", "a/\u{301}b/c"]) == ["a"])
    }

    /// Unchanged by the scalar split: a mark before the "/" belongs to the folder's name, a
    /// prepended mark too ("link\u{600}/pwn" lies in "link\u{600}", not in "link"), and an NFD
    /// spelling lies in its NFC folder.
    @Test func topmostKeepsFolderNamesWholeOnScalars() {
        #expect(ScreenState.topmost(["a\u{301}", "a\u{301}/b"]) == ["a\u{301}"])
        #expect(ScreenState.topmost(["link\u{600}", "link\u{600}/pwn"]) == ["link\u{600}"])
        #expect(ScreenState.topmost(["link", "link\u{600}/pwn"]) == ["link", "link\u{600}/pwn"])
        #expect(ScreenState.topmost(["\u{E9}", "e\u{301}/x"]) == ["\u{E9}"])
        #expect(ScreenState.topmost(["", "a"]) == ["", "a"])
    }

    /// The selection the toolbar's Extract and Share act on holds a folder once, not also an item
    /// listed behind a marked "/" in it.
    @Test func extractTargetsDropItemBehindAMarkedSlash() async throws {
        let entries = [
            ArchiveEntry(path: "d", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil),
            ArchiveEntry(path: "d/\u{301}x", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
            ArchiveEntry(path: "e.txt", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
        ]
        let state = try await open(reader: FakeReader(entries: entries))
        state.isSelecting = true
        state.selection = ["d", "d/\u{301}x", "e.txt"]
        #expect(state.extractTargets() == ["d", "e.txt"])
        await state.document.closeOnMain()
    }

    // MARK: - Unknown sizes (BUG 2)

    /// Single-stream fixtures and the bytes their one file holds. KernirCore lists that file with an
    /// unknown (nil) size: it can't tell without decompressing. notes.txt.zst is left out until the
    /// iOS engine reads zstd; today it fails to open.
    private nonisolated static let singleStreams = ["single/hello.txt.gz": 15, "single/no-name.gz": 20_000,
                                        "single/notes.txt.bz2": 20_000, "single/notes.txt.xz": 20_000]

    /// The one entry of a single-stream fixture: its file name without the compression extension.
    private nonisolated static func singleEntry(of fixture: String) -> String {
        ((fixture as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    @Test(arguments: singleStreams.keys.sorted())
    func rowDetailOfUnknownSizeIsDashes(_ fixture: String) async throws {
        let state = try await openLive(fixture)
        let item = try #require(state.model?.item(at: Self.singleEntry(of: fixture)))
        #expect(item.size == nil)

        // As the Mac's Size column: "--" on screen, words for VoiceOver.
        #expect(state.rowDetail(for: item) == "--")
        #expect(state.rowSpokenDetail(for: item) == "Unknown size")
        await state.document.closeOnMain()
    }

    @Test func rowSpokenDetailOfKnownSizeIsTheSize() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let file = try #require(model.item(at: "brief.pdf"))
        #expect(state.rowSpokenDetail(for: file) == KernirFormat.size(340_000))
        #expect(state.rowSpokenDetail(for: try #require(model.item(at: "src"))) == "2 objects")
        await state.document.closeOnMain()
    }

    /// The subtitle never claims "0 KB" for a file of unknown size: it leaves the size out.
    @Test(arguments: singleStreams.keys.sorted())
    func rootSubtitleLeavesOutUnknownSize(_ fixture: String) async throws {
        let state = try await openLive(fixture)
        #expect(state.subtitle(for: "") == "1 item")
        #expect(!state.subtitle(for: "").contains("KB"))
        await state.document.closeOnMain()
    }

    /// One file of unknown size makes the folder's total unknown, even next to known ones.
    @Test func folderSubtitleLeavesOutUnknownSize() async throws {
        let entries: [ArchiveEntry] = [
            .init(path: "docs", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil),
            .init(path: "docs/known.txt", isDirectory: false, size: 10, compressedSize: nil, modificationDate: nil),
            .init(path: "docs/unknown.txt", isDirectory: false, size: nil, compressedSize: nil, modificationDate: nil),
            .init(path: "sized", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil),
            .init(path: "sized/a.txt", isDirectory: false, size: 2_048, compressedSize: nil, modificationDate: nil),
        ]
        let state = try await open(reader: FakeReader(entries: entries))
        #expect(state.subtitle(for: "docs") == "2 items")
        #expect(!state.subtitle(for: "docs").contains("KB"))
        #expect(state.subtitle(for: "") == "5 items")
        #expect(state.subtitle(for: "sized") == KernirFormat.summary(itemCount: 1, size: 2_048,
                                                                     compressedSize: nil, format: nil))
        await state.document.closeOnMain()
    }

    /// Tapping a single-stream file previews it: nothing on the app's path waits for a known size.
    @Test(arguments: singleStreams.keys.sorted())
    func previewSingleStreamFile(_ fixture: String) async throws {
        let state = try await openLive(fixture)
        let entry = Self.singleEntry(of: fixture)

        await state.preview(entry)

        let url = try #require(state.previewURL, "alert: \(String(describing: state.alert))")
        #expect(url.lastPathComponent == entry)
        #expect(try Data(contentsOf: url).count == Self.singleStreams[fixture])
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    // MARK: - Presenting after the progress sheet

    /// Polls until `condition` holds, for up to about five seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func slowReader(_ delay: Duration = .milliseconds(500)) -> FakeReader {
        FakeReader(entries: SampleArchive().entries, extractDelay: delay)
    }

    /// A slow preview comes up only once the progress sheet has gone: UIKit can't present it
    /// while the sheet is still going away.
    @Test func slowPreviewWaitsForProgressSheetToGo() async throws {
        let state = try await open(reader: slowReader())
        let preview = Task { await state.preview("README.md") }
        try await waitUntil { state.progress != nil }
        #expect(state.progress?.title == "Preparing “README.md”…")
        state.progressSheetDidAppear()

        await preview.value
        #expect(state.progress == nil)
        #expect(state.previewURL == nil, "the sheet is still going away")

        state.progressSheetDidDismiss()
        #expect(state.previewURL?.lastPathComponent == "README.md")
        #expect(state.previewFolder == "")
        await state.document.closeOnMain()
    }

    /// A preview whose extraction ended after the model was replaced (read again after a change
    /// elsewhere) isn't presented: its file belongs to the old model.
    @Test func previewIsNotPresentedAfterModelReplacement() async throws {
        let state = try await open(reader: slowReader())
        let model = try #require(state.model)
        let preview = Task { await state.preview("README.md") }
        try await waitUntil { state.progress != nil }

        state.session.phase = .ready(ArchiveModel(reader: FakeReader(entries: SampleArchive().entries),
                                                  undoManager: nil))
        await preview.value
        #expect(state.previewURL == nil)
        state.session.phase = .ready(model)
        await state.document.closeOnMain()
    }

    @Test func slowShareWaitsForProgressSheetToGo() async throws {
        let state = try await open(reader: slowReader())
        let share = Task { await state.share(["src/main.swift"], from: .row("src/main.swift")) }
        try await waitUntil { state.progress != nil }
        state.progressSheetDidAppear()

        await share.value
        #expect(state.progress == nil)
        #expect(state.shareRequest == nil, "the sheet is still going away")

        state.progressSheetDidDismiss()
        let request = try #require(state.shareRequest)
        #expect(request.anchor == .row("src/main.swift"))
        #expect(request.urls.map(\.lastPathComponent) == ["main.swift"])
        await state.document.closeOnMain()
    }

    /// The progress sheet never came up (no level could present it): nothing to wait for.
    @Test func slowPreviewWithoutSheetShowsAtOnce() async throws {
        let state = try await open(reader: slowReader())
        await state.preview("README.md")
        #expect(state.previewURL?.lastPathComponent == "README.md")
        await state.document.closeOnMain()
    }

    /// Work that ends just after the sheet started coming up (0.35 s against the 0.3 s delay)
    /// still leaves the sheet up for `minimumSheetTime`, so it is never dismissed halfway up.
    @Test func progressSheetStaysUpForMinimumTime() async throws {
        let state = try await open(reader: slowReader(.milliseconds(350)))
        let preview = Task { await state.preview("README.md") }
        try await waitUntil { state.progress != nil }
        let shown = ContinuousClock.now
        state.progressSheetDidAppear()

        try await waitUntil { state.progress == nil }
        #expect(ContinuousClock.now - shown >= ScreenState.minimumSheetTime - .milliseconds(50))
        await preview.value
        state.progressSheetDidDismiss()
        #expect(state.previewURL != nil)
        await state.document.closeOnMain()
    }

    /// Cancel on the progress sheet: nothing comes up after it goes.
    @Test func cancelledSlowPreviewShowsNothing() async throws {
        let state = try await open(reader: slowReader(.seconds(30)))
        let preview = Task { await state.preview("README.md") }
        try await waitUntil { state.progress != nil }
        state.progressSheetDidAppear()
        let cancel = try #require(state.progress?.cancel)
        cancel()
        await preview.value
        state.progressSheetDidDismiss()
        #expect(state.previewURL == nil)
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    // MARK: - Saving drops previews and shares

    /// A save replaces the archive, and with it the reader whose temporary files the preview
    /// shows: the preview and share sheet go, and don't come back after the save.
    @Test func saveStartDropsPreviewAndShare() async throws {
        let state = try await open()
        await state.preview("README.md")
        #expect(state.previewURL != nil)
        state.session.saveFraction = 0
        #expect(state.previewURL == nil)
        state.session.saveFraction = nil
        #expect(state.previewURL == nil)

        await state.share(["README.md"], from: .row("README.md"))
        #expect(state.shareRequest != nil)
        state.session.saveFraction = 0
        #expect(state.shareRequest == nil)
        state.session.saveFraction = nil
        #expect(state.shareRequest == nil)
        await state.document.closeOnMain()
    }

    /// A save that starts while a file is being prepared: the copy shows the archive as it was,
    /// so nothing comes up once the sheet goes.
    @Test func saveDuringSlowPreviewDropsIt() async throws {
        let state = try await open(reader: slowReader())
        let preview = Task { await state.preview("README.md") }
        try await waitUntil { state.progress != nil }
        state.progressSheetDidAppear()
        state.session.saveFraction = 0
        await preview.value
        state.session.saveFraction = nil
        state.progressSheetDidDismiss()
        #expect(state.previewURL == nil)

        let share = Task { await state.share(["README.md"], from: .row("README.md")) }
        try await waitUntil { state.progress != nil }
        state.progressSheetDidAppear()
        state.session.saveFraction = 0
        await share.value
        state.session.saveFraction = nil
        state.progressSheetDidDismiss()
        #expect(state.shareRequest == nil)
        await state.document.closeOnMain()
    }

    // MARK: - Stale share requests

    @Test func leavingSelectModeDropsToolbarShare() async throws {
        let state = try await open()
        state.isSelecting = true
        state.selection = ["README.md"]
        await state.share(["README.md"], from: .toolbar(""))
        #expect(state.shareRequest != nil)
        state.isSelecting = false
        #expect(state.shareRequest == nil)

        // A row's share sheet doesn't depend on Select mode.
        state.isSelecting = true
        await state.share(["README.md"], from: .row("README.md"))
        state.isSelecting = false
        #expect(state.shareRequest?.anchor == .row("README.md"))
        await state.document.closeOnMain()
    }

    @Test func deletingSharedRowDropsShare() async throws {
        let state = try await open()
        await state.share(["README.md"], from: .row("README.md"))
        state.delete(["brief.pdf"])
        #expect(state.shareRequest != nil)
        state.delete(["README.md"])
        #expect(state.shareRequest == nil)
        await state.document.closeOnMain()
    }

    /// Undo (from the bar, the keyboard or the state) can take the row away too.
    @Test func undoRemovingSharedRowDropsShare() async throws {
        let state = try await open()
        state.add([try sourceFile("new.txt")], to: "")
        await state.share(["new.txt"], from: .row("new.txt"))
        #expect(state.shareRequest != nil)
        for _ in 0..<100 where !state.canUndo {
            try await Task.sleep(for: .milliseconds(10))
        }
        state.document.undoManager?.undo()
        #expect(state.model?.item(at: "new.txt") == nil)
        try await waitUntil { state.shareRequest == nil }
        #expect(state.shareRequest == nil)
        await state.document.closeOnMain()
    }

    @Test func leavingLevelDropsItsShare() async throws {
        let state = try await open()
        await state.share(["src/main.swift"], from: .row("src/main.swift"))
        state.levelDidDisappear("")
        #expect(state.shareRequest != nil, "another level")
        state.levelDidDisappear("src")
        #expect(state.shareRequest == nil)

        state.isSelecting = true
        state.selection = ["src/main.swift"]
        await state.share(["src/main.swift"], from: .toolbar("src"))
        state.levelDidDisappear("src")
        #expect(state.shareRequest == nil)
        await state.document.closeOnMain()
    }

    // MARK: - Share copies

    /// The batch folders in the document's scratch area.
    private func shareBatches(_ state: ScreenState) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: state.document.scratch.root.path)) ?? []
    }

    @Test func failedShareRemovesItsCopies() async throws {
        let state = try await open(reader: FakeReader(entries: SampleArchive().entries, failure: .io("")))
        await state.share(["README.md"], from: .row("README.md"))
        #expect(state.alert?.title == "Couldn't share “README.md”")
        #expect(shareBatches(state).isEmpty)
        await state.document.closeOnMain()
    }

    @Test func cancelledShareRemovesItsCopies() async throws {
        let state = try await open(reader: slowReader(.seconds(30)))
        let share = Task { await state.share(["README.md"], from: .row("README.md")) }
        try await waitUntil { state.progress != nil }
        #expect(shareBatches(state).count == 1)
        let cancel = try #require(state.progress?.cancel)
        cancel()
        await share.value
        #expect(state.shareRequest == nil)
        #expect(shareBatches(state).isEmpty)
        await state.document.closeOnMain()
    }

    @Test func newShareRemovesPreviousCopies() async throws {
        let state = try await open()
        await state.share(["README.md"], from: .row("README.md"))
        let first = try #require(state.shareRequest).urls
        state.shareRequest = nil

        await state.share(["brief.pdf"], from: .row("brief.pdf"))

        #expect(!FileManager.default.fileExists(atPath: first[0].path))
        let second = try #require(state.shareRequest).urls
        #expect(second.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(shareBatches(state).count == 1)
        await state.document.closeOnMain()
    }

    // MARK: - Read-only and encrypted archives

    /// A read-only format (ISO) extracts and shares like any other.
    @Test func readOnlyFormatExtractsAndShares() async throws {
        let state = try await openLive("iso/basic.iso")
        #expect(!state.canEdit)
        let folder = try destinationFolder()

        await state.extract(["hello.txt", "docs"], to: folder)

        #expect(state.alert == nil)
        #expect(contents(of: folder) == ["hello.txt", "docs", "docs/notes.txt", "docs/readme.md", "docs/nested",
                                         "docs/nested/deep", "docs/nested/deep/data.bin"])
        #expect(try fileSize(folder.appendingPathComponent("docs/nested/deep/data.bin")) == 70_000)

        await state.share(["hello.txt"], from: .row("hello.txt"))
        let shared = try #require(state.shareRequest).urls
        #expect(try fileSize(shared[0]) == 15)
        await state.document.closeOnMain()
    }

    /// An AES-256 ZIP, once unlocked, extracts, shares and previews its encrypted entries.
    @Test func unlockedZipExtractsSharesAndPreviews() async throws {
        ArchiveDocument.engine = .live
        let service = "com.kernir.app.tests.\(UUID().uuidString)"
        let document = ArchiveDocument(fileURL: try Fixture.copy("zip/aes256.zip"), keychainService: service)
        defer { KeychainPasswordStore.remove(for: document.fileURL, service: service) }
        #expect(await document.openOnMain())
        await document.unlock(password: "kernir", remember: false)
        let state = ScreenState(document: document)
        #expect(state.model != nil, "expected .ready, got \(document.session.phase)")
        let folder = try destinationFolder()

        await state.extract(nil, to: folder)

        #expect(state.alert == nil)
        #expect(try fileSize(folder.appendingPathComponent("hello.txt")) == 15)
        #expect(try fileSize(folder.appendingPathComponent("docs/nested/deep/data.bin")) == 70_000)

        await state.share(["docs/notes.txt"], from: .row("docs/notes.txt"))
        #expect(try fileSize(try #require(state.shareRequest).urls[0]) == 20_000)

        await state.preview("hello.txt")
        #expect(try fileSize(try #require(state.previewURL)) == 15)
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    private func fileSize(_ url: URL) throws -> Int {
        try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }


    @Test(arguments: [
        ("notes.txt", "doc.text"), ("main.swift", "doc.text"), ("cover.png", "photo"),
        ("brief.pdf", "doc.richtext"), ("clip.mov", "film"), ("song.mp3", "music.note"),
        ("inner.zip", "doc.zipper"), ("blob.unknownext", "doc"), ("Makefile", "doc"),
    ])
    func fileSymbolFollowsType(name: String, symbol: String) {
        #expect(EntryRow.symbol(forFileNamed: name) == symbol)
    }

    // MARK: - Keyboard and menu bar commands (ArchiveNavigationController)

    private let saveAction = #selector(ArchiveNavigationController.saveArchive(_:))
    private let deleteAction = #selector(UIResponderStandardEditActions.delete(_:))
    private let selectAllAction = #selector(UIResponderStandardEditActions.selectAll(_:))
    private let findAction = #selector(UIResponderStandardEditActions.find(_:))
    private let undoAction = #selector(ArchiveNavigationController.undo(_:))
    private let redoAction = #selector(ArchiveNavigationController.redo(_:))
    private let closeAction = #selector(ArchiveNavigationController.closeArchive(_:))

    /// A window's navigation controller with `state`'s document open, at the root level.
    private func navigation(for state: ScreenState?) -> ArchiveNavigationController {
        let navigation = ArchiveNavigationController(rootViewController: UIViewController())
        navigation.screenState = state
        return navigation
    }

    /// No document: none of the commands is ours, so the launch browser keeps its own.
    @Test func commandsNeedAnOpenDocument() async throws {
        let none = navigation(for: nil)
        for action in [saveAction, deleteAction, selectAllAction, findAction, undoAction, redoAction, closeAction] {
            #expect(!none.canPerformAction(action, withSender: nil), "\(action)")
        }
        #expect(none.target(forAction: undoAction, withSender: nil) == nil)
        if #available(iOS 26.0, *) {
            #expect(!none.canPerformAction(#selector(UIResponderStandardEditActions.performClose(_:)), withSender: nil))
        }

        // Locked: the document is open but not listed yet.
        let locked = try await openLocked("zip/aes256.zip", engine: FakeEngine(password: "kernir"))
        #expect(locked.model == nil)
        let navigation = navigation(for: locked)
        for action in [deleteAction, selectAllAction, findAction] {
            #expect(!navigation.canPerformAction(action, withSender: nil), "\(action)")
        }
        navigation.selectAll(nil)
        navigation.find(nil)
        #expect(!locked.isSelecting)
        #expect(!locked.isSearchPresented)
        await locked.document.closeOnMain()
    }

    @Test func saveCommandEnabledOnlyWithChanges() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let navigation = navigation(for: state)
        #expect(!state.canSaveNow)
        #expect(!navigation.canPerformAction(saveAction, withSender: nil))

        model.remove(["README.md"])
        #expect(state.canSaveNow)
        #expect(navigation.canPerformAction(saveAction, withSender: nil))

        state.session.saveFraction = 0.5
        #expect(!state.canSaveNow)
        #expect(!navigation.canPerformAction(saveAction, withSender: nil))
        state.session.saveFraction = nil
        await state.document.closeOnMain()
    }

    /// ⌘⌫ removes the selection in Select mode, only where the archive can be edited.
    @Test func deleteCommandNeedsEditableSelection() async throws {
        let rar = try await open(reader: FakeReader(entries: SampleArchive().entries, format: .rar))
        let readOnly = navigation(for: rar)
        rar.isSelecting = true
        rar.selection = ["README.md"]
        #expect(!readOnly.canPerformAction(deleteAction, withSender: nil))
        readOnly.delete(nil)
        #expect(rar.model?.item(at: "README.md") != nil)
        await rar.document.closeOnMain()

        let state = try await open()
        let model = try #require(state.model)
        let navigation = navigation(for: state)
        state.isSelecting = true
        #expect(!navigation.canPerformAction(deleteAction, withSender: nil), "empty selection")
        state.selection = ["README.md", "src"]
        #expect(navigation.canPerformAction(deleteAction, withSender: nil))
        navigation.delete(nil)
        #expect(model.item(at: "README.md") == nil)
        #expect(model.item(at: "src") == nil)
        #expect(model.item(at: "brief.pdf") != nil)
        #expect(!state.isSelecting)
        await state.document.closeOnMain()
    }

    /// While the search field is up, ⌘⌫ belongs to it (delete to the line start), not to the
    /// selected rows: the sim showed that the field doesn't take `delete:`, so it would reach
    /// the navigation controller. The toolbar's Delete still works.
    @Test func deleteCommandWaitsWhileSearching() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let navigation = navigation(for: state)
        state.isSelecting = true
        state.selection = ["README.md"]
        state.isSearchPresented = true
        #expect(!navigation.canPerformAction(deleteAction, withSender: nil))
        navigation.delete(nil)
        #expect(model.item(at: "README.md") != nil)
        #expect(state.canDeleteSelection, "the toolbar's Delete")

        state.isSearchPresented = false
        #expect(navigation.canPerformAction(deleteAction, withSender: nil))
        navigation.delete(nil)
        #expect(model.item(at: "README.md") == nil)
        await state.document.closeOnMain()
    }

    /// ⌘A selects the rows of the level on screen that the search shows, in Select mode.
    @Test func selectAllSelectsCurrentLevel() async throws {
        let state = try await open()
        let navigation = navigation(for: state)
        #expect(navigation.currentPath == "")
        #expect(navigation.canPerformAction(selectAllAction, withSender: nil))
        navigation.selectAll(nil)
        #expect(state.isSelecting)
        #expect(state.selection == ["src", "assets", "brief.pdf", "README.md"])
        state.isSelecting = false

        navigation.pushViewController(FolderHostingController(state: state, path: "src"), animated: false)
        #expect(navigation.currentPath == "src")
        navigation.selectAll(nil)
        #expect(state.isSelecting)
        #expect(state.selection == ["src/main.swift", "src/utils.swift"])
        state.isSelecting = false

        state.searchText = "main"
        navigation.selectAll(nil)
        #expect(state.selection == ["src/main.swift"])
        await state.document.closeOnMain()
    }

    /// For the keyboard: ⌘Z and ⇧⌘Z stop at the navigation controller while a save
    /// writes, disabled, instead of reaching the window's undo.
    @Test func undoCommandDisabledWhileSaving() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let navigation = navigation(for: state)
        model.remove(["README.md"])
        try await waitUntil { state.canUndo }
        #expect(navigation.canPerformAction(undoAction, withSender: nil))
        #expect(navigation.target(forAction: undoAction, withSender: nil) as? ArchiveNavigationController === navigation)

        state.session.saveFraction = 0.5
        #expect(!navigation.canPerformAction(undoAction, withSender: nil))
        #expect(!navigation.canPerformAction(redoAction, withSender: nil))
        #expect(navigation.target(forAction: undoAction, withSender: nil) == nil)
        navigation.undo(nil)
        #expect(model.item(at: "README.md") == nil)

        state.session.saveFraction = nil
        navigation.undo(nil)
        #expect(model.item(at: "README.md") != nil)
        try await waitUntil { state.canRedo }
        #expect(navigation.canPerformAction(redoAction, withSender: nil))
        navigation.redo(nil)
        #expect(model.item(at: "README.md") == nil)
        await state.document.closeOnMain()
    }

    @Test func findPresentsSearch() async throws {
        let state = try await open()
        let navigation = navigation(for: state)
        #expect(!state.isSearchPresented)
        #expect(navigation.canPerformAction(findAction, withSender: nil))
        navigation.find(nil)
        #expect(state.isSearchPresented)
        await state.document.closeOnMain()
    }

    /// ⌘W with a document open closes the document (the back chevron's action), not the window.
    @Test func closeCommandClosesDocument() async throws {
        let state = try await open()
        var closed = 0
        state.closeDocument = { closed += 1 }
        let navigation = navigation(for: state)
        if #available(iOS 26.0, *) {
            let performClose = #selector(UIResponderStandardEditActions.performClose(_:))
            #expect(navigation.canPerformAction(performClose, withSender: nil))
            navigation.performClose(nil)
        } else {
            #expect(navigation.canPerformAction(closeAction, withSender: nil))
            navigation.closeArchive(nil)
        }
        #expect(closed == 1)
        await state.document.closeOnMain()
    }

    // MARK: - Text Encoding

    /// Opens a copy of `zip/legacy-cp1251.zip` (names stored in CP1251, no UTF-8 flag) with the live
    /// engine; choices are kept in `store`, not the app's own defaults.
    private func openLegacyCP1251(store: ArchiveNameEncodingStore) async throws -> ScreenState {
        let state = try await openLive("zip/legacy-cp1251.zip")
        let model = try #require(state.model)
        model.nameEncodingStore = store
        #expect(model.item(at: Self.cp1251Report) != nil)
        return state
    }

    /// A store in a defaults suite of its own; `remove` deletes the suite.
    private func scratchStore() -> (store: ArchiveNameEncodingStore, remove: () -> Void) {
        let (defaults, suiteName) = makeTestDefaults("KernirIOSTests.TextEncoding")
        return (ArchiveNameEncodingStore(defaults: defaults), { removeTestDefaults(defaults, suite: suiteName) })
    }

    /// The report's name in `zip/legacy-cp1251.zip`, read as CP1251 and as CP866.
    private static let cp1251Report = "Отчёт за май.docx"
    private static let cp866Report = "╬Єў╕Є чр ьрщ.docx"
    /// DOS Russian; KernirCore keeps its own constant internal.
    private static let cp866 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosRussian.rawValue)))

    /// "отчет.txt" in `zip/legacy-cp1251.zip`, read as CP866.
    private static let cp866Notes = "юЄўхЄ.txt"

    /// KernirCore's engine, except that its plain open reads every file Automatic, as for a file with
    /// no choice remembered: only `openWithNameEncoding` can carry a choice to the file a save wrote.
    /// (The live engine's open reads the app's own store, which a test's model doesn't write to.)
    private static let automaticOpenEngine = DocumentEngine(
        open: { url, password in try await Archive.open(at: url, password: password) },
        openWithNameEncoding: DocumentEngine.live.openWithNameEncoding,
        write: DocumentEngine.live.write)

    /// For a save after a switch: the choice survives the save,
    /// through the reopen after it (`openSaved` with the engine's `openWithNameEncoding`), and the names
    /// the save keeps are written back byte for byte: read as CP1251, the saved file still shows them
    /// (CP1251 maps those bytes one to one), with no UTF-8 flag added.
    @Test func savingAfterASwitchKeepsTheChoiceAndTheNames() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        // Swapped and reset with no await between, so another suite's test can't see it swapped.
        let document: ArchiveDocument
        do {
            ArchiveDocument.engine = Self.automaticOpenEngine
            defer { ArchiveDocument.engine = .live }
            document = ArchiveDocument(fileURL: try Fixture.copy("zip/legacy-cp1251.zip"))
        }
        #expect(await document.openOnMain())
        let state = ScreenState(document: document)
        let model = try #require(state.model)
        model.nameEncodingStore = scratch.store
        let url = document.fileURL

        state.chooseNameEncoding(.specific(Self.cp866))
        await state.nameEncodingTask?.value
        #expect(state.nameEncoding == .specific(Self.cp866))
        state.delete([Self.cp866Notes])
        #expect(state.hasChanges)
        // UIDocument counts the edit when the undo group closes, at the end of this run loop turn.
        try await waitUntil { document.hasUnsavedChanges }
        await state.save()

        #expect(state.session.saveError == nil)
        #expect(state.hasChanges == false)
        #expect(state.model?.reader?.nameEncoding == .specific(Self.cp866))
        #expect(state.nameEncoding == .specific(Self.cp866))
        #expect(scratch.store.nameEncoding(for: url) == .specific(Self.cp866))
        #expect(state.model?.item(at: Self.cp866Report) != nil)
        #expect(state.model?.item(at: Self.cp866Notes) == nil)

        let saved = try await Archive.open(at: url, nameEncoding: .specific(.windowsCP1251))
        #expect(saved.entries.map(\.path).sorted() == [Self.cp1251Report, "Фото", "Фото/Лето 2024.jpg"].sorted())
        #expect(saved.legacyNameEncoding != nil, "the save added no UTF-8 flag")
        await document.closeOnMain()
    }

    /// A copy of `zip/legacy-cp1251.zip` whose readers hold every extraction at `hold`'s gate, so a
    /// preview or share stays in flight until the test opens it. The progress sheet waits 10 s, so it
    /// stays down while the test looks.
    private func openHeldLegacyCP1251(store: ArchiveNameEncodingStore,
                                      hold: ExtractionHold) async throws -> ScreenState {
        let engine = Self.automaticOpenEngine
        ArchiveDocument.engine = DocumentEngine(
            open: { url, password in HeldReader(base: try await engine.open(url, password), hold: hold) },
            openWithNameEncoding: { url, password, nameEncoding in
                HeldReader(base: try await engine.openWithNameEncoding(url, password, nameEncoding), hold: hold)
            },
            write: engine.write)
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: try Fixture.copy("zip/legacy-cp1251.zip"))
        #expect(await document.openOnMain())
        let state = ScreenState(document: document)
        try #require(state.model).nameEncodingStore = store
        state.preparingSheetDelay = .seconds(10)
        return state
    }

    /// Waits until an operation under `perform` has reached its extraction, which `gate` holds. Its
    /// progress sheet isn't up: `preparingSheetDelay` is 10 s.
    private func waitForExtraction(at gate: OpenGate, of state: ScreenState) async throws {
        try await waitUntil { gate.arrivals > 0 }
        #expect(gate.arrivals == 1, "the operation reached the gate")
        #expect(state.runningOperations == 1)
        #expect(state.progress == nil, "its progress sheet isn't up yet")
    }

    /// Off while Extract's conflict questions are open, between them too: their answers are keyed by
    /// the names as read now. On again once they end.
    @Test func textEncodingIsOffWhileExtractAsks() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = quickQuestions(try await openLegacyCP1251(store: scratch.store))
        let folder = try destinationFolder()
        try existing(Self.cp1251Report, in: folder)
        #expect(state.canChooseNameEncoding)

        await state.extract([Self.cp1251Report], to: folder)
        #expect(state.extractionQuestion != nil)
        #expect(state.canChooseNameEncoding == false)
        #expect(state.canShowInfo == false, "Info is off while Extract asks too")
        state.chooseNameEncoding(.specific(Self.cp866))
        #expect(state.nameEncodingTask == nil)
        state.answerExtractionConflict(.keepBoth, at: 0)
        #expect(state.canChooseNameEncoding == false, "between the answer and the extraction")
        #expect(state.canShowInfo == false, "between the answer and the extraction")
        state.stopExtraction()
        #expect(state.canChooseNameEncoding)
        #expect(state.canShowInfo)
        await state.document.closeOnMain()
    }

    /// A preview or share preparing its file, before its progress sheet comes up: Text Encoding is off
    ///, as while the sheet is up, so a reopen can't rename the item under it. On again
    /// once it has finished.
    @Test func textEncodingIsOffWhileAPreviewOrShareIsPrepared() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let hold = ExtractionHold()
        let state = try await openHeldLegacyCP1251(store: scratch.store, hold: hold)
        #expect(state.canChooseNameEncoding)

        let previewGate = hold.gate
        let preview = Task { await state.preview(Self.cp1251Report) }
        try await waitForExtraction(at: previewGate, of: state)
        #expect(state.canChooseNameEncoding == false)
        #expect(state.canShowInfo == false, "Info is off while an operation runs too")
        state.chooseNameEncoding(.specific(Self.cp866))
        #expect(state.nameEncodingTask == nil)
        previewGate.open()
        await preview.value
        #expect(state.previewURL != nil)
        #expect(state.canChooseNameEncoding)
        state.previewURL = nil

        let shareGate = OpenGate()
        hold.gate = shareGate
        let share = Task { await state.share([Self.cp1251Report], from: .row(Self.cp1251Report)) }
        try await waitForExtraction(at: shareGate, of: state)
        #expect(state.canChooseNameEncoding == false)
        state.chooseNameEncoding(.specific(Self.cp866))
        #expect(state.nameEncodingTask == nil)
        shareGate.open()
        await share.value
        #expect(state.shareRequest != nil)
        #expect(state.canChooseNameEncoding)
        #expect(state.nameEncoding == .automatic)
        await state.document.closeOnMain()
    }

    /// A preview preparing its file, before its progress sheet comes up, turns
    /// Extract's buttons off, as Text Encoding: its Files picker would have the preview, or its progress
    /// sheet, come up over it. On again once the preview has finished.
    @Test(.timeLimit(.minutes(1))) func extractIsOffWhileAPreviewIsPrepared() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let hold = ExtractionHold()
        let state = try await openHeldLegacyCP1251(store: scratch.store, hold: hold)
        #expect(state.canExtract)

        let gate = hold.gate
        let preview = Task { await state.preview(Self.cp1251Report) }
        try await waitForExtraction(at: gate, of: state)
        #expect(state.canExtract == false)
        #expect(state.allowsPresenting, "nothing asks")
        gate.open()
        await preview.value
        #expect(state.previewURL != nil)
        #expect(state.canExtract)
        state.previewURL = nil
        await state.document.closeOnMain()
    }

    /// The archive was read again while a file was being prepared (the menu is off then, so only from
    /// code): the preview and the share sheet don't come up, since their item may have another name or
    /// none now, and the share's copies go. Nothing is reported.
    @Test func previewOrShareFinishingAfterAReopenShowsNothing() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let hold = ExtractionHold()
        let state = try await openHeldLegacyCP1251(store: scratch.store, hold: hold)

        let previewGate = hold.gate
        let preview = Task { await state.preview(Self.cp1251Report) }
        try await waitForExtraction(at: previewGate, of: state)
        try await state.document.reopen(nameEncoding: .specific(Self.cp866))
        #expect(state.model?.item(at: Self.cp1251Report) == nil)
        previewGate.open()
        await preview.value
        #expect(state.previewURL == nil)
        #expect(state.alert == nil)

        // The reopen read the file through the document's engine, so the new reader holds its
        // extractions too.
        let shareGate = OpenGate()
        hold.gate = shareGate
        let share = Task { await state.share([Self.cp866Report], from: .row(Self.cp866Report)) }
        try await waitForExtraction(at: shareGate, of: state)
        try await state.document.reopen(nameEncoding: .automatic)
        shareGate.open()
        await share.value
        #expect(state.shareRequest == nil)
        #expect(state.alert == nil)
        #expect(shareBatches(state).isEmpty, "the share's copies went")
        await state.document.closeOnMain()
    }

    /// A reopen that fails while a file is being prepared changes nothing, so the preview still comes up:
    /// only a reopen that adopted the new listing counts.
    @Test func previewFinishingAfterAFailedReopenComesUp() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let hold = ExtractionHold()
        let state = try await openHeldLegacyCP1251(store: scratch.store, hold: hold)

        let gate = hold.gate
        let preview = Task { await state.preview(Self.cp1251Report) }
        try await waitForExtraction(at: gate, of: state)
        await #expect(throws: ArchiveError.self) {
            try await state.document.reopen(nameEncoding: .specific(Self.cp866)) { _, _, _ in
                throw ArchiveError.io("")
            }
        }
        #expect(state.model?.item(at: Self.cp1251Report) != nil)
        gate.open()
        await preview.value
        #expect(state.previewURL != nil)
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    /// Nothing to reinterpret: every name is declared (7z) or plain ASCII, so the menu is off.
    @Test func textEncodingIsOffWithoutLegacyNames() async throws {
        let fake = try await open()
        #expect(fake.model?.reader?.legacyNameEncoding == nil)
        #expect(fake.canChooseNameEncoding == false)
        await fake.document.closeOnMain()

        for fixture in ["7z/copy.7z", "zip/deflate.zip"] {
            let state = try await openLive(fixture)
            #expect(state.model?.reader?.legacyNameEncoding == nil, "\(fixture)")
            #expect(state.canChooseNameEncoding == false, "\(fixture)")
            #expect(state.nameEncoding == .automatic, "\(fixture)")
            await state.document.closeOnMain()
        }
    }

    /// Names stored in a code page: the menu is on, with Automatic selected.
    @Test func textEncodingIsOnForLegacyNames() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        #expect(state.model?.reader?.legacyNameEncoding == .windowsCP1251)
        #expect(state.nameEncoding == .automatic)
        #expect(state.canChooseNameEncoding)
        await state.document.closeOnMain()
    }

    /// Off while the archive has unsaved changes; choosing then does nothing.
    @Test func textEncodingIsOffWithUnsavedChanges() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let model = try #require(state.model)
        state.delete(["отчет.txt"])
        #expect(state.hasChanges)
        #expect(state.canChooseNameEncoding == false)

        state.chooseNameEncoding(.specific(Self.cp866))
        #expect(state.nameEncodingTask == nil)
        #expect(state.progress == nil)
        #expect(model.item(at: Self.cp1251Report) != nil)
        #expect(model.item(at: "отчет.txt") == nil, "the edit stays")

        // `undo()` goes by the undo manager's notifications, which come once the delete's group closes.
        try await waitUntil { state.canUndo }
        state.undo()
        #expect(state.hasChanges == false)
        #expect(state.canChooseNameEncoding)
        await state.document.closeOnMain()
    }

    /// Off while another operation shows the progress sheet, or a save writes, even without unsaved
    /// changes; choosing then does nothing.
    @Test func textEncodingIsOffWhileSomethingRuns() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let model = try #require(state.model)
        #expect(state.canChooseNameEncoding)

        state.progress = OperationProgress(title: "Extracting “Фото”…")
        #expect(state.hasChanges == false)
        #expect(state.canChooseNameEncoding == false)
        state.chooseNameEncoding(.specific(Self.cp866))
        #expect(state.nameEncodingTask == nil)
        state.progress = nil
        #expect(state.canChooseNameEncoding)

        state.session.saveFraction = 0.5
        #expect(state.hasChanges == false)
        #expect(state.canChooseNameEncoding == false)
        state.chooseNameEncoding(.specific(Self.cp866))
        #expect(state.nameEncodingTask == nil)
        state.session.saveFraction = nil
        #expect(state.canChooseNameEncoding)
        #expect(model.item(at: Self.cp1251Report) != nil)
        await state.document.closeOnMain()
    }

    /// Adding files while Text Encoding reads the archive again (a picker's answer arriving late) is
    /// refused and the user told, as during a save: the new listing would drop them.
    @Test func addDuringReopenTellsUser() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let model = try #require(state.model)

        state.chooseNameEncoding(.specific(Self.cp866))
        let task = try #require(state.nameEncodingTask)
        state.add([try sourceFile("a.txt")], to: "")
        #expect(model.item(at: "a.txt") == nil)
        #expect(state.alert?.title == "Couldn't add “a.txt”")
        #expect(state.alert?.message == "The archive is being read again. Try again.")
        // `add` itself refuses, before copying anything in.
        #expect(stagedBatches(state).isEmpty)
        await task.value

        #expect(state.nameEncoding == .specific(Self.cp866), "the reopen went ahead")
        #expect(model.item(at: Self.cp866Report) != nil)
        #expect(model.hasChanges == false)
        await state.document.closeOnMain()
    }

    /// The batch folders in the document's staging area: one per `stage` call.
    private func stagedBatches(_ state: ScreenState) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: state.document.staging.root.path)) ?? []
    }

    /// Replace on the Replace alert while Text Encoding reads the archive again is refused and the user
    /// told: the new listing would drop the addition.
    @Test func replaceDuringReopenTellsUser() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let model = try #require(state.model)
        state.add([try sourceFile("отчет.txt")], to: "")
        #expect(state.pendingReplacement != nil)

        state.chooseNameEncoding(.specific(Self.cp866))
        let task = try #require(state.nameEncodingTask)
        state.confirmReplacement()
        #expect(state.pendingReplacement == nil)
        #expect(model.hasChanges == false)
        #expect(state.alert?.title == "Couldn't add “отчет.txt”")
        #expect(state.alert?.message == "The archive is being read again. Try again.")
        await task.value

        #expect(state.nameEncoding == .specific(Self.cp866), "the reopen went ahead")
        #expect(model.item(at: Self.cp866Notes)?.isPendingAddition == false)
        #expect(model.hasChanges == false)
        await state.document.closeOnMain()
    }

    /// Photos picked while Text Encoding reads the archive again are refused before loading anything,
    /// and the reopen's progress sheet stays.
    @Test func addPhotosDuringReopenTellsUser() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let model = try #require(state.model)
        let item = FakePickedItem(types: [.jpeg], data: Data("pixels".utf8))

        state.chooseNameEncoding(.specific(Self.cp866))
        let task = try #require(state.nameEncodingTask)
        try await waitUntil { state.progress != nil }
        let reading = try #require(state.progress)
        await state.addPhotos([item], to: "")
        #expect(item.loads.count == 0)
        #expect(state.alert?.title == "Couldn't add 1 item")
        #expect(state.alert?.message == "The archive is being read again. Try again.")
        #expect(state.progress?.id == reading.id, "the reopen's sheet stays")
        #expect(stagedBatches(state).isEmpty)
        await task.value

        #expect(state.nameEncoding == .specific(Self.cp866), "the reopen went ahead")
        #expect(model.hasChanges == false)
        await state.document.closeOnMain()
    }

    /// Closing the document from its view controller (`document = nil`, as Close and the password
    /// prompt's Cancel do) stops a reopen still running: `removeContent` cancels it first.
    /// Nothing is adopted, remembered or reported. The controller is given a document of its own
    /// (never opened, no scene session, so nothing is registered) before the screen state: the setter
    /// ignores nil → nil, and only a real document → nil close reaches `removeContent`.
    @Test func closingTheDocumentViewStopsTheReopen() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let url = state.document.fileURL
        let controller = ArchiveDocumentViewController(document: nil)
        let shown = ArchiveDocument(fileURL: url)
        controller.document = shown
        #expect(controller.document === shown)
        controller.screenState = state

        state.chooseNameEncoding(.specific(Self.cp866))
        let task = try #require(state.nameEncodingTask)
        controller.document = nil
        #expect(controller.screenState == nil)
        await task.value
        #expect(state.nameEncoding == .automatic)
        #expect(state.model?.item(at: Self.cp1251Report) != nil)
        #expect(scratch.store.nameEncoding(for: url) == .automatic)
        #expect(state.alert == nil)
        if !shown.documentState.contains(.closed) { await shown.closeOnMain() }
        await state.document.closeOnMain()
    }

    /// Swapping the document view to another document stops the shown one's reopen at
    /// once, as closing does, not only once the new document has opened (`installContent`), and so
    /// even if that open fails. Nothing is adopted, remembered or reported.
    @Test func swappingTheDocumentStopsTheReopen() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let url = state.document.fileURL
        let controller = ArchiveDocumentViewController(document: nil)
        let shown = ArchiveDocument(fileURL: url)
        let next = ArchiveDocument(fileURL: try Fixture.copy("zip/deflate.zip"))
        controller.document = shown
        #expect(controller.document === shown)
        controller.screenState = state

        state.chooseNameEncoding(.specific(Self.cp866))
        let task = try #require(state.nameEncodingTask)
        controller.document = next
        #expect(task.isCancelled, "stopped at the swap")
        #expect(controller.document === next)
        await task.value
        #expect(state.nameEncoding == .automatic)
        #expect(state.model?.item(at: Self.cp1251Report) != nil)
        #expect(scratch.store.nameEncoding(for: url) == .automatic)
        #expect(state.alert == nil)
        controller.document = nil
        for document in [shown, next] where !document.documentState.contains(.closed) {
            await document.closeOnMain()
        }
        await state.document.closeOnMain()
    }

    /// Undo and Redo stay on the bar while Text Encoding reads the archive again, disabled, so the bar
    /// doesn't lose them and lay out twice. As before, a save without pending edits
    /// shows neither.
    @Test func undoAndRedoStayOnTheBarDuringAReopen() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        #expect(state.showsUndoRedo)

        state.chooseNameEncoding(.specific(Self.cp866))
        let task = try #require(state.nameEncodingTask)
        #expect(state.allowsEditing == false)
        #expect(state.hasChanges == false)
        #expect(state.showsUndoRedo)
        #expect(state.canUndo == false)
        #expect(state.canRedo == false)
        await task.value
        #expect(state.nameEncoding == .specific(Self.cp866))
        #expect(state.showsUndoRedo)

        state.session.saveFraction = 0.5
        #expect(state.hasChanges == false)
        #expect(state.showsUndoRedo == false)
        state.session.saveFraction = nil
        await state.document.closeOnMain()
    }

    /// Choosing an encoding lists the archive again with it, clears the selection, closes folder
    /// levels that are no longer listed, and remembers the choice; Automatic goes back and forgets it.
    /// While it reads, editing, saving and the menu are off, and a delete does nothing.
    @Test func choosingAnEncodingRelistsTheArchive() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let model = try #require(state.model)
        let url = state.document.fileURL
        var closings = 0
        state.closeUnlistedFolders = { closings += 1 }
        state.isSelecting = true
        state.selection = [Self.cp1251Report]

        state.chooseNameEncoding(.specific(Self.cp866))
        let task = try #require(state.nameEncodingTask)
        #expect(state.canChooseNameEncoding == false)
        #expect(state.allowsEditing == false)
        #expect(state.canDeleteSelection == false)
        #expect(state.canSaveAsCopy == false)
        state.delete(["отчет.txt"])
        #expect(model.hasChanges == false, "no edit while the names are read again")
        await task.value

        #expect(state.nameEncodingTask == nil)
        #expect(state.progress == nil)
        #expect(state.alert == nil)
        #expect(state.nameEncoding == .specific(Self.cp866))
        #expect(model.item(at: Self.cp866Report) != nil)
        #expect(model.item(at: Self.cp1251Report) == nil)
        #expect(state.selection.isEmpty)
        #expect(closings == 1)
        #expect(scratch.store.nameEncoding(for: url) == .specific(Self.cp866))
        // A save writes from the document's snapshot, which now holds the new reader.
        let snapshot = try #require(try state.document.contents(forType: "public.zip-archive")
            as? ArchiveDocument.SaveSnapshot)
        #expect(snapshot.reader?.nameEncoding == .specific(Self.cp866))
        #expect(state.allowsEditing)
        #expect(state.canSaveAsCopy)
        #expect(state.canChooseNameEncoding)

        state.chooseNameEncoding(.automatic)
        await state.nameEncodingTask?.value
        #expect(state.nameEncoding == .automatic)
        #expect(model.item(at: Self.cp1251Report) != nil)
        #expect(closings == 2)
        #expect(scratch.store.nameEncoding(for: url) == .automatic)
        await state.document.closeOnMain()
    }

    /// With the progress sheet up, the levels the archive no longer lists close only once the sheet
    /// has gone: the level on screen presents it, and UIKit mishandles a level leaving while its sheet
    /// is still going away (as with presenting then). Without a sheet they close at once (above).
    @Test func unlistedFolderLevelsCloseAfterTheProgressSheet() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let model = try #require(state.model)
        var closings = 0
        state.closeUnlistedFolders = { closings += 1 }

        state.chooseNameEncoding(.specific(Self.cp866))
        let task = try #require(state.nameEncodingTask)
        try await waitUntil { state.progress != nil }
        state.progressSheetDidAppear()
        await task.value
        #expect(model.item(at: Self.cp866Report) != nil)
        #expect(state.progress == nil)
        #expect(closings == 0, "the sheet is still going away")

        state.progressSheetDidDismiss()
        #expect(closings == 1)
        // Once only: a later sheet going away closes nothing.
        state.progressSheetDidAppear()
        state.progressSheetDidDismiss()
        #expect(closings == 1)
        await state.document.closeOnMain()
    }

    /// After Text Encoding, the folder levels whose folders the archive no longer lists go; the
    /// document's own level and the folders still listed stay.
    @Test func unlistedFolderLevelsGo() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let model = try #require(state.model)
        let root = UIViewController()
        let photos = FolderHostingController(state: state, path: "Фото")
        #expect(FolderHostingController.listedLevels([root, photos], in: model) == [root, photos])

        try await model.reopen(nameEncoding: .specific(Self.cp866))
        #expect(model.item(at: "╘юЄю")?.isDirectory == true)
        #expect(FolderHostingController.listedLevels([root, photos], in: model) == [root])
        let renamed = FolderHostingController(state: state, path: "╘юЄю")
        #expect(FolderHostingController.listedLevels([root, renamed], in: model) == [root, renamed])
        // Everything from the first unlisted level on goes, even a level above it whose path is
        // listed: it was reached through the level that went.
        #expect(FolderHostingController.listedLevels([root, photos, renamed], in: model) == [root])
        #expect(FolderHostingController.listedLevels([root, renamed, photos, renamed], in: model)
            == [root, renamed])
        await state.document.closeOnMain()
    }

    /// The document closing stops a reopen still running: nothing is adopted or remembered, and no
    /// alert says so.
    @Test func closingStopsTheReopen() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let model = try #require(state.model)
        let url = state.document.fileURL
        var closings = 0
        state.closeUnlistedFolders = { closings += 1 }

        state.chooseNameEncoding(.specific(Self.cp866))
        let task = try #require(state.nameEncodingTask)
        state.cancelNameEncoding()
        await task.value
        #expect(state.nameEncodingTask == nil)
        #expect(state.nameEncoding == .automatic)
        #expect(model.item(at: Self.cp1251Report) != nil)
        #expect(scratch.store.nameEncoding(for: url) == .automatic)
        #expect(state.alert == nil)
        #expect(closings == 0)
        await state.document.closeOnMain()
    }

    /// The encoding already in use: nothing is read again.
    @Test func choosingTheCurrentEncodingDoesNothing() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        state.selection = [Self.cp1251Report]
        state.chooseNameEncoding(.automatic)
        #expect(state.nameEncodingTask == nil)
        #expect(state.selection == [Self.cp1251Report])
        await state.document.closeOnMain()
    }

    /// The archive can't be read again (its file is gone): the listing and the selection stay, the
    /// choice isn't remembered, and an alert says so.
    @Test func failedReopenKeepsTheListing() async throws {
        let scratch = scratchStore()
        defer { scratch.remove() }
        let state = try await openLegacyCP1251(store: scratch.store)
        let model = try #require(state.model)
        var closings = 0
        state.closeUnlistedFolders = { closings += 1 }
        state.selection = [Self.cp1251Report]
        try FileManager.default.removeItem(at: state.document.fileURL)

        state.chooseNameEncoding(.specific(Self.cp866))
        await state.nameEncodingTask?.value
        #expect(state.alert?.title == "Couldn't open “\(state.name)”")
        #expect(state.nameEncoding == .automatic)
        #expect(model.item(at: Self.cp1251Report) != nil)
        #expect(state.selection == [Self.cp1251Report])
        #expect(closings == 0)
        #expect(state.canChooseNameEncoding)
        await state.document.closeOnMain()
    }

    // MARK: - Multi-volume sets

    @Test func volumeErrorIsExposedOnlyInVolumePhase() async throws {
        let state = try await open()
        #expect(state.volumeError == nil)
        let error = ArchiveVolumeError(reason: .missing, part: 3, fileName: "a.part3.rar", setName: "a.part1.rar",
                                       folder: URL(fileURLWithPath: "/tmp"), openedPart: 1)
        state.session.phase = .volume(error)
        #expect(state.volumeError == error)
        // The document stays open: no failure alert, and it is not locked.
        #expect(state.presentedAlert == nil)
        #expect(!state.isLocked)
        state.session.phase = .locked(error: nil)
        #expect(state.volumeError == nil)
        await state.document.closeOnMain()
    }

    /// Choose Folder… on another folder than the one holding the parts says which one to choose.
    @Test func grantingAnotherFolderAsksForTheRightOne() async throws {
        let state = try await open()
        let error = ArchiveVolumeError(reason: .noAccess, part: 2, fileName: "a.part2.rar", setName: "a.part1.rar",
                                       folder: URL(fileURLWithPath: "/tmp/Parts"), openedPart: 1)
        state.session.phase = .volume(error)
        await state.grantFolder(URL(fileURLWithPath: "/tmp/Other"))
        #expect(state.alert?.title == "That folder doesn't contain this archive's other parts.")
        #expect(state.alert?.message == "Choose the folder that holds all parts of this archive.")
        #expect(state.presentedAlert != nil)
        #expect(state.volumeError == error)
        await state.document.closeOnMain()
    }

    /// Choose Folder… on the right folder, when the reopen still fails on the same part, says so
    /// instead of leaving the screen as it was.
    @Test func grantingTheRightFolderThatStillFailsSaysSo() async throws {
        let url = try Fixture.copy("zip/deflate.zip")
        let folder = url.deletingLastPathComponent()
        let error = ArchiveVolumeError(reason: .missing, part: 3, fileName: "a.part3.rar", setName: "a.part1.rar",
                                       folder: folder, openedPart: 1)
        let fake = FakeEngine(openFailures: [error, error])
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        let state = ScreenState(document: document)
        #expect(state.volumeError == error)
        await state.grantFolder(folder)
        #expect(fake.openCalls.count == 2)
        #expect(state.alert?.title == "Part 3 is still missing.")
        #expect(state.alert?.message == "Make sure every part is downloaded and in this folder, then try again.")
        #expect(state.presentedAlert != nil)
        #expect(state.volumeError == error)
        #expect(!state.isGrantingFolder)
        await document.closeOnMain()
    }
}

/// The iOS 27.2 Simulator (iPhone 17) scratch volume artifact: it says it folds case, but its lookups
/// match exact case only (lstat "probe" with "Probe" there: ENOENT) while its creates still collide
/// (O_EXCL, mkdir: EEXIST). Real devices and Macs are consistent. True only when both halves show in a
/// fresh folder in the temporary directory, which is removed again. Internal for MixedCaseVolumeTests.
func scratchVolumeIsMixedCase() -> Bool {
    let fileManager = FileManager.default
    let probe = fileManager.temporaryDirectory
        .appendingPathComponent("case-probe-\(UUID().uuidString)", isDirectory: true)
    guard (try? fileManager.createDirectory(at: probe, withIntermediateDirectories: false)) != nil else { return false }
    defer { try? fileManager.removeItem(at: probe) }
    guard fileManager.createFile(atPath: probe.appendingPathComponent("Probe").path, contents: nil),
          mkdir(probe.appendingPathComponent("Dir").path, 0o755) == 0 else { return false }
    var status = stat()
    let lookupMisses = lstat(probe.appendingPathComponent("probe").path, &status) != 0 && errno == ENOENT
        && !fileManager.fileExists(atPath: probe.appendingPathComponent("probe").path)
    let descriptor = open(probe.appendingPathComponent("probe").path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    let createError = descriptor >= 0 ? 0 : errno
    if descriptor >= 0 { close(descriptor) }
    let mkdirError = mkdir(probe.appendingPathComponent("dir").path, 0o755) == 0 ? 0 : errno
    let collides = [createError, mkdirError].contains { $0 == EEXIST || $0 == EIO }
    return lookupMisses && collides
}

/// A picked photo or video: a file named `fileName`, or only `data`.
private struct FakePickedItem: PickedItem {
    let supportedContentTypes: [UTType]
    let fileName: String?
    let data: Data?
    /// "file" and "data", per load asked for.
    let loads = LoadLog()
    /// Where the first load waits, if anywhere, until the test opens it.
    let gate: OpenGate?

    init(types: [UTType], fileName: String? = nil, data: Data? = nil, gate: OpenGate? = nil) {
        supportedContentTypes = types
        self.fileName = fileName
        self.data = data
        self.gate = gate
    }

    func loadFile() async throws -> PickedMedia? {
        loads.append("file")
        await gate?.pass()
        guard let fileName else { return nil }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Picked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try Data("media".utf8).write(to: url)
        return PickedMedia(url: url)
    }

    func loadData() async throws -> Data? {
        loads.append("data")
        return data
    }
}

private final class LoadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var count: Int { lock.withLock { entries.count } }

    func append(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }
}

/// Where `HeldReader`s hold their extractions: at `gate`, until the test opens it. A new gate holds
/// the extractions that start after it is set.
private final class ExtractionHold: @unchecked Sendable {
    private let lock = NSLock()
    private var current = OpenGate()

    var gate: OpenGate {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// A reader whose extractions wait at `hold`'s gate first, so a preview or share stays in flight
/// for as long as the test needs, whatever the clock.
private struct HeldReader: ArchiveReading {
    let base: any ArchiveReading
    let hold: ExtractionHold

    var url: URL { base.url }
    var volumeURLs: [URL] { base.volumeURLs }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }
    var encryption: ArchiveEncryption { base.encryption }
    var compressionMethod: ArchiveCompressionMethod? { base.compressionMethod }
    var nameEncoding: ArchiveNameEncoding { base.nameEncoding }
    var legacyNameEncoding: String.Encoding? { base.legacyNameEncoding }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        await hold.gate.pass()
        try await base.extract(paths, to: directory, progress: progress)
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        await hold.gate.pass()
        return try await base.extractToTemporaryFile(path)
    }
}
