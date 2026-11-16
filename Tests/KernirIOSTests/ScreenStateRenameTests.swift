import Foundation
import os
import Testing
import UIKit
import KernirCore
@testable import Kernir

/// Rename and New Folder on iOS: the name alert's request, the commit through
/// `ArchiveModel.rename`, the gates (`allowsEditing`), undo, and File > New Folder / Rename.
/// In `ScreenStateTests` for its `.serialized`: `ArchiveDocument.engine` is a process-wide test seam.
extension ScreenStateTests {
    /// Opens a copy of a ZIP fixture with a fake engine listing the sample entries (`format` as given).
    private func openForRename(format: ArchiveFormat = .zip,
                               legacyNameEncoding: String.Encoding? = nil) async throws -> (ScreenState, FakeEngine) {
        let url = try Fixture.copy("zip/deflate.zip")
        let fake = FakeEngine(reader: { url in
            FakeReader(entries: SampleArchive().entries, format: format, url: url,
                       legacyNameEncoding: legacyNameEncoding)
        })
        ArchiveDocument.engine = fake.engine
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        #expect(document.session.model != nil)
        return (ScreenState(document: document), fake)
    }

    /// Waits up to 5 s for `condition`: the undo manager reports an edit when its group closes, at the end
    /// of the run loop turn.
    private func eventuallyAfterRename(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func renameUpdatesListAndSelection() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)
        state.isSelecting = true
        state.selection = ["src", "README.md"]

        state.beginRename("src")
        let request = try #require(state.renameRequest)
        #expect(request.path == "src")
        #expect(request.name == "src")
        #expect(request.text == "src")
        #expect(!request.isNewFolder)

