import AppKit
import SwiftUI
import Testing
@testable import Kernir
import KernirCore

// Regression tests for the drag-out hook (`ArchiveTableDragSource`) against the table's other
// behaviour: with an earlier hook (a forwarder set as the table's data source) a right-click on a row
// showed no context menu and a Finder file dropped on the window was not added. What guards what:
// - the context menu: `aRightClickOnARowGetsTheContextMenu` (the window's table) and
//   `aBareTableGetsItsMenuAndDrop` (a bare Table, with and without the rows' drag gate);
// - SwiftUI's own data source object stays the table's (a Swift cast or identity check on it still
//   finds SwiftUI's coordinator) and the registered drop types stay:
//   `theTableKeepsSwiftUIsDataSourceAndDropTypes`;
// - no install churn through selection, sort and folder updates: `theHookGoesInOnceThroughUpdates`;
// - the data source still validates a Finder file, and the app's drop handler adds it:
//   `theDataSourceTakesAFinderFile`, `aFolderRowValidatesAFinderFileAndTheAppsHandlerAddsIt`;
// - a Finder file over the table itself, between or below rows, or on a file row goes to the top
//   level, and a drag from inside Kernir doesn't (root drop): `aFinderFileOverTheTableIsValidatedForTheTopLevel`,
//   `aFinderFileDroppedOnTheTableIsAddedAtTheTopLevel`, `aDragFromInsideKernirIsNotTakenForTheTopLevel`,
//   `theDropTargetOfAProposal`.
// Evidence (run 2026-11-14 on a test Mac, with the forwarder hook, before the in-place hook): the menu test, the data source
// test and the bare-table probe went red in hooked mode; the data-source drop tests stayed green
// there, so they don't guard the real Finder drop (SwiftUI's accept, which no test may call with a
// fake drag: it traps the host). That one is covered by a manual check on a real Mac.
// Each test runs with the hook in, with it taken out (control) and, in DEBUG builds, with only its
// swap skipped (`ArchiveTableDragAnchor.swapSkippedWindow`). Lines tagged "[table-drag]" are the
// details to grep for in the run's log. Hosted (AppKit, SwiftUI) run only.

/// How a test has the hook.
enum DragHookMode: String, CaseIterable, Sendable {
    /// As the app has it.
    case hooked
    /// Put in, then taken out as the view's dismantling does (control).
    case removed
    /// The anchor does everything but the swap (a DEBUG-only seam).
    case swapSkipped

    /// The modes a test build can set up: `swapSkipped` needs the DEBUG seam.
    static var testable: [DragHookMode] {
        #if DEBUG
        allCases
        #else
        allCases.filter { $0 != .swapSkipped }
        #endif
    }
}

/// The window's table, as `ArchiveTableDragSourceTests` hosts it.
private struct RegressionTable: View {
    let state: ArchiveWindowState
    let model: ArchiveModel
    let actions: ArchiveActions

    var body: some View {
        ArchiveTableView(items: state.tableItems(of: model), state: state, actions: actions)
    }
}

/// A window held offscreen (AppKit keeps a titled window on a screen unless told not to).
private final class RegressionWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// An item of `ProbeTable`.
private struct ProbeItem: Identifiable, Hashable {
    let id: String
}

/// A bare Table with a context menu and a drop destination, with or without the rows' empty item
/// provider (the drag gate) and the drag-out hook, apart from Kernir's view.
private struct ProbeTable: View {
    let gate: Bool
    let hook: Bool
    @State var selection = Set<String>()
    let items = ["docs", "b.pdf", "c.png"].map(ProbeItem.init)

    var body: some View {
        Table(of: ProbeItem.self, selection: $selection) {
            TableColumn("Name") { item in Text(item.id) }
        } rows: {
            ForEach(items) { item in
                if gate {
                    TableRow(item).itemProvider { NSItemProvider() }
                } else {
                    TableRow(item)
                }
            }
        }
        .background {
            if hook { ArchiveTableDragSource(rows: { [] }, writer: { _, _ in nil }) }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty { Button("Probe Open") {} }
        }
        .dropDestination(for: URL.self) { _, _ in true }
    }
}

