import Foundation
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
import KernirCore
@testable import Kernir

/// In-archive move on iOS: which folders take which items (`MovePlanning.roots`), the
/// same-document drop, the Move sheet's request, the Replace question for same-named items, and the gates.
/// Most tests record what reaches the model (`moveOperations`); the end-to-end ones run the real `ArchiveModel.move`.
/// In `ScreenStateTests` for its `.serialized`: `ArchiveDocument.engine` is a process-wide test seam.
extension ScreenStateTests {
    /// Opens a copy of a ZIP fixture with a fake engine listing `entries` (`format` as given).
    private func openForMove(_ entries: [ArchiveEntry] = SampleArchive().entries,
                             format: ArchiveFormat = .zip) async throws -> ScreenState {
        let url = try Fixture.copy("zip/deflate.zip")
        ArchiveDocument.engine = FakeEngine(reader: { url in
            FakeReader(entries: entries, format: format, url: url)
        }).engine
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        #expect(document.session.model != nil)
        return ScreenState(document: document)
    }

    private func folder(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
    }

    private func file(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
    }

    /// The calls that reach the model's move, answered with `result` (nil: each root lands in the folder).
    @MainActor private final class MoveRecorder {
        var calls: [(paths: [String], folder: String)] = []
        var result: Result<[String: String], MoveProblem>?

        func install(on state: ScreenState) {
            state.moveOperations.move = { [self] _, paths, folder in
                calls.append((paths, folder))
                if let result { return result }
                return .success(Dictionary(uniqueKeysWithValues: paths.map { path in
                    let name = (path as NSString).lastPathComponent
                    return (path, folder.isEmpty ? name : folder + "/" + name)
                }))
            }
        }
    }

    // MARK: - Targets

    /// A folder takes items unless it is one of them or beneath one, or every item is already in it.
    @Test func moveTargetRules() {
        #expect(ScreenState.isMoveTarget("src", for: ["README.md"]))
        #expect(ScreenState.isMoveTarget("", for: ["src/main.swift"]))
        #expect(ScreenState.isMoveTarget("assets", for: ["src"]))
        #expect(ScreenState.isMoveTarget("src", for: ["src/main.swift", "README.md"]), "README.md still moves")
        #expect(!ScreenState.isMoveTarget("src", for: ["src"]), "into itself")
        #expect(!ScreenState.isMoveTarget("src/sub", for: ["src"]), "into a descendant")
        #expect(!ScreenState.isMoveTarget("src", for: ["src/main.swift"]), "already there")
        #expect(!ScreenState.isMoveTarget("", for: ["README.md", "brief.pdf"]), "already at the top level")
        #expect(!ScreenState.isMoveTarget("src", for: []))
        #expect(ScreenState.isMoveTarget("srcs", for: ["src/main.swift"]), "per component, not a prefix")
    }

    /// Only a listed folder (or the top level) of an archive that edits now.
    @Test func canMoveGates() async throws {
        let state = try await openForMove()
        #expect(state.canMove(["README.md"], into: "src"))
        #expect(state.canMove(["src/main.swift"], into: ""))
        #expect(!state.canMove(["README.md"], into: "brief.pdf"), "not a folder")
        #expect(!state.canMove(["README.md"], into: "gone"), "not listed")
        #expect(!state.canMove(["src"], into: "src"))
        state.session.saveFraction = 0.5
        #expect(!state.canMove(["README.md"], into: "src"), "while saving")
        state.session.saveFraction = nil
        await state.document.closeOnMain()

        let rar = try await openForMove(format: .rar)
        #expect(!rar.canMove(["README.md"], into: "src"))
        await rar.document.closeOnMain()
    }

    // MARK: - Moving

