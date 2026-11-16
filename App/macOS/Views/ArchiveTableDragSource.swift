import AppKit
import os
import SwiftUI

/// Rows drag out of the archive table as file promises: this view, in the Table's background, finds
/// the Table's own AppKit table view (an NSOutlineView for a Table with DisclosureTableRow) and has
/// SwiftUI's own data source object answer AppKit's row-writer message (`ArchiveTableDragHook`), so
/// AppKit's row drag gets one file promise per dragged row. SwiftUI's own `.draggable` can only hand over a file once it
/// exists; a promise lets Finder name the drop and ask for the file when it lands.
///
/// Inside Lutik a drag moves or copies (the table's local drag operations are move and copy): rows dropped
/// on a folder row, on the table itself or on a file row of their own window move inside the archive (the
/// private `ArchiveFilePromiseProvider.moveType` names them, with the window's token), and rows from another
/// Lutik window are copied in (`ArchiveActions.copyIn`: that window's archive extracts them, this one adds
/// them); the hook decides every drag carrying that type, and refuses an Option-drag inside a window or rows
/// of two windows. No drop inside Lutik reads the promise: a receiver in a Lutik window waiting for a
/// promise that waits for that same window could deadlock (`QueuedOperations`). Elsewhere a drag copies.
///
/// The hook also takes Finder files dropped on the table itself (on it, between rows, below them) or
/// on a row that has no drop destination of its own (a file row), for the top level
/// (`ArchiveTableDropTarget`): once a folder row has a drop destination, the table, not the hosting
/// view, is the drag's destination, and SwiftUI's own coordinator refuses those proposals, so the
/// Table's own `.dropDestination` never saw them. A folder row's drop stays SwiftUI's.
struct ArchiveTableDragSource: NSViewRepresentable {
    /// The table's rows top to bottom, from the items the Table was handed
    /// (`ArchiveTableDragSelection.rows(of:expanded:)`).
    let rows: @MainActor () -> [ArchiveTableDragSelection.Row]
    /// The pasteboard writer for one dragged path, tagged with the drag's drop id (one per drag
    /// session, shared by its rows); nil leaves that row out of the drag.
    let writer: @MainActor (String, UUID) -> (any NSPasteboardWriting)?
    /// Whether files can be added now (`ArchiveActions.canAdd`).
    var canDrop: @MainActor () -> Bool = { false }
    /// Adds files dropped from Finder to the archive folder at the path ("" the top level); whether it
    /// added them (`ArchiveActions.addDropped`).
    var drop: @MainActor ([URL], String) -> Bool = { _, _ in false }
    /// The window's move token (`ArchiveActions.moveToken`): a move drop is taken only with it; nil takes none.
    var moveToken: String?
    /// Whether the archive path is a folder (`ArchiveActions.isFolder`).
    var isFolder: @MainActor (String) -> Bool = { _ in false }
    /// Whether the paths can move into the folder ("" the top level) now (`ArchiveActions.canMove`).
    var canMove: @MainActor ([String], String) -> Bool = { _, _ in false }
    /// Moves the paths into the folder; whether it took them (`ArchiveActions.move`).
    var move: @MainActor ([String], String) -> Bool = { _, _ in false }
    /// Whether the paths of the window with the move token can be copied into the folder now
    /// (`ArchiveActions.canCopyIn(_:fromMoveToken:into:)`): rows dragged from another Lutik window.
    var canCopyIn: @MainActor (_ paths: [String], _ token: String, _ folder: String) -> Bool = { _, _, _ in false }
    /// Starts copying them in; whether it started (`ArchiveActions.copyIn(_:fromMoveToken:into:)`).
    var copyIn: @MainActor (_ paths: [String], _ token: String, _ folder: String) -> Bool = { _, _, _ in false }

    func makeNSView(context: Context) -> ArchiveTableDragAnchor {
        let view = ArchiveTableDragAnchor()
        view.source = self
        return view
    }

    func updateNSView(_ view: ArchiveTableDragAnchor, context: Context) {
        view.update(source: self)
    }

    static func dismantleNSView(_ view: ArchiveTableDragAnchor, coordinator: ()) {
        view.source = nil  // a turn scheduled before doesn't put the hook back
        view.uninstall()
    }
}

/// The representable's view, filling the Table's background; it never takes clicks. Hooks the table's
/// data source in place (SwiftUI's own object stays the table's data source) and hooks again
/// whenever SwiftUI has set a new one: on every update, on the next turn after one, and on every
/// selection change. Out of a window it unhooks it.
final class ArchiveTableDragAnchor: NSView {
    private nonisolated static let logger = Logger(subsystem: "com.kernir.app", category: "dragOut")
    /// How many later turns look for a table that isn't in the window yet (the Table's scroll view
    /// may come after this view), 50 ms apart.
    private static let maxRetries = 20

