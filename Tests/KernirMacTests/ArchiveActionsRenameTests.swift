import Testing
import AppKit
@testable import Kernir
import KernirCore

/// Rename (Return, the context menu, File > Rename) and New Folder (⇧⌘N) on the Mac. Both exist where
/// Add does (an editable archive, no save running) and not while View > Text Encoding's reopen runs.
@Suite(.serialized) @MainActor
struct ArchiveActionsRenameTests {
    private static func file(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
    }

    private static func folder(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
    }

    private static let entries = [
        folder("docs"), file("docs/a.txt"), folder("docs/sub"), file("docs/sub/d.txt"), file("README"), file("notes"),
    ]

    /// A document showing `entries` in `format`, with no window, and its actions.
    private func makeActions(format: ArchiveFormat = .zip) throws -> (ArchiveDocument, ArchiveActions) {
        let document = try ArchiveDocument(type: "public.zip-archive")
        document.state.model = ArchiveModel(reader: FakeReader(entries: Self.entries, format: format),
                                            undoManager: document.undoManager)
        let actions = ArchiveActions(document: document)
        document.actions = actions
        return (document, actions)
    }

    @Test func canRenameSingleSelectionOnly() throws {
        let (document, actions) = try makeActions()
        let state = document.state
        #expect(!actions.canRename)
        #expect(actions.canNewFolder)

        state.selection = ["README"]
        #expect(actions.canRename)
        state.selection = ["README", "notes"]
        #expect(!actions.canRename)
        #expect(actions.canRename(["notes"]))
        #expect(!actions.canRename([]))
        #expect(!actions.canRename(["README", "notes"]))
        #expect(!actions.canRename(["missing"]))

        // Two selected rows: Return renames nothing.
        actions.beginRename()
        #expect(state.renamingPath == nil)
        state.selection = ["docs/sub"]
        actions.beginRename()
        #expect(state.renamingPath == "docs/sub")
        actions.cancelRename()
        #expect(state.renamingPath == nil)
        #expect(document.model?.hasChanges == false)
    }

    @Test func notOnRAR() throws {
        let (document, actions) = try makeActions(format: .rar)
        let state = document.state
        state.selection = ["README"]
        #expect(!actions.canRename)
        #expect(!actions.canRename(["README"]))
        #expect(!actions.canNewFolder)

        actions.beginRename()
        #expect(state.renamingPath == nil)
        actions.newFolder()
        #expect(state.renamingPath == nil)
        #expect(state.selection == ["README"])
        #expect(document.model?.item(at: "untitled folder") == nil)
        #expect(document.model?.hasChanges == false)
    }

    @Test func notWhileSaving() throws {
        let (document, actions) = try makeActions()
        let state = document.state
        state.selection = ["README"]
        actions.beginRename()
        #expect(state.renamingPath == "README")

        state.progress = OperationProgress(title: "Saving", fraction: nil)
        #expect(!actions.canRename)
        #expect(!actions.canRename(["notes"]))
        #expect(!actions.canNewFolder)
        // A name typed before the save began waits in its field: the save must not see the model change under it.
        actions.commitRename("greeting")
        #expect(state.renamingPath == "README")
        #expect(document.model?.item(at: "README") != nil)
        actions.beginRename("notes")
        actions.newFolder()
        #expect(state.renamingPath == "README")
        #expect(document.model?.hasChanges == false)
    }