    /// No same-named item in the folder: the model moves at once, and moved rows leave the selection
    /// (they left this level); Select mode ends with its last selected row, as after Delete.
    @Test func moveWithoutConflictMoves() async throws {
        let state = try await openForMove()
        let recorder = MoveRecorder()
        recorder.install(on: state)
        state.isSelecting = true
        state.selection = ["README.md", "brief.pdf"]

        state.move(["README.md"], into: "src")
        #expect(recorder.calls.map(\.paths) == [["README.md"]])
        #expect(recorder.calls.map(\.folder) == ["src"])
        #expect(state.pendingReplacement == nil)
        #expect(state.alert == nil)
        #expect(state.selection == ["brief.pdf"])
        #expect(state.isSelecting)

        state.move(["brief.pdf"], into: "assets")
        #expect(state.selection.isEmpty)
        #expect(!state.isSelecting)
        await state.document.closeOnMain()
    }

    /// Paths no longer listed (stale after a reopen or revert) don't move, and leave the selection after a move.
    @Test func moveIgnoresStalePaths() async throws {
        let state = try await openForMove()
        let recorder = MoveRecorder()
        recorder.install(on: state)
        #expect(!state.canMove(["ghost.txt"], into: "src"))
        #expect(!state.canMove(["README.md", "ghost.txt"], into: "src"))
        state.move(["ghost.txt"], into: "src")
        #expect(recorder.calls.isEmpty)

        state.isSelecting = true
        state.selection = ["README.md", "ghost.txt", "brief.pdf"]
        state.move(["README.md"], into: "src")
        #expect(state.selection == ["brief.pdf"], "the moved row and the one no longer listed leave")
        await state.document.closeOnMain()
    }

    /// The Replace question outlives the archive's state: a confirm whose paths are no longer listed moves nothing.
    @Test func confirmReplacementChecksMoveAgain() async throws {
        let state = try await openForMove(SampleArchive().entries + [file("assets/README.md")])
        let recorder = MoveRecorder()
        recorder.install(on: state)
        state.pendingReplacement = PendingReplacement(urls: [], directory: "assets",
                                                      conflicts: ["assets/ghost.txt"], moving: ["ghost.txt"])
        state.confirmReplacement()
        #expect(state.pendingReplacement == nil)
        #expect(recorder.calls.isEmpty)

        state.move(["README.md"], into: "assets")
        #expect(state.pendingReplacement != nil)
        state.confirmReplacement()
        #expect(recorder.calls.count == 1, "a valid one still moves")
        await state.document.closeOnMain()
    }

    /// Replace answers for the items it named: when the folder's same-named items changed meanwhile, a new
    /// question comes (after the old alert's settle) instead of a move; the same set moves.
    @Test func confirmReplacementAsksAgainWhenConflictsChange() async throws {
        let state = try await openForMove(SampleArchive().entries + [file("assets/README.md")])
        let recorder = MoveRecorder()
        recorder.install(on: state)
        state.replacementAlertSettle = .zero
        state.move(["README.md", "brief.pdf"], into: "assets")
        #expect(state.pendingReplacement?.conflicts == ["assets/README.md"])

        state.moveOperations.conflicts = { _, _, _ in ["assets/brief.pdf", "assets/README.md"] }
        state.confirmReplacement()
        #expect(recorder.calls.isEmpty, "nothing replaced unasked")
        #expect(state.pendingReplacement == nil, "the answered alert goes first")
        await state.replacementAskedAgain?.value
        let again = try #require(state.pendingReplacement)
        #expect(again.conflicts == ["assets/brief.pdf", "assets/README.md"])
        #expect(again.moving == ["README.md", "brief.pdf"])
        #expect(again.directory == "assets")

        state.moveOperations.conflicts = { _, _, _ in ["assets/README.md", "assets/brief.pdf"] }
        state.confirmReplacement()
        #expect(recorder.calls.map(\.paths) == [["README.md", "brief.pdf"]], "the same set, in any order, moves")
        await state.replacementAskedAgain?.value
        #expect(state.pendingReplacement == nil)
        await state.document.closeOnMain()
    }