/// The archive window's table over a zip with a folder and two files (or `entries`), hosted offscreen. Also
/// hosts `ArchiveTableMoveTests`.
@MainActor
final class RegressionHosted {
    let zip: URL
    let model: ArchiveModel
    let document: ArchiveDocument
    let actions: ArchiveActions
    let window: NSWindow
    /// The drags' plain-file folders (`ArchiveDragOutFiles`), this host's own: `end` deletes them.
    let dragOutFolders: ArchiveDragOutFolders

    init(_ mode: DragHookMode, entries: [String] = ["docs/", "docs/a.txt", "b.pdf", "c.png"]) async throws {
        let zip = try LegacyZip.write(entries, as: .utf8)
        let model = ArchiveModel(reader: try await Archive.open(at: zip), undoManager: nil)
        let document = try ArchiveDocument(type: "public.zip-archive")
        document.state.model = model
        let actions = ArchiveActions(document: document)
        let dragOutFolders = ArchiveDragOutFolders()
        actions.makeDragOutFiles = { [dragOutFolders] reader in ArchiveDragOutFiles(reader: reader, folders: dragOutFolders) }
        let window = RegressionWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 600, height: 400),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        #if DEBUG
        if mode == .swapSkipped { ArchiveTableDragAnchor.swapSkippedWindow = window }
        #endif
        window.contentView = NSHostingView(rootView: RegressionTable(state: document.state, model: model,
                                                                     actions: actions))
        window.orderFrontRegardless()
        self.zip = zip
        self.model = model
        self.document = document
        self.actions = actions
        self.window = window
        self.dragOutFolders = dragOutFolders
    }

    func end() {
        window.orderOut(nil)
        window.contentView = nil
        model.removeTemporaryFiles()
        dragOutFolders.removeAll()
        try? FileManager.default.removeItem(at: zip.deletingLastPathComponent())
    }

    var anchor: ArchiveTableDragAnchor? { findAnchor(in: window.contentView) }

    /// The Table's table view with the hook as `mode` has it (the folder closed: docs, b.pdf, c.png),
    /// and SwiftUI's own data source as the hook found it.
    func table(_ mode: DragHookMode) async throws -> (table: NSTableView, swiftUIs: AnyObject?) {
        // The anchor found the table and SwiftUI's data source (it set the hook unless skipped).
        try #require(await waitFor { self.anchor?.tableView != nil && self.anchor?.swiftUIDataSource != nil },
                     "the anchor never put its hook in")
        let anchor = try #require(anchor)
        let table = try #require(anchor.tableView)
        try #require(await waitFor { table.numberOfRows == 3 })
        let swiftUIs = anchor.swiftUIDataSource
        describe(table, anchor: anchor, swiftUIs: swiftUIs, "\(mode.rawValue), set up")
        switch mode {
        case .hooked:
            try #require(anchor.isHooked)
        case .removed:
            anchor.source = nil  // as `dismantleNSView`: no later turn puts it back
            anchor.uninstall()
            try #require(!anchor.isHooked)
            #expect(table.dataSource === swiftUIs)
        case .swapSkipped:
            try #require(!anchor.isHooked)
            #expect(table.dataSource === swiftUIs)
        }
        return (table, swiftUIs)
    }
}

@MainActor
func findAnchor(in view: NSView?) -> ArchiveTableDragAnchor? {
    guard let view else { return nil }
    if let anchor = view as? ArchiveTableDragAnchor { return anchor }
    for subview in view.subviews { if let found = findAnchor(in: subview) { return found } }
    return nil
}

/// Polls for at most `seconds` while the main run loop turns (SwiftUI updates, the hook's turns).
@MainActor
func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

/// The runtime class (the isa, not `-class`) of `object`.
private func isaName(_ object: Any?) -> String {
    object_getClass(object).map(NSStringFromClass) ?? "nil"
}