        state.commitRename("Sources")
        #expect(state.renameRequest == nil)
        #expect(state.alert == nil)
        #expect(model.item(at: "src") == nil)
        #expect(model.item(at: "Sources")?.isDirectory == true)
        #expect(model.item(at: "Sources/main.swift") != nil)
        #expect(model.children(of: "").map(\.name).contains("Sources"))
        #expect(state.selection == ["Sources", "README.md"])
        #expect(state.hasChanges)
        await state.document.closeOnMain()
    }

    /// A refused name says why (`EntryNameValidation.message`) and changes nothing; the name alert comes back
    /// after that alert with the name as typed (as Finder keeps editing). The same name is no edit.
    @Test func renameRefusedNameShowsAlert() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)

        state.beginRename("README.md")
        #expect(state.renameCheck("") == .invalid(.empty))
        #expect(state.renameCheck("brief.pdf") == .invalid(.taken("brief.pdf")))
        #expect(state.renameCheck("README.md") == .unchanged)
        #expect(state.renameCheck("Notes.md") == .valid("Notes.md"))
        let id = try #require(state.renameRequest?.id)
        state.commitRename("brief.pdf")
        let alert = try #require(state.alert)
        #expect(alert.message == EntryNameValidation.message(for: .taken("brief.pdf")))
        #expect(model.item(at: "README.md") != nil)
        #expect(!state.hasChanges)
        #expect(state.renameRequest?.id == id)
        #expect(state.renameRequest?.path == "README.md")
        #expect(state.renameRequest?.text == "brief.pdf")
        #expect(!state.canShowRename)
        state.dismissAlert()
        #expect(state.canShowRename)

        state.commitRename("a/b")
        #expect(state.alert?.message == EntryNameValidation.message(for: .containsSlash))
        #expect(state.renameRequest?.text == "a/b")
        state.dismissAlert()

        // Unchanged: no edit, no undo step, no alert.
        state.commitRename("README.md")
        #expect(state.renameRequest == nil)
        #expect(state.alert == nil)
        #expect(!state.hasChanges)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!state.document.undoManager.canUndo)
        await state.document.closeOnMain()
    }

    /// New Folder adds "untitled folder" in the folder on screen and asks for its name; Cancel keeps it
    /// (as Files does). A second one is "untitled folder 2".
    @Test func newFolderThenCancelKeepsFolder() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)

        state.newFolder(in: "src")
        let request = try #require(state.renameRequest)
        #expect(request.path == "src/untitled folder")
        #expect(request.name == "untitled folder")
        #expect(request.isNewFolder)
        #expect(model.item(at: "src/untitled folder")?.isDirectory == true)
        state.cancelRename()
        #expect(state.renameRequest == nil)
        #expect(model.item(at: "src/untitled folder")?.isDirectory == true)

        state.newFolder(in: "src")
        #expect(state.renameRequest?.path == "src/untitled folder 2")
        state.commitRename("Docs")
        #expect(model.item(at: "src/Docs")?.isDirectory == true)
        #expect(model.item(at: "src/untitled folder 2") == nil)
        #expect(model.item(at: "src/untitled folder") != nil)
        await state.document.closeOnMain()
    }

    /// Rename and New Folder only while `allowsEditing`: not on a read-only archive, not while a save
    /// writes (a commit then says why), not while Text Encoding reads the archive again.
    @Test func noRenameOnReadOnlyOrWhileSaving() async throws {
        let (rar, _) = try await openForRename(format: .rar)
        let rarModel = try #require(rar.model)
        rar.beginRename("README.md")
        #expect(rar.renameRequest == nil)
        rar.newFolder(in: "")
        #expect(rar.renameRequest == nil)
        #expect(rarModel.item(at: "untitled folder") == nil)
        await rar.document.closeOnMain()

        let (state, _) = try await openForRename()
        let model = try #require(state.model)
        state.session.saveFraction = 0.5
        state.beginRename("README.md")
        #expect(state.renameRequest == nil)
        state.newFolder(in: "")
        #expect(state.renameRequest == nil)
        #expect(model.item(at: "untitled folder") == nil)
        state.session.saveFraction = nil

        // A save starts while the name alert is up: nothing is renamed, and the user is told.
        state.beginRename("README.md")
        #expect(state.renameRequest != nil)
        state.session.saveFraction = 0.5
        state.commitRename("Notes.md")
        #expect(state.renameRequest == nil)
        #expect(model.item(at: "README.md") != nil)
        #expect(model.item(at: "Notes.md") == nil)
        #expect(state.alert?.message == state.busyMessage)
        state.session.saveFraction = nil
        state.dismissAlert()
        await state.document.closeOnMain()

        let (encoded, fake) = try await openForRename(legacyNameEncoding: .windowsCP1251)
        let encodedModel = try #require(encoded.model)
        let gate = OpenGate()
        fake.gate = gate
        encoded.chooseNameEncoding(.specific(.isoLatin1))
        let task = try #require(encoded.nameEncodingTask)
        encoded.beginRename("README.md")
        #expect(encoded.renameRequest == nil)
        encoded.newFolder(in: "")
        #expect(encoded.renameRequest == nil)
        #expect(encodedModel.item(at: "untitled folder") == nil)
        encoded.cancelNameEncoding()
        gate.open()
        await task.value
        #expect(encoded.nameEncodingTask == nil)

        // No Text Encoding under the name alert: it would replace the listing the alert names.
        encoded.beginRename("README.md")
        #expect(encoded.renameRequest != nil)
        #expect(!encoded.canChooseNameEncoding)
        encoded.cancelRename()
        #expect(encoded.canChooseNameEncoding)
        await encoded.document.closeOnMain()
    }

    /// Rename is one undo step "Rename"; New Folder and then its name are two.
    @Test func undoRename() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)
        let document = state.document

        state.beginRename("README.md")
        state.commitRename("Notes.md")
        try await eventuallyAfterRename { state.canUndo }
        #expect(document.undoManager.undoActionName == "Rename")
        state.undo()
        #expect(model.item(at: "README.md") != nil)
        #expect(model.item(at: "Notes.md") == nil)
        #expect(!state.hasChanges)

        state.newFolder(in: "")
        try await eventuallyAfterRename { state.canUndo }
        #expect(document.undoManager.undoActionName == "New Folder")
        state.commitRename("Folder")
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.item(at: "Folder") != nil)
        state.undo()
        #expect(model.item(at: "untitled folder") != nil)
        #expect(model.item(at: "Folder") == nil)
        try await Task.sleep(for: .milliseconds(20))
        state.undo()
        #expect(model.item(at: "untitled folder") == nil)
        #expect(!state.hasChanges)
        await document.closeOnMain()
    }

    /// The name alert's text field finds its undo manager up the responder chain (alert, presenting level,
    /// navigation, document view controller). While the alert is up every level hands out the rename's own
    /// (`renameUndoManager`, new for each rename), as the Mac's name field has: the "Typing" steps never
    /// enable Undo, mark the document changed or mix with the model's steps, and the document's undo
    /// manager keeps registering (New Folder's step under the alert, the rename's on Save).
    @Test func nameAlertTypingRegistersNoUndo() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)
        let document = state.document
        let undoManager = try #require(document.undoManager)
        let level = FolderHostingController(state: state, path: "src")
        let navigation = ArchiveNavigationController(rootViewController: UIViewController())
        navigation.screenState = state
        let root = ArchiveDocumentViewController(document: nil)
        root.screenState = state
        /// What the field's typing does: a step on the undo manager its responder chain reaches.
        func type() { level.undoManager?.registerUndo(withTarget: model) { _ in } }
        #expect(state.renameUndoManager == nil)
        #expect(level.undoManager === undoManager)

        // Cancel: no step, no change; the rename's undo manager goes with the request.
        state.beginRename("README.md")
        let renaming = try #require(state.renameUndoManager)
        #expect(renaming !== undoManager)
        #expect(level.undoManager === renaming)
        #expect(navigation.undoManager === renaming)
        #expect(root.undoManager === renaming)
        #expect(undoManager.isUndoRegistrationEnabled)
        type()
        #expect(renaming.canUndo)
        state.cancelRename()
        #expect(state.renameUndoManager == nil)
        #expect(level.undoManager === undoManager)
        #expect(navigation.undoManager !== renaming)
        #expect(root.undoManager !== renaming)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!undoManager.canUndo)
        #expect(!state.canUndo)
        #expect(!document.hasUnsavedChanges)

        // Each rename has a new one; a refused name keeps the alert and its typing apart. Save then
        // registers "Rename" alone on the document's.
        state.beginRename("README.md")
        #expect(state.renameUndoManager !== renaming)
        type()
        state.commitRename("brief.pdf")
        #expect(state.renameRequest != nil)
        #expect(level.undoManager !== undoManager)
        state.dismissAlert()
        type()
        state.commitRename("Notes.md")
        #expect(state.renameUndoManager == nil)
        try await eventuallyAfterRename { state.canUndo }
        #expect(undoManager.undoActionName == "Rename")
        state.undo()
        #expect(model.item(at: "README.md") != nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!undoManager.canUndo)

        // New Folder: its step on the document's, the alert's typing on the rename's.
        state.newFolder(in: "")
        #expect(state.renameRequest?.isNewFolder == true)
        type()
        state.cancelRename()
        try await eventuallyAfterRename { state.canUndo }
        #expect(undoManager.undoActionName == "New Folder")
        state.undo()
        try await Task.sleep(for: .milliseconds(20))
        #expect(!undoManager.canUndo)

        // A commit refused as busy, or dropped as stale, drops the rename's undo manager too.
        state.beginRename("README.md")
        state.session.saveFraction = 0.5
        state.commitRename("Notes.md")
        state.session.saveFraction = nil
        #expect(state.renameUndoManager == nil)
        state.dismissAlert()
        state.beginRename("brief.pdf")
        model.remove(["brief.pdf"])
        state.commitRename("Brief 2.pdf")
        #expect(state.renameRequest == nil)
        #expect(state.renameUndoManager == nil)
        #expect(level.undoManager === undoManager)
        await document.closeOnMain()
    }

    /// While the name alert is up, ⌘Z and ⇧⌘Z are not the navigation controller's: they go on up the
    /// responder chain (to `UIWindow`), which undoes the field's typing through the rename's own undo
    /// manager. The document's steps (New Folder's here) stay. Once the alert has gone they are ours again.
    @Test func undoCommandsPassOnWhileRenaming() async throws {
        let (state, _) = try await openForRename()
        let navigation = ArchiveNavigationController(rootViewController: UIViewController())
        navigation.screenState = state
        let host = UndoCommandCatcher()
        host.addChild(navigation)
        host.view.addSubview(navigation.view)
        navigation.didMove(toParent: host)
        let undo = #selector(ArchiveNavigationController.undo(_:))
        let redo = #selector(ArchiveNavigationController.redo(_:))

        state.newFolder(in: "")
        try await eventuallyAfterRename { state.canUndo }
        #expect(state.canUndo)
        #expect(state.renameUndoManager != nil)
        #expect(!navigation.canPerformAction(undo, withSender: nil))
        #expect(!navigation.canPerformAction(redo, withSender: nil))
        #expect((navigation.target(forAction: undo, withSender: nil) as AnyObject?) === host)
        #expect((navigation.target(forAction: redo, withSender: nil) as AnyObject?) === host)

        state.cancelRename()
        #expect(navigation.canPerformAction(undo, withSender: nil))
        #expect((navigation.target(forAction: undo, withSender: nil) as AnyObject?) === navigation)
        #expect(navigation.target(forAction: redo, withSender: nil) == nil)
        await state.document.closeOnMain()
    }

    /// Undo or redo can take away the folder a level shows (a rename undone, a delete redone): the levels
    /// the archive no longer lists close (`closeUnlistedFolders`), as after Text Encoding.
    @Test func undoClosesTheLevelOfAVanishedFolder() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)
        var closings = 0
        state.closeUnlistedFolders = { closings += 1 }
        let root = UIViewController()

        state.beginRename("src")
        state.commitRename("Sources")
        try await eventuallyAfterRename { state.canUndo }
        let sources = FolderHostingController(state: state, path: "Sources")
        #expect(FolderHostingController.listedLevels([root, sources], in: model) == [root, sources])
        #expect(closings == 0)

        state.undo()
        try await eventuallyAfterRename { closings == 1 }
        #expect(closings == 1)
        #expect(FolderHostingController.listedLevels([root, sources], in: model) == [root])

        try await eventuallyAfterRename { state.canRedo }
        let src = FolderHostingController(state: state, path: "src")
        state.redo()
        try await eventuallyAfterRename { closings == 2 }
        #expect(closings == 2)
        #expect(FolderHostingController.listedLevels([root, src], in: model) == [root])
        await state.document.closeOnMain()
    }

    /// A late commit for an item that has gone, or for a listing replaced meanwhile (Text Encoding's reopen,
    /// a revert), changes nothing and says nothing.
    @Test func commitForAMissingPathIsSilent() async throws {
        let (state, _) = try await openForRename(legacyNameEncoding: .windowsCP1251)
        let model = try #require(state.model)

        state.beginRename("README.md")
        model.remove(["README.md"])
        state.commitRename("Notes.md")
        #expect(state.renameRequest == nil)
        #expect(state.alert == nil)
        #expect(model.item(at: "Notes.md") == nil)
        await state.document.closeOnMain()

        let (fresh, _) = try await openForRename(legacyNameEncoding: .windowsCP1251)
        let freshModel = try #require(fresh.model)
        fresh.beginRename("brief.pdf")
        #expect(fresh.renameRequest != nil)
        try await fresh.document.reopen(nameEncoding: .specific(.isoLatin1))
        #expect(freshModel.item(at: "brief.pdf") != nil)
        fresh.commitRename("Brief 2.pdf")
        #expect(fresh.renameRequest == nil)
        #expect(fresh.alert == nil)
        #expect(freshModel.item(at: "Brief 2.pdf") == nil)
        #expect(!fresh.hasChanges)
        await fresh.document.closeOnMain()
    }

    /// File > New Folder (⇧⌘N) in the folder on screen; File > Rename on the one selected item, validated
    /// as Delete is: in Select mode, with edits allowed.
    @Test func newFolderAndRenameCommands() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)
        let navigation = ArchiveNavigationController(rootViewController: UIViewController())
        navigation.screenState = state
        let newFolder = #selector(ArchiveNavigationController.newFolder(_:))
        let rename = #selector(ArchiveNavigationController.renameItem(_:))

        #expect(navigation.canPerformAction(newFolder, withSender: nil))
        #expect(!navigation.canPerformAction(rename, withSender: nil))
        state.isSelecting = true
        state.selection = ["README.md"]
        #expect(navigation.canPerformAction(rename, withSender: nil))
        state.selection = ["README.md", "brief.pdf"]
        #expect(!navigation.canPerformAction(rename, withSender: nil))
        state.selection = ["README.md"]
        navigation.renameItem(nil)
        #expect(state.renameRequest?.path == "README.md")
        state.cancelRename()

        navigation.newFolder(nil)
        #expect(state.renameRequest?.path == "untitled folder")
        #expect(model.item(at: "untitled folder") != nil)
        state.cancelRename()

        state.session.saveFraction = 0.5
        #expect(!navigation.canPerformAction(newFolder, withSender: nil))
        #expect(!navigation.canPerformAction(rename, withSender: nil))
        state.session.saveFraction = nil

        #expect(Key(ArchiveCommands.newFolder) == Key("n", [.command, .shift]))
        #expect(ArchiveCommands.newFolder.title == "New Folder")
        #expect(ArchiveCommands.rename.title == "Rename")
        #expect(ArchiveCommands.all.contains { $0.action == newFolder })

        let none = ArchiveNavigationController(rootViewController: UIViewController())
        #expect(!none.canPerformAction(newFolder, withSender: nil))
        #expect(!none.canPerformAction(rename, withSender: nil))
        await state.document.closeOnMain()
    }

    /// New Folder under a search that hides "untitled folder" clears the search: after Cancel the folder
    /// is listed; a search it matches stays.
    @Test func newFolderUnderASearchClearsIt() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)
        state.searchText = "main"
        state.newFolder(in: "src")
        #expect(state.renameRequest?.path == "src/untitled folder")
        #expect(state.searchText.isEmpty)
        state.cancelRename()
        #expect(model.children(of: "src", matching: state.searchText).map(\.name).contains("untitled folder"))

        state.searchText = "untitled"
        state.newFolder(in: "")
        #expect(state.renameRequest?.path == "untitled folder")
        #expect(state.searchText == "untitled")
        state.cancelRename()
        await state.document.closeOnMain()
    }

    /// Undo and redo keep only the selected rows still listed.
    @Test func undoPrunesTheSelection() async throws {
        let (state, _) = try await openForRename()
        state.beginRename("README.md")
        state.commitRename("Notes.md")
        try await eventuallyAfterRename { state.canUndo }
        state.isSelecting = true
        state.selection = ["Notes.md", "src"]
        state.undo()
        try await eventuallyAfterRename { state.selection == ["src"] }
        #expect(state.selection == ["src"])
        #expect(state.isSelecting)
        await state.document.closeOnMain()
    }

    /// Undo taking the last selected row away ends Select mode, as Delete does.
    @Test func undoOfTheLastSelectedRowEndsSelectMode() async throws {
        let (state, _) = try await openForRename()
        state.beginRename("README.md")
        state.commitRename("Notes.md")
        try await eventuallyAfterRename { state.canUndo }
        state.isSelecting = true
        state.selection = ["Notes.md"]
        state.undo()
        try await eventuallyAfterRename { !state.isSelecting }
        #expect(state.selection.isEmpty)
        #expect(!state.isSelecting)
        await state.document.closeOnMain()
    }

    /// Undo and redo drop the share sheet of a row they take away.
    @Test func undoAndRedoDropSharesOfRemovedRows() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)
        state.beginRename("README.md")
        state.commitRename("Notes.md")
        try await eventuallyAfterRename { state.canUndo }

        state.shareRequest = ShareRequest(urls: [], anchor: .row("Notes.md"))
        state.undo()
        try await eventuallyAfterRename { state.shareRequest == nil }
        #expect(model.item(at: "README.md") != nil)
        #expect(state.shareRequest == nil)

        try await eventuallyAfterRename { state.canRedo }
        state.shareRequest = ShareRequest(urls: [], anchor: .row("README.md"))
        state.redo()
        try await eventuallyAfterRename { state.shareRequest == nil }
        #expect(model.item(at: "Notes.md") != nil)
        #expect(state.shareRequest == nil)
        await state.document.closeOnMain()
    }

    /// On a pushed level (a subfolder on screen, not the root), File > New Folder adds in that folder and
    /// File > Rename renames the item selected there: names are checked against that folder's items, the
    /// renamed item stays in it, the selection follows.
    @Test func renameAndNewFolderOnAPushedLevel() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)
        let navigation = ArchiveNavigationController(rootViewController: UIViewController())
        navigation.screenState = state
        navigation.pushViewController(FolderHostingController(state: state, path: "src"), animated: false)
        #expect(navigation.currentPath == "src")

        navigation.newFolder(nil)
        let request = try #require(state.renameRequest)
        #expect(request.path == "src/untitled folder")
        #expect(request.isNewFolder)
        #expect(model.item(at: "untitled folder") == nil)
        #expect(state.renameCheck("utils.swift") == .invalid(.taken("utils.swift")))
        #expect(state.renameCheck("README.md") == .valid("README.md"))
        state.commitRename("Docs")
        #expect(model.item(at: "src/Docs")?.isDirectory == true)
        #expect(model.item(at: "Docs") == nil)
        #expect(model.children(of: "src").map(\.name).contains("Docs"))
        try await Task.sleep(for: .milliseconds(20))

        state.isSelecting = true
        state.selection = ["src/main.swift"]
        navigation.renameItem(nil)
        #expect(state.renameRequest?.path == "src/main.swift")
        #expect(state.renameRequest?.name == "main.swift")
        #expect(state.renameRequest?.isNewFolder == false)
        state.commitRename("app.swift")
        #expect(state.alert == nil)
        #expect(model.item(at: "src/main.swift") == nil)
        #expect(model.item(at: "src/app.swift") != nil)
        #expect(model.item(at: "app.swift") == nil)
        #expect(state.selection == ["src/app.swift"])
        // Each step closes its own undo group at the end of the run loop turn (as in `undoRename`).
        try await Task.sleep(for: .milliseconds(20))
        try await eventuallyAfterRename { state.canUndo }
        #expect(state.document.undoManager.undoActionName == "Rename")
        state.undo()
        #expect(model.item(at: "src/main.swift") != nil)
        #expect(model.item(at: "src/app.swift") == nil)
        #expect(model.item(at: "src/Docs") != nil)
        await state.document.closeOnMain()
    }

    /// The name alert waits while a progress sheet is asked for or still going away (`canShowRename`), as
    /// the other alerts do: published then it would be dropped. Its request, typed text and undo manager
    /// stay meanwhile; once the sheet has gone (observed) the alert comes back and Save works. New Folder's
    /// alert asked for under an operation's sheet waits the same way.
    @Test func nameAlertWaitsForTheProgressSheet() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)
        state.beginRename("README.md")
        state.renameRequest?.text = "Notes.md"
        let id = try #require(state.renameRequest?.id)
        let renaming = try #require(state.renameUndoManager)
        #expect(state.canShowRename)

        state.session.saveFraction = 0
        state.progressSheetDidAppear()
        #expect(!state.canShowRename, "the save's sheet is up")
        state.session.saveFraction = nil
        #expect(!state.canShowRename, "the sheet is still going away")
        #expect(state.renameRequest?.id == id)
        #expect(state.renameRequest?.text == "Notes.md")
        #expect(state.renameUndoManager === renaming)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = state.canShowRename
        } onChange: {
            changed.withLock { $0 = true }
        }
        state.progressSheetDidDismiss()
        #expect(changed.withLock { $0 }, "the sheet's going is observed")
        #expect(state.canShowRename)
        #expect(state.renameRequest?.id == id)
        let text = try #require(state.renameRequest?.text)
        state.commitRename(text)
        #expect(model.item(at: "Notes.md") != nil)
        #expect(model.item(at: "README.md") == nil)
        #expect(state.renameRequest == nil)

        // New Folder while another operation's sheet is asked for: the folder is added, its name alert waits.
        state.progress = OperationProgress(title: "Sharing…")
        state.newFolder(in: "")
        #expect(state.renameRequest?.path == "untitled folder")
        #expect(!state.canShowRename, "the operation's sheet is asked for")
        state.progressSheetDidAppear()
        state.progress = nil
        #expect(!state.canShowRename, "the sheet is still going away")
        state.progressSheetDidDismiss()
        #expect(state.canShowRename)
        #expect(state.renameRequest?.isNewFolder == true)
        state.cancelRename()
        #expect(model.item(at: "untitled folder")?.isDirectory == true)
        await state.document.closeOnMain()
    }

    /// New Folder that can't add, here on a pushed level whose folder has gone meanwhile: "Couldn't add the
    /// folder" with the error, no name alert, nothing added and no undo step.
    @Test func newFolderFailureShowsAlert() async throws {
        let (state, _) = try await openForRename()
        let model = try #require(state.model)
        let undoManager = try #require(state.document.undoManager)
        let navigation = ArchiveNavigationController(rootViewController: UIViewController())
        navigation.screenState = state
        navigation.pushViewController(FolderHostingController(state: state, path: "src"), animated: false)
        model.remove(["src"])
        try await eventuallyAfterRename { undoManager.canUndo }
        let undoName = undoManager.undoActionName
        #expect(state.canAdd)

        navigation.newFolder(nil)
        #expect(state.renameRequest == nil)
        #expect(state.renameUndoManager == nil)
        #expect(!state.canShowRename)
        let alert = try #require(state.alert)
        #expect(alert.title == "Couldn't add the folder")
        #expect(alert.message == ArchiveError.entryNotFound("src").localizedDescription)
        #expect(state.canShowAlert)
        #expect(model.item(at: "src") == nil)
        #expect(model.item(at: "untitled folder") == nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(undoManager.undoActionName == undoName)
        state.dismissAlert()
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    private struct Key: Equatable {
        var input: String
        var modifiers: UIKeyModifierFlags.RawValue
        init(_ input: String, _ modifiers: UIKeyModifierFlags) {
            self.input = input
            self.modifiers = modifiers.rawValue
        }
        init(_ command: UIKeyCommand) { self.init(command.input ?? "", command.modifierFlags) }
    }
}

/// Stands for the responder chain above the navigation controller: takes Undo and Redo.
private final class UndoCommandCatcher: UIViewController {
    @objc func undo(_ sender: Any?) {}
    @objc func redo(_ sender: Any?) {}
}