    /// Through the real model: the same-named item renamed away while the question was up leaves nothing to
    /// replace, and Replace just moves.
    @Test func confirmReplacementMovesWhenConflictGone() async throws {
        let state = try await openForMove(SampleArchive().entries + [file("assets/README.md")])
        let model = try #require(state.model)
        state.move(["README.md"], into: "assets")
        #expect(state.pendingReplacement?.conflicts == ["assets/README.md"])
        _ = try model.rename("assets/README.md", to: "OLD.md").get()
        state.confirmReplacement()
        #expect(state.pendingReplacement == nil)
        #expect(state.alert == nil)
        #expect(model.item(at: "assets/README.md")?.size == 1_024, "the moved one")
        #expect(model.item(at: "assets/OLD.md") != nil, "nothing replaced")
        await state.document.closeOnMain()
    }

    /// A same-named item in the folder asks first (Add's Replace question); Replace moves, Cancel doesn't.
    @Test func moveConflictAsksToReplace() async throws {
        let state = try await openForMove(SampleArchive().entries + [file("assets/README.md")])
        let recorder = MoveRecorder()
        recorder.install(on: state)

        state.move(["README.md"], into: "assets")
        #expect(recorder.calls.isEmpty)
        let replacement = try #require(state.pendingReplacement)
        #expect(replacement.conflicts == ["assets/README.md"])
        #expect(replacement.moving == ["README.md"])
        #expect(replacement.directory == "assets")
        #expect(replacement.title == "Replace “README.md”?")
        state.cancelReplacement()
        #expect(recorder.calls.isEmpty)

        state.move(["README.md"], into: "assets")
        state.confirmReplacement()
        #expect(state.pendingReplacement == nil)
        #expect(recorder.calls.count == 1, "one move; it replaces the target itself, as one undo step")
        #expect(recorder.calls.map(\.paths) == [["README.md"]])
        #expect(recorder.calls.map(\.folder) == ["assets"])
        #expect(state.model?.item(at: "assets/README.md") != nil, "the target isn't removed first")
        await state.document.closeOnMain()
    }

    /// A folder over a same-named folder asks the same way: it would replace that folder (no merge).
    @Test func moveFolderOntoFolderAsks() async throws {
        let state = try await openForMove(SampleArchive().entries + [folder("assets/src")])
        let recorder = MoveRecorder()
        recorder.install(on: state)
        state.move(["src"], into: "assets")
        #expect(state.pendingReplacement?.conflicts == ["assets/src"])
        state.confirmReplacement()
        #expect(recorder.calls.count == 1, "one move; no removal of assets/src beforehand")
        #expect(recorder.calls.map(\.folder) == ["assets"])
        #expect(state.model?.item(at: "assets/src") != nil, "the target isn't removed first")
        await state.document.closeOnMain()
    }

    /// A refusal the UI can't foresee says why: a name taken by an item the list doesn't show in its own words,
    /// every other problem in the model's (`MovePlanning.message(for:)`), the deleted folder's name included.
    @Test func moveTakenShowsAlert() async throws {
        let state = try await openForMove()
        let recorder = MoveRecorder()
        recorder.install(on: state)
        recorder.result = .failure(.taken("x"))
        state.move(["README.md"], into: "src")
        #expect(state.alert?.title == "Couldn't move “README.md”")
        #expect(state.alert?.message == "There is already an item named “x” there.")

        for problem in [MoveProblem.unavailable, .holdsMovedOutItems("d")] {
            state.alert = nil
            recorder.result = .failure(problem)
            state.move(["README.md"], into: "src")
            #expect(state.alert?.title == "Couldn't move “README.md”")
            #expect(state.alert?.message == MovePlanning.message(for: problem))
        }

        state.alert = nil
        recorder.result = .failure(.taken("cover.png"))
        state.move(["README.md"], into: "assets")
        #expect(state.alert?.message == MovePlanning.message(for: .taken("cover.png")), "a listed item there")
        await state.document.closeOnMain()
    }

