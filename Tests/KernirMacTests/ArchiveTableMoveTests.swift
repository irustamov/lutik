import AppKit
import Testing
@testable import Kernir
import KernirCore

// Rows dragged onto a folder row, the table itself or a file row of the same window move inside
// the archive (`ArchiveActions.move`, `ArchiveTableDragAnchor.validateMove/acceptMove`). These tests inject a
// mover that returns what the model's move would (`ArchiveActions.Mover`) and records what it was asked;
// `ArchiveActionsMoveLiveTests` drives the real model on a real ZIP. Hosted (AppKit) run only. The hook
// decides every drag carrying the move type, so validate never reaches SwiftUI's; accept is called only when
// `theHookAnswersAccept` holds.

/// A mover answering as the model's move will: each moved root lands in the folder under its own name.
@MainActor
private final class RecordingMover {
    var calls: [(paths: [String], folder: String)] = []
    var conflicts: [String] = []
    /// What the replace alert answers; nil: it is never answered.
    var replace: Bool?
    var asked: [[String]] = []
    var failure: MoveProblem?

    func install(on actions: ArchiveActions) {
        actions.mover = ArchiveActions.Mover(
            conflicts: { [unowned self] _, _, _ in conflicts },
            move: { [unowned self] _, paths, folder in
                calls.append((paths, folder))
                if let failure { return .failure(failure) }
                guard case .success(let roots) = MovePlanning.roots(paths, into: folder) else { return .failure(.intoItself) }
                var moves: [String: String] = [:]
                for root in roots {
                    let name = String(root.split(separator: "/").last ?? Substring(root))
                    moves[root] = folder.isEmpty ? name : folder + "/" + name
                }
                return .success(moves)
            },
            confirmReplace: { [unowned self] conflicts, answer in
                asked.append(conflicts)
                if let replace { answer(replace) }
            })
    }
}

private func file(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
}

private func folder(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
}

/// A window held offscreen and ordered front, so a sheet attaches to it; `end()` takes its sheets down and
/// closes it.
@MainActor
private final class SheetHostWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    static func make() -> SheetHostWindow {
        let window = SheetHostWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    /// A plain sheet, standing for any alert, panel or the progress sheet.
    func beginPlainSheet() -> NSWindow {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        beginSheet(sheet)
        return sheet
    }

    func end() {
        for sheet in sheets { endSheet(sheet) }
        orderOut(nil)
    }
}

/// One dragged row of a move, as `ArchiveFilePromiseProvider` writes it.
private func moveItem(_ path: String, token: String) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setPropertyList(["path": path, "token": token], forType: ArchiveFilePromiseProvider.moveType)
    return item
}

@Suite(.serialized) @MainActor
struct ArchiveActionsMoveTests {
    private static let entries = [
        folder("docs"), file("docs/a.txt"), folder("docs/sub"), file("docs/sub/d.txt"), file("README"), file("notes"),
    ]

    private func makeActions(format: ArchiveFormat = .zip)
        throws -> (ArchiveDocument, ArchiveActions, RecordingMover, UndoManager) {
        let document = try ArchiveDocument(type: "public.zip-archive")
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        document.state.model = ArchiveModel(reader: FakeReader(entries: Self.entries, format: format),
                                            undoManager: undoManager)
        let actions = ArchiveActions(document: document)
        document.actions = actions
        let mover = RecordingMover()
        mover.install(on: actions)
        return (document, actions, mover, undoManager)
    }

    /// A step of the undo manager (it doesn't group by event: a registration outside a group raises).
    private func step<T>(_ undoManager: UndoManager, _ body: () throws -> T) rethrows -> T {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        return try body()
    }