/// Logs what the table holds: its class, its data source and delegate against SwiftUI's own data
/// source, the hook's state and installs (DEBUG), its menu, and its registered drag types.
@MainActor
private func describe(_ table: NSTableView, anchor: ArchiveTableDragAnchor?, swiftUIs: AnyObject?, _ label: String) {
    let source = table.dataSource as AnyObject?
    let delegate = table.delegate as AnyObject?
    #if DEBUG
    let installs = anchor?.installs ?? -1
    #else
    let installs = -1
    #endif
    print("[table-drag] \(label): table \(isaName(table)), dataSource \(isaName(source)), "
          + "delegate \(isaName(delegate)), SwiftUI's \(isaName(swiftUIs)), "
          + "dataSource===SwiftUI's \(source === swiftUIs), delegate===SwiftUI's \(delegate === swiftUIs), "
          + "hooked \(anchor?.isHooked ?? false), installs \(installs), "
          + "table.menu \(isaName(table.menu)) delegate \(isaName(table.menu?.delegate)), "
          + "registered \(table.registeredDraggedTypes.map(\.rawValue).sorted())")
}

/// What a right-click on `row` gets, as AppKit asks for it: the menu of the view under the mouse, else
/// of its ancestors in turn (a view without one passes the click up); and the table's own answer.
@MainActor
private func rightClickMenu(row: Int, in table: NSTableView) throws -> (menu: NSMenu?, from: String, table: NSMenu?) {
    let window = try #require(table.window)
    let rect = table.rect(ofRow: row)
    let location = table.convert(NSPoint(x: rect.minX + 30, y: rect.midY), to: nil)
    let event = try #require(NSEvent.mouseEvent(
        with: .rightMouseDown, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1))
    let tableMenu = table.menu(for: event)
    var view = window.contentView?.superview?.hitTest(location) ?? window.contentView?.hitTest(location)
    while let current = view {
        if let menu = current.menu(for: event) { return (menu, isaName(current), tableMenu) }
        view = current.superview
    }
    return (nil, "none", tableMenu)
}

/// The menu's item titles once its delegate has filled it, as AppKit has it do before showing it.
@MainActor
private func titles(of menu: NSMenu?) -> [String] {
    guard let menu else { return [] }
    menu.delegate?.menuNeedsUpdate?(menu)
    return menu.items.map(\.title)
}

/// A drag from another app (Finder) carrying one file URL (or `writers`), over a point of the window, without a
/// real drag session.
@MainActor
final class FakeDrop: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let location: NSPoint
    weak var window: NSWindow?

    /// The drag's source in this app (nil: another app's, as Finder's).
    let source: AnyObject?
    /// The source's operation mask; a test changes it as Option held mid-drag does.
    var mask: NSDragOperation
    /// This drag's own sequence number, as AppKit gives each drag session one (the hook caches a move per
    /// drag by it), unless a test gives one.
    let sequence: Int
    private static var lastSequence = 3_003

    convenience init(url: URL, location: NSPoint, window: NSWindow?, source: AnyObject? = nil,
                     mask: NSDragOperation = [.copy, .link, .generic, .move]) {
        self.init(writers: [url as NSURL], location: location, window: window, source: source, mask: mask)
    }

    init(writers: [any NSPasteboardWriting], location: NSPoint, window: NSWindow?, source: AnyObject? = nil,
         mask: NSDragOperation = [.copy, .link, .generic, .move], sequence: Int? = nil) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("com.kernir.tests.dt.drop.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(writers)
        self.location = location
        self.window = window
        self.source = source
        self.mask = mask
        if let sequence {
            self.sequence = sequence
        } else {
            Self.lastSequence += 1
            self.sequence = Self.lastSequence
        }
    }

    func end() { pasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }  // nil: another app's drag
    var draggingSequenceNumber: Int { sequence }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    // NSObject already declares this (AppKit's deprecated NSDraggingSourceDeprecated category).
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let objects = pasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        var stop = ObjCBool(false)
        for (index, object) in objects.enumerated() {
            guard let writer = object as? any NSPasteboardWriting else { continue }
            block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
            if stop.boolValue { break }
        }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// A new file of this test's own, in a new folder in the temporary directory; the caller removes
/// the folder.
private func droppedFile() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveTableDragRegressionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let file = folder.appendingPathComponent("dropped-dt.txt")
    try Data("dt".utf8).write(to: file)
    return file
}

