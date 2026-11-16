import AppKit
import os
import SwiftUI
import Testing
@testable import Kernir
import KernirCore

// Rows drag out of the archive table as file promises through the Table's own AppKit table view
// (`ArchiveTableDragSource`). The window's real `ArchiveTableView` over a real zip, in an
// NSHostingView in an offscreen window: the hook installs and survives SwiftUI's updates, every row
// passes SwiftUI's own drag gate, a drag from N selected rows gives N writers
// (`ArchiveActions.filePromise(for:)`) and a drag from an unselected row that row's alone, each
// for the row the outline shows under any sort, search and open folders, drops inside Kernir are
// refused, and the writers land the archive's files when AppKit fulfils them.
// Hosted (AppKit, SwiftUI): needs a hosted UI test run.

/// The table as the window shows it: rows refiltered and resorted from the state on every update.
private struct HostedTable: View {
    let state: ArchiveWindowState
    let model: ArchiveModel
    let actions: ArchiveActions

    var body: some View {
        ArchiveTableView(items: state.tableItems(of: model), state: state, actions: actions)
    }
}

/// A window held offscreen (AppKit keeps a titled window on a screen unless told not to).
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Every call of the promises' completion handlers, by promised name.
private final class Completions: Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: [String: [String]]())
    func record(_ name: String, _ error: (any Error)?) {
        calls.withLock { $0[name, default: []].append(error.map { "\($0)" } ?? "nil") }
    }
    var all: [String: [String]] { calls.withLock { $0 } }
    var count: Int { calls.withLock { $0.values.reduce(0) { $0 + $1.count } } }
}

/// Carries a provider and its delegate onto the delegate's queue, as AppKit does on a drop.
private struct OnQueue: @unchecked Sendable {
    let provider: NSFilePromiseProvider
    let delegate: any NSFilePromiseProviderDelegate
}

/// The archive window's table, hosted: a zip with a folder and two files, its document and actions.
@MainActor
private final class Hosted {
    static let paths = ["docs/", "docs/a.txt", "b.pdf", "c.png"]

    let zip: URL
    let model: ArchiveModel
    let document: ArchiveDocument
    let actions: ArchiveActions
    let window: OffscreenWindow
    /// The drags' plain-file folders (`ArchiveDragOutFiles`), this host's own: `end` deletes them.
    let dragOutFolders: ArchiveDragOutFolders

    init(paths: [String] = Hosted.paths) async throws {
        zip = try LegacyZip.write(paths, as: .utf8)
        model = ArchiveModel(reader: try await Archive.open(at: zip), undoManager: nil)
        document = try ArchiveDocument(type: "public.zip-archive")
        document.state.model = model
        actions = ArchiveActions(document: document)
        let folders = ArchiveDragOutFolders()
        dragOutFolders = folders
        window = OffscreenWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 600, height: 400),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HostedTable(state: document.state, model: model, actions: actions))
        window.orderFrontRegardless()
        actions.makeDragOutFiles = { reader in ArchiveDragOutFiles(reader: reader, folders: folders) }
    }

    func end() {
        window.orderOut(nil)
        window.contentView = nil
        model.removeTemporaryFiles()
        dragOutFolders.removeAll()
        try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
    }

    var anchor: ArchiveTableDragAnchor? {
        func find(_ view: NSView) -> ArchiveTableDragAnchor? {
            if let anchor = view as? ArchiveTableDragAnchor { return anchor }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// The hooked table, once its data source is hooked.
    func hookedTable() async throws -> NSTableView {
        try #require(await waitUntil { self.anchor?.isHooked == true }, "the hook never got installed")
        return try #require(anchor?.tableView)
    }

    /// Selects `paths` (the folder open) and waits for the table to show it.
    func select(_ paths: Set<String>, in table: NSTableView) async throws {
        document.state.expanded.insert("docs")
        try #require(await waitUntil { table.numberOfRows == 4 })
        document.state.selection = paths
        try #require(await waitUntil { table.selectedRowIndexes.count == paths.count })
    }

    /// What AppKit gets for the row: the writer message sent to the table's data source.
    func writer(forRow row: Int, in table: NSTableView) -> (any NSPasteboardWriting)? {
        if let outline = table as? NSOutlineView {
            guard let item = outline.item(atRow: row) else { return nil }
            return outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: item)
        }
        return table.dataSource?.tableView?(table, pasteboardWriterForRow: row)
    }

    /// The writers of a drag that starts on a selected row, by row in row order: AppKit asks for the
    /// selected rows only; nil at every other row and for a row the drag leaves out.
    func writers(in table: NSTableView) -> [(any NSPasteboardWriting)?] {
        let selected = table.selectedRowIndexes
        return (0..<table.numberOfRows).map { selected.contains($0) ? writer(forRow: $0, in: table) : nil }
    }

    /// Whether SwiftUI's table lets a drag start on `row` alone, the mouse down on its name.
    func canDrag(row: Int, in table: NSTableView) -> Bool {
        let rect = table.rect(ofRow: row)
        return table.canDragRows(with: IndexSet(integer: row), at: NSPoint(x: rect.minX + 30, y: rect.midY))
    }
}