    @Test func canMoveOnlyWhereItDoesSomething() throws {
        // The actions hold their document weakly: it must outlive every call.
        let (document, actions, _, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        #expect(actions.canMove(["README"], into: "docs"))
        #expect(actions.canMove(["docs/a.txt"], into: ""))
        #expect(actions.canMove(["README", "docs/a.txt"], into: "docs/sub"))
        // Already there: the own parent, the top level for a top-level item.
        #expect(!actions.canMove(["docs/a.txt"], into: "docs"))
        #expect(!actions.canMove(["README"], into: ""))
        // Into itself or beneath it.
        #expect(!actions.canMove(["docs"], into: "docs"))
        #expect(!actions.canMove(["docs"], into: "docs/sub"))
        // Not a folder, gone, nothing.
        #expect(!actions.canMove(["README"], into: "notes"))
        #expect(!actions.canMove(["README"], into: "gone"))
        #expect(!actions.canMove(["gone"], into: "docs"))
        #expect(!actions.canMove([], into: "docs"))
    }

    @Test func notOnAReadOnlyArchiveWhileAJobRunsOrWhileRenaming() throws {
        let (rarDocument, rar, _, _) = try makeActions(format: .rar)
        defer { withExtendedLifetime(rarDocument) {} }
        #expect(!rar.canMove(["README"], into: "docs"))
        #expect(!rar.move(["README"], into: "docs"))

        let (document, actions, mover, _) = try makeActions()
        document.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
        #expect(!actions.canMove(["README"], into: "docs"))
        document.state.progress = nil
        actions.beginRename("notes")
        #expect(!actions.canMove(["README"], into: "docs"))
        #expect(!actions.move(["README"], into: "docs"))
        #expect(mover.calls.isEmpty)
    }

    @Test func aMoveRemapsTheSelectionAndOpenFoldersAndUndoMapsThemBack() throws {
        let (document, actions, mover, undoManager) = try makeActions()
        let state = document.state
        state.selection = ["docs/sub", "README"]
        state.expanded = ["docs", "docs/sub"]

        #expect(step(undoManager) { actions.move(["docs/sub", "README"], into: "") })
        // README is already at the top level: only docs/sub moves (the mover's map).
        #expect(mover.calls.count == 1)
        #expect(mover.calls.first?.paths == ["docs/sub", "README"] && mover.calls.first?.folder == "")
        #expect(state.selection == ["sub", "README"])
        #expect(state.expanded == ["docs", "sub"])

        undoManager.undo()
        #expect(state.selection == ["docs/sub", "README"])
        #expect(state.expanded == ["docs", "docs/sub"])
        undoManager.redo()
        #expect(state.selection == ["sub", "README"])
    }

    @Test func aCollisionAsksAndReplaceMovesOnce() throws {
        let (document, actions, mover, undoManager) = try makeActions()
        mover.conflicts = ["docs/sub/README"]
        mover.replace = true
        document.state.selection = ["README"]
        #expect(step(undoManager) { actions.move(["README"], into: "docs/sub") })
        #expect(mover.asked == [["docs/sub/README"]])
        #expect(mover.calls.count == 1)
        #expect(document.state.selection == ["docs/sub/README"])
    }

    @Test func aCollisionStoppedMovesNothing() throws {
        let (document, actions, mover, undoManager) = try makeActions()
        mover.conflicts = ["docs/sub/README"]
        mover.replace = false
        document.state.selection = ["README"]
        #expect(step(undoManager) { actions.move(["README"], into: "docs/sub") })
        #expect(mover.asked.count == 1)
        #expect(mover.calls.isEmpty)
        #expect(document.state.selection == ["README"])
    }

    /// A sheet (an alert, a panel, the progress sheet) came up during the drag: the drop moves nothing under it
    /// and asks nothing, so a conflict never queues a second sheet. With the sheet gone it can move again.
    @Test func notWhileASheetIsUp() throws {
        let (document, actions, mover, undoManager) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let window = SheetHostWindow.make()
        defer { window.end() }
        actions.window = window
        mover.conflicts = ["docs/README"]
        mover.replace = true
        let sheet = window.beginPlainSheet()
        try #require(window.attachedSheet === sheet)

        #expect(!actions.canMove(["README"], into: "docs"))
        #expect(!step(undoManager) { actions.move(["README"], into: "docs") })
        #expect(mover.asked.isEmpty)
        #expect(mover.calls.isEmpty)

        window.endSheet(sheet)
        try #require(window.attachedSheet == nil)
        #expect(actions.canMove(["README"], into: "docs"))
    }

    /// Replace is answered while the alert may still be attached (AppKit calls back as it ends the sheet): the
    /// sheet check of `canMove` holds the drop, never the answer.
    @Test func replaceAnsweredUnderTheAlertStillMoves() throws {
        let (document, actions, mover, undoManager) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let window = SheetHostWindow.make()
        defer { window.end() }
        actions.window = window
        mover.conflicts = ["docs/sub/README"]
        actions.mover.confirmReplace = { _, answer in
            _ = window.beginPlainSheet()
            answer(true)
        }
        document.state.selection = ["README"]
        #expect(step(undoManager) { actions.move(["README"], into: "docs/sub") })
        #expect(window.attachedSheet != nil)
        #expect(mover.calls.count == 1)
        #expect(document.state.selection == ["docs/sub/README"])
    }

    /// A conflict with no window and no one else to ask (the window's alert needs a window): nothing moves, so
    /// the drop is not taken.
    @Test func aWindowlessCollisionFailsTheDrop() throws {
        let (document, actions, mover, undoManager) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        actions.mover.confirmReplace = nil
        mover.conflicts = ["docs/sub/README"]
        document.state.selection = ["README"]
        #expect(actions.window == nil)
        #expect(!step(undoManager) { actions.move(["README"], into: "docs/sub") })
        #expect(mover.calls.isEmpty)
        #expect(document.state.selection == ["README"])
    }

    @Test func aRefusedMoveKeepsTheSelection() async throws {
        try await PresentedErrors.collecting { presented in
            let (document, actions, mover, undoManager) = try makeActions()
            mover.failure = .taken("README")
            document.state.selection = ["README"]
            // Not taken: the drop fails.
            #expect(!step(undoManager) { actions.move(["README"], into: "docs") })
            #expect(mover.calls.count == 1)
            #expect(document.state.selection == ["README"])
            #expect(presented.errors.map(\.localizedDescription) == [MovePlanning.message(for: .taken("README"))])
        }
    }
}

/// The window's table as the hook's move validate reads it (rows, levels, items), recording where the
/// validate retargets the drop: AppKit gives no getter for an outline's drop item outside a drag session.
@MainActor
private final class RetargetRecordingOutline: NSOutlineView {
    let real: NSOutlineView
    var retargets: [(item: AnyObject?, childIndex: Int)] = []