/// The fake drop over the middle of `row` (or, for nil, just below the last row).
@MainActor
private func fakeDrop(of url: URL, overRow row: Int?, in table: NSTableView, source: AnyObject? = nil,
                      mask: NSDragOperation = [.copy, .link, .generic, .move]) -> FakeDrop {
    let point: NSPoint
    if let row {
        let rect = table.rect(ofRow: row)
        point = NSPoint(x: rect.minX + 30, y: rect.midY)
    } else {
        let last = table.rect(ofRow: table.numberOfRows - 1)
        point = NSPoint(x: last.minX + 30, y: table.isFlipped ? last.maxY + 4 : last.minY - 4)
    }
    return FakeDrop(url: url, location: table.convert(point, to: nil), window: table.window, source: source,
                    mask: mask)
}

/// Whether the accept message of `table`'s data source is the hook's own, not its original class's
/// (SwiftUI's, which traps the host with a fake drag): a test calls accept only when it is, so a hook
/// that bailed out fails the test instead of the host.
@MainActor
func theHookAnswersAccept(_ table: NSTableView) -> Bool {
    let accept = #selector(NSOutlineViewDataSource.outlineView(_:acceptDrop:item:childIndex:))
    guard let dataSource = table.dataSource, let hook: AnyClass = object_getClass(dataSource),
          NSStringFromClass(hook).hasPrefix("KernirTableDragHook_"), let original = class_getSuperclass(hook),
          let hooks = class_getInstanceMethod(hook, accept), let own = class_getInstanceMethod(original, accept)
    else { return false }
    return method_getImplementation(hooks) != method_getImplementation(own)
}

/// What the table's data source answers, as AppKit asks it while a Finder file is dragged over the
/// table: on the whole table, between the first two rows, on the file row b.pdf (row 1), and on the
/// folder row docs (row 0). SwiftUI's coordinator takes a drop only on a row with a drop destination
/// of its own (`canDropOn`; here only folder rows) or an insert where rows have an insert handler
/// (none here): it refuses the whole table outright (root item) and turns a drop on a file row into an
/// insert after it, so of these only docs can be accepted.
@MainActor
private func dataSourceAnswers(_ drop: FakeDrop, table: NSTableView) -> [UInt?] {
    guard let outline = table as? NSOutlineView else {
        return [(-1, NSTableView.DropOperation.on), (1, .above), (1, .on)].map { proposal in
            table.dataSource?.tableView?(table, validateDrop: drop, proposedRow: proposal.0,
                                         proposedDropOperation: proposal.1).rawValue
        }
    }
    let proposals: [(Any?, Int)] = [(nil, NSOutlineViewDropOnItemIndex), (nil, 1),
                                    (outline.item(atRow: 1), NSOutlineViewDropOnItemIndex),
                                    (outline.item(atRow: 0), NSOutlineViewDropOnItemIndex)]
    return proposals.map { proposal in
        outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: proposal.0,
                                         proposedChildIndex: proposal.1).rawValue
    }
}

private func accepts(_ answers: [UInt?]) -> Bool {
    answers.contains { ($0 ?? 0) != 0 }
}

@Suite(.serialized) @MainActor
struct ArchiveTableDragRegressionTests {
    /// A right-click on row 0 (the folder docs) gets the context menu, with its items, with the hook
    /// in as without it. Red in hooked mode on the forwarder hook (2026-11-14).
    @Test(arguments: DragHookMode.testable)
    func aRightClickOnARowGetsTheContextMenu(mode: DragHookMode) async throws {
        let hosted = try await RegressionHosted(mode)
        defer { hosted.end() }
        let (table, swiftUIs) = try await hosted.table(mode)
        let probe = try rightClickMenu(row: 0, in: table)
        let items = titles(of: probe.menu)
        print("[table-drag] menu \(mode.rawValue): from \(probe.from), table.menu(for:) \(isaName(probe.table)) "
              + "\(titles(of: probe.table)), items \(items)")
        describe(table, anchor: hosted.anchor, swiftUIs: swiftUIs, "\(mode.rawValue), after the right-click")
        #expect(probe.menu != nil, "no menu for a right-click (\(mode.rawValue))")
        #expect(items.contains("Open") && items.contains("Delete"), "\(mode.rawValue): \(items)")
    }