    var source: ArchiveTableDragSource?
    private(set) weak var tableView: NSTableView?
    /// SwiftUI's data source, as the last install found it; it lives as long as SwiftUI holds it.
    private(set) weak var swiftUIDataSource: AnyObject?
    /// A data source the hook can't take (logged once, not tried again).
    private weak var unhookable: AnyObject?
    private var retries = 0
    private var selectionObserver: (any NSObjectProtocol)?
    /// A look on the next turn of the main queue is pending (`update(source:)`).
    private var isNextTurnScheduled = false
    /// The rows of the drag being started; AppKit asks for every row's writer in one go, and the
    /// next turn of the main queue drops it.
    private var dragSelection: ArchiveTableDragSelection?
    /// A move dragged over the table, as read from its pasteboard: AppKit asks validate on every mouse move.
    private struct MoveDrag {
        /// The drag's `draggingSequenceNumber`, and the token its rows were checked against.
        let sequence: Int
        let token: String
        /// Its archive paths, top to bottom; nil when a row is not a move of this window's.
        let paths: [String]?
        /// What `ArchiveActions.canMove` answered for the paths, by target folder.
        var canMove: [String: Bool] = [:]
    }
    /// The last move dragged over the table (`movedPaths`).
    private var moveDragCache: MoveDrag?
    /// Rows dragged over the table from another Lutik window, as read from the pasteboard (`copiedRows`).
    private struct CopyDrag {
        let sequence: Int
        /// The other window's token and its archive paths, top to bottom; nil when the rows are not all moves
        /// of one window's.
        let rows: (token: String, paths: [String])?
        /// What `ArchiveActions.canCopyIn` answered for the rows, by target folder.
        var canCopy: [String: Bool] = [:]
    }
    /// The last drag of rows from elsewhere over the table (`copiedRows`).
    private var copyDragCache: CopyDrag?
    #if DEBUG
    /// Test seam: how many times this anchor has tried to put its hook in (once while SwiftUI keeps its
    /// data source; more is install churn).
    private(set) var installs = 0
    /// Test seam: an anchor in this window finds its table, counts its installs and sets the drag
    /// masks as usual, but leaves SwiftUI's data source as it is: the hook's swap (its class,
    /// `ArchiveTableDragHook`) alone is left out. Per window, so hosted tests running alongside keep
    /// their hook.
    static weak var swapSkippedWindow: NSWindow?
    #endif

    /// The table's data source answers the drag's writer message for this anchor.
    var isHooked: Bool {
        guard let tableView, let current = Self.dataSource(of: tableView), current === swiftUIDataSource
        else { return false }
        return ArchiveTableDragHook.isHooked(current, by: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            uninstall()
            return
        }
        retries = 0
        ensureInstalled()
    }