/// Polls for at most `seconds` while the main run loop turns (SwiftUI updates, the hook's retries).
@MainActor
private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

/// A data source with no rows, for tables of a test's own; it has a row writer (none), as the hook
/// only takes a data source whose class answers the writer message.
private final class EmptyDataSource: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 0 }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? { nil }
}

/// A data source the hook can't take: its class answers no row writer.
private final class WriterlessDataSource: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 0 }
}

/// The runtime class (the isa) of `object`.
private func isa(_ object: AnyObject) -> ObjectIdentifier? {
    object_getClass(object).map(ObjectIdentifier.init)
}

/// What the table offers a drag's destination in `context`, as AppKit asks it during a drag (the
/// table's own subclass, SwiftUI's, has the last word).
@MainActor
private func mask(of table: NSTableView, _ context: NSDraggingContext) -> NSDragOperation {
    table.draggingSession(NSDraggingSession(), sourceOperationMaskFor: context)
}

private func promisedPath(_ writer: (any NSPasteboardWriting)?) -> String? {
    ((writer as? NSFilePromiseProvider)?.delegate as? ArchiveFilePromiseDelegate)?.path
}

@MainActor
private func promisedDrop(_ writer: (any NSPasteboardWriting)?) -> ArchiveFilePromiseDrop? {
    ((writer as? NSFilePromiseProvider)?.delegate as? ArchiveFilePromiseDelegate)?.drop
}

/// A new, empty folder of this test's own in the temporary directory; the caller removes it.
private func freshFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveTableDragSourceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

@Suite(.serialized) @MainActor
struct ArchiveTableDragSourceTests {
    /// SwiftUI's data-source messages: the hook must leave every answer as SwiftUI's own class gives it.
    private static let probes: [String] = [
        "outlineView:numberOfChildrenOfItem:", "outlineView:child:ofItem:", "outlineView:isItemExpandable:",
        "outlineView:objectValueForTableColumn:byItem:", "outlineView:validateDrop:proposedItem:proposedChildIndex:",
        "outlineView:acceptDrop:item:childIndex:", "outlineView:sortDescriptorsDidChange:",
        "outlineView:draggingSession:willBeginAtPoint:forItems:",
        "outlineView:draggingSession:endedAtPoint:operation:", "outlineView:updateDraggingItemsForDrag:",
        "outlineView:pasteboardWriterForItem:",
        "numberOfRowsInTableView:", "tableView:objectValueForTableColumn:row:",
        "tableView:validateDrop:proposedRow:proposedDropOperation:", "tableView:acceptDrop:row:dropOperation:",
        "tableView:sortDescriptorsDidChange:", "tableView:draggingSession:willBeginAtPoint:forRowIndexes:",
        "tableView:updateDraggingItemsForDrag:", "tableView:pasteboardWriterForRow:",
    ]
    /// Of those, what the Table's outline needs SwiftUI's data source to answer: its rows, the drops
    /// it takes (the window's drop-in) and the row writer the hook overrides.
    private static let required: [String] = [
        "outlineView:numberOfChildrenOfItem:", "outlineView:child:ofItem:", "outlineView:isItemExpandable:",
        "outlineView:validateDrop:proposedItem:proposedChildIndex:", "outlineView:acceptDrop:item:childIndex:",
        "outlineView:pasteboardWriterForItem:",
    ]