    /// The table keeps SwiftUI's own data source object (a Swift cast or identity check on it still
    /// finds SwiftUI's coordinator), and its registered drag types take file URLs and don't change when
    /// the hook comes out. Red in hooked mode on the forwarder hook (2026-11-14): its forwarder stood in.
    /// The hosting view's types are only printed here; that no view of the window but the table takes the
    /// promise or move types is `MoveDragReceiverTests.noOtherViewOfTheArchiveWindowTakesPromiseOrMove`.
    @Test(arguments: DragHookMode.testable)
    func theTableKeepsSwiftUIsDataSourceAndDropTypes(mode: DragHookMode) async throws {
        let hosted = try await RegressionHosted(mode)
        defer { hosted.end() }
        let (table, swiftUIs) = try await hosted.table(mode)
        let registered = Set(table.registeredDraggedTypes)
        print("[table-drag] types \(mode.rawValue): table \(registered.map(\.rawValue).sorted()), hosting view "
              + "\((hosted.window.contentView?.registeredDraggedTypes ?? []).map(\.rawValue).sorted())")
        #expect(swiftUIs != nil)
        #expect(table.dataSource === swiftUIs, "\(mode.rawValue): the table's data source is \(isaName(table.dataSource))")
        #expect(!registered.isDisjoint(with: [.fileURL, .URL]), "\(mode.rawValue): \(registered)")

        if mode == .hooked, let anchor = hosted.anchor {
            anchor.source = nil
            anchor.uninstall()
            describe(table, anchor: anchor, swiftUIs: swiftUIs, "hooked, then removed")
            #expect(Set(table.registeredDraggedTypes) == registered)
        }
    }

    /// A Finder file dragged over the table is accepted by the data source the table holds, as AppKit
    /// asks it, with the hook in as without it. Green on the forwarder hook too: it doesn't guard the real
    /// Finder drop (SwiftUI's accept; a manual real-Mac check covers it).
    @Test(arguments: DragHookMode.testable)
    func theDataSourceTakesAFinderFile(mode: DragHookMode) async throws {
        let hosted = try await RegressionHosted(mode)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(mode)
        let file = try droppedFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let drop = fakeDrop(of: file, overRow: 0, in: table)
        defer { drop.end() }
        let answers = dataSourceAnswers(drop, table: table)
        print("[table-drag] drop (data source) \(mode.rawValue): \(answers)")
        #expect(accepts(answers), "\(mode.rawValue): \(answers)")
    }

