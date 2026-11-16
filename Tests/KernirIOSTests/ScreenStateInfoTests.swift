import Foundation
import Testing
import UIKit
import KernirCore
@testable import Kernir

/// The Info sheet: when it can open, when its comment field takes typing, and a comment edit as a
/// document change: marked, one undo step on the document's undo manager, written by the document's save.
/// In `ScreenStateTests` for its `.serialized`: `ArchiveDocument.engine` is a process-wide test seam.
extension ScreenStateTests {
    private static let sourceText = "Hello from Kernir\n"

    private static func comment(isWritable: Bool = true) -> ArchiveComment {
        ArchiveComment(bytes: Array(sourceText.utf8), text: sourceText, isWritable: isWritable)
    }

    /// Opens a copy of a ZIP fixture with a fake engine whose readers list the sample entries with `comment`.
    private func openCommented(_ comment: ArchiveComment? = ScreenStateTests.comment(),
                               writeDelay: Duration = .zero,
                               legacyNameEncoding: String.Encoding? = nil) async throws -> (ScreenState, FakeEngine) {
        let url = try Fixture.copy("zip/deflate.zip")
        let fake = FakeEngine(writeDelay: writeDelay, reader: { url in
            FakeReader(entries: SampleArchive().entries, url: url, legacyNameEncoding: legacyNameEncoding,
                       comment: comment)
        })
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        #expect(document.session.model != nil)
        return (ScreenState(document: document), fake)
    }

    /// Waits up to 5 s for `condition`: UIDocument counts an edit, and the undo manager reports it, when the undo
    /// group closes at the end of the run loop turn.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A comment longer than Kernir writes (`ArchiveComment.maximumWritableLength`).
    private static var tooLongComment: String {
        String(repeating: "a", count: ArchiveComment.maximumWritableLength + 1)
    }