    init(_ real: NSOutlineView) {
        self.real = real
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var numberOfRows: Int { real.numberOfRows }
    override func row(forItem item: Any?) -> Int { real.row(forItem: item) }
    override func level(forRow row: Int) -> Int { real.level(forRow: row) }
    override func item(atRow row: Int) -> Any? { real.item(atRow: row) }
    override func setDropItem(_ item: Any?, dropChildIndex index: Int) {
        retargets.append((item as AnyObject?, index))
    }
}

/// The hook over the window's table: zip with docs/, docs/a.txt, docs/sub/, b.pdf, c.png (closed: docs, b.pdf,
/// c.png).
@Suite(.serialized) @MainActor
struct ArchiveTableMoveTests {
    private static let entries = ["docs/", "docs/a.txt", "docs/sub/", "b.pdf", "c.png"]

    private func hosted() async throws -> (RegressionHosted, NSOutlineView, RecordingMover) {
        let hosted = try await RegressionHosted(.hooked, entries: Self.entries)
        let (table, _) = try await hosted.table(.hooked)
        let outline = try #require(table as? NSOutlineView)
        try #require(theHookAnswersAccept(outline))
        let mover = RecordingMover()
        mover.install(on: hosted.actions)
        return (hosted, outline, mover)
    }

    /// A move of `paths` from `outline` (or `source`), with `token` (the window's when nil).
    private func moveDrop(_ paths: [String], from hosted: RegressionHosted, outline: NSOutlineView,
                          source: AnyObject?? = nil, token: String? = nil,
                          mask: NSDragOperation = .move) -> FakeDrop {
        let items = paths.map { moveItem($0, token: token ?? hosted.actions.moveToken) }
        let resolved: AnyObject? = source ?? (outline as AnyObject?)
        return FakeDrop(writers: items, location: .zero, window: outline.window, source: resolved, mask: mask)
    }

    private func validate(_ drop: FakeDrop, _ outline: NSOutlineView, row: Int?) -> UInt? {
        let item = row.map { outline.item(atRow: $0) as AnyObject? } ?? nil
        return outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: item,
                                                proposedChildIndex: NSOutlineViewDropOnItemIndex).rawValue
    }

