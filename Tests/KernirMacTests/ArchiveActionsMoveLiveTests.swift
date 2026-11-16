import AppKit
import Testing
@testable import Kernir
import KernirCore

/// End to end: `ArchiveActions.move` on the real model (`ArchiveModel.move(_:into:)`) over
/// a real ZIP built by hand (`LiveMetadataSaveTests.storedZip`, a few bytes, no repo fixture), then a real save
/// (`ArchiveEngine.live`) reopened. Each move is one undo step: the model's "Move" and the actions' selection
/// remap land in one group, so one Undo restores the entries and the selection together. Hosted (AppKit) run.
/// What the replace test's mover was asked.
@MainActor
private final class Calls {
    var moves = 0
    var asked: [[String]] = []
}

/// The Move To move the late-run test's wait started.
@MainActor
private final class LateMove {
    var task: Task<Void, Never>?
}

@Suite(.serialized) @MainActor
struct ArchiveActionsMoveLiveTests {
    private static let sourceEntries: [(path: String, contents: String?)] = [
        ("docs/", nil),
        ("docs/a.txt", "a"),
        ("docs/sub/", nil),
        ("docs/sub/d.txt", "d"),
        ("other/", nil),
        ("other/README", "old readme"),
        ("README", "readme"),
    ]

    private static let sourcePaths: Set<String> = [
        "docs", "docs/a.txt", "docs/sub", "docs/sub/d.txt", "other", "other/README", "README",
    ]

    /// One move test's world; `close()` removes its folder, temporary files and defaults suite.
    @MainActor private struct Opened {
        let directory: URL
        let reader: any ArchiveReading
        let model: ArchiveModel
        let document: ArchiveDocument
        let actions: ArchiveActions
        let undoManager: UndoManager
        let defaults: UserDefaults
        let suite: String