    /// A file to add, "added.txt" in a folder of its own, which the caller removes.
    private func fileToAdd() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("added.txt")
        try Data("added\n".utf8).write(to: file)
        return file
    }

    @Test func infoOpensOnAListedArchiveAndCloses() async throws {
        let (state, _) = try await openCommented()
        #expect(state.canShowInfo)
        #expect(!state.isShowingInfo)
        state.showInfo()
        #expect(state.isShowingInfo)
        state.closeInfo()
        #expect(!state.isShowingInfo)
        await state.document.closeOnMain()
    }

    /// File > Get Info (⌘I) opens the sheet on an open archive, and isn't ours with no document.
    @Test func getInfoCommandOpensInfo() async throws {
        let (state, _) = try await openCommented()
        let action = #selector(ArchiveNavigationController.getInfo(_:))
        let navigation = ArchiveNavigationController(rootViewController: UIViewController())
        navigation.screenState = state
        #expect(navigation.canPerformAction(action, withSender: nil))
        navigation.getInfo(nil)
        #expect(state.isShowingInfo)

        let none = ArchiveNavigationController(rootViewController: UIViewController())
        #expect(!none.canPerformAction(action, withSender: nil))
        await state.document.closeOnMain()
    }

    /// Extract Here has set its request and its Files picker isn't up yet: no Info (the bar's button, ⌘I), so
    /// the sheet can't take the picker's place.
    @Test func infoOffWhileAnExtractHereRequestIsPending() async throws {
        let (state, _) = try await openCommented()
        let folder = state.document.fileURL.deletingLastPathComponent()
        #expect(state.canShowInfo)
        state.extractHereRequest = ExtractHereRequest(step: .grant, paths: nil, folder: folder)
        #expect(!state.canShowInfo)
        let navigation = ArchiveNavigationController(rootViewController: UIViewController())
        navigation.screenState = state
        #expect(!navigation.canPerformAction(#selector(ArchiveNavigationController.getInfo(_:)), withSender: nil))
        state.showInfo()
        #expect(!state.isShowingInfo)
        state.extractHereRequest = nil
        #expect(state.canShowInfo)
        await state.document.closeOnMain()
    }

    /// Nothing listed yet: no Info.
    @Test func infoNeedsAListedArchive() throws {
        let state = ScreenState(document: ArchiveDocument(fileURL: try Fixture.copy("zip/deflate.zip")))
        #expect(!state.canShowInfo)
        state.showInfo()
        #expect(!state.isShowingInfo)
        #expect(!state.showsComment)
        #expect(!state.canEditCommentNow)
    }

    /// A writable ZIP comment shows, editable, with no note; one Kernir can't write back shows read-only with
    /// the general note, and typing into it changes nothing.
    @Test func commentFieldEditableOnlyForAWritableComment() async throws {
        let (writable, _) = try await openCommented()
        #expect(writable.showsComment)
        #expect(writable.canEditCommentNow)
        #expect(writable.commentReadOnlyNote == nil)
        await writable.document.closeOnMain()

        let (readOnly, _) = try await openCommented(Self.comment(isWritable: false))
        #expect(readOnly.showsComment)
        #expect(!readOnly.canEditCommentNow)
        #expect(readOnly.commentReadOnlyNote == "This comment can’t be changed in Lutik.")
        readOnly.setComment("Changed")
        #expect(readOnly.model?.commentText == Self.sourceText)
        #expect(!readOnly.hasChanges)
        await readOnly.document.closeOnMain()
    }

    /// A ZIP without a comment can get one: the field shows, empty and editable.
    @Test func zipWithoutCommentOffersAnEmptyField() async throws {
        let (state, _) = try await openCommented(nil)
        #expect(state.showsComment)
        #expect(state.canEditCommentNow)
        #expect(state.model?.commentText == "")
        await state.document.closeOnMain()
    }

    /// Typing marks the document changed, as one "Edit Comment" step on the document's undo manager: one
    /// Undo after the sheet closes takes all of it back, and the document has nothing left to save.
    @Test func commentTypingIsOneUndoStepOfTheDocument() async throws {
        let (state, _) = try await openCommented()
        let model = try #require(state.model)
        let document = state.document
        #expect(!state.hasChanges)

        state.showInfo()
        state.setComment("N")
        try await eventually { state.canUndo }
        #expect(state.canUndo)
        state.setComment("Ne")
        try await Task.sleep(for: .milliseconds(20))
        state.setComment("New")
        #expect(state.hasChanges)
        #expect(model.commentText == "New")
        try await eventually { document.hasUnsavedChanges }
        #expect(document.hasUnsavedChanges)
        #expect(document.undoManager.undoActionName == "Edit Comment")
        state.closeInfo()

        state.undo()
        #expect(model.commentText == Self.sourceText)
        #expect(!state.hasChanges)
        try await eventually { !document.hasUnsavedChanges }
        #expect(!document.hasUnsavedChanges)
        #expect(!document.undoManager.canUndo)
        await document.closeOnMain()
    }

    /// The edited comment goes into the document's own save, all of the typing: the keystrokes after the first
    /// join its undo step without registering any, yet reach the save snapshot. The saved document has no
    /// changes left.
    @Test func commentEditSavesWithTheDocument() async throws {
        let (state, fake) = try await openCommented()
        state.setComment("N")
        try await eventually { state.document.hasUnsavedChanges && state.canUndo }
        #expect(state.document.hasUnsavedChanges)
        #expect(state.canUndo)
        state.setComment("Ne")
        try await Task.sleep(for: .milliseconds(20))
        state.setComment("New")
        #expect(await state.document.commitSave())
        #expect(fake.writeCalls.last?.changes.comment == ArchiveChangeSet.CommentChange.set("New"))
        #expect(fake.writeCalls.last?.format == .zip)
        #expect(!state.hasChanges)
        await state.document.closeOnMain()
    }

    /// A comment the engine would refuse (too long) refuses the save before anything is written, with the
    /// message the Info sheet shows under the field; the edit stays.
    @Test(.timeLimit(.minutes(1))) func tooLongCommentRefusesTheSave() async throws {
        let (state, fake) = try await openCommented()
        let model = try #require(state.model)
        state.setComment(String(repeating: "a", count: ArchiveComment.maximumWritableLength + 1))
        let problem = try #require(model.commentProblem)
        try await eventually { state.document.hasUnsavedChanges }
        #expect(state.document.hasUnsavedChanges)
        #expect(await state.document.commitSave() == false)
        #expect(fake.writeCalls.isEmpty)
        #expect(state.session.saveError == problem)
        #expect(state.document.refusedSaves == 1, "refused before UIKit's save, which iOS 17 never ends")
        #expect(state.hasChanges)
        await state.document.closeOnMain()
    }

    /// Save As Copy writes the edited comment into a ZIP copy and leaves it out of a format without comments,
    /// where the engine would refuse it.
    @Test func saveAsCopyTakesTheCommentWhereTheFormatHasOne() async throws {
        let (state, fake) = try await openCommented()
        state.setComment("New")
        for format in [ArchiveFormat.zip, .sevenZip] {
            var settings = ArchiveSaveSettings(format: format, options: ArchiveWriteOptions())
            settings.formatDidChange()
            let copy = try await state.saveAsCopy(settings)
            try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
            let write = try #require(fake.writeCalls.last)
            #expect(write.format == format)
            let expected: ArchiveChangeSet.CommentChange = format == .zip ? .set("New") : .keep
            #expect(write.changes.comment == expected, "\(format)")
        }
        #expect(state.hasChanges, "the open document keeps its edit")
        await state.document.closeOnMain()
    }

    /// While a save writes the archive Info can't open and the comment field takes no typing: the save adopts
    /// the saved archive when it ends, which would drop text typed meanwhile.
    @Test func infoAndCommentOffWhileSaving() async throws {
        let (state, _) = try await openCommented(writeDelay: .milliseconds(500))
        let model = try #require(state.model)
        state.setComment("New")
        try await eventually { state.document.hasUnsavedChanges }
        #expect(state.document.hasUnsavedChanges)
        let document = state.document
        let save = Task { @MainActor in await document.commitSave() }
        try await eventually { state.isSaving }
        #expect(state.isSaving)
        #expect(!state.canShowInfo)
        #expect(!state.canEditCommentNow)
        state.setComment("Lost")
        #expect(model.commentText == "New")
        #expect(await save.value)
        #expect(state.canShowInfo)
        #expect(state.canEditCommentNow)
        await document.closeOnMain()
    }

    /// The live engine: an edited comment is in the file the document saves.
    @Test func editedCommentIsInTheSavedFile() async throws {
        ArchiveDocument.engine = .live
        let document = ArchiveDocument(fileURL: try Fixture.copy("zip/comment-utf8.zip"))
        #expect(await document.openOnMain())
        let state = ScreenState(document: document)
        let model = try #require(state.model)
        #expect(state.showsComment)
        #expect(model.commentText.hasPrefix("Привет из Kernir"))

        state.setComment("Edited on iOS\n")
        try await eventually { document.hasUnsavedChanges }
        #expect(document.hasUnsavedChanges)
        #expect(await document.commitSave())
        #expect(state.session.saveError == nil)
        #expect(!state.hasChanges)
        #expect(state.model?.commentText == "Edited on iOS\n")
        let saved = try await Archive.open(at: document.fileURL)
        #expect(saved.comment?.text == "Edited on iOS\n")
        await document.closeOnMain()
    }

    // MARK: - A comment Kernir won't write

    /// Closing (the back chevron, ⌘W, the window) saves the other edits of a document whose comment Kernir won't
    /// write: UIDocument closes whatever its save does, so a refused save would lose them all. The
    /// comment stays as the file has it.
    @Test func closeWithAnUnwritableCommentSavesTheOtherEdits() async throws {
        ArchiveDocument.engine = .live
        let document = ArchiveDocument(fileURL: try Fixture.copy("zip/comment-utf8.zip"))
        #expect(await document.openOnMain())
        let state = ScreenState(document: document)
        let model = try #require(state.model)
        let file = try fileToAdd()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.add([file], to: "")
        state.setComment(Self.tooLongComment)
        #expect(model.commentProblem != nil)
        try await eventually { document.hasUnsavedChanges }
        #expect(document.hasUnsavedChanges)
        #expect(await document.closeOnMain())

        let saved = try await Archive.open(at: document.fileURL)
        #expect(saved.entries.contains { $0.path == "added.txt" })
        #expect(saved.comment?.text.hasPrefix("Привет из Kernir") == true)
    }

    /// The Save button still refuses the comment, other edits or not; going to the background saves like a
    /// close: the other edits written, the comment kept as the file has it.
    @Test func backgroundSaveWithAnUnwritableCommentWritesTheOtherEdits() async throws {
        let (state, fake) = try await openCommented()
        let model = try #require(state.model)
        let document = state.document
        let file = try fileToAdd()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        model.add([file], to: "")
        state.setComment(Self.tooLongComment)
        try await eventually { document.hasUnsavedChanges }
        #expect(document.hasUnsavedChanges)
        #expect(await document.commitSave() == false)
        #expect(fake.writeCalls.isEmpty)

        document.saveForBackground()
        try await eventually { !fake.writeCalls.isEmpty && !document.hasUnsavedChanges && state.session.saveFraction == nil }
        let write = try #require(fake.writeCalls.last)
        #expect(fake.writeCalls.count == 1)
        #expect(write.changes.comment == ArchiveChangeSet.CommentChange.keep)
        #expect(write.changes.additions.count == 1)
        #expect(!document.hasUnsavedChanges)
        await document.closeOnMain()
        #expect(fake.writeCalls.count == 1)
    }

    /// Nothing but that comment to save: closing writes nothing rather than the archive as it is.
    @Test(.timeLimit(.minutes(1))) func closeWithOnlyAnUnwritableCommentWritesNothing() async throws {
        let (state, fake) = try await openCommented()
        state.setComment(Self.tooLongComment)
        try await eventually { state.document.hasUnsavedChanges }
        #expect(state.document.hasUnsavedChanges)
        #expect(await state.document.closeOnMain() == false)
        #expect(fake.writeCalls.isEmpty)
        #expect(state.document.refusedSaves == 1, "the close's save goes through the override")
    }

    /// Nothing but that comment to save: going to the background writes nothing either. The file is as it was,
    /// the edit stays (`hasUnsavedChanges`), and `saveError` carries the Info sheet's message for the return.
    @Test(.timeLimit(.minutes(1))) func backgroundSaveWithOnlyAnUnwritableCommentWritesNothing() async throws {
        let (state, fake) = try await openCommented()
        let model = try #require(state.model)
        let document = state.document
        let before = try Data(contentsOf: document.fileURL)
        state.setComment(Self.tooLongComment)
        let problem = try #require(model.commentProblem)
        try await eventually { document.hasUnsavedChanges }
        #expect(document.hasUnsavedChanges)

        document.saveForBackground()
        try await eventually { state.session.saveError != nil && state.session.saveFraction == nil }
        #expect(state.session.saveError == problem)
        #expect(document.refusedSaves == 1, "refused before UIKit's save, which iOS 17 never ends")
        #expect(fake.writeCalls.isEmpty)
        #expect(try Data(contentsOf: document.fileURL) == before)
        #expect(document.hasUnsavedChanges)
        #expect(await document.closeOnMain() == false)
        #expect(fake.writeCalls.isEmpty)
        #expect(document.refusedSaves == 2, "the close's save of the kept edit is refused too")
    }

    /// Save As Copy to a ZIP refuses that comment before anything is written, with the Info sheet's message; a
    /// format without comments leaves it out and writes.
    @Test func saveAsCopyRefusesAnUnwritableCommentInAZIP() async throws {
        let (state, fake) = try await openCommented()
        let model = try #require(state.model)
        state.setComment(Self.tooLongComment)
        let problem = try #require(model.commentProblem)
        var zip = ArchiveSaveSettings(format: .zip, options: ArchiveWriteOptions())
        zip.formatDidChange()
        let error = await #expect(throws: CommentSaveError.self) { _ = try await state.saveAsCopy(zip) }
        #expect(error?.message == problem)
        #expect(fake.writeCalls.isEmpty)

        var sevenZip = ArchiveSaveSettings(format: .sevenZip, options: ArchiveWriteOptions())
        sevenZip.formatDidChange()
        let copy = try await state.saveAsCopy(sevenZip)
        try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
        #expect(fake.writeCalls.last?.changes.comment == ArchiveChangeSet.CommentChange.keep)
        #expect(state.hasChanges)
        await state.document.closeOnMain()
    }

    /// A split copy writes no comment change, as on the Mac: a removed comment is what the split writer's
    /// `.keep` writes anyway; a typed one refuses the copy (`ArchiveModel.splitSaveProblem`).
    @Test func splitCopyWritesNoCommentChange() async throws {
        let (state, fake) = try await openCommented()
        var options = ArchiveWriteOptions()
        options.volumeSize = 1_000_000
        let split = ArchiveSaveSettings(format: .zip, options: options)

        state.setComment("")
        #expect(state.model?.changes.comment == ArchiveChangeSet.CommentChange.remove)
        let copy = try await state.saveAsCopy(split)
        try? FileManager.default.removeItem(at: copy.deletingLastPathComponent())
        #expect(fake.writeCalls.last?.changes.comment == ArchiveChangeSet.CommentChange.keep)

        state.setComment("New")
        await #expect(throws: CommentSaveError.self) { _ = try await state.saveAsCopy(split) }
        #expect(fake.writeCalls.count == 1)
        await state.document.closeOnMain()
    }

    /// While Text Encoding reads the archive again Info can't open and the comment takes no typing: the reopen
    /// adopts a new listing, as a save does.
    @Test func infoAndCommentOffWhileTextEncodingReadsAgain() async throws {
        let (state, fake) = try await openCommented(legacyNameEncoding: .windowsCP1251)
        let model = try #require(state.model)
        #expect(state.canChooseNameEncoding)
        #expect(state.canShowInfo)
        #expect(state.canEditCommentNow)

        let gate = OpenGate()
        fake.gate = gate
        state.chooseNameEncoding(.specific(.isoLatin1))
        let task = try #require(state.nameEncodingTask)
        #expect(!state.canShowInfo)
        state.showInfo()
        #expect(!state.isShowingInfo)
        #expect(state.showsComment)
        #expect(!state.canEditCommentNow)
        state.setComment("Lost")
        #expect(model.commentText == Self.sourceText)
        #expect(!state.hasChanges)

        state.cancelNameEncoding()
        gate.open()
        await task.value
        #expect(state.nameEncodingTask == nil)
        #expect(state.canShowInfo)
        #expect(state.canEditCommentNow)
        await state.document.closeOnMain()
    }
}