    private func accept(_ drop: FakeDrop, _ outline: NSOutlineView, row: Int?) -> Bool? {
        let item = row.map { outline.item(atRow: $0) as AnyObject? } ?? nil
        return outline.dataSource?.outlineView?(outline, acceptDrop: drop, item: item,
                                                childIndex: NSOutlineViewDropOnItemIndex)
    }

    private func path(ofRow row: Int, _ hosted: RegressionHosted) -> String {
        ArchiveTableDragSelection.rows(of: hosted.document.state.tableItems(of: hosted.model),
                                       expanded: hosted.document.state.expanded)[row].path
    }

    @Test func theTableRegistersTheMoveType() async throws {
        let (hosted, outline, _) = try await hosted()
        defer { hosted.end() }
        #expect(outline.registeredDraggedTypes.contains(ArchiveFilePromiseProvider.moveType))
        #expect(!Set(outline.registeredDraggedTypes).isDisjoint(with: [.fileURL, .URL]))
    }

    @Test func aFileDroppedOnAFolderRowMovesIntoIt() async throws {
        let (hosted, outline, mover) = try await hosted()
        defer { hosted.end() }
        #expect(path(ofRow: 0, hosted) == "docs" && path(ofRow: 1, hosted) == "b.pdf")
        // The row's own writer, as a drag gets it: the promise names the path and the window's token.
        let writer = try #require(hosted.actions.dragWriter(for: "b.pdf", drop: UUID()))
        let drop = FakeDrop(writers: [writer], location: .zero, window: outline.window, source: outline, mask: .move)
        defer { drop.end() }
        #expect(validate(drop, outline, row: 0) == NSDragOperation.move.rawValue)
        #expect(accept(drop, outline, row: 0) == true)
        #expect(mover.calls.map(\.paths) == [["b.pdf"]] && mover.calls.map(\.folder) == ["docs"])
    }

    @Test func aNestedItemDroppedOnTheTableOrAFileRowMovesToTheTopLevel() async throws {
        let (hosted, outline, mover) = try await hosted()
        defer { hosted.end() }
        hosted.document.state.expanded = ["docs"]
        try #require(await waitFor { outline.numberOfRows == 5 })
        let drop = moveDrop(["docs/a.txt"], from: hosted, outline: outline)
        defer { drop.end() }
        let fileRow = 3  // folders first: docs, sub, a.txt, b.pdf, c.png
        #expect(path(ofRow: fileRow, hosted) == "b.pdf")
        #expect(validate(drop, outline, row: nil) == NSDragOperation.move.rawValue)
        #expect(validate(drop, outline, row: fileRow) == NSDragOperation.move.rawValue)
        #expect(accept(drop, outline, row: nil) == true)
        #expect(accept(drop, outline, row: fileRow) == true)
        #expect(mover.calls.map(\.folder) == ["", ""])
    }

    /// A move validate retargets the drop to what it moves into: a folder row (on it, not between its
    /// children), the table itself for the top level (a file row or a gap: item nil, on it).
    @Test func aMoveValidateRetargetsTheDropToItsFolder() async throws {
        let (hosted, outline, mover) = try await hosted()
        defer { hosted.end() }
        hosted.document.state.expanded = ["docs"]
        try #require(await waitFor { outline.numberOfRows == 5 })
        let recording = RetargetRecordingOutline(outline)
        let drop = moveDrop(["b.pdf"], from: hosted, outline: outline)
        let nested = moveDrop(["docs/a.txt"], from: hosted, outline: outline)
        defer { drop.end(); nested.end() }
        // Folders first: docs, docs/sub, docs/a.txt, b.pdf, c.png.
        #expect((0..<5).map { path(ofRow: $0, hosted) } == ["docs", "docs/sub", "docs/a.txt", "b.pdf", "c.png"])
        let docs = outline.item(atRow: 0) as AnyObject?
        let sub = outline.item(atRow: 1) as AnyObject?
        for (row, index) in [(0, NSOutlineViewDropOnItemIndex), (0, 1), (1, 0)] {
            let item = outline.item(atRow: row) as AnyObject?
            let answer = outline.dataSource?.outlineView?(recording, validateDrop: drop, proposedItem: item,
                                                          proposedChildIndex: index)
            #expect(answer == .move, "row \(row) index \(index)")
        }
        for (row, index): (Int?, Int) in [(nil, NSOutlineViewDropOnItemIndex), (nil, 2), (3, NSOutlineViewDropOnItemIndex)] {
            let item = row.map { outline.item(atRow: $0) as AnyObject? } ?? nil
            let answer = outline.dataSource?.outlineView?(recording, validateDrop: nested, proposedItem: item,
                                                          proposedChildIndex: index)
            #expect(answer == .move, "row \(String(describing: row)) index \(index)")
        }
        // A top-level file on a nested file row goes to the top level, where it already is: refused, not retargeted.
        let fileRow = outline.item(atRow: 2) as AnyObject?
        #expect(outline.dataSource?.outlineView?(recording, validateDrop: drop, proposedItem: fileRow,
                                                 proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
        let on = NSOutlineViewDropOnItemIndex
        try #require(recording.retargets.count == 6)
        #expect(recording.retargets.map(\.childIndex) == [on, on, on, on, on, on])
        #expect(recording.retargets[0].item === docs && recording.retargets[1].item === docs)
        #expect(recording.retargets[2].item === sub)
        #expect(recording.retargets[3...].allSatisfy { $0.item == nil })
        #expect(mover.calls.isEmpty)
    }