    /// SwiftUI's own data source object stays the Table's data source, hooked in place: a Swift
    /// cast or an identity check on it still finds SwiftUI's object, `-class` still names its own
    /// class, and it answers every message just as its own class does. It stays hooked through
    /// opening a folder, selecting, sorting and SwiftUI setting it again, and goes back to its own
    /// class, with SwiftUI's own writer, when the view goes.
    @Test func theHookStaysOnTheTablesOwnTableView() async throws {
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        let outline = try #require(table as? NSOutlineView)
        let anchor = try #require(hosted.anchor)
        let source = try #require(anchor.swiftUIDataSource)
        #expect(table.dataSource === source)
        #expect(ArchiveTableDragAnchor.tableViews(under: try #require(hosted.window.contentView)).count == 1)
        let hookClass: AnyClass = try #require(object_getClass(source))
        let ownClass: AnyClass = try #require(class_getSuperclass(hookClass))
        #expect(NSStringFromClass(hookClass) == "KernirTableDragHook_" + NSStringFromClass(ownClass))
        #expect(!NSStringFromClass(ownClass).hasPrefix("NSKVONotifying_"))
        #expect((source as? NSObject)?.isMember(of: ownClass) == true)
        for name in Self.probes {
            let selector = NSSelectorFromString(name)
            #expect(source.responds(to: selector) == class_respondsToSelector(ownClass, selector), "\(name) changed")
        }
        for name in Self.required {
            #expect(class_respondsToSelector(ownClass, NSSelectorFromString(name)), "SwiftUI's \(name) is gone")
        }
        #expect(await waitUntil { table.numberOfRows == 3 })  // docs, b.pdf, c.png; the folder closed

        try await hosted.select(["b.pdf"], in: table)
        #expect(anchor.isHooked)
        hosted.document.state.sortOrder = [KeyPathComparator(\.name, order: .reverse)]
        #expect(await waitUntil { anchor.isHooked })
        let same = outline.dataSource
        outline.dataSource = same  // as SwiftUI may set it again on an update
        #expect(anchor.isHooked && table.dataSource === source)
        #expect(hosted.writer(forRow: 2, in: table) is NSFilePromiseProvider)

        anchor.uninstall()
        #expect(table.dataSource === source)
        #expect(isa(source) == ObjectIdentifier(ownClass))
        #expect(!ArchiveTableDragHook.isHooked(source, by: anchor))
        // SwiftUI's own writer answers again (its private drag-item type, never a promise).
        if let item = outline.item(atRow: 2), let own = outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: item) {
            #expect(!(own is NSFilePromiseProvider))
        }
    }

    /// A drag from two selected rows gives two promises, for their own paths in table order.
    @Test func eachSelectedRowGivesItsOwnPromise() async throws {
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        try await hosted.select(["b.pdf", "docs/a.txt"], in: table)

        let writers = hosted.writers(in: table)
        // Folders first: docs, docs/a.txt, b.pdf, c.png.
        #expect(writers.map(promisedPath) == [nil, "docs/a.txt", "b.pdf", nil])
        #expect(writers.compactMap { $0 }.allSatisfy { $0 is NSFilePromiseProvider })
        // One drag, one drop: its rows share a drop; the next drag is another one.
        let drops = writers.compactMap(promisedDrop)
        #expect(drops.count == 2 && drops.allSatisfy { $0 === drops[0] })
        try await Task.sleep(for: .milliseconds(50))  // a later drag starts in a later turn
        let nextDrops = hosted.writers(in: table).compactMap(promisedDrop)
        #expect(nextDrops.count == 2 && nextDrops.allSatisfy { $0 === nextDrops[0] })
        if let first = drops.first, let next = nextDrops.first { #expect(first.id != next.id) }
        #expect(!hosted.actions.hasFilePromiseWork)  // a drag starts nothing until a drop lands
    }

    /// A click-drag on an unselected row: AppKit moves the table's selection to that row and asks for
    /// the writers in the same turn, before SwiftUI's selection binding need have caught up. They
    /// belong to the new row, never the one selected before. (Programmatic here; a hosted run
    /// checks it with a real mouse.)
    @Test func aSelectionMovedByTheTableBringsTheNewRow() async throws {
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        #expect(await waitUntil { table.numberOfRows == 3 })  // docs, b.pdf, c.png; the folder closed
        table.selectRowIndexes(IndexSet([1]), byExtendingSelection: false)
        #expect(hosted.writers(in: table).map(promisedPath) == [nil, "b.pdf", nil])
        try await Task.sleep(for: .milliseconds(50))  // a later drag starts in a later turn

        table.selectRowIndexes(IndexSet([2]), byExtendingSelection: false)
        #expect(hosted.writers(in: table).map(promisedPath) == [nil, nil, "c.png"])
    }

    /// A selected row hidden under a closed, selected folder doesn't stop the drag: the folder's row
    /// brings the folder (and the hidden row with it), as the table shows it.
    @Test func aSelectedRowUnderAClosedFolderDoesntStopTheDrag() async throws {
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        try await hosted.select(["docs", "docs/a.txt", "c.png"], in: table)
        hosted.document.state.expanded.remove("docs")
        try #require(await waitUntil { table.numberOfRows == 3 })
        // The window's selection may still hold docs/a.txt; the table shows docs and c.png selected.
        try #require(await waitUntil { table.selectedRowIndexes == IndexSet([0, 2]) })

        #expect(hosted.writers(in: table).map(promisedPath) == ["docs", nil, "c.png"])
    }

    /// SwiftUI may change its data source after the representable's update in the same pass: the
    /// next turn hooks it again. (Unhooked here as a stand-in for a data source SwiftUI swapped in.)
    @Test func theHookComesBackTheTurnAfterAnUpdate() async throws {
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        let anchor = try #require(hosted.anchor)
        let source = try #require(anchor.source)
        let dataSource = try #require(anchor.swiftUIDataSource)

        anchor.update(source: source)
        ArchiveTableDragHook.uninstall(from: dataSource, for: anchor)
        #expect(!anchor.isHooked && table.dataSource === dataSource)
        #expect(await waitUntil(0.5) { anchor.isHooked })
        #expect(table.dataSource === dataSource)
    }

    /// Out of its window the anchor unhooks SwiftUI's data source (back to its own class, still the
    /// table's data source); back in, it hooks it again.
    @Test func theAnchorOutOfItsWindowGivesTheDataSourceBack() async throws {
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        let anchor = try #require(hosted.anchor)
        let parent = try #require(anchor.superview)
        let dataSource = try #require(anchor.swiftUIDataSource)
        let ownClass: AnyClass = try #require(object_getClass(dataSource).flatMap { class_getSuperclass($0) })

        anchor.removeFromSuperview()
        #expect(table.dataSource === dataSource)
        #expect(isa(dataSource) == ObjectIdentifier(ownClass))
        #expect(anchor.swiftUIDataSource == nil && anchor.tableView == nil)

        parent.addSubview(anchor)
        #expect(await waitUntil { anchor.isHooked && anchor.tableView === table })
        #expect(table.dataSource === dataSource)
    }

    /// Under a non-default sort (Size descending, folders first), with a nested folder
    /// open and a search on, every row's writer brings the path the outline itself shows at that row
    /// (the window's selection of a path lands on that row) at the outline's own level. The
    /// `theRowsFollowSearchSortAndNestedFolders` checks the same fixture's rows.
    @Test func theWritersFollowTheOutlinesRows() async throws {
        // LegacyZip stores each file's path as its contents: a file's size is its path's length.
        let hosted = try await Hosted(paths: [
            "a-reports/", "a-reports/q.txt", "docs/", "docs/sub/", "docs/sub/report-long-name.txt", "docs/sub/r.txt",
            "docs/report.md", "docs/z-report-extended.md", "docs/x.bin", "big-report.txt", "readme-report.txt", "a.txt",
        ])
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        let outline = try #require(table as? NSOutlineView)
        let state = hosted.document.state
        state.sortOrder = [KeyPathComparator(\.sizeSortKey, order: .reverse)]
        state.searchText = "report"
        state.expanded = ["docs", "docs/sub", "a-reports"]
        let rows = ["docs", "docs/sub", "docs/sub/report-long-name.txt", "docs/z-report-extended.md", "docs/report.md",
                    "a-reports", "a-reports/q.txt", "readme-report.txt", "big-report.txt"]
        try #require(await waitUntil { table.numberOfRows == rows.count })
        #expect((0..<rows.count).map { outline.level(forRow: $0) } == [0, 1, 2, 1, 1, 0, 1, 0, 0])

        for (row, path) in rows.enumerated() {
            state.selection = [path]
            #expect(await waitUntil { table.selectedRowIndexes == IndexSet([row]) }, "\(path) is not at row \(row)")
            #expect(hosted.writers(in: table).map(promisedPath) == rows.indices.map { $0 == row ? path : nil })
        }
    }

    /// A sort flip or a search swap that keeps the row count and the levels (the count and
    /// level check can't see it), and a drag asking for its writers in the same turn, before SwiftUI
    /// has redrawn: every writer brings the file the table shows selected at its row, or none, never
    /// the file the new order puts there. Pins the premise that the Table's outline and the drag
    /// source's rows update in the same pass (`ArchiveTableView`). Once redrawn, the file drags from
    /// its new row.
    @Test(arguments: [false, true])
    func aSortOrSearchChangeInTheDragsTurnBringsTheShownFile(bySearch: Bool) async throws {
        let hosted = try await Hosted(paths: ["x-one.txt", "x-two.txt", "y-one.txt", "y-two.txt"])
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        let state = hosted.document.state
        // By search: "one" shows x-one, y-one; "y" then shows y-one, y-two. By sort: Name ascending,
        // then descending (y-two, y-one, x-two, x-one). Same count, all at level 0.
        if bySearch { state.searchText = "one" }
        let (before, after) = bySearch ? (1, 0) : (2, 1)
        try #require(await waitUntil { table.numberOfRows == (bySearch ? 2 : 4) })
        state.selection = ["y-one.txt"]
        try #require(await waitUntil { table.selectedRowIndexes == IndexSet([before]) })
        try await Task.sleep(for: .milliseconds(50))  // the drag starts in a later turn

        if bySearch {
            state.searchText = "y"
        } else {
            state.sortOrder = [KeyPathComparator(\.name, order: .reverse)]
        }
        let sameTurn = hosted.writers(in: table).map(promisedPath)
        #expect(sameTurn.compactMap { $0 }.allSatisfy { $0 == "y-one.txt" }, "\(sameTurn)")
        if let row = sameTurn.firstIndex(where: { $0 != nil }) {
            #expect(table.selectedRowIndexes == IndexSet([row]))
        }

        // No wait past the redraw: this assumes SwiftUI runs the anchor's updateNSView synchronously,
        // in the same update pass that redraws the outline, so once the table shows the new selected
        // row the drag source already has the new rows.
        try #require(await waitUntil { table.selectedRowIndexes == IndexSet([after]) })
        #expect(hosted.writers(in: table).map(promisedPath)
                == (0..<table.numberOfRows).map { $0 == after ? "y-one.txt" : nil })
    }

    /// SwiftUI's table lets a row drag only when the row carries a drag modifier of SwiftUI's own
    /// (its `canDragRowsWithIndexes:atPoint:`); the rows carry an empty item provider, so a drag can
    /// start on any row, selected or not, a folder or a file, and with nothing selected.
    @Test func everyRowPassesSwiftUIsDragGate() async throws {
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        try await hosted.select(["b.pdf"], in: table)  // docs, docs/a.txt, b.pdf (selected), c.png
        #expect(table.selectedRowIndexes == IndexSet([2]))
        #expect((0..<4).map { hosted.canDrag(row: $0, in: table) } == [true, true, true, true])

        hosted.document.state.selection = []
        try #require(await waitUntil { table.selectedRowIndexes.isEmpty })
        #expect((0..<4).map { hosted.canDrag(row: $0, in: table) } == [true, true, true, true])
    }

    /// A drag that starts on a row outside the selection brings that row alone, as in Finder: AppKit
    /// leaves the selection as it is and asks for that row's writer only. Its promise is that row's
    /// file in a drop of its own, never a selected row's; the selection drags as before.
    @Test func anUnselectedRowDragsAlone() async throws {
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        try await hosted.select(["b.pdf"], in: table)  // docs, docs/a.txt, b.pdf (selected), c.png
        let selectionDrag = try #require(hosted.writer(forRow: 2, in: table))
        #expect(promisedPath(selectionDrag) == "b.pdf")

        // In the same turn as the selection's drag (the cached drag rows must not leak into it). AppKit
        // asks for the clicked row's writer only: one writer, and its entry is that row's own (c.png at
        // row 3: path, promised name and type), never the selected row's (b.pdf) or a neighbour's.
        let aloneWriters = [3].compactMap { hosted.writer(forRow: $0, in: table) }
        #expect(aloneWriters.count == 1)
        let alone = try #require(aloneWriters.first as? NSFilePromiseProvider)
        #expect(promisedPath(alone) == "c.png")
        let aloneDelegate = try #require(alone.delegate)
        #expect(aloneDelegate.filePromiseProvider(alone, fileNameForType: alone.fileType) == "c.png")
        #expect(alone.fileType == "public.png")
        let drop = try #require(promisedDrop(alone))
        let other = try #require(promisedDrop(selectionDrag))
        #expect(drop.id != other.id)
        #expect(table.selectedRowIndexes == IndexSet([2]) && hosted.document.state.selection == ["b.pdf"])

        // A folder, and a file in it, each alone; and a file inside the selected folder, alone.
        try await Task.sleep(for: .milliseconds(50))  // a later drag starts in a later turn
        #expect(promisedPath(hosted.writer(forRow: 0, in: table)) == "docs")
        try await Task.sleep(for: .milliseconds(50))
        #expect(promisedPath(hosted.writer(forRow: 1, in: table)) == "docs/a.txt")
        hosted.document.state.selection = ["docs"]
        try #require(await waitUntil { table.selectedRowIndexes == IndexSet([0]) })
        try await Task.sleep(for: .milliseconds(50))
        #expect(promisedPath(hosted.writer(forRow: 1, in: table)) == "docs/a.txt")
        #expect(hosted.writers(in: table).map(promisedPath) == ["docs", nil, nil, nil])

        // Nothing selected.
        hosted.document.state.selection = []
        try #require(await waitUntil { table.selectedRowIndexes.isEmpty })
        #expect(promisedPath(hosted.writer(forRow: 3, in: table)) == "c.png")
        #expect(!hosted.actions.hasFilePromiseWork)  // a drag starts nothing until a drop lands
    }

    /// A row AppKit could name outside the table brings nothing, never a neighbour's file:
    /// row -1 (an item the outline doesn't show) and row `numberOfRows`, with a selection and without.
    @Test func aRowOutsideTheTableBringsNothing() async throws {
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        let outline = try #require(table as? NSOutlineView)
        let anchor = try #require(hosted.anchor)
        try await hosted.select(["b.pdf"], in: table)  // docs, docs/a.txt, b.pdf (selected), c.png
        for selected in [true, false] {
            if !selected {
                hosted.document.state.selection = []
                try #require(await waitUntil { table.selectedRowIndexes.isEmpty })
            }
            #expect(anchor.writer(forRow: -1, in: table) == nil)
            #expect(anchor.writer(forRow: table.numberOfRows, in: table) == nil)
            #expect(outline.row(forItem: NSObject()) == -1)
            #expect(outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: NSObject()) == nil)
        }
        #expect(!hosted.actions.hasFilePromiseWork)
    }

    /// The table gets our writer, never SwiftUI's. SwiftUI's own writer is not inert (its
    /// rows carry an item provider to pass its drag gate, and its writer offers SwiftUI's private
    /// drag-item type), so the hook must answer the table's writer message itself: for every row,
    /// selected or not, and with nothing selected, the data source the table holds hands out our file
    /// promise, never a writer that offers SwiftUI's type; a row outside the table gets nothing.
    @Test func theTableGetsOurWriterNeverSwiftUIs() async throws {
        let swiftUIsType = NSPasteboard.PasteboardType("com.apple.swiftui.private.drag-item")
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        let outline = try #require(table as? NSOutlineView)
        let dataSource = try #require(hosted.anchor?.swiftUIDataSource)
        #expect(outline.dataSource === dataSource)
        try await hosted.select(["b.pdf"], in: table)  // docs, docs/a.txt, b.pdf (selected), c.png
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        for selected in [true, false] {
            if !selected {
                hosted.document.state.selection = []
                try #require(await waitUntil { table.selectedRowIndexes.isEmpty })
            }
            for (row, path) in ["docs", "docs/a.txt", "b.pdf", "c.png"].enumerated() {
                try await Task.sleep(for: .milliseconds(50))  // each drag starts in a turn of its own
                let item = try #require(outline.item(atRow: row))
                // As AppKit asks it: the message sent to the data source the table holds.
                let source = try #require(outline.dataSource)
                let writer = try #require(source.outlineView?(outline, pasteboardWriterForItem: item),
                                          "row \(row) (selected: \(selected)) got no writer")
                let promise = try #require(writer as? NSFilePromiseProvider, "row \(row): \(type(of: writer))")
                #expect(promisedPath(promise) == path)
                #expect(!promise.writableTypes(for: board).contains(swiftUIsType), "row \(row)")
            }
            #expect(outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: NSObject()) == nil)
        }

        #if DEBUG
        // Why the hook must answer itself: SwiftUI's own writer, if it gives one, offers only its
        // private type (nothing a Finder drop could take). It does give one for these rows (the hosted
        // run showed it); none at all would leave this check empty, so count them.
        var seen = 0
        for row in 0..<table.numberOfRows {
            let item = try #require(outline.item(atRow: row))
            // As its own class answers it (the hook's call-through), the hook in.
            if let own = ArchiveTableDragHook.ownWriter(of: dataSource, outline: outline, item: item) {
                seen += 1
                #expect(Set(own.writableTypes(for: board)).isSubset(of: [swiftUIsType]),
                        "row \(row): \(type(of: own)) offers \(own.writableTypes(for: board))")
            }
        }
        #expect(seen > 0, "SwiftUI's own data source gave no writer for any row")
        #endif
        #expect(!hosted.actions.hasFilePromiseWork)
    }

    /// Before its first layout the anchor has no size and overlaps no table: it takes none (and
    /// caches none), and takes the one it overlaps once it has a size.
    @Test func anAnchorWithNoSizeTakesNoTable() async throws {
        let window = OffscreenWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        let tables = [NSRect(x: 0, y: 0, width: 200, height: 300), NSRect(x: 200, y: 0, width: 200, height: 300)]
            .map { frame in
                let scroll = NSScrollView(frame: frame)
                let table = NSTableView(frame: NSRect(origin: .zero, size: frame.size))
                scroll.documentView = table
                container.addSubview(scroll)
                return table
            }
        let dataSources = tables.map { _ in EmptyDataSource() }  // held: a table's data source is weak
        for (table, dataSource) in zip(tables, dataSources) { table.dataSource = dataSource }

        let anchor = ArchiveTableDragAnchor(frame: .zero)
        anchor.source = ArchiveTableDragSource(rows: { [] }, writer: { _, _ in nil })
        container.addSubview(anchor)
        #expect(anchor.tableView == nil && anchor.swiftUIDataSource == nil)

        anchor.frame = NSRect(x: 220, y: 0, width: 180, height: 300)
        anchor.ensureInstalled()
        #expect(anchor.tableView === tables[1])
        #expect(anchor.isHooked && tables[1].dataSource === dataSources[1])
        #expect(!ArchiveTableDragHook.isHooked(dataSources[0], by: anchor))
        #expect(isa(dataSources[0]) == ObjectIdentifier(EmptyDataSource.self))
        anchor.uninstall()
        #expect(isa(dataSources[1]) == ObjectIdentifier(EmptyDataSource.self))
    }

    /// When a new table takes the old one's place while the old one still lives (out
    /// of the window), the next look gives the old one its data source back and hooks the new one,
    /// masks included.
    @Test func aSwappedInTableGetsTheHook() async throws {
        let window = OffscreenWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        let scrolls = (0..<2).map { _ in NSScrollView(frame: container.bounds) }  // held: both live on
        let tables = scrolls.map { scroll in
            let table = NSTableView(frame: container.bounds)
            scroll.documentView = table
            return table
        }
        let dataSources = tables.map { _ in EmptyDataSource() }  // held: a table's data source is weak
        for (table, dataSource) in zip(tables, dataSources) { table.dataSource = dataSource }
        container.addSubview(scrolls[0])

        let anchor = ArchiveTableDragAnchor(frame: container.bounds)
        anchor.source = ArchiveTableDragSource(rows: { [] }, writer: { _, _ in nil })
        container.addSubview(anchor)
        anchor.ensureInstalled()
        #expect(anchor.tableView === tables[0] && anchor.isHooked)

        // The swap: the old table leaves the window (still alive here), a new one comes in.
        scrolls[0].removeFromSuperview()
        container.addSubview(scrolls[1], positioned: .below, relativeTo: anchor)
        anchor.ensureInstalled()
        #expect(anchor.tableView === tables[1] && anchor.isHooked)
        #expect(!ArchiveTableDragHook.isHooked(dataSources[0], by: anchor))
        #expect(isa(dataSources[0]) == ObjectIdentifier(EmptyDataSource.self))
        #expect(mask(of: tables[1], .withinApplication) == [.move, .copy])
        #expect(mask(of: tables[1], .outsideApplication) == .copy)
        anchor.uninstall()
        #expect(isa(dataSources[1]) == ObjectIdentifier(EmptyDataSource.self))
        #expect(tables[1].dataSource === dataSources[1])
    }

    /// When SwiftUI sets a data source the hook can't take, the one hooked before goes back as it was,
    /// also when that one was seen (and refused) before: A hooked, B refused, A again, B again.
    @Test func anUnhookableDataSourceGivesTheOldOneBack() async throws {
        let window = OffscreenWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        let scroll = NSScrollView(frame: container.bounds)
        let table = NSTableView(frame: container.bounds)
        scroll.documentView = table
        container.addSubview(scroll)
        let hookable = EmptyDataSource()  // held: a table's data source is weak
        let unhookable = WriterlessDataSource()
        table.dataSource = hookable

        let anchor = ArchiveTableDragAnchor(frame: container.bounds)
        anchor.source = ArchiveTableDragSource(rows: { [] }, writer: { _, _ in nil })
        container.addSubview(anchor)
        defer { anchor.uninstall() }
        anchor.ensureInstalled()
        #expect(anchor.isHooked)

        for round in 1...2 {
            table.dataSource = unhookable
            anchor.ensureInstalled()
            #expect(!anchor.isHooked, "round \(round)")
            #expect(!ArchiveTableDragHook.isHooked(hookable, by: anchor), "round \(round)")
            #expect(isa(hookable) == ObjectIdentifier(EmptyDataSource.self), "round \(round)")
            #expect(isa(unhookable) == ObjectIdentifier(WriterlessDataSource.self), "round \(round)")
            #expect(table.dataSource === unhookable, "round \(round)")

            table.dataSource = hookable
            anchor.ensureInstalled()
            #expect(anchor.isHooked, "round \(round)")
        }
    }

    /// A selected folder brings its selected rows: they give no promise of their own.
    @Test func aRowInsideASelectedFolderGivesNoPromise() async throws {
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        try await hosted.select(["docs", "docs/a.txt", "c.png"], in: table)

        #expect(hosted.writers(in: table).map(promisedPath) == ["docs", nil, nil, "c.png"])
    }

    /// Inside Kernir the table offers move and copy (its own table takes it as a move inside the
    /// archive, another window's table as a copy read from this window's model, neither reading the promise, so
    /// no Kernir receiver ever waits for a promise its own window's line holds); outside it copies. Kernir's other drop destinations take file URLs, and the promises carry
    /// none (checked by `MoveDragReceiverTests.noOtherViewOfTheArchiveWindowTakesPromiseOrMove`: no
    /// other view of the window registers the promise or move types).
    @Test func dropsInsideKernirMoveOrCopy() async throws {
        let hosted = try await Hosted()
        defer { hosted.end() }
        let table = try await hosted.hookedTable()
        #expect(mask(of: table, .withinApplication) == [.move, .copy])
        #expect(mask(of: table, .outsideApplication) == .copy)
        hosted.document.state.sortOrder = [KeyPathComparator(\.name, order: .reverse)]
        try await hosted.select(["b.pdf", "c.png"], in: table)
        #expect(mask(of: table, .withinApplication) == [.move, .copy])

        let writers = hosted.writers(in: table).compactMap { $0 }
        #expect(writers.count == 2)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.kernir.tests.dragOut.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects(writers))
        let types = (pasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
        #expect(types.count == 2)
        for itemTypes in types {
            // macOS 26 writes NSFilePromiseID (and no promised-file-url) outside a drag; older systems
            // the url type. Either is a promise.
            #expect(itemTypes.contains("com.apple.pasteboard.promised-file-url")
                    || itemTypes.contains("com.apple.pasteboard.NSFilePromiseID"))
            #expect(itemTypes.contains("com.apple.pasteboard.promised-file-content-type"))
        }
        // Each row also names its archive path for a move, with the window's token.
        let moves = (pasteboard.pasteboardItems ?? []).map { ArchiveFilePromiseProvider.move(on: $0) }
        #expect(moves.map { $0?.path } == ["c.png", "b.pdf"])
        #expect(moves.allSatisfy { $0?.token == hosted.actions.moveToken })
        // Beside the promise, each file row offers its extracted file (`ArchiveDragOutFiles`), for
        // receivers that don't take promises.
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        #expect(urls.map(\.lastPathComponent) == ["c.png", "b.pdf"])
        // In the host's own folders (deleted by `end`), not the app's.
        #expect(hosted.dragOutFolders.registered.count == 1)
        #expect(!hosted.actions.hasFilePromiseWork)
    }

    /// End to end without Finder: the hook's promises for one and for two selected rows are fulfilled
    /// as AppKit fulfils a drop (writePromiseTo on the delegate's own queue, at <drop folder>/<promised
    /// name>), and the files land with the archive's bytes, each completion called once, nothing
    /// hidden left behind.
    @Test(arguments: [["b.pdf"], ["docs/a.txt", "b.pdf"]])
    func thePromisesLandTheRowsFiles(selection: [String]) async throws {
        try await PresentedErrors.expectingNone {
            let hosted = try await Hosted()
            defer { hosted.end() }
            let table = try await hosted.hookedTable()
            try await hosted.select(Set(selection), in: table)
            let providers = hosted.writers(in: table).compactMap { $0 as? NSFilePromiseProvider }
            #expect(providers.compactMap(promisedPath) == selection)

            let drop = try freshFolder()
            defer { try? FileManager.default.removeItem(at: drop) }
            let completions = Completions()
            for provider in providers {
                let delegate = try #require(provider.delegate)
                let name = delegate.filePromiseProvider(provider, fileNameForType: provider.fileType)
                let target = drop.appendingPathComponent(name)
                let call = OnQueue(provider: provider, delegate: delegate)
                try #require(delegate.operationQueue?(for: call.provider)).addOperation {
                    call.delegate.filePromiseProvider(call.provider, writePromiseTo: target) { error in
                        completions.record(name, error)
                    }
                }
            }
            #expect(await waitUntil(10) { completions.count >= providers.count })
            try await Task.sleep(for: .milliseconds(300))  // a second completion would show here

            let names = selection.map { ArchiveEntry.components(of: $0).last ?? $0 }
            #expect(completions.all == Dictionary(uniqueKeysWithValues: names.map { ($0, ["nil"]) }))
            #expect(try FileManager.default.contentsOfDirectory(atPath: drop.path).sorted() == names.sorted())
            for (name, path) in zip(names, selection) {
                // LegacyZip stores each file's own path as its contents.
                #expect((try? Data(contentsOf: drop.appendingPathComponent(name))) == Data(path.utf8))
            }
            #expect(await waitUntil { !hosted.actions.hasFilePromiseWork && hosted.document.state.progress == nil })
        }
    }
}