    /// The reopen runs under the progress sheet, which `canAdd` checks; the gate asks for the reopen itself
    /// too, so it holds with the sheet gone.
    @Test func notWhileReopening() async throws {
        let (defaults, suite) = makeTestDefaults("ArchiveActionsRenameTests")
        defer { removeTestDefaults(defaults, suite: suite) }
        let zip = try LegacyZip.write(["Docs/", "Docs/Отчёт.txt"], as: .windowsCP1251)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let document = ArchiveDocument()
        let model = ArchiveModel(reader: try await Archive.open(at: zip, nameEncoding: .automatic),
                                 undoManager: document.undoManager)
        model.nameEncodingStore = ArchiveNameEncodingStore(defaults: defaults)
        document.state.model = model
        let actions = ArchiveActions(document: document)
        document.actions = actions
        document.state.selection = ["Docs"]
        #expect(actions.canRename)
        #expect(actions.canNewFolder)
        // Nor the other way round: no reopen while a name field shows.
        #expect(document.canChooseNameEncoding)
        actions.beginRename()
        #expect(!document.canChooseNameEncoding)
        actions.cancelRename()
        #expect(document.canChooseNameEncoding)

        let cp866 = try #require(MainMenu.textEncodingMenu().items.first {
            !$0.isSeparatorItem && ArchiveDocument.nameEncoding(of: $0) == .specific(.testCP866)
        })
        document.selectNameEncoding(cp866)
        #expect(document.nameEncodingTask != nil)
        #expect(!actions.canRename)
        document.state.progress = nil
        #expect(!actions.canRename)
        #expect(!actions.canRename(["Docs"]))
        #expect(!actions.canNewFolder)
        actions.beginRename("Docs")
        #expect(document.state.renamingPath == nil)
        // A field's late commit during the reopen is dropped.
        actions.commitRename("Reports", of: "Docs")
        #expect(document.model?.hasChanges == false)

        await document.nameEncodingTask?.value
        #expect(document.model?.reader?.nameEncoding == .specific(.testCP866))
        #expect(document.model?.hasChanges == false)
    }

    @Test func commitRenameRemapsSelectionAndExpansion() throws {
        let (document, actions) = try makeActions()
        let state = document.state
        state.selection = ["docs"]
        state.expanded = ["docs", "docs/sub"]

        // The same name: no edit, no undo step.
        actions.beginRename()
        #expect(state.renamingPath == "docs")
        actions.commitRename("docs")
        #expect(state.renamingPath == nil)
        #expect(document.model?.hasChanges == false)
        #expect(document.undoManager?.canUndo == false)

        actions.beginRename()
        actions.commitRename("papers")
        #expect(state.renamingPath == nil)
        #expect(state.selection == ["papers"])
        #expect(state.expanded == ["papers", "papers/sub"])
        let model = try #require(document.model)
        #expect(model.item(at: "papers/sub/d.txt") != nil)
        #expect(model.item(at: "docs") == nil)
    }

    @Test func commitTakenNameKeepsOldName() async throws {
        try await PresentedErrors.collecting { presented in
            let (document, actions) = try makeActions()
            let state = document.state
            state.selection = ["README"]
            actions.beginRename()
            actions.commitRename("notes")

            #expect(state.renamingPath == nil)
            #expect(state.selection == ["README"])
            #expect(document.model?.item(at: "README") != nil)
            #expect(document.model?.hasChanges == false)
            #expect(presented.errors.map(\.localizedDescription)
                == [EntryNameValidation.message(for: .taken("notes"))])
        }
    }

    /// An empty name puts the old one back, with a beep and no alert, as in Finder.
    @Test func commitEmptyNameRevertsSilently() async throws {
        try await PresentedErrors.expectingNone {
            let (document, actions) = try makeActions()
            document.state.selection = ["README"]
            actions.beginRename()
            actions.commitRename("   ")
            #expect(document.state.renamingPath == nil)
            #expect(document.model?.item(at: "README") != nil)
            #expect(document.model?.hasChanges == false)
        }
    }

    @Test func newFolderSelectsAndBeginsRename() throws {
        let (document, actions) = try makeActions()
        defer { document.model?.removeTemporaryFiles() }
        let state = document.state
        actions.newFolder()
        #expect(state.renamingPath == "untitled folder")
        #expect(state.selection == ["untitled folder"])
        #expect(document.model?.item(at: "untitled folder")?.isDirectory == true)
        actions.commitRename("scratch")
        #expect(state.selection == ["scratch"])
        #expect(state.renamingPath == nil)

        // In the one selected folder, which opens to show it.
        state.selection = ["docs"]
        actions.newFolder()
        #expect(state.renamingPath == "docs/untitled folder")
        #expect(state.selection == ["docs/untitled folder"])
        #expect(state.expanded.contains("docs"))
    }

    /// A folder renamed while a new folder inside it waits for its name: the new folder's field follows it.
    @Test func renamingAFolderMovesTheRenameInsideIt() throws {
        let (document, actions) = try makeActions()
        defer { document.model?.removeTemporaryFiles() }
        let state = document.state
        state.selection = ["docs"]
        actions.newFolder()
        #expect(state.renamingPath == "docs/untitled folder")

        actions.commitRename("papers", of: "docs")
        #expect(state.renamingPath == "papers/untitled folder")
        #expect(state.selection == ["papers/untitled folder"])
        #expect(state.expanded.contains("papers"))
    }

    /// While a name field shows, Edit > Undo is the field's own: ⌘Z right after New Folder must not take the
    /// folder away under its field, and typing never lands on the document's undo manager.
    @Test func undoWhileRenamingIsTheFieldsOwn() throws {
        let document = try ArchiveDocument(type: "public.zip-archive")
        document.state.model = ArchiveModel(reader: FakeReader(entries: Self.entries, format: .zip),
                                            undoManager: document.undoManager)
        defer { document.model?.removeTemporaryFiles() }
        let controller = ArchiveWindowController(document: document, windowFrame: nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        let actions = try #require(document.actions)
        #expect(controller.windowWillReturnUndoManager(window) === document.undoManager)

        actions.newFolder()
        let fieldUndo = try #require(controller.windowWillReturnUndoManager(window))
        #expect(fieldUndo !== document.undoManager)
        #expect(fieldUndo === actions.renameUndoManager)
        #expect(!fieldUndo.canUndo)
        actions.commitRename("scratch")
        #expect(controller.windowWillReturnUndoManager(window) === document.undoManager)

        // Each rename has a manager of its own: nothing typed in an earlier field is left to undo.
        actions.beginRename("README")
        let next = try #require(controller.windowWillReturnUndoManager(window))
        #expect(next !== fieldUndo && next !== document.undoManager)
        actions.cancelRename()
        #expect(controller.windowWillReturnUndoManager(window) === document.undoManager)
    }

    /// A field torn down after its item moved commits for a path that is gone: nothing changes, and no alert
    /// (rename docs, then ⇧⌘N in it, then docs commits and the new folder's field goes with it).
    @Test func commitForAMissingPathIsSilent() async throws {
        try await PresentedErrors.expectingNone {
            let (document, actions) = try makeActions()
            defer { document.model?.removeTemporaryFiles() }
            let state = document.state
            state.selection = ["docs"]
            actions.newFolder()
            actions.commitRename("papers", of: "docs")
            #expect(state.renamingPath == "papers/untitled folder")

            // The old field's late commit, for the path it was shown on.
            actions.commitRename("untitled folder", of: "docs/untitled folder")
            actions.commitRename("other", of: "missing")
            #expect(state.renamingPath == "papers/untitled folder")
            let model = try #require(document.model)
            #expect(model.item(at: "papers/untitled folder") != nil)
            #expect(model.item(at: "missing") == nil && model.item(at: "other") == nil)
        }
    }

    /// File > Rename or the context menu on the row already being renamed leaves its field alone: a new
    /// undo manager under the live field would lose the typing's undo.
    @Test func beginRenameOnTheRowBeingRenamedKeepsItsUndoManager() throws {
        let (document, actions) = try makeActions()
        let state = document.state
        actions.beginRename("README")
        let fieldUndo = actions.renameUndoManager
        actions.beginRename("README")
        #expect(actions.renameUndoManager === fieldUndo)
        actions.beginRename()
        #expect(actions.renameUndoManager === fieldUndo)
        #expect(state.renamingPath == "README")
        #expect(state.selection == ["README"])
    }

    /// A row inside closed folders shows once they open: its field is there to end the rename.
    @Test func beginRenameOpensTheFoldersAbove() throws {
        let (document, actions) = try makeActions()
        let state = document.state
        actions.beginRename("docs/sub/d.txt")
        #expect(state.renamingPath == "docs/sub/d.txt")
        #expect(state.expanded == ["docs", "docs/sub"])
        #expect(state.selection == ["docs/sub/d.txt"])
    }

    /// The selection moving off the row being renamed ends its field; the row's own selection
    /// keeps it.
    @Test func selectionLeavingTheRowEndsTheRename() throws {
        let (document, actions) = try makeActions()
        let state = document.state
        actions.beginRename("README")
        actions.selectionDidChange()
        #expect(state.renamingPath == "README")

        state.selection = ["README", "notes"]
        actions.selectionDidChange()
        #expect(state.renamingPath == nil)

        actions.beginRename("notes")
        state.selection = []
        actions.selectionDidChange()
        #expect(state.renamingPath == nil)
        #expect(document.model?.hasChanges == false)
    }

    /// Revert to Saved puts a new listing in: the field's late commit named the old one and changes nothing
    /// in the new one, though it has an item at that path.
    @Test func commitAfterTheListingIsReplacedIsDropped() async throws {
        try await PresentedErrors.expectingNone {
            let (document, actions) = try makeActions()
            let state = document.state
            actions.beginRename("README")
            let reverted = ArchiveModel(reader: FakeReader(entries: Self.entries, format: .zip),
                                        undoManager: document.undoManager)
            state.model = reverted
            actions.commitRename("greeting", of: "README")
            #expect(state.renamingPath == nil)
            #expect(reverted.item(at: "README") != nil)
            #expect(reverted.item(at: "greeting") == nil)
            #expect(!reverted.hasChanges)
        }
    }

    /// A name field on a row the search hides would never show, and the rename would never end: New Folder
    /// (whose "untitled folder" matches no search) and Rename on a hidden row clear the search first, as
    /// Finder does; a row the search shows keeps it.
    @Test func renamingARowTheSearchHidesClearsTheSearch() throws {
        let (document, actions) = try makeActions()
        defer { document.model?.removeTemporaryFiles() }
        let state = document.state

        state.searchText = "docs"
        actions.beginRename("docs/a.txt")
        #expect(state.renamingPath == "docs/a.txt")
        #expect(state.searchText == "docs")
        actions.cancelRename()

        state.searchText = "a.txt"
        actions.beginRename("README")
        #expect(state.renamingPath == "README")
        #expect(state.searchText.isEmpty)
        actions.cancelRename()

        state.searchText = "a.txt"
        state.selection = []
        actions.newFolder()
        #expect(state.renamingPath == "untitled folder")
        #expect(state.searchText.isEmpty)
    }

    /// The search clearing restores the folders open before it, which must keep those above the row being
    /// renamed open: its field shows there.
    @Test func expansionAfterTheSearchKeepsTheRenamedRowShown() {
        #expect(ArchiveWindowView.expansionAfterSearch(restoring: ["notes"], renaming: nil) == ["notes"])
        #expect(ArchiveWindowView.expansionAfterSearch(restoring: ["notes"], renaming: "docs/sub/untitled folder")
            == ["notes", "docs", "docs/sub"])
    }

    /// A commit during a save changes nothing then, and leaves the field showing with its typed name, so
    /// Return commits it once the save is done.
    @Test func commitDuringASaveKeepsTheField() throws {
        let (document, actions) = try makeActions()
        let state = document.state
        actions.beginRename("README")
        state.progress = OperationProgress(title: "Saving", fraction: nil)
        #expect(!actions.commitRename("greeting"))
        #expect(state.renamingPath == "README")
        #expect(document.model?.hasChanges == false)

        state.progress = nil
        #expect(actions.commitRename("greeting"))
        #expect(state.renamingPath == nil)
        #expect(document.model?.item(at: "greeting") != nil)
    }

    /// Undo and redo of a rename move the selection and the open folders with the item, as the rename did.
    @Test func undoAndRedoOfARenameRemapSelectionAndExpansion() throws {
        let (document, actions) = try makeActions()
        let state = document.state
        let undoManager = try #require(document.undoManager)
        state.selection = ["docs"]
        state.expanded = ["docs", "docs/sub"]
        actions.beginRename()
        actions.commitRename("papers")
        #expect(state.selection == ["papers"])

        undoManager.undo()
        #expect(document.model?.item(at: "docs") != nil)
        #expect(state.selection == ["docs"])
        #expect(state.expanded == ["docs", "docs/sub"])

        undoManager.redo()
        #expect(document.model?.item(at: "papers") != nil)
        #expect(state.selection == ["papers"])
        #expect(state.expanded == ["papers", "papers/sub"])
    }

    /// The drag leaves out the row being renamed: its field commits as the drag takes focus, after the drag
    /// took the row's path, and the drop would then ask for a path that is gone.
    @Test func dragLeavesOutTheRowBeingRenamed() throws {
        let (document, actions) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let drop = UUID()
        #expect(actions.dragWriter(for: "README", drop: drop) != nil)
        actions.beginRename("README")
        #expect(actions.dragWriter(for: "README", drop: drop) == nil)
        #expect(actions.dragWriter(for: "notes", drop: drop) != nil)
        actions.cancelRename()
        #expect(actions.dragWriter(for: "README", drop: drop) != nil)

        // A folder being renamed: the rows inside it move with it too; the folder above a renamed row doesn't.
        actions.beginRename("docs/sub")
        #expect(actions.dragWriter(for: "docs/sub", drop: drop) == nil)
        #expect(actions.dragWriter(for: "docs/sub/d.txt", drop: drop) == nil)
        #expect(actions.dragWriter(for: "docs", drop: drop) != nil)
        #expect(actions.dragWriter(for: "docs/a.txt", drop: drop) != nil)
    }

    /// The field can commit before AppKit asks for the drag's writers: the field is gone by then, and the rows
    /// still name the old paths, which no longer exist.
    @Test func dragLeavesOutRowsARenameMovedAway() throws {
        let (document, actions) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let drop = UUID()
        actions.beginRename("docs")
        actions.commitRename("papers")
        #expect(document.state.renamingPath == nil)
        #expect(actions.dragWriter(for: "docs", drop: drop) == nil)
        #expect(actions.dragWriter(for: "docs/a.txt", drop: drop) == nil)
        #expect(actions.dragWriter(for: "papers/a.txt", drop: drop) != nil)
    }

    /// Under a search, a rename, its undo and its redo leave selected only rows the search shows: "a.txt"
    /// renamed "b.txt" while searching "a.txt" leaves the results, and Delete must not remove it unseen.
    @Test func renameUnderASearchKeepsOnlyShownRowsSelected() throws {
        let (document, actions) = try makeActions()
        let state = document.state
        let undoManager = try #require(document.undoManager)
        state.searchText = "a.txt"
        state.selection = ["docs/a.txt"]
        actions.beginRename()
        #expect(state.renamingPath == "docs/a.txt")
        actions.commitRename("b.txt")
        #expect(document.model?.item(at: "docs/b.txt") != nil)
        #expect(state.selection.isEmpty)
        #expect(!actions.canRemoveSelection)

        undoManager.undo()
        #expect(document.model?.item(at: "docs/a.txt") != nil)
        state.selection = ["docs/a.txt"]
        // Redo renames the selected row out of the results again.
        undoManager.redo()
        #expect(document.model?.item(at: "docs/b.txt") != nil)
        #expect(state.selection.isEmpty)

        // Undo does too, under a search the new name matches: its remap runs before the model's undo.
        state.searchText = "b.txt"
        state.selection = ["docs/b.txt"]
        undoManager.undo()
        #expect(document.model?.item(at: "docs/a.txt") != nil)
        #expect(state.selection.isEmpty)
    }

    /// A row the search still shows keeps its selection across the rename, and the folders open before the
    /// search follow the rename too, so a renamed open folder stays open when the search clears.
    @Test func renameUnderASearchRemapsTheFoldersOpenBeforeIt() throws {
        let (document, actions) = try makeActions()
        let state = document.state
        let undoManager = try #require(document.undoManager)
        // As the window does when the search begins: the folders open before it are kept aside.
        state.expandedBeforeSearch = ["docs", "docs/sub"]
        state.searchText = "sub"
        state.expanded = ["docs", "docs/sub"]
        state.selection = ["docs"]
        actions.beginRename()
        actions.commitRename("papers")
        #expect(state.selection == ["papers"])
        #expect(state.expandedBeforeSearch == ["papers", "papers/sub"])
        #expect(ArchiveWindowView.expansionAfterSearch(restoring: try #require(state.expandedBeforeSearch),
                                                       renaming: state.renamingPath) == ["papers", "papers/sub"])

        undoManager.undo()
        #expect(state.selection == ["docs"])
        #expect(state.expandedBeforeSearch == ["docs", "docs/sub"])
        undoManager.redo()
        #expect(state.expandedBeforeSearch == ["papers", "papers/sub"])
    }

    @Test func fileMenuHasNewFolderAndRename() throws {
        let menu = MainMenu.fileMenu()
        let newFolder = try #require(menu.items.first { $0.action == #selector(ArchiveWindowController.newFolder(_:)) })
        #expect(newFolder.keyEquivalent == "n")
        #expect(newFolder.keyEquivalentModifierMask == [.command, .shift])
        let rename = try #require(menu.items.first { $0.action == #selector(ArchiveWindowController.rename(_:)) })
        // Return renames through the table: a menu key equivalent would take Return from the name field.
        #expect(rename.keyEquivalent.isEmpty)
    }
}