    /// The model's `.taken` through the real model: two moved items with one name (an item of that name in the
    /// folder too), or replacing a folder that holds a moved item, in the model's words; a hidden entry there
    /// (Finder metadata alone in a folder) as a plain collision. No Replace question; nothing moves.
    @Test func moveTakenEndToEndSaysWhy() async throws {
        let state = try await openForMove([folder("a"), file("a/x.txt"), folder("b"), file("b/x.txt"),
                                           folder("dst"), folder("p"), folder("p/a"), file("a/y.txt")])
        let model = try #require(state.model)
        state.move(["a/x.txt", "b/x.txt"], into: "dst")
        #expect(state.pendingReplacement == nil)
        #expect(state.alert?.title == "Couldn't move 2 items")
        #expect(state.alert?.message == MovePlanning.message(for: .taken("x.txt")))
        #expect(model.item(at: "a/x.txt") != nil && model.item(at: "b/x.txt") != nil)

        state.alert = nil
        state.move(["a/x.txt", "b/x.txt"], into: "b")
        #expect(state.pendingReplacement == nil, "b/x.txt is itself moved: nothing to replace")
        #expect(state.alert?.message == MovePlanning.message(for: .taken("x.txt")))

        state.alert = nil
        state.move(["p/a", "a/y.txt"], into: "")
        #expect(state.pendingReplacement == nil, "replacing a would take a/y.txt along")
        #expect(state.alert?.message == MovePlanning.message(for: .taken("a")))
        #expect(model.item(at: "p/a") != nil && model.item(at: "a/y.txt") != nil)
        await state.document.closeOnMain()

        let hidden = try await openForMove(SampleArchive().entries + [file("x/._y"), folder("d2"), folder("d2/x")])
        #expect(hidden.model?.item(at: "x") == nil, "x holds only Finder metadata")
        hidden.move(["d2/x"], into: "")
        #expect(hidden.pendingReplacement == nil)
        #expect(hidden.alert?.title == "Couldn't move “x”")
        #expect(hidden.alert?.message == "There is already an item named “x” there.")
        #expect(hidden.model?.item(at: "d2/x") != nil)
        await hidden.document.closeOnMain()
    }

    /// Read-only or busy: nothing reaches the model; a save running says so.
    @Test func moveRefusedWhenNotEditing() async throws {
        let state = try await openForMove()
        let recorder = MoveRecorder()
        recorder.install(on: state)
        state.session.saveFraction = 0.5
        state.move(["README.md"], into: "src")
        #expect(recorder.calls.isEmpty)
        #expect(state.alert?.message == "The archive is being saved. Try again.")
        state.session.saveFraction = nil
        state.alert = nil

        state.move(["README.md"], into: "")
        #expect(recorder.calls.isEmpty, "already there")
        #expect(state.alert == nil)
        await state.document.closeOnMain()

        let rar = try await openForMove(format: .rar)
        let rarRecorder = MoveRecorder()
        rarRecorder.install(on: rar)
        rar.move(["README.md"], into: "src")
        rar.beginMove(["README.md"])
        #expect(rarRecorder.calls.isEmpty)
        #expect(rar.moveRequest == nil)
        #expect(rar.alert == nil)
        await rar.document.closeOnMain()
    }

    /// The app's own path (`moveOperations.model`) reaches `ArchiveModel`'s conflicts and move.
    @Test func defaultOperationsUseTheModel() async throws {
        let state = try await openForMove()
        let model = try #require(state.model)
        let viaState = state.moveOperations.conflicts(model, ["README.md"], "src")
        #expect(viaState == model.conflicts(moving: ["README.md"], into: "src"))
        await state.document.closeOnMain()
    }

    // MARK: - The Move sheet

