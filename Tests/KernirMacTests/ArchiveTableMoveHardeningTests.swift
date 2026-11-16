import AppKit
import SwiftUI
import Testing
@testable import Kernir
import KernirCore

// A move drag (`ArchiveFilePromiseProvider.moveType`, with its file promise) never
// reaches a receiver that could read the promise: its promise waits for the window the receiver is in. The
// hook refuses a move with no anchor linked instead of passing it to SwiftUI's drop messages; the table with the
// hook out refuses it too; no other view of Kernir registers the promise or move types. And the hook reads a
// move's pasteboard once per drag (by its sequence number), with the source and mask still checked on every
// update. Hosted (AppKit, SwiftUI) run only. SwiftUI's accept is never called with a fake
// drag (it traps the host): accept only where `theHookAnswersAccept` holds.

/// One dragged row of a move, as `ArchiveFilePromiseProvider` writes it.
private func moveRow(_ path: String, token: String) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setPropertyList(["path": path, "token": token], forType: ArchiveFilePromiseProvider.moveType)
    return item
}

/// The types a drag of rows out of an archive window carries that a receiver must not take: the file promise's
/// and the move's.
@MainActor
private var promiseAndMoveTypes: Set<NSPasteboard.PasteboardType> {
    Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        + [ArchiveFilePromiseProvider.moveType])
}

/// `view` and every view under it.
@MainActor
private func allViews(under view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap { allViews(under: $0) }
}

/// A window held offscreen (AppKit keeps a titled window on a screen unless told not to).
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@Suite(.serialized) @MainActor
struct ArchiveTableMoveHardeningTests {
    /// Proposals over the closed table (docs, b.pdf, c.png): the table itself, the folder row docs, the file row
    /// b.pdf.
    private static let rows: [Int?] = [nil, 0, 1]

    private func item(_ row: Int?, _ outline: NSOutlineView) -> AnyObject? {
        row.map { outline.item(atRow: $0) as AnyObject? } ?? nil
    }

    private func validate(_ drop: FakeDrop, _ outline: NSOutlineView, row: Int?) -> UInt? {
        outline.dataSource?.outlineView?(outline, validateDrop: drop, proposedItem: item(row, outline),
                                         proposedChildIndex: NSOutlineViewDropOnItemIndex).rawValue
    }

    private func accept(_ drop: FakeDrop, _ outline: NSOutlineView, row: Int?) -> Bool? {
        outline.dataSource?.outlineView?(outline, acceptDrop: drop, item: item(row, outline),
                                         childIndex: NSOutlineViewDropOnItemIndex)
    }

    /// A row's own drag (promise and move type) of b.pdf from `outline`, held to move.
    private func rowDrag(_ hosted: RegressionHosted, _ outline: NSOutlineView) throws -> FakeDrop {
        let writer = try #require(hosted.actions.dragWriter(for: "b.pdf", drop: UUID()))
        return FakeDrop(writers: [writer], location: .zero, window: outline.window, source: outline, mask: .move)
    }

    /// A hook class with no anchor linked (its anchor gone without unhooking it) refuses a move, validate and
    /// accept, instead of passing it to SwiftUI's own drop messages.
    @Test func anUnlinkedHookRefusesAMoveItself() async throws {
        let hosted = try await RegressionHosted(.hooked)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(.hooked)
        let outline = try #require(table as? NSOutlineView)
        let anchor = try #require(hosted.anchor)
        let dataSource = try #require(outline.dataSource)
        let drop = try rowDrag(hosted, outline)
        defer { drop.end() }
        #expect(drop.draggingPasteboard.types?.contains(ArchiveFilePromiseProvider.moveType) == true)
        anchor.source = nil  // no later update links it again
        ArchiveTableDragHook.unlink(dataSource)
        try #require(!anchor.isHooked)
        try #require(theHookAnswersAccept(outline), "SwiftUI's accept would get the fake drag; not called")
        for row in Self.rows {
            #expect(validate(drop, outline, row: row) == 0, "row \(String(describing: row))")
            #expect(accept(drop, outline, row: row) == false, "row \(String(describing: row))")
        }
    }

    /// With the hook out (SwiftUI's own data source class), the table refuses a row's move drag on itself and
    /// on a file row. Validate only. On a folder row it can't: the row's `dropDestination(for: URL.self)` is a
    /// TableRowContent drop modifier, which validates by type alone (the drag's plain file URL,
    /// `ArchiveDragOutFiles`), with no way to filter the drag. Its drop goes to `addDropped`, which ignores the
    /// drag's own files (`ArchiveActions.isOwnTemporaryFile`, the `Kernir-DragOut-` folder): nothing is added.
    /// (SwiftUI's accept can't be called with a fake drag.) A real archive table is hooked, and there a move is
    /// the hook's alone.
    @Test func anUnhookedTableRefusesAMove() async throws {
        let hosted = try await RegressionHosted(.removed)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(.removed)
        let outline = try #require(table as? NSOutlineView)
        let drop = try rowDrag(hosted, outline)
        defer { drop.end() }
        for row in Self.rows where row != 0 {
            #expect(validate(drop, outline, row: row) == 0, "row \(String(describing: row))")
        }
        let urls = drop.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        #expect(urls.map(\.lastPathComponent) == ["b.pdf"])
        #expect(urls.allSatisfy { ArchiveActions.isOwnTemporaryFile($0) })
        // In the host's own folders (deleted by `end`), not the app's.
        #expect(hosted.dragOutFolders.registered.count == 1)
        #expect(!hosted.actions.addDropped(urls, to: "docs"))
        #expect(!hosted.model.hasChanges)
    }