    /// An update of the representable: looks now, and once more on the next turn of the main queue
    /// (SwiftUI may set its own data source again later in the same pass). One pending turn at most.
    func update(source: ArchiveTableDragSource) {
        self.source = source
        ensureInstalled()
        guard !isNextTurnScheduled else { return }
        isNextTurnScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isNextTurnScheduled = false
            ensureInstalled()
        }
    }

    /// Finds the table (again once the one found has left this window: SwiftUI swapped in a new one),
    /// then makes sure its data source is hooked and its drag operations are copy outside Lutik and
    /// none inside.
    func ensureInstalled() {
        guard window != nil, source != nil else { return }
        if let tableView, tableView.window !== window {
            uninstall()  // the old table's data source is unhooked
            retries = 0
        }
        guard let table = tableView ?? findTableView() else {
            if retries < Self.maxRetries {
                retries += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.ensureInstalled() }
            } else if retries == Self.maxRetries {
                retries += 1
                Self.logger.error("Drag out: the table view was not found; rows can't be dragged out")
            }
            return
        }
        if tableView == nil {
            tableView = table
            observeSelection(of: table)
        }
        if !isHooked {
            install(on: table)
        }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Inside Kernir: a move within the window, a copy into another window's archive (`validateMove`).
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        // AppKit sends the table a drag only for a type it registered (adds to SwiftUI's own types).
        if !table.registeredDraggedTypes.contains(ArchiveFilePromiseProvider.moveType) {
            table.registerForDraggedTypes([ArchiveFilePromiseProvider.moveType])
        }
    }

    /// Unhooks SwiftUI's data source and forgets the table (back in a window, the table is looked for
    /// again). The drag masks stay as `ensureInstalled()` set them: AppKit has no public
    /// getter for the masks set before (only the deprecated `draggingSourceOperationMaskForLocal:`;
    /// SwiftUI's table subclass overrides only `canDragRowsWithIndexes:atPoint:`, not the mask
    /// queries, probe 2), so there is nothing sound to put back. So the local mask stays move and copy and the
    /// table stays registered for `ArchiveFilePromiseProvider.moveType`: a row dragged onto the unhooked
    /// table still offers a move. That is safe only because SwiftUI's own validate then refuses it
    /// (`anUnhookedTableRefusesAMove`), and the table normally goes with this view.
    func uninstall() {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
        if let swiftUIDataSource { ArchiveTableDragHook.uninstall(from: swiftUIDataSource, for: self) }
        tableView = nil
        swiftUIDataSource = nil
        dragSelection = nil
    }

    /// The writer for the dragged row `row`, or nil for a row the drag leaves out
    /// (`ArchiveTableDragSelection.path(forRow:)`). As in Finder, a drag that starts on a selected
    /// row brings the table's selected rows, and one that starts on another row brings that row
    /// alone: AppKit then leaves the selection as it is and asks for that row's writer only. The
    /// table's own selected rows decide, not the window's selection binding, which may not have
    /// caught up with a click yet (`ArchiveTableDragSelection`).
    func writer(forRow row: Int, in table: NSTableView) -> (any NSPasteboardWriting)? {
        guard let source, row >= 0 else { return nil }
        let selected = table.selectedRowIndexes
        let dragged = selected.contains(row) ? selected : IndexSet(integer: row)
        let selection: ArchiveTableDragSelection
        if let dragSelection, dragSelection.draggedRows == dragged {
            selection = dragSelection
        } else {
            let outline = table as? NSOutlineView
            selection = ArchiveTableDragSelection(draggedRows: dragged, rows: source.rows(),
                                                  rowCount: table.numberOfRows,
                                                  level: { outline?.level(forRow: $0) ?? 0 })
            dragSelection = selection
            DispatchQueue.main.async { [weak self] in self?.dragSelection = nil }
        }
        return selection.path(forRow: row).flatMap { source.writer($0, selection.dropID) }
    }

    /// What the table answers for a drag of files from another app (Finder) that the hook takes:
    /// copy while files can be added; none for a drag from inside Lutik (a source in this app), one
    /// with no file URLs, or one without the copy operation in its mask (a Finder drag held to move or
    /// link only is refused at the top level, not turned into a copy). AppKit asks on every mouse move:
    /// this only checks that the pasteboard has file URLs; `acceptFinderDrop` reads them.
    func finderDropOperation(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard let source, info.draggingSource == nil, info.draggingSourceOperationMask.contains(.copy),
              source.canDrop(),
              info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: Self.fileURLsOnly)
        else { return [] }
        return .copy
    }

    /// Adds the files of a Finder drop that `finderDropOperation` takes to `directory`; whether it added.
    func acceptFinderDrop(_ info: any NSDraggingInfo, to directory: String) -> Bool {
        guard let source, finderDropOperation(info) != [] else { return false }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: Self.fileURLsOnly)
            as? [URL] ?? []
        return !urls.isEmpty && source.drop(urls, directory)
    }

    private static let fileURLsOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    /// Whether `info` carries a move inside an archive (from any Lutik table): the hook decides it.
    nonisolated static func isMove(_ info: any NSDraggingInfo) -> Bool {
        info.draggingPasteboard.types?.contains(ArchiveFilePromiseProvider.moveType) == true
    }

    /// The archive paths of a move dragged from this table in this window, top to bottom; nil for a drag from
    /// elsewhere (another table, another Lutik window: another token), one with a row that is not a move,
    /// or one held to copy (Option). The source and the mask are checked on every call (Option changes the
    /// mask mid-drag); the pasteboard is read once per drag (`MoveDrag`).
    func movedPaths(_ info: any NSDraggingInfo) -> [String]? {
        guard let source, let token = source.moveToken, let tableView,
              (info.draggingSource as AnyObject?) === tableView, info.draggingSourceOperationMask.contains(.move)
        else { return nil }
        return moveDrag(info, token: token).paths
    }

    /// The move of the drag `info` (by its sequence number), read from its pasteboard on its first call.
    private func moveDrag(_ info: any NSDraggingInfo, token: String) -> MoveDrag {
        let sequence = info.draggingSequenceNumber
        if let moveDragCache, moveDragCache.sequence == sequence, moveDragCache.token == token { return moveDragCache }
        var paths: [String]? = []
        if let items = info.draggingPasteboard.pasteboardItems, !items.isEmpty {
            for item in items {
                guard let move = ArchiveFilePromiseProvider.move(on: item), move.token == token else {
                    paths = nil
                    break
                }
                paths?.append(move.path)
            }
        } else {
            paths = nil
        }
        let drag = MoveDrag(sequence: sequence, token: token, paths: paths)
        moveDragCache = drag
        return drag
    }

    /// Whether `paths` (the move of the drag `info`, `movedPaths`) can move into `folder`, asked of
    /// `ArchiveActions.canMove` once per folder and drag. `ArchiveActions.move` asks again on the drop.
    private func canMove(_ paths: [String], into folder: String, _ info: any NSDraggingInfo,
                         source: ArchiveTableDragSource) -> Bool {
        let sequence = info.draggingSequenceNumber
        guard var drag = moveDragCache, drag.sequence == sequence else { return source.canMove(paths, folder) }
        if let known = drag.canMove[folder] { return known }
        let answer = source.canMove(paths, folder)
        drag.canMove[folder] = answer
        moveDragCache = drag
        return answer
    }

    /// The archive folder a move proposed on `item` goes into: a folder row's path, "" for the table itself
    /// (nil) and for a file row (`ArchiveTableDropTarget`); nil for a row the table's rows don't match.
    func moveTarget(item: Any?, in outline: NSOutlineView) -> String? {
        guard let source else { return nil }
        guard let item else { return "" }
        let row = outline.row(forItem: item)
        let rows = source.rows()
        guard rows.count == outline.numberOfRows, rows.indices.contains(row),
              outline.level(forRow: row) == rows[row].level else { return nil }
        let path = rows[row].path
        return ArchiveTableDropTarget.directory(proposedItem: item, rowTakesIt: source.isFolder(path)) ?? path
    }

    /// What the table answers for a move proposed on `item`: move, retargeted onto the folder row (or the
    /// table itself for the top level), when `ArchiveActions.canMove` takes it; for rows dragged from another
    /// Lutik window (`copiedRows`), copy, retargeted the same way, when `ArchiveActions.canCopyIn` takes them;
    /// none otherwise.
    func validateMove(_ info: any NSDraggingInfo, outline: NSOutlineView, item: Any?) -> NSDragOperation {
        guard let source, let folder = moveTarget(item: item, in: outline) else { return [] }
        if let paths = movedPaths(info) {
            guard canMove(paths, into: folder, info, source: source) else { return [] }
            outline.setDropItem(folder.isEmpty ? nil : item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }
        guard let rows = copiedRows(info), canCopy(rows, into: folder, info, source: source) else { return [] }
        outline.setDropItem(folder.isEmpty ? nil : item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    /// Moves the rows of a move dropped on `item` (as `validateMove` retargeted it), or starts copying in the
    /// rows of another window's; whether it took them. The copy runs as a task, after this returns.
    func acceptMove(_ info: any NSDraggingInfo, outline: NSOutlineView, item: Any?) -> Bool {
        guard let source, let folder = moveTarget(item: item, in: outline) else { return false }
        if let paths = movedPaths(info) { return source.move(paths, folder) }
        guard let rows = copiedRows(info) else { return false }
        return source.copyIn(rows.paths, rows.token, folder)
    }

    /// The token and archive paths of rows dragged from another Lutik window's table, nil for anything else:
    /// a row that is not a move, rows of two windows, this window's own rows (Option-dragged too: a drag inside
    /// a window only moves), or a drag without the copy operation in its mask. Which window the token names is
    /// `ArchiveActions.canCopyIn`'s to find. The pasteboard is read once per drag.
    func copiedRows(_ info: any NSDraggingInfo) -> (token: String, paths: [String])? {
        guard let source, let ownToken = source.moveToken, info.draggingSourceOperationMask.contains(.copy)
        else { return nil }
        let sequence = info.draggingSequenceNumber
        if let copyDragCache, copyDragCache.sequence == sequence { return Self.foreign(copyDragCache.rows, ownToken) }
        var token: String?
        var paths: [String] = []
        for item in info.draggingPasteboard.pasteboardItems ?? [] {
            guard let move = ArchiveFilePromiseProvider.move(on: item), token == nil || token == move.token else {
                token = nil
                paths = []
                break
            }
            token = move.token
            paths.append(move.path)
        }
        let rows = token.map { ($0, paths) }
        copyDragCache = CopyDrag(sequence: sequence, rows: rows)
        return Self.foreign(rows, ownToken)
    }

    private static func foreign(_ rows: (token: String, paths: [String])?,
                                _ ownToken: String) -> (token: String, paths: [String])? {
        guard let rows, rows.token != ownToken, !rows.paths.isEmpty else { return nil }
        return rows
    }

    /// Whether `rows` (`copiedRows`) can be copied into `folder`, asked of `ArchiveActions.canCopyIn` once per
    /// folder and drag. `ArchiveActions.copyIn` asks again on the drop.
    private func canCopy(_ rows: (token: String, paths: [String]), into folder: String, _ info: any NSDraggingInfo,
                         source: ArchiveTableDragSource) -> Bool {
        guard var drag = copyDragCache, drag.sequence == info.draggingSequenceNumber else {
            return source.canCopyIn(rows.paths, rows.token, folder)
        }
        if let known = drag.canCopy[folder] { return known }
        let answer = source.canCopyIn(rows.paths, rows.token, folder)
        drag.canCopy[folder] = answer
        copyDragCache = drag
        return answer
    }

    private func install(on table: NSTableView) {
        guard let current = Self.dataSource(of: table) else {
            Self.logger.error("Drag out: the table view has no data source; rows can't be dragged out")
            return
        }
        // SwiftUI set a new data source: the one hooked before goes back as it was, even when the new
        // one can't be hooked.
        if let old = swiftUIDataSource, old !== current { ArchiveTableDragHook.uninstall(from: old, for: self) }
        swiftUIDataSource = current
        guard current !== unhookable else { return }
        #if DEBUG
        installs += 1
        if let skipped = Self.swapSkippedWindow, skipped === window { return }
        #endif
        // The table's data source stays the same object, answering the same messages: AppKit's
        // cached answers stay true, and nothing is set on the table.
        if !ArchiveTableDragHook.install(on: current, for: self) {
            unhookable = current
            Self.logger.error("Drag out: the table's data source can't be hooked; rows can't be dragged out")
        }
    }

    private func observeSelection(of table: NSTableView) {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        let name = table is NSOutlineView ? NSOutlineView.selectionDidChangeNotification
            : NSTableView.selectionDidChangeNotification
        selectionObserver = NotificationCenter.default.addObserver(forName: name, object: table, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.dragSelection = nil
                self?.ensureInstalled()
            }
        }
    }

    private static func dataSource(of table: NSTableView) -> AnyObject? {
        if let outline = table as? NSOutlineView { outline.dataSource } else { table.dataSource }
    }

    /// Walks up from this view; at the first ancestor with table views under it, takes the one whose
    /// scroll view overlaps this view the most (this view fills the Table's background). None while
    /// nothing overlaps it (before the first layout this view has no size): the next look tries again.
    private func findTableView() -> NSTableView? {
        guard window != nil else { return nil }
        let mine = convert(bounds, to: nil)
        var ancestor = superview
        while let current = ancestor {
            let tables = Self.tableViews(under: current)
            if !tables.isEmpty {
                func overlap(_ table: NSTableView) -> CGFloat {
                    let outer = table.enclosingScrollView ?? table
                    let frame = outer.convert(outer.bounds, to: nil).intersection(mine)
                    return frame.isNull ? 0 : frame.width * frame.height
                }
                guard let best = tables.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 else { return nil }
                return best
            }
            ancestor = current.superview
        }
        return nil
    }

    /// The table views under `root`, not looking inside one (a table in a cell is not the Table).
    static func tableViews(under root: NSView) -> [NSTableView] {
        var found: [NSTableView] = []
        var queue: [NSView] = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let table = view as? NSTableView {
                found.append(table)
                continue
            }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }
}

/// Where a Finder drop the table is asked about lands, by AppKit's proposal (one place, for the drops
/// to come).
enum ArchiveTableDropTarget {
    /// The archive folder for a drop proposed on `proposedItem`: "" (the top level) for the table
    /// itself (nil: on it, between its top-level rows, below them) and for a row whose own drop
    /// destination doesn't take it (a file row); nil for a row whose own destination does (a folder
    /// row, `ArchiveTableRows`): that drop stays SwiftUI's.
    static func directory(proposedItem: Any?, rowTakesIt: Bool) -> String? {
        proposedItem != nil && rowTakesIt ? nil : ""
    }
}

/// Has a table's data source object answer AppKit's row-writer message for an anchor, in place: the
/// object gets a subclass of its own class (made once per class, registered with the runtime) that
/// overrides only the writer messages its class already answers (and, with the outline writer, its
/// outline drop messages for the root drop), and goes back to its own class when unhooked. The table
/// keeps the very object SwiftUI set, so a Swift cast or an identity check on its data source still
/// finds SwiftUI's coordinator, and the messages it answers stay the same (AppKit
/// caches them when the data source is set). Key-value observing swaps classes too: an object it
/// already observes is not hooked; one it observes later keeps the hook's writers until unhooked,
/// which then gives the messages back to its own class's writers.
enum ArchiveTableDragHook {
    private static let logger = Logger(subsystem: "com.kernir.app", category: "dragOut")
    private static let tableWriter = #selector(NSTableViewDataSource.tableView(_:pasteboardWriterForRow:))
    private static let outlineWriter = #selector(NSOutlineViewDataSource.outlineView(_:pasteboardWriterForItem:))
    private typealias TableWriterIMP = @convention(c) (AnyObject, Selector, NSTableView, Int) -> AnyObject?
    private typealias OutlineWriterIMP = @convention(c) (AnyObject, Selector, NSOutlineView, AnyObject) -> AnyObject?
    private static let outlineValidate = #selector(NSOutlineViewDataSource.outlineView(_:validateDrop:proposedItem:proposedChildIndex:))
    private static let outlineAccept = #selector(NSOutlineViewDataSource.outlineView(_:acceptDrop:item:childIndex:))
    private typealias OutlineValidateIMP = @convention(c) (AnyObject, Selector, NSOutlineView, any NSDraggingInfo,
                                                           AnyObject?, Int) -> UInt
    private typealias OutlineAcceptIMP = @convention(c) (AnyObject, Selector, NSOutlineView, any NSDraggingInfo,
                                                         AnyObject?, Int) -> ObjCBool

    /// The hook's subclasses by their original class; and the hook classes themselves.
    nonisolated(unsafe) private static var subclasses: [ObjectIdentifier: AnyClass] = [:]
    nonisolated(unsafe) private static var hookClasses: Set<ObjectIdentifier> = []
    nonisolated(unsafe) private static let lock = NSLock()
    /// The hooked object's `Link`.
    nonisolated(unsafe) private static let linkKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    /// The anchor a hooked object answers for; the object holds it, and it holds the anchor weakly.
    private final class Link: NSObject {
        weak var anchor: ArchiveTableDragAnchor?
        init(_ anchor: ArchiveTableDragAnchor) { self.anchor = anchor }
    }

    /// Hooks `dataSource` for `anchor` (another anchor's hook on it gives way). False when its class
    /// answers neither writer message or key-value observing already swapped its class.
    @MainActor
    static func install(on dataSource: AnyObject, for anchor: ArchiveTableDragAnchor) -> Bool {
        guard let current: AnyClass = object_getClass(dataSource) else { return false }
        if hookClass(in: current) == nil {
            guard !NSStringFromClass(current).hasPrefix("NSKVONotifying_") else {
                logger.error("Drag out: the data source \(NSStringFromClass(current), privacy: .public) is observed")
                return false
            }
            guard let hook = subclass(of: current) else { return false }
            object_setClass(dataSource, hook)
        }
        objc_setAssociatedObject(dataSource, linkKey, Link(anchor), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return true
    }

    /// Unhooks `dataSource` unless another anchor has hooked it since: back to its own class, or, when
    /// key-value observing has swapped its class since, its own class's writers answer again.
    @MainActor
    static func uninstall(from dataSource: AnyObject, for anchor: ArchiveTableDragAnchor) {
        if let other = linkedAnchor(of: dataSource), other !== anchor { return }
        objc_setAssociatedObject(dataSource, linkKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        guard let current: AnyClass = object_getClass(dataSource), isHookClass(current),
              let original = class_getSuperclass(current) else { return }
        object_setClass(dataSource, original)
    }

    /// `dataSource` answers the writer messages for `anchor`.
    static func isHooked(_ dataSource: AnyObject, by anchor: ArchiveTableDragAnchor) -> Bool {
        guard let current: AnyClass = object_getClass(dataSource), hookClass(in: current) != nil else { return false }
        return linkedAnchor(of: dataSource) === anchor
    }

    #if DEBUG
    /// Test seam: what `dataSource`'s own class writes for `item` (SwiftUI's writer), hooked or not;
    /// nil when its class has no writer.
    @MainActor
    static func ownWriter(of dataSource: AnyObject, outline: NSOutlineView, item: Any) -> (any NSPasteboardWriting)? {
        guard let current: AnyClass = object_getClass(dataSource) else { return nil }
        let own: AnyClass = hookClass(in: current).flatMap { class_getSuperclass($0) } ?? current
        return callOwnOutlineWriter(own, dataSource, outline, item as AnyObject) as? any NSPasteboardWriting
    }

    /// Test seam: drops `dataSource`'s link and leaves its hook class, as when its anchor has gone (the link
    /// holds it weakly) without unhooking it.
    @MainActor
    static func unlink(_ dataSource: AnyObject) {
        objc_setAssociatedObject(dataSource, linkKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    #endif

    private static func linkedAnchor(of dataSource: AnyObject) -> ArchiveTableDragAnchor? {
        (objc_getAssociatedObject(dataSource, linkKey) as? Link)?.anchor
    }

    private static func isHookClass(_ cls: AnyClass) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hookClasses.contains(ObjectIdentifier(cls))
    }

    /// The hook class in `cls`'s superclass chain (key-value observing may have subclassed it).
    private static func hookClass(in cls: AnyClass) -> AnyClass? {
        var next: AnyClass? = cls
        while let current = next {
            if isHookClass(current) { return current }
            next = class_getSuperclass(current)
        }
        return nil
    }

    /// The hook's subclass of `original`, made and registered on first use; nil when `original`
    /// answers neither writer message (the hook never adds a message its class doesn't answer).
    private static func subclass(of original: AnyClass) -> AnyClass? {
        lock.lock()
        defer { lock.unlock() }
        if let made = subclasses[ObjectIdentifier(original)] { return made }
        let overridesTable = class_getInstanceMethod(original, tableWriter) != nil
        let overridesOutline = class_getInstanceMethod(original, outlineWriter) != nil
        guard overridesTable || overridesOutline else {
            logger.error("Drag out: \(NSStringFromClass(original), privacy: .public) gives no row writer")
            return nil
        }
        let name = "KernirTableDragHook_" + NSStringFromClass(original)
        let made: AnyClass
        if let existing = objc_lookUpClass(name) {
            guard let superclass = class_getSuperclass(existing),
                  ObjectIdentifier(superclass) == ObjectIdentifier(original) else { return nil }
            made = existing
        } else {
            guard let pair = objc_allocateClassPair(original, name, 0) else { return nil }
            if overridesTable {
                let block: @convention(block) (AnyObject, NSTableView, Int) -> AnyObject? = { object, table, row in
                    guard let anchor = linkedAnchor(of: object) else {
                        return callOwnTableWriter(original, object, table, row)
                    }
                    return MainActor.assumeIsolated {  // AppKit asks on the main thread, as the drag starts
                        MainThreadWriter(anchor.writer(forRow: row, in: table))
                    }.writer as AnyObject?
                }
                class_addMethod(pair, tableWriter, imp_implementationWithBlock(block), "@@:@q")
            }
            if overridesOutline {
                let block: @convention(block) (AnyObject, NSOutlineView, AnyObject) -> AnyObject? = { object, outline, item in
                    guard let anchor = linkedAnchor(of: object) else {
                        return callOwnOutlineWriter(original, object, outline, item)
                    }
                    // AppKit sends this on the main thread as the drag starts, and `item` is only
                    // handed back to the outline it came from there, so it never crosses threads.
                    nonisolated(unsafe) let item = item
                    return MainActor.assumeIsolated {
                        MainThreadWriter(anchor.writer(forRow: outline.row(forItem: item), in: outline))
                    }.writer as AnyObject?
                }
                class_addMethod(pair, outlineWriter, imp_implementationWithBlock(block), "@@:@@")
                addOutlineDrop(to: pair, original: original)
            }
            // As key-value observing does: `-class` still names the object's own class.
            let classBlock: @convention(block) (AnyObject) -> AnyClass = { _ in original }
            class_addMethod(pair, NSSelectorFromString("class"), imp_implementationWithBlock(classBlock), "#@:")
            objc_registerClassPair(pair)
            made = pair
        }
        subclasses[ObjectIdentifier(original)] = made
        hookClasses.insert(ObjectIdentifier(made))
        return made
    }

    /// The outline's drop messages, where `original` answers them: a Finder file over the table
    /// itself or a row SwiftUI's own validate refuses goes to the top level (`ArchiveTableDropTarget`),
    /// retargeted to the table (item nil, on it) and added by the anchor's handler; every other
    /// proposal, and every accept on a row, gets `original`'s answer. A move inside an archive
    /// (`ArchiveFilePromiseProvider.moveType`) is the anchor's alone, validate and accept, wherever it is
    /// proposed; any other drag from inside Lutik gets `original`'s answer (none on the table).
    private static func addOutlineDrop(to pair: AnyClass, original: AnyClass) {
        guard let validate = class_getInstanceMethod(original, outlineValidate),
              let accept = class_getInstanceMethod(original, outlineAccept) else {
            let name = NSStringFromClass(original)
            logger.error("Root drop: \(name, privacy: .public) gives no outline drop messages; no drop on the table")
            return
        }
        let validateBlock: @convention(block) (AnyObject, NSOutlineView, any NSDraggingInfo, AnyObject?, Int) -> UInt = {
            object, outline, info, item, index in
            // A move inside an archive is the hook's alone: SwiftUI's own drop messages never see it, not even
            // with no anchor linked (its anchor gone): none then, never SwiftUI's (whose drop of a promise from
            // its own window would wait on that window).
            if ArchiveTableDragAnchor.isMove(info) {
                guard let anchor = linkedAnchor(of: object) else { return 0 }
                nonisolated(unsafe) let info = info
                nonisolated(unsafe) let item = item
                return MainActor.assumeIsolated { anchor.validateMove(info, outline: outline, item: item).rawValue }
            }
            guard let anchor = linkedAnchor(of: object) else {
                return callOwnValidate(original, object, outline, info, item, index)
            }
            // SwiftUI's own validate is asked every time, so its row drop state follows the drag. On
            // the table itself (item nil) its answer is ignored: it refuses that outright.
            let answer = callOwnValidate(original, object, outline, info, item, index)
            let own = item == nil ? 0 : answer
            guard ArchiveTableDropTarget.directory(proposedItem: item, rowTakesIt: own != 0) != nil else { return own }
            // AppKit sends this on the main thread, while the drag is over the table.
            nonisolated(unsafe) let info = info
            return MainActor.assumeIsolated {
                let operation = anchor.finderDropOperation(info)
                guard operation != [] else { return own }
                // The top level, even for a file row or a gap inside an expanded folder that SwiftUI
                // refuses: the drop is retargeted to the table, not to the folder around it.
                outline.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
                return operation.rawValue
            }
        }
        let acceptBlock: @convention(block) (AnyObject, NSOutlineView, any NSDraggingInfo, AnyObject?, Int) -> ObjCBool = {
            object, outline, info, item, index in
            if ArchiveTableDragAnchor.isMove(info) {
                guard let anchor = linkedAnchor(of: object) else { return false }
                nonisolated(unsafe) let info = info
                nonisolated(unsafe) let item = item
                return ObjCBool(MainActor.assumeIsolated { anchor.acceptMove(info, outline: outline, item: item) })
            }
            guard let anchor = linkedAnchor(of: object), item == nil,
                  let directory = ArchiveTableDropTarget.directory(proposedItem: nil, rowTakesIt: false) else {
                return callOwnAccept(original, object, outline, info, item, index)
            }
            nonisolated(unsafe) let info = info
            return ObjCBool(MainActor.assumeIsolated { anchor.acceptFinderDrop(info, to: directory) })
        }
        class_addMethod(pair, outlineValidate, imp_implementationWithBlock(validateBlock),
                        method_getTypeEncoding(validate))
        class_addMethod(pair, outlineAccept, imp_implementationWithBlock(acceptBlock), method_getTypeEncoding(accept))
    }

    private static func callOwnValidate(_ own: AnyClass, _ object: AnyObject, _ outline: NSOutlineView,
                                        _ info: any NSDraggingInfo, _ item: AnyObject?, _ index: Int) -> UInt {
        guard let method = class_getInstanceMethod(own, outlineValidate) else { return 0 }
        let imp = unsafeBitCast(method_getImplementation(method), to: OutlineValidateIMP.self)
        return imp(object, outlineValidate, outline, info, item, index)
    }

    private static func callOwnAccept(_ own: AnyClass, _ object: AnyObject, _ outline: NSOutlineView,
                                      _ info: any NSDraggingInfo, _ item: AnyObject?, _ index: Int) -> ObjCBool {
        guard let method = class_getInstanceMethod(own, outlineAccept) else { return false }
        let imp = unsafeBitCast(method_getImplementation(method), to: OutlineAcceptIMP.self)
        return imp(object, outlineAccept, outline, info, item, index)
    }

    /// `own`'s writer for `row` (as `super` would call it), or nil when `own` has none.
    private static func callOwnTableWriter(_ own: AnyClass, _ object: AnyObject, _ table: NSTableView,
                                           _ row: Int) -> AnyObject? {
        guard let method = class_getInstanceMethod(own, tableWriter) else { return nil }
        let imp = unsafeBitCast(method_getImplementation(method), to: TableWriterIMP.self)
        return imp(object, tableWriter, table, row)
    }

    private static func callOwnOutlineWriter(_ own: AnyClass, _ object: AnyObject, _ outline: NSOutlineView,
                                             _ item: AnyObject) -> AnyObject? {
        guard let method = class_getInstanceMethod(own, outlineWriter) else { return nil }
        let imp = unsafeBitCast(method_getImplementation(method), to: OutlineWriterIMP.self)
        return imp(object, outlineWriter, outline, item)
    }
}

/// Carries a writer out of `MainActor.assumeIsolated`; it never leaves the main thread.
private struct MainThreadWriter: @unchecked Sendable {
    let writer: (any NSPasteboardWriting)?
    init(_ writer: (any NSPasteboardWriting)?) { self.writer = writer }
}