    /// Move… asks for a folder; the move runs once the sheet has gone (so its Replace question can come up).
    @Test func moveSheetFlow() async throws {
        let state = try await openForMove()
        let recorder = MoveRecorder()
        recorder.install(on: state)

        state.beginMove(["README.md"])
        #expect(state.moveRequest?.paths == ["README.md"])
        state.confirmMove(into: "src")
        #expect(state.moveRequest == nil)
        #expect(recorder.calls.isEmpty, "not before the sheet has gone")
        state.moveSheetDidDismiss()
        #expect(recorder.calls.map(\.folder) == ["src"])
        state.moveSheetDidDismiss()
        #expect(recorder.calls.count == 1, "once")

        state.beginMove(["brief.pdf"])
        state.cancelMove()
        state.moveSheetDidDismiss()
        #expect(recorder.calls.count == 1)

        state.beginMove(["brief.pdf"])
        state.confirmMove(into: "")
        state.moveSheetDidDismiss()
        #expect(recorder.calls.count == 1, "an invalid target moves nothing")

        state.beginMove([])
        #expect(state.moveRequest == nil)
        state.beginMove(["gone"])
        #expect(state.moveRequest == nil)
        await state.document.closeOnMain()
    }

    /// The document's content going cancels the Move sheet, a confirmed move, a Replace question for a
    /// move (also one about to be asked again) and the remembered drags.
    @Test func cancelPendingMoveClearsMoveState() async throws {
        let state = try await openForMove(SampleArchive().entries + [file("assets/README.md")])
        let recorder = MoveRecorder()
        recorder.install(on: state)

        state.beginMove(["README.md"])
        #expect(state.moveRequest != nil)
        state.cancelPendingMove()
        #expect(state.moveRequest == nil)

        state.beginMove(["brief.pdf"])
        state.confirmMove(into: "src")
        state.cancelPendingMove()
        state.moveSheetDidDismiss()
        #expect(recorder.calls.isEmpty, "a confirmed move doesn't run afterwards")

        state.move(["README.md"], into: "assets")
        #expect(state.pendingReplacement != nil)
        state.cancelPendingMove()
        #expect(state.pendingReplacement == nil, "a move's Replace question goes")

        state.replacementAlertSettle = .milliseconds(50)
        state.move(["README.md"], into: "assets")
        state.moveOperations.conflicts = { _, _, _ in ["assets/README.md", "assets/other"] }
        state.confirmReplacement()
        let asking = try #require(state.replacementAskedAgain)
        state.cancelPendingMove()
        await asking.value
        #expect(state.pendingReplacement == nil, "the question asked again doesn't come up")
        #expect(state.replacementAskedAgain == nil)

        _ = state.dragProvider(for: "README.md")
        #expect(!state.draggedRows.isEmpty)
        state.cancelPendingMove()
        #expect(state.draggedRows.isEmpty)
        #expect(state.draggedRowOrder.isEmpty)
        await state.document.closeOnMain()
    }

    /// Select mode's Move… takes the topmost selected rows.
    @Test func moveSelectionTargets() async throws {
        let state = try await openForMove()
        #expect(!state.canMoveSelection)
        state.isSelecting = true
        #expect(!state.canMoveSelection, "nothing selected")
        state.selection = ["src", "src/main.swift", "README.md"]
        #expect(state.canMoveSelection)
        #expect(state.moveTargets() == ["README.md", "src"])
        state.session.saveFraction = 0.5
        #expect(!state.canMoveSelection)
        state.session.saveFraction = nil
        await state.document.closeOnMain()
    }

    /// The sheet lists every folder of the archive, nested, and no files.
    @Test func moveFoldersTree() async throws {
        let state = try await openForMove(SampleArchive().entries + [folder("src/sub"), file("src/sub/a.txt")])
        let folders = state.moveFolders()
        #expect(Set(folders.map(\.path)) == ["src", "assets"])
        let src = try #require(folders.first { $0.path == "src" })
        #expect(src.children?.map(\.path) == ["src/sub"])
        #expect(src.children?.first?.children == nil)
        #expect(src.name == "src")
        #expect(folders.first { $0.path == "assets" }?.children == nil)
        await state.document.closeOnMain()
    }

    // MARK: - Drag and drop