    /// A drag's pasteboard is read once: the same drag (sequence number) with other rows on its pasteboard still
    /// answers as it did, for each folder; the source's mask is checked on every update (Option held mid-drag).
    @Test func aDragIsReadOnceButItsMaskOnEveryUpdate() async throws {
        let hosted = try await RegressionHosted(.hooked)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(.hooked)
        let outline = try #require(table as? NSOutlineView)
        let token = hosted.actions.moveToken
        let drop = FakeDrop(writers: [moveRow("b.pdf", token: token)], location: .zero, window: outline.window,
                            source: outline, mask: .move)
        defer { drop.end() }
        #expect(validate(drop, outline, row: 0) == NSDragOperation.move.rawValue)
        #expect(validate(drop, outline, row: nil) == 0)  // b.pdf is at the top level already
        drop.pasteboard.clearContents()
        drop.pasteboard.writeObjects([moveRow("docs", token: token)])
        #expect(validate(drop, outline, row: 0) == NSDragOperation.move.rawValue)  // still b.pdf's answer
        drop.mask = .copy
        #expect(validate(drop, outline, row: 0) == 0)
        drop.mask = .move
        #expect(validate(drop, outline, row: 0) == NSDragOperation.move.rawValue)
    }

    /// A new drag (a new sequence number) reads its own pasteboard, not the last drag's.
    @Test func aNewDragReadsItsOwnPasteboard() async throws {
        let hosted = try await RegressionHosted(.hooked)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(.hooked)
        let outline = try #require(table as? NSOutlineView)
        let token = hosted.actions.moveToken
        let file = FakeDrop(writers: [moveRow("b.pdf", token: token)], location: .zero, window: outline.window,
                            source: outline, mask: .move)
        let folder = FakeDrop(writers: [moveRow("docs", token: token)], location: .zero, window: outline.window,
                              source: outline, mask: .move)
        let other = FakeDrop(writers: [moveRow("b.pdf", token: UUID().uuidString)], location: .zero,
                             window: outline.window, source: outline, mask: .move)
        defer { file.end(); folder.end(); other.end() }
        #expect(file.draggingSequenceNumber != folder.draggingSequenceNumber)
        #expect(validate(file, outline, row: 0) == NSDragOperation.move.rawValue)
        #expect(validate(folder, outline, row: 0) == 0)  // docs onto itself
        #expect(validate(other, outline, row: 0) == 0)   // another window's token
        #expect(validate(file, outline, row: 0) == NSDragOperation.move.rawValue)
    }
}

/// No receiver in Kernir but the archive table's hook takes a row's drag: none registers the file promise's types
/// or the move type (a receiver reading the promise would wait on its own window).
@Suite(.serialized) @MainActor
struct MoveDragReceiverTests {
    /// The Info popover's editable comment (`CommentEditor`, an AppKit text view).
    @Test func theCommentEditorTakesNoPromiseOrMove() async throws {
        let summary = ArchiveInfoSummary(format: .zip, itemCount: 3, size: 10, compressedSize: 8, fileSize: 12,
                                         encryption: .none)
        let view = NSHostingView(rootView: ArchiveInfoView(summary: summary, comment: .constant("hello"),
                                                           showsComment: true, canEditComment: true,
                                                           readOnlyNote: nil, commentProblem: nil))
        view.frame.size = view.fittingSize
        let window = OffscreenWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 400),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        view.layoutSubtreeIfNeeded()
        let textView = try #require(allViews(under: view).lazy.compactMap { $0 as? NSTextView }.first { $0.isEditable })
        let taken = Set(textView.registeredDraggedTypes).intersection(promiseAndMoveTypes)
        #expect(taken.isEmpty, "the comment editor registers \(taken.map(\.rawValue))")
    }

    /// The archive window's views other than the table itself: the SwiftUI hosting view behind the Table's
    /// `.dropDestination(for: URL.self)`, the scroll and clip views, the column header, the rows and cells,
    /// the window's frame (title bar). None registers the file promise's types or the move type, so only the
    /// table's hook can take a row's drag. (An `NSWindow` has no registered types of its own; its frame view
    /// is the top of the walk.) Reads registrations only: no SwiftUI drop entry point is called.
    @Test func noOtherViewOfTheArchiveWindowTakesPromiseOrMove() async throws {
        let hosted = try await RegressionHosted(.hooked)
        defer { hosted.end() }
        let (table, _) = try await hosted.table(.hooked)
        let top = try #require(hosted.window.contentView?.superview ?? hosted.window.contentView)
        let views = allViews(under: top).filter { $0 !== table }
        #expect(views.contains { $0 === hosted.window.contentView })
        #expect(views.count > 1)
        for view in views {
            let taken = Set(view.registeredDraggedTypes).intersection(promiseAndMoveTypes)
            #expect(taken.isEmpty, "\(type(of: view)) registers \(taken.map(\.rawValue).sorted())")
        }
    }

    /// The preview window's views, its frame (title bar) included.
    @Test func thePreviewWindowTakesNoPromiseOrMove() throws {
        let controller = PreviewWindowController()
        defer { controller.tearDown() }
        let window = try #require(controller.window)
        let views = allViews(under: window.contentView?.superview ?? window.contentView)
        #expect(!views.isEmpty)
        for view in views {
            let taken = Set(view.registeredDraggedTypes).intersection(promiseAndMoveTypes)
            #expect(taken.isEmpty, "\(type(of: view)) registers \(taken.map(\.rawValue))")
        }
    }
}