    /// The data source the table holds validates a Finder file on the folder row docs; the app's own
    /// handler for that drop (`ArchiveActions.addDropped`, what the row's drop destination calls) then
    /// adds it, a row for it showing in the opened folder. The test calls that handler itself: it never
    /// calls SwiftUI's acceptDrop with the fake drag, which traps the host (EXC_BREAKPOINT, a "quit
    /// unexpectedly" dialog), even validated. So the step from validate to the handler is not covered
    /// here (a manual real-Mac check covers it).
    @Test(arguments: DragHookMode.testable)
    func aFolderRowValidatesAFinderFileAndTheAppsHandlerAddsIt(mode: DragHookMode) async throws {
        let hosted = try await RegressionHosted(mode)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(mode)
        let outline = try #require(table as? NSOutlineView)
        let file = try droppedFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let drop = fakeDrop(of: file, overRow: 0, in: table)
        defer { drop.end() }
        let docs = outline.item(atRow: 0)
        let validated = outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: docs,
                                                         proposedChildIndex: NSOutlineViewDropOnItemIndex)
        guard let validated, validated != [] else {
            print("[table-drag] drop (handler) \(mode.rawValue): validate \(validated?.rawValue as Any), handler not called")
            Issue.record("\(mode.rawValue): validateDrop refused the drop on docs (\(validated?.rawValue as Any))")
            return
        }
        // The add is a pending edit, made before `addDropped` returns: no job runs on after it (none
        // could still touch the zip when `end()` removes it).
        let accepted = hosted.actions.addDropped([file], to: "docs")
        #expect(hosted.model.hasChanges && hosted.document.state.progress == nil, "\(mode.rawValue)")
        hosted.document.state.expanded.insert("docs")  // docs, a.txt, dropped-dt.txt, b.pdf, c.png
        let added = await waitFor { table.numberOfRows == 5 }
        print("[table-drag] drop (handler) \(mode.rawValue): validate \(validated.rawValue), handler "
              + "\(accepted), added \(added), canAdd \(hosted.actions.canAdd)")
        #expect(accepted && added, "\(mode.rawValue)")
    }

    /// A Finder file over the table itself, between rows, below the last row or on the file row b.pdf
    /// is validated for the top level by the data source the table holds, as AppKit asks it (root
    /// drop: only a folder row took a Finder file). Hooked only: SwiftUI's own
    /// coordinator refuses these (the control modes log its answers), and nothing else in the table
    /// takes them, as the table, not the hosting view, is the drag's destination once a folder row
    /// has a drop destination. The drop on the folder row docs keeps SwiftUI's own answer.
    @Test(arguments: DragHookMode.testable)
    func aFinderFileOverTheTableIsValidatedForTheTopLevel(mode: DragHookMode) async throws {
        let hosted = try await RegressionHosted(mode)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(mode)
        let outline = try #require(table as? NSOutlineView)
        let file = try droppedFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let drop = fakeDrop(of: file, overRow: nil, in: table)
        defer { drop.end() }
        let proposals: [(label: String, item: Any?, index: Int)] = [
            ("on the table", nil, NSOutlineViewDropOnItemIndex), ("between rows 0 and 1", nil, 1),
            ("below the rows", nil, 3), ("on b.pdf", outline.item(atRow: 1), NSOutlineViewDropOnItemIndex),
        ]
        for proposal in proposals {
            let answer = outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: proposal.item,
                                                          proposedChildIndex: proposal.index)
            print("[table-drag] root drop (validate) \(mode.rawValue), \(proposal.label): \(answer?.rawValue as Any)")
            if mode == .hooked { #expect(answer == .copy, "\(proposal.label): \(answer?.rawValue as Any)") }
        }
        let docs = outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: outline.item(atRow: 0),
                                                    proposedChildIndex: NSOutlineViewDropOnItemIndex)
        #expect((docs ?? []) != [], "\(mode.rawValue): the folder row docs refused (\(docs?.rawValue as Any))")
    }

    /// The data source the table holds accepts a Finder file AppKit drops on the table (item nil, the
    /// drop a validate above retargets to, or an insert at the top level) and adds it at the top
    /// level: its row shows beside docs, b.pdf and c.png. The accept is the hook's own (SwiftUI's,
    /// which traps the host with a fake drag, is never called): the test calls it only once the
    /// hook's validate took the drop, so a hook that doesn't take it fails here, not in the host.
    @Test(arguments: [NSOutlineViewDropOnItemIndex, 1, 3])
    func aFinderFileDroppedOnTheTableIsAddedAtTheTopLevel(childIndex: Int) async throws {
        let hosted = try await RegressionHosted(.hooked)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(.hooked)
        let outline = try #require(table as? NSOutlineView)
        let file = try droppedFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let drop = fakeDrop(of: file, overRow: nil, in: table)
        defer { drop.end() }
        let validated = outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: nil,
                                                         proposedChildIndex: childIndex)
        guard validated == .copy, try #require(hosted.anchor).isHooked, theHookAnswersAccept(table) else {
            Issue.record("\(childIndex): the table refused the drop (\(validated?.rawValue as Any)); accept not called")
            return
        }
        let accepted = outline.dataSource?.outlineView?(outline, acceptDrop: drop, item: nil, childIndex: childIndex)
        // A pending edit, made before the accept returns: no job runs on after it.
        #expect(hosted.model.hasChanges && hosted.document.state.progress == nil)
        let added = await waitFor { table.numberOfRows == 4 }  // docs (closed), b.pdf, c.png, dropped-dt.txt
        let levels = (0..<table.numberOfRows).map { outline.level(forRow: $0) }
        print("[table-drag] root drop (accept) \(childIndex): accepted \(accepted as Any), added \(added), levels \(levels)")
        #expect(accepted == true && added && levels == [0, 0, 0, 0], "\(childIndex)")
    }

    /// A drag from inside Kernir (a source in this app) over the table is not taken for the top level:
    /// the root drop is Finder's only, and in-window moves are left as they were.
    @Test func aDragFromInsideKernirIsNotTakenForTheTopLevel() async throws {
        let hosted = try await RegressionHosted(.hooked)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(.hooked)
        let outline = try #require(table as? NSOutlineView)
        let file = try droppedFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let drop = fakeDrop(of: file, overRow: nil, in: table, source: table)
        defer { drop.end() }
        for index in [NSOutlineViewDropOnItemIndex, 1] {
            let answer = outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: nil,
                                                          proposedChildIndex: index)
            #expect((answer ?? []) == [], "\(index): \(answer?.rawValue as Any)")
        }
        try #require(theHookAnswersAccept(table), "SwiftUI's accept would get the fake drag; not called")
        let accepted = outline.dataSource?.outlineView?(outline, acceptDrop: drop, item: nil,
                                                        childIndex: NSOutlineViewDropOnItemIndex)
        #expect(accepted == false && !hosted.model.hasChanges)
    }

    /// While files can't be added (here a job runs: `ArchiveActions.canAdd` is false), a Finder file
    /// over the table is refused at the top level: validate answers none and accept adds nothing.
    @Test func aFinderFileIsRefusedAtTheTopLevelWhileFilesCantBeAdded() async throws {
        let hosted = try await RegressionHosted(.hooked)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(.hooked)
        let outline = try #require(table as? NSOutlineView)
        let file = try droppedFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let drop = fakeDrop(of: file, overRow: nil, in: table)
        defer { drop.end() }
        hosted.document.state.progress = OperationProgress(title: "Saving", fraction: nil)
        defer { hosted.document.state.progress = nil }
        try #require(!hosted.actions.canAdd)
        for index in [NSOutlineViewDropOnItemIndex, 1] {
            let answer = outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: nil,
                                                          proposedChildIndex: index)
            #expect((answer ?? []) == [], "\(index): \(answer?.rawValue as Any)")
        }
        let onFile = outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: outline.item(atRow: 1),
                                                      proposedChildIndex: NSOutlineViewDropOnItemIndex)
        #expect((onFile ?? []) == [], "on b.pdf: \(onFile?.rawValue as Any)")
        try #require(theHookAnswersAccept(table), "SwiftUI's accept would get the fake drag; not called")
        let accepted = outline.dataSource?.outlineView?(outline, acceptDrop: drop, item: nil,
                                                        childIndex: NSOutlineViewDropOnItemIndex)
        #expect(accepted == false && !hosted.model.hasChanges)
    }

    /// A Finder drag whose operation mask lacks copy (held to move or link only) is refused at the top
    /// level, not turned into a copy: validate answers none and accept adds nothing.
    @Test func aFinderDragWithoutCopyIsRefusedAtTheTopLevel() async throws {
        let hosted = try await RegressionHosted(.hooked)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(.hooked)
        let outline = try #require(table as? NSOutlineView)
        let file = try droppedFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let drop = fakeDrop(of: file, overRow: nil, in: table, mask: [.move, .link, .generic])
        defer { drop.end() }
        try #require(hosted.actions.canAdd)
        for index in [NSOutlineViewDropOnItemIndex, 1] {
            let answer = outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: nil,
                                                          proposedChildIndex: index)
            #expect((answer ?? []) == [], "\(index): \(answer?.rawValue as Any)")
        }
        try #require(theHookAnswersAccept(table), "SwiftUI's accept would get the fake drag; not called")
        let accepted = outline.dataSource?.outlineView?(outline, acceptDrop: drop, item: nil,
                                                        childIndex: NSOutlineViewDropOnItemIndex)
        #expect(accepted == false && !hosted.model.hasChanges)
    }

    /// Where the hook sends a drop: the top level ("") for the table itself and a row whose own drop
    /// destination doesn't take it; nil (the row's own destination) for one that does.
    @Test func theDropTargetOfAProposal() {
        #expect(ArchiveTableDropTarget.directory(proposedItem: nil, rowTakesIt: false) == "")
        #expect(ArchiveTableDropTarget.directory(proposedItem: nil, rowTakesIt: true) == "")
        #expect(ArchiveTableDropTarget.directory(proposedItem: NSObject(), rowTakesIt: false) == "")
        #expect(ArchiveTableDropTarget.directory(proposedItem: NSObject(), rowTakesIt: true) == nil)
    }

    #if DEBUG
    /// How often the hook goes in again while the table updates: ten selection changes, two sort
    /// flips, a folder opened and closed. One install when SwiftUI never sets its data source again;
    /// more is churn (each forwarder install set the table's data source). DEBUG: it counts `installs`.
    @Test func theHookGoesInOnceThroughUpdates() async throws {
        let hosted = try await RegressionHosted(.hooked)
        defer { hosted.end() }
        let (table, swiftUIs) = try await hosted.table(.hooked)
        let anchor = try #require(hosted.anchor)
        let before = anchor.installs
        let paths = ["docs", "b.pdf", "c.png"]
        for index in 0..<10 {
            hosted.document.state.selection = [paths[index % paths.count]]
            _ = await waitFor(1) { table.selectedRowIndexes == IndexSet([index % paths.count]) }
        }
        for order in [SortOrder.reverse, .forward] {
            hosted.document.state.sortOrder = [KeyPathComparator(\.name, order: order)]
            try await Task.sleep(for: .milliseconds(100))
        }
        hosted.document.state.expanded.insert("docs")
        _ = await waitFor { table.numberOfRows == 4 }
        hosted.document.state.expanded.remove("docs")
        _ = await waitFor { table.numberOfRows == 3 }
        try await Task.sleep(for: .milliseconds(200))  // the hook's next turn
        print("[table-drag] installs: \(before) after setup, \(anchor.installs) after the updates")
        describe(table, anchor: anchor, swiftUIs: swiftUIs, "hooked, after the updates")
        #expect(anchor.installs == before, "the hook went in \(anchor.installs - before) more times")
        #expect(anchor.isHooked)
    }
    #endif
}