    /// A row's drag names its path: in its marker's data, and to this document at once (a drop delegate
    /// decides before it can load data). Another document, or any foreign item in the drop, gets no paths.
    @Test func dragCarriesRowPath() async throws {
        let state = try await openForMove()
        let other = try await openForMove()
        let provider = state.dragProvider(for: "README.md")
        let folderProvider = state.dragProvider(for: "src")

        #expect(state.isFromThisDocument([provider]))
        #expect(state.draggedPaths([provider, folderProvider]) == ["README.md", "src"])
        #expect(other.draggedPaths([provider]) == nil)
        #expect(state.draggedPaths([provider, NSItemProvider(object: "text" as NSString)]) == nil)
        #expect(state.draggedPaths([]) == nil)
        MoveRecorder().install(on: state)
        for _ in 0..<(ScreenState.draggedRowsKept + 4) { _ = state.dragProvider(for: "README.md") }
        #expect(state.draggedRows.count <= ScreenState.draggedRowsKept, "the map is capped")
        #expect(state.draggedPaths([provider]) == nil, "the oldest drag is forgotten")
        let dropped = state.dragProvider(for: "README.md")
        #expect(state.performMoveDrop([dropped], into: "src"))
        #expect(state.draggedPaths([dropped]) == nil, "a drop forgets its drag")
        let data = try await markerData(provider, type: state.dragMarkerType)
        #expect(String(decoding: data, as: UTF8.self) == "README.md")
        await state.document.closeOnMain()
        await other.document.closeOnMain()
    }

    /// Rows of this archive move onto a folder that takes them; onto their own folder, into themselves,
    /// or while edits are off, the drop is refused. Other drops are as before.
    @Test func sameDocumentDropProposal() async throws {
        let state = try await openForMove(SampleArchive().entries + [folder("src/sub")])
        func operation(_ paths: [String]?, into folder: String, fromHere: Bool = true) -> DropOperation {
            state.dropProposal(isFromThisDocument: fromHere, moving: paths, into: folder).operation
        }
        #expect(operation(["README.md"], into: "src") == .move)
        #expect(operation(["src/main.swift"], into: "") == .move, "onto the top level's list")
        #expect(operation(["README.md"], into: "") == .forbidden, "its own folder")
        #expect(operation(["src"], into: "src") == .forbidden, "onto itself")
        #expect(operation(["src"], into: "src/sub") == .forbidden, "into a descendant")
        #expect(operation(nil, into: "src") == .forbidden, "mixed with foreign items")
        #expect(operation(nil, into: "src", fromHere: false) == .copy, "from elsewhere")
        state.session.saveFraction = 0.5
        #expect(operation(["README.md"], into: "src") == .forbidden)
        state.session.saveFraction = nil
        await state.document.closeOnMain()

        let rar = try await openForMove(format: .rar)
        #expect(rar.dropProposal(isFromThisDocument: true, moving: ["README.md"], into: "src").operation == .forbidden)
        await rar.document.closeOnMain()
    }

    /// A drag of many rows (more than the old cap of 16) still moves all of them; a drop on this document,
    /// moved or refused, ends its drag and forgets its rows.
    @Test func dragOfManyRowsMoves() async throws {
        let names = (0..<20).map { "f\($0).txt" }
        let state = try await openForMove(names.map { file($0) } + [folder("dst")])
        let recorder = MoveRecorder()
        recorder.install(on: state)
        let providers = names.map { state.dragProvider(for: $0) }
        #expect(state.draggedPaths(providers) == names)
        #expect(state.performMoveDrop(providers, into: "dst"))
        #expect(recorder.calls.map(\.paths) == [names])
        #expect(state.draggedRows.isEmpty, "the drop forgets its rows")
        let refused = [state.dragProvider(for: "dst")]
        #expect(!state.performMoveDrop(refused, into: ""), "already there")
        #expect(state.draggedRows.isEmpty && state.draggedRowOrder.isEmpty, "a refused drop forgets its rows too")
        await state.document.closeOnMain()
    }

    /// The drop of this document's rows moves them, through the same path as Move….
    @Test func sameDocumentDropMoves() async throws {
        let state = try await openForMove()
        let recorder = MoveRecorder()
        recorder.install(on: state)
        let providers = [state.dragProvider(for: "README.md")]

        #expect(state.performMoveDrop(providers, into: "src"))
        #expect(recorder.calls.map(\.paths) == [["README.md"]])
        #expect(!state.performMoveDrop(providers, into: ""), "its own folder")
        #expect(recorder.calls.count == 1)
        await state.document.closeOnMain()
    }