        func close() {
            model.removeTemporaryFiles()
            removeTestDefaults(defaults, suite: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// `groupsByEvent`: a window's undo manager (one group per run-loop pass) instead of explicit groups.
    private func open(_ entries: [(path: String, contents: String?)] = sourceEntries,
                      groupsByEvent: Bool = false) async throws -> Opened {
        let (defaults, suite) = makeTestDefaults("ArchiveActionsMoveLiveTests")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveActionsMoveLiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("source.zip")
        try LiveMetadataSaveTests.storedZip(entries).write(to: sourceURL)
        let reader = try await ArchiveEngine.live.open(sourceURL, nil)
        // The document's own manager, as in a window: the actions' undo observers watch it.
        let document = try ArchiveDocument(type: "public.zip-archive")
        let undoManager = try #require(document.undoManager)
        undoManager.groupsByEvent = groupsByEvent
        let model = ArchiveModel(reader: reader, undoManager: undoManager)
        model.nameEncodingStore = ArchiveNameEncodingStore(defaults: defaults)
        document.state.model = model
        let actions = ArchiveActions(document: document)
        document.actions = actions
        return Opened(directory: directory, reader: reader, model: model, document: document, actions: actions,
                      undoManager: undoManager, defaults: defaults, suite: suite)
    }

    /// One event's undo group (the manager doesn't group by event: a registration outside a group raises).
    private func step<T>(_ undoManager: UndoManager, _ body: () throws -> T) rethrows -> T {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        return try body()
    }

    private func visiblePaths(_ model: ArchiveModel) -> Set<String> {
        Set(model.items.flattened().map(\.path))
    }

    /// Saves the model's changes to a new ZIP and reopens it; its paths and file contents.
    private func saveAndReopen(_ opened: Opened) async throws -> (paths: Set<String>, contents: [String: String]) {
        #expect(opened.model.saveProblem(as: .zip, split: false) == nil)
        let savedURL = opened.directory.appendingPathComponent("saved-\(UUID().uuidString).zip")
        try await ArchiveEngine.live.write(opened.reader, opened.model.saveChanges(as: .zip), .zip, savedURL,
                                           opened.model.saveOptions, nil)
        let saved = try await ArchiveEngine.live.open(savedURL, nil)
        let out = opened.directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await saved.extract(nil, to: out, progress: nil)
        var contents: [String: String] = [:]
        for entry in saved.entries where !entry.isDirectory {
            contents[entry.path] = (try? Data(contentsOf: out.appendingPathComponent(entry.path)))
                .map { String(decoding: $0, as: UTF8.self) }
        }
        return (Set(saved.entries.map(\.path)), contents)
    }

    private var moveActionName: String { String(localized: "Move", table: "Shared") }

    @Test func aFileIntoAFolderAndAFolderToTheTopLevelEachUndoInOneStepAndSurviveASave() async throws {
        let opened = try await open()
        defer { opened.close() }
        let (model, actions, undoManager, state) = (opened.model, opened.actions, opened.undoManager,
                                                    opened.document.state)
        #expect(visiblePaths(model) == Self.sourcePaths)

        state.selection = ["README"]
        #expect(step(undoManager) { actions.move(["README"], into: "docs") })
        #expect(model.item(at: "docs/README") != nil && model.item(at: "README") == nil)
        #expect(state.selection == ["docs/README"])
        #expect(undoManager.undoActionName == moveActionName)

        state.selection = ["docs/sub"]
        state.expanded = ["docs", "docs/sub"]
        #expect(step(undoManager) { actions.move(["docs/sub"], into: "") })
        let moved: Set<String> = ["docs", "docs/a.txt", "docs/README", "sub", "sub/d.txt", "other", "other/README"]
        #expect(visiblePaths(model) == moved)
        #expect(state.selection == ["sub"])
        #expect(state.expanded == ["docs", "sub"])

        // One Undo takes back the folder's move, entries and selection alike; the next one the file's.
        undoManager.undo()
        #expect(model.item(at: "docs/sub/d.txt") != nil && model.item(at: "sub") == nil)
        #expect(model.item(at: "docs/README") != nil)
        #expect(state.selection == ["docs/sub"])
        #expect(state.expanded == ["docs", "docs/sub"])
        // The file's Undo restores the selection from before its move (README), not the one after the
        // folder's Undo.
        undoManager.undo()
        #expect(visiblePaths(model) == Self.sourcePaths)
        #expect(model.changes.isEmpty)
        #expect(state.selection == ["README"])
        #expect(!undoManager.canUndo)

        // Redo both, then save: the reopened archive holds the moved paths with their bytes.
        undoManager.redo()
        undoManager.redo()
        #expect(visiblePaths(model) == moved)
        let saved = try await saveAndReopen(opened)
        #expect(saved.paths == moved)
        #expect(saved.contents["docs/README"] == "readme")
        #expect(saved.contents["sub/d.txt"] == "d")
        #expect(saved.contents["docs/a.txt"] == "a")
    }

    @Test func replaceOnAConflictIsOneMoveCallAndOneUndoStep() async throws {
        let opened = try await open()
        defer { opened.close() }
        let (model, actions, undoManager, state) = (opened.model, opened.actions, opened.undoManager,
                                                    opened.document.state)
        let calls = Calls()
        actions.mover.move = { model, paths, folder in
            calls.moves += 1
            return model.move(paths, into: folder)
        }
        actions.mover.confirmReplace = { conflicts, answer in
            calls.asked.append(conflicts)
            answer(true)
        }
        state.selection = ["README"]

        #expect(step(undoManager) { actions.move(["README"], into: "other") })

        #expect(calls.asked == [["other/README"]])
        #expect(calls.moves == 1)
        #expect(model.item(at: "README") == nil && model.item(at: "other/README") != nil)
        #expect(state.selection == ["other/README"])
        #expect(undoManager.undoActionName == moveActionName)

        undoManager.undo()
        #expect(visiblePaths(model) == Self.sourcePaths)
        #expect(model.changes.isEmpty)
        #expect(state.selection == ["README"])
        #expect(!undoManager.canUndo)

        undoManager.redo()
        let saved = try await saveAndReopen(opened)
        #expect(saved.paths == ["docs", "docs/a.txt", "docs/sub", "docs/sub/d.txt", "other", "other/README"])
        // The moved README replaced the old one.
        #expect(saved.contents["other/README"] == "readme")
    }

    @Test func stopOnAConflictMovesNothing() async throws {
        let opened = try await open()
        defer { opened.close() }
        let (model, actions, undoManager) = (opened.model, opened.actions, opened.undoManager)
        actions.mover.confirmReplace = { _, answer in answer(false) }

        // Outside an undo group: nothing registers, and an empty group would be an undo step of its own.
        #expect(actions.move(["README"], into: "other"))

        #expect(visiblePaths(model) == Self.sourcePaths)
        #expect(model.changes.isEmpty)
        #expect(!undoManager.canUndo)
    }

    /// The model took the move but moved nothing (no moves back): `moved` doesn't run, so a Cut's pasteboard
    /// stays for the next Paste. It runs once an item does move.
    @Test func movedRunsOnlyWhenSomethingMoved() async throws {
        let opened = try await open()
        defer { opened.close() }
        let (actions, undoManager) = (opened.actions, opened.undoManager)
        let moved = Calls()
        actions.mover.move = { _, _, _ in .success([:]) }

        #expect(step(undoManager) { actions.move(["docs/a.txt"], into: "") { moved.moves += 1 } })
        #expect(moved.moves == 0)

        actions.mover.move = { model, paths, folder in model.move(paths, into: folder) }
        #expect(step(undoManager) { actions.move(["docs/a.txt"], into: "") { moved.moves += 1 } })
        #expect(moved.moves == 1)
        #expect(opened.model.item(at: "a.txt") != nil)
    }

    @Test func aMoveIntoItselfIsRefusedAndTheModelsRefusalIsShown() async throws {
        try await PresentedErrors.collecting { presented in
            let opened = try await open()
            defer { opened.close() }
            let (model, actions, undoManager, state) = (opened.model, opened.actions, opened.undoManager,
                                                        opened.document.state)
            state.selection = ["docs"]

            // Into itself: the actions refuse before the model is asked; the model would refuse too.
            #expect(!actions.canMove(["docs"], into: "docs/sub"))
            // Outside an undo group, as no refusal registers anything (an empty group would be a step).
            #expect(!actions.move(["docs"], into: "docs/sub"))
            #expect(model.move(["docs"], into: "docs/sub") == .failure(.intoItself))
            #expect(visiblePaths(model) == Self.sourcePaths)
            #expect(state.selection == ["docs"])

            // Two items named README into docs: only the model sees it; it refuses, the actions say why and
            // report the move as not taken (the drop fails).
            state.selection = ["README", "other/README"]
            #expect(!actions.move(["README", "other/README"], into: "docs"))
            #expect(visiblePaths(model) == Self.sourcePaths)
            #expect(model.changes.isEmpty)
            #expect(state.selection == ["README", "other/README"])
            #expect(presented.errors.map(\.localizedDescription) == [MovePlanning.message(for: .taken("README"))])
            #expect(!undoManager.canUndo)
        }
    }

    /// Under a search, a move can take the selected rows out of what it shows (docs/a.txt shows as inside the
    /// matching docs; in other it matches nothing): they leave the selection, and the Undo selects them again.
    @Test func undoReselectsMovedRowsTheSearchDropped() async throws {
        let opened = try await open()
        defer { opened.close() }
        let (model, actions, undoManager, state) = (opened.model, opened.actions, opened.undoManager,
                                                    opened.document.state)
        state.searchText = "docs"
        state.selection = ["docs/a.txt"]

        #expect(step(undoManager) { actions.move(["docs/a.txt"], into: "other") })
        #expect(model.item(at: "other/a.txt") != nil)
        #expect(state.selection.isEmpty)

        undoManager.undo()
        #expect(visiblePaths(model) == Self.sourcePaths)
        #expect(state.selection == ["docs/a.txt"])
        #expect(!undoManager.canUndo)

        // Redo moves it out of the search's rows again; the Undo after it selects it again too.
        undoManager.redo()
        #expect(model.item(at: "other/a.txt") != nil)
        #expect(state.selection.isEmpty)
        undoManager.undo()
        #expect(state.selection == ["docs/a.txt"])
    }

    /// A window's undo manager (groups by event): the model's registration opens the event's one group and the
    /// selection remap joins it; one Undo closes it and takes back the entries and the selection. Inside a test
    /// body the run loop never ends that event (a nested `RunLoop.main.run` doesn't close it either): the Undo
    /// does, as in `ArchiveInfoTests`.
    @Test func oneUndoTakesBackAMoveUnderAnEventGroupedUndoManager() async throws {
        let opened = try await open(groupsByEvent: true)
        defer { opened.close() }
        let (model, actions, undoManager, state) = (opened.model, opened.actions, opened.undoManager,
                                                    opened.document.state)
        // Never leave the event group open past the test, whatever fails before the Undo.
        defer { while undoManager.groupingLevel > 0 { undoManager.endUndoGrouping() } }
        #expect(undoManager.groupsByEvent)
        #expect(undoManager.groupingLevel == 0)
        state.selection = ["README"]

        #expect(actions.move(["README"], into: "docs"))
        #expect(state.selection == ["docs/README"])
        // One group, not nested: the move and its remap opened nothing of their own.
        #expect(undoManager.groupingLevel == 1)
        #expect(undoManager.undoActionName == moveActionName)

        undoManager.undo()
        #expect(undoManager.groupingLevel == 0)
        #expect(visiblePaths(model) == Self.sourcePaths)
        #expect(model.changes.isEmpty)
        #expect(state.selection == ["README"])
        #expect(!undoManager.canUndo)
    }

    /// Move To end to end on a window's undo manager, its move run late from a Task as `whenNoSheetAttached` runs
    /// it once the sheet is gone (outside any event): still one undo step, and one Undo takes back the entries
    /// and the selection. The actions hold the document weakly: `opened` keeps it alive.
    @Test func moveToRunLateFromATaskIsOneUndoStep() async throws {
        let opened = try await open(groupsByEvent: true)
        defer { opened.close() }
        let (model, actions, undoManager, state) = (opened.model, opened.actions, opened.undoManager,
                                                    opened.document.state)
        // Never leave the event group open past the test, whatever fails before the Undo.
        defer { while undoManager.groupingLevel > 0 { undoManager.endUndoGrouping() } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        // The actions hold the window weakly too.
        defer { withExtendedLifetime(window) {} }
        actions.window = window
        let late = LateMove()
        actions.whenNoSheetAttached = { _, body in late.task = Task { @MainActor in body() } }
        #expect(undoManager.groupingLevel == 0)
        state.selection = ["README"]

        actions.beginMoveTo(["README"])
        #expect(state.moveTo?.paths == ["README"])
        actions.chooseMoveTo("docs")
        #expect(state.moveTo == nil)
        actions.moveToSheetDidEnd()
        let task = try #require(late.task)
        await task.value

        #expect(model.item(at: "docs/README") != nil)
        #expect(model.item(at: "README") == nil)
        #expect(state.selection == ["docs/README"])
        // At most the one group the model's registration opened: the move and its remap opened none of their
        // own (the run loop may already have closed it between the Task and here).
        #expect(undoManager.groupingLevel <= 1)
        #expect(undoManager.undoActionName == moveActionName)

        undoManager.undo()
        #expect(undoManager.groupingLevel == 0)
        #expect(visiblePaths(model) == Self.sourcePaths)
        #expect(model.changes.isEmpty)
        #expect(state.selection == ["README"])
        #expect(!undoManager.canUndo)
    }

    /// a.txt moved out of d, d deleted, then the folders renamed so that a.txt sits beneath the deleted d's path
    /// again: deleting q would make the writer drop it. The model refuses; Delete says why, with nothing removed
    /// and the selection kept.
    @Test func aDeleteTheModelRefusesIsShownAndKeepsTheSelection() async throws {
        try await PresentedErrors.collecting { presented in
            let opened = try await open([("p/", nil), ("p/d/", nil), ("p/d/a.txt", "a"), ("r/", nil), ("r/d/", nil)])
            defer { opened.close() }
            let (model, actions, undoManager, state) = (opened.model, opened.actions, opened.undoManager,
                                                        opened.document.state)
            let first = step(undoManager) { model.rename("p", to: "q") }
            #expect(first == .success("q"))
            #expect(step(undoManager) { actions.move(["q/d/a.txt"], into: "r/d") })
            step(undoManager) { actions.remove(["q/d"]) }
            let second = step(undoManager) { model.rename("r", to: "p") }
            #expect(second == .success("p"))
            let before = model.changes
            let paths = visiblePaths(model)
            #expect(paths == ["p", "p/d", "p/d/a.txt", "q"])
            #expect(model.remove(["q"]) == .holdsMovedOutItems("d"))
            #expect(presented.errors.isEmpty)
            state.selection = ["q", "p/d/a.txt"]

            // Outside an undo group, as the refusal registers nothing (an empty group would be a step).
            actions.remove(["q"])

            #expect(presented.errors.map(\.localizedDescription)
                == [MovePlanning.message(for: .holdsMovedOutItems("d"))])
            #expect(model.changes == before)
            #expect(visiblePaths(model) == paths)
            #expect(state.selection == ["q", "p/d/a.txt"])
            #expect(undoManager.undoActionName == String(localized: "Rename", table: "Shared"))
        }
    }
}