/// The same right-click and drag on a bare Table, with and without the rows' empty item provider (the
/// drag gate) and the hook: its menu comes with each. Red in hooked mode on the forwarder hook (2026-11-14).
@Suite(.serialized) @MainActor
struct ArchiveTableDragGateProbeTests {
    @Test(arguments: [false, true], [false, true])
    func aBareTableGetsItsMenuAndDrop(gate: Bool, hook: Bool) async throws {
        let window = RegressionWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ProbeTable(gate: gate, hook: hook))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        try #require(await waitFor {
            guard let root = window.contentView else { return false }
            return ArchiveTableDragAnchor.tableViews(under: root).first?.numberOfRows == 3
        })
        let table = try #require(window.contentView.flatMap { ArchiveTableDragAnchor.tableViews(under: $0).first })
        if hook {
            try #require(await waitFor { findAnchor(in: window.contentView)?.isHooked == true })
        }
        let label = "probe gate \(gate) hook \(hook)"
        describe(table, anchor: findAnchor(in: window.contentView), swiftUIs: nil, label)

        let probe = try rightClickMenu(row: 0, in: table)
        let items = titles(of: probe.menu)
        print("[table-drag] \(label): menu from \(probe.from), items \(items)")
        #expect(items.contains("Probe Open"), "\(label): \(items)")

        let file = try droppedFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let drop = fakeDrop(of: file, overRow: 1, in: table)
        defer { drop.end() }
        let answers = dataSourceAnswers(drop, table: table)
        // Logged only: the bare table's drop destination is view level, not a row's, so its table
        // registers no drag types and SwiftUI's coordinator refuses every proposal by design.
        print("[table-drag] \(label): drop (data source) \(answers)")
    }
}