    // MARK: - End to end (ArchiveModel)

    /// Waits up to 5 s for `condition`: the document's undo group closes at the end of the run loop turn.
    private func moveUndoSettles(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// `move(_:into:)` through the real model: the file lands in the folder, as one undo step "Move" that
    /// brings it back.
    @Test func moveEndToEndIsOneUndoStep() async throws {
        let state = try await openForMove()
        let model = try #require(state.model)
        let undoManager = state.document.undoManager

        state.move(["README.md"], into: "src")
        #expect(state.alert == nil)
        #expect(state.pendingReplacement == nil)
        #expect(model.item(at: "README.md") == nil)
        #expect(Set(model.children(of: "src").map(\.path)) == ["src/main.swift", "src/utils.swift", "src/README.md"])
        #expect(Set(model.children(of: "").map(\.path)) == ["src", "assets", "brief.pdf"])
        try await moveUndoSettles { state.canUndo }
        #expect(undoManager?.undoActionName == "Move")

        state.undo()
        #expect(model.item(at: "README.md")?.size == 1_024)
        #expect(model.item(at: "src/README.md") == nil)
        #expect(Set(model.children(of: "src").map(\.path)) == ["src/main.swift", "src/utils.swift"])
        #expect(!model.hasChanges)
        #expect(undoManager?.canUndo == false, "one undo step")
        await state.document.closeOnMain()
    }

    /// Replace through the real model: the Replace question, then one move that leaves exactly one
    /// README.md in the folder (the moved one); one undo brings both back.
    @Test func moveReplaceEndToEndIsOneUndoStep() async throws {
        let state = try await openForMove(SampleArchive().entries + [file("src/README.md")])
        let model = try #require(state.model)
        let undoManager = state.document.undoManager

        state.move(["README.md"], into: "src")
        #expect(state.pendingReplacement?.conflicts == ["src/README.md"])
        #expect(model.item(at: "README.md") != nil, "nothing moves before the answer")
        state.confirmReplacement()
        #expect(state.pendingReplacement == nil)
        #expect(state.alert == nil)
        #expect(model.item(at: "README.md") == nil)
        #expect(model.children(of: "src").filter { $0.name == "README.md" }.count == 1, "exactly one item")
        #expect(model.item(at: "src/README.md")?.size == 1_024, "the moved one")
        #expect(model.children(of: "src").count == 3)
        try await moveUndoSettles { state.canUndo }
        #expect(undoManager?.undoActionName == "Move")

        state.undo()
        #expect(model.item(at: "README.md")?.size == 1_024)
        #expect(model.item(at: "src/README.md")?.size == 1, "the replaced item is back")
        #expect(!model.hasChanges)
        #expect(undoManager?.canUndo == false, "one undo step")
        await state.document.closeOnMain()
    }

    /// Items moved out of a deleted folder can't go back to its name before a save: the model's
    /// `.holdsMovedOutItems`, shown in its own words; nothing moves.
    @Test func moveOntoADeletedFolderNameSaysSaveFirst() async throws {
        let state = try await openForMove([folder("d"), file("d/a.txt"), file("d/b.txt"), folder("x"), folder("x/d")])
        let model = try #require(state.model)
        state.move(["d/a.txt"], into: "x/d")
        state.delete(["d"])
        #expect(state.alert == nil)
        #expect(model.item(at: "d") == nil && model.item(at: "x/d/a.txt") != nil)

        state.move(["x/d"], into: "")
        #expect(state.alert?.title == "Couldn't move “d”")
        #expect(state.alert?.message == MovePlanning.message(for: .holdsMovedOutItems("d")))
        #expect(model.item(at: "x/d/a.txt") != nil)
        await state.document.closeOnMain()
    }

    /// Delete refused by the real model (`ArchiveModel.remove` -> `.holdsMovedOutItems`): source x renamed z and
    /// w renamed x, d/a.txt moved into that x, d deleted; deleting z drops x's rename, so the writer would put
    /// x/a.txt beneath the deleted source x. The alert says why; rows, selection and Select mode stay.
    @Test func deleteRefusedByTheModelKeepsRowsAndSelection() async throws {
        let state = try await openForMove([folder("d"), file("d/a.txt"), folder("x"), folder("w"), file("w/q.txt")])
        let model = try #require(state.model)
        _ = try model.rename("x", to: "z").get()
        _ = try model.rename("w", to: "x").get()
        state.move(["d/a.txt"], into: "x")
        state.delete(["d"])
        #expect(state.alert == nil)
        #expect(model.item(at: "x/a.txt") != nil && model.item(at: "d") == nil)

        state.isSelecting = true
        state.selection = ["z"]
        let rows = model.children(of: "").map(\.path)
        state.delete(state.deleteTargets())
        #expect(state.alert?.title.hasPrefix("Couldn't delete") == true)
        #expect(state.alert?.message == MovePlanning.message(for: .holdsMovedOutItems("x")))
        #expect(model.children(of: "").map(\.path) == rows)
        #expect(model.item(at: "z") != nil && model.item(at: "x/a.txt") != nil)
        #expect(state.selection == ["z"])
        #expect(state.isSelecting)
        await state.document.closeOnMain()
    }

    /// Root drop's routing carries moves: a folder row's target is that folder (moves), a file row's and the
    /// list's own area are the level on screen (refused: already there, and never added back).
    @Test func rowDropTargetsRouteMoves() async throws {
        let state = try await openForMove()
        let model = try #require(state.model)
        let src = try #require(model.item(at: "src"))
        let readme = try #require(model.item(at: "README.md"))
        let providers = [state.dragProvider(for: "brief.pdf")]

        let fileRowTarget = state.dropDirectory(forRow: readme, in: "")
        #expect(fileRowTarget == "")
        #expect(!state.performMoveDrop(providers, into: fileRowTarget))
        #expect(!state.acceptDrop(providers, to: fileRowTarget))
        #expect(!model.hasChanges)

        // A drop ends its drag (its rows are forgotten, refused or not): the folder row gets a fresh drag.
        let again = [state.dragProvider(for: "brief.pdf")]
        #expect(state.performMoveDrop(again, into: state.dropDirectory(forRow: src, in: "")))
        #expect(model.item(at: "src/brief.pdf") != nil && model.item(at: "brief.pdf") == nil)
        await state.document.closeOnMain()
    }

    /// While this archive's rows hover without item providers, their item markers' types still find them:
    /// a folder that takes them proposes a move, their own level is refused, as with the providers at hand.
    @Test func hoveringOwnRowsProposeMove() async throws {
        let state = try await openForMove()
        let own = state.dragProvider(for: "README.md")
        let registered = own.registeredTypeIdentifiers
        let conforms: ([UTType]) -> Bool = { types in
            types.contains { type in
                registered.contains { $0 == type.identifier || UTType($0)?.conforms(to: type) == true }
            }
        }
        #expect(state.hoveringDraggedPaths(conforms) == ["README.md"])
        #expect(state.hoveringDraggedPaths { _ in false } == nil)
        #expect(state.dropProposal(hovering: [], conforms: conforms, into: "src").operation == .move)
        #expect(state.dropProposal(hovering: [], conforms: conforms, into: "").operation == .forbidden)
        #expect(state.dropProposal(hovering: [own], conforms: { _ in false }, into: "src").operation == .move)
        #expect(state.dropProposal(hovering: [own], conforms: { _ in false }, into: "").operation == .forbidden)
        await state.document.closeOnMain()
    }
}

@MainActor private func markerData(_ provider: NSItemProvider, type: String) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadDataRepresentation(forTypeIdentifier: type) { @Sendable data, error in
            if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
            }
        }
    }
}