    @Test func severalRowsMoveTogether() async throws {
        let (hosted, outline, mover) = try await hosted()
        defer { hosted.end() }
        let drop = moveDrop(["b.pdf", "c.png"], from: hosted, outline: outline)
        defer { drop.end() }
        #expect(validate(drop, outline, row: 0) == NSDragOperation.move.rawValue)
        #expect(accept(drop, outline, row: 0) == true)
        #expect(mover.calls.map(\.paths) == [["b.pdf", "c.png"]])
    }

    @Test func noOpsAndMovesIntoItselfAreRefused() async throws {
        let (hosted, outline, mover) = try await hosted()
        defer { hosted.end() }
        hosted.document.state.expanded = ["docs"]
        try #require(await waitFor { outline.numberOfRows == 5 })
        let nested = moveDrop(["docs/a.txt"], from: hosted, outline: outline)
        let top = moveDrop(["b.pdf"], from: hosted, outline: outline)
        let folder = moveDrop(["docs"], from: hosted, outline: outline)
        defer { nested.end(); top.end(); folder.end() }
        #expect(validate(nested, outline, row: 0) == 0)   // its own parent
        #expect(validate(top, outline, row: nil) == 0)    // already at the top level
        #expect(validate(top, outline, row: 4) == 0)      // c.png: the top level again
        #expect(validate(folder, outline, row: 0) == 0)   // onto itself
        #expect(validate(folder, outline, row: 2) == 0)   // into docs/sub
        #expect(accept(folder, outline, row: 2) == false)
        #expect(mover.calls.isEmpty)
    }

    @Test func aMoveFromElsewhereIsRefused() async throws {
        let (hosted, outline, mover) = try await hosted()
        defer { hosted.end() }
        let otherWindow = moveDrop(["b.pdf"], from: hosted, outline: outline, token: UUID().uuidString)
        let otherSource = moveDrop(["b.pdf"], from: hosted, outline: outline, source: .some(NSView()))
        let noSource = moveDrop(["b.pdf"], from: hosted, outline: outline, source: .some(nil))
        let copying = moveDrop(["b.pdf"], from: hosted, outline: outline, mask: .copy)
        defer { otherWindow.end(); otherSource.end(); noSource.end(); copying.end() }
        for drop in [otherWindow, otherSource, noSource, copying] {
            #expect(validate(drop, outline, row: 0) == 0)
            #expect(accept(drop, outline, row: 0) == false)
        }
        #expect(mover.calls.isEmpty)
    }

    @Test func notWhileAJobRuns() async throws {
        let (hosted, outline, mover) = try await hosted()
        defer { hosted.end() }
        hosted.document.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
        defer { hosted.document.state.progress = nil }
        let drop = moveDrop(["b.pdf"], from: hosted, outline: outline)
        defer { drop.end() }
        #expect(validate(drop, outline, row: 0) == 0)
        #expect(accept(drop, outline, row: 0) == false)
        #expect(mover.calls.isEmpty)
    }
}
