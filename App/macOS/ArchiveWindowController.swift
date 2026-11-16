import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The archive window: stock SwiftUI content in an `NSHostingController`, with the SwiftUI
/// toolbar bridged into the real window toolbar.
final class ArchiveWindowController: NSWindowController, NSMenuItemValidation, NSWindowDelegate {
    /// Name under which archive windows autosave their frame; nil autosaves none. The unit-test
    /// bundle sets nil before any test runs, so hosted tests never write the app's real defaults.
    static var frameAutosaveName: String? = "ArchiveWindow"

    private let state: ArchiveWindowState
    private let actions: ArchiveActions
    /// This window's Quick Look preview window and its stand-ins.
    private let previewSource: PreviewWindowSource
    /// The document this window shows. Set at init, unlike `document`, which AppKit sets only
    /// once the document adds this controller; the undo gate needs it from the first query.
    private weak var archiveDocument: ArchiveDocument?

    /// `windowFrame`: the screenshot UI test's fixed frame, if any (tests pass their own).
    init(document: ArchiveDocument, windowFrame: CGSize? = LaunchOverrides.windowFrame) {
        state = document.state
        archiveDocument = document
        previewSource = PreviewWindowSource(state: document.state)
        let actions = ArchiveActions(document: document)
        self.actions = actions
        document.actions = actions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 600, height: 360)

        super.init(window: window)
        // Before any content: the SwiftUI view asks the window for its undo manager, and the undo
        // gate only works if this delegate answers that first question (see windowWillReturnUndoManager).
        window.delegate = self

        let hosting = NSHostingController(rootView: ArchiveWindowView(state: document.state, actions: actions))
        hosting.sceneBridgingOptions = [.toolbars]
        // The window sizes the content, not the other way round; keep the default frame.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 820, height: 520))
        window.center()

        // Launch-argument hook for the screenshot UI test: a fixed frame replaces the autosaved
        // frame and the cascade, and is never autosaved, so later launches keep their own size.
        let frameForced = LaunchOverrides.apply(to: window, frame: windowFrame)
        if let name = Self.autosaveName(Self.frameAutosaveName, frameForced: frameForced) {
            windowFrameAutosaveName = name
        }
        if !frameForced { Self.cascade(window) }
        actions.window = window
        previewSource.window = window
        previewSource.actions = actions
        // The row menu's Share copies into the preview's share folder, which goes with the window.
        actions.makeShareCopy = { [weak source = previewSource] file, name in
            guard let source else { throw CancellationError() }
            return try await source.shareCopy(of: file, named: name)
        }
    }

    /// Empty undo manager handed to the window while an operation runs. Registration is
    /// disabled, so it never holds anything and Undo/Redo stay disabled.
    private let gatedUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    /// Edit > Undo/Redo ask the window for its undo manager. While an operation shows the
    /// progress sheet this returns an empty, registration-disabled manager, so the model can't
    /// change under a running save (the save completion adopts the saved snapshot and would wipe
    /// such edits). The same while the Info popover is on screen with an editable comment: the model's
    /// own "Edit Comment" step covers the typing (its field has no undo of its own, `CommentEditor`), and
    /// ⌘Z in the open popover does nothing; Edit > Undo after it closes takes the typing back.
    /// While a name field shows (Rename, New Folder) it's the field's own (`ArchiveActions.renameUndoManager`):
    /// ⌘Z there must not undo the New Folder or a rename under the field.
    /// Otherwise it's the document's undo manager. The model registers undo through the document
    /// directly, so registration is not affected.
    ///
    /// This must never return nil (macOS 26 AppKit, `-[NSWindow _getUndoManager:]`): on nil, with
    /// no document yet, the window makes its own undo manager and sets a flag that `_resetUndoManager`
    /// never clears, and from then on it skips this delegate for good. Hence `archiveDocument`
    /// rather than `document`, and the delegate set before the SwiftUI content.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        let editingComment = state.isInfoPopoverOnScreen && state.model?.canEditComment == true
        if state.progress != nil || editingComment { return gatedUndoManager }
        return state.renamingPath != nil ? actions.renameUndoManager : archiveDocument?.undoManager
    }

    /// The autosave name for a new window: `name`, but none when the launch override forced its
    /// frame (later launches keep their own size).
    nonisolated static func autosaveName(_ name: String?, frameForced: Bool) -> String? {
        frameForced ? nil : name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Every archive window restores the same autosaved frame; offset a new one down and to the
    /// right of the frontmost archive window so it doesn't hide it.
    private static func cascade(_ window: NSWindow) {
        guard let front = NSApp.orderedWindows.first(where: {
            $0 !== window && $0.isVisible && $0.windowController is ArchiveWindowController
        }) else { return }
        // The first call places `window` at the front window's corner and returns the next cascade point.
        let next = window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY))
        window.cascadeTopLeft(from: next)
    }

    // MARK: - Actions

    @objc func addFiles(_ sender: Any?) {
        actions.addFiles()
    }

    /// File > New Folder (⇧⌘N).
    @objc func newFolder(_ sender: Any?) {
        actions.newFolder()
    }

    /// File > Rename: the name field on the selected row, as Return shows it.
    @objc func rename(_ sender: Any?) {
        actions.beginRename()
    }

    @objc func extract(_ sender: Any?) {
        actions.extract(nextToArchive: NSEvent.modifierFlags.contains(.option))
    }

    @objc func toggleQuickLook(_ sender: Any?) {
        actions.toggleQuickLook()
    }

    /// ⌘↓ (a hidden File menu item): opens the selected rows, like double-click.
    @objc func openSelection(_ sender: Any?) {
        actions.openSelectionInDefaultApp()
    }

    /// The key window; tests set their own (a hosted test's window is never key).
    var keyWindow: @MainActor () -> NSWindow? = { NSApp.keyWindow }

    /// The main window; tests set their own (a hosted test's window is never main).
    var mainWindow: @MainActor () -> NSWindow? = { NSApp.mainWindow }

    /// Whether `key` is this window's preview window (never main out of full screen, so this one stays main).
    /// Tests set their own.
    lazy var isPreviewWindow: @MainActor (NSWindow) -> Bool = { [weak self] key in
        guard let preview = self?.previewSource.previewWindow?.window else { return false }
        return key === preview
    }

    /// The type of the item the preview window shows (`PreviewWindowController.shownContentType`): nil in its index
    /// sheet or with no preview. Tests set their own.
    lazy var previewedContentType: @MainActor () -> UTType? = { [weak self] in
        self?.previewSource.previewWindow?.shownContentType
    }

    /// Whether the preview of an item of `type` has no text to select: an image, a movie or a sound, an archive, a
    /// folder, unknown binary data (exactly `.data`, also the type when the item's can't be read; every file type
    /// conforms to it), or nothing (the index sheet). Quick Look enables copy: there with nothing selected, which
    /// would copy the item's content instead of the rows. Text, PDF, HTML, RTF, source and documents may have: their
    /// previews render out of process, so the selection can't be seen here.
    static func previewHasNoText(_ type: UTType?) -> Bool {
        guard let type, type != .data else { return true }
        let noText: [UTType] = [.image, .audiovisualContent, .movie, .audio, .archive, .folder]
        return noText.contains { type.conforms(to: $0) }
    }

    /// Whether `key` is a child window of this one, at any depth (the Info popover's).
    private func isChildWindow(_ key: NSWindow) -> Bool {
        guard let window else { return false }
        var parent = key.parent
        while let current = parent {
            if current === window { return true }
            parent = current.parent
        }
        return false
    }

    /// The `NSText` (a field's editor, a text view) at `responder` or holding it; nil when the focus isn't in text.
    static func textFocus(from responder: NSResponder?) -> NSText? {
        var view = responder as? NSView
        while let current = view {
            if let text = current as? NSText { return text }
            view = current.superview
        }
        return nil
    }

    /// Whether the focus at `responder`, or a view that holds it, is in-process text with text selected: an `NSText`
    /// (a field's editor, a text view) with a non-empty selection, or a `PDFView` whose selection has text; false
    /// with nothing selected there (a PDF view enables copy: then too). Nil out of such text, whatever the
    /// focus answers to copy: (the Quick Look preview of an image or a page enables it with nothing selected).
    static func textSelection(from responder: NSResponder?) -> Bool? {
        var view = responder as? NSView
        while let current = view {
            if let text = current as? NSText { return text.selectedRange.length > 0 }
            if let pdf = current as? PDFView { return !(pdf.currentSelection?.string ?? "").isEmpty }
            view = current.superview
        }
        return nil
    }

    /// Edit > Cut and Copy where the rows aren't the target; tests stand in their own window's chain.
    var standardEdit = StandardEditCommand()

    /// Whether Edit > Cut or Copy (`action`, the standard cut: or copy:) takes the selected rows; never while a sheet
    /// is attached to this window, nor with the key window's focus in editable text with only the caret
    /// (`StandardEditCommand.isCaretOnlyInEditableText`: there the standard one is off and does nothing, in any
    /// window). This window key: when its first responder is a view of it that isn't text (the table's hosting view, a
    /// toolbar button with full keyboard access), or the window itself (nothing in it has the focus, as after a sheet
    /// closes: the rows are all there is); not in text (a name, the comment, the search). This one main, as Edit >
    /// Delete there deletes the rows: its preview window key, as the focus there is in-process text (a PDF's page, a
    /// text view) with nothing selected and not with text selected (`textSelection(from:)`); out of such text for an
    /// item that may have text (`previewHasNoText`: not an image, a movie, a sound, an archive, a folder or unknown
    /// binary data) unless it has an enabled standard `action` (Quick Look's text selection is out of process); a child
    /// window key (the Info popover's), unless its focus is text with a selection (`textFocus(from:)`; with only the
    /// caret in selectable text that isn't editable it is the rows', as a text view may enable copy: there too) or, out
    /// of text, has an enabled standard `action`. Anywhere else (a sheet's or another window's field, an open or save
    /// panel) it is the standard one (`standardEdit`). Validation and action ask the same.
    private func rowsAreTheTarget(of action: Selector, from sender: Any?) -> Bool {
        guard let window, window.attachedSheet == nil, let key = keyWindow(),
              !StandardEditCommand.isCaretOnlyInEditableText(key.firstResponder) else { return false }
        if key === window {
            if window.firstResponder === window { return true }
            guard let focus = window.firstResponder as? NSView else { return false }
            return focus.window === window && !(focus is NSText)
        }
        guard mainWindow() === window else { return false }
        if isPreviewWindow(key) {
            if let selected = Self.textSelection(from: key.firstResponder) { return !selected }
            if Self.previewHasNoText(previewedContentType()) { return true }
        } else {
            guard isChildWindow(key) else { return false }
            // Selectable text, not editable (that is ruled out above): a text view may enable copy: with only the
            // caret in it, which would put empty text on the pasteboard.
            if let text = Self.textFocus(from: key.firstResponder) { return text.selectedRange.length == 0 }
        }
        return !standardEdit.validate(action, for: sender)
    }

    /// The selected rows can be copied (`canCopy`) and no name field shows, as for Cut (`canCut`).
    private var canCopyRows: Bool { actions.canCopy && state.renamingPath == nil }

    /// Edit > Copy (⌘C): the selected rows (`copySelection`) where they are the target, which puts them on the
    /// pasteboard only once their export is done: a failed Copy leaves it as it was. Else the standard copy:.
    @objc func copySelection(_ sender: Any?) {
        if rowsAreTheTarget(of: #selector(NSText.copy(_:)), from: sender) {
            if canCopyRows { actions.copySelection() }
        } else {
            standardEdit.send(#selector(NSText.copy(_:)), from: sender)
        }
    }

    /// Edit > Cut (⌘X): the selected rows (`cutSelection`) where they are the target, else the standard cut:.
    @objc func cutSelection(_ sender: Any?) {
        if rowsAreTheTarget(of: #selector(NSText.cut(_:)), from: sender) {
            actions.cutSelection()
        } else {
            standardEdit.send(#selector(NSText.cut(_:)), from: sender)
        }
    }

    /// Edit > Delete (⌘⌫). While the Quick Look preview is key it still deletes the previewed selection in this
    /// archive window, as in Finder (intended).
    @objc func delete(_ sender: Any?) {
        actions.removeSelection()
    }

    /// File > Get Info (⌘I): shows the Info popover, or hides it when it is open, as the toolbar's Info button does.
    @objc func showInfo(_ sender: Any?) {
        actions.toggleInfo()
    }

    /// Edit > Find: the toolbar's search field (SwiftUI's `.searchable`).
    @objc func performFind(_ sender: Any?) {
        let search = window?.toolbar?.items.lazy.compactMap { $0 as? NSSearchToolbarItem }.first
        search?.beginSearchInteraction()
    }

    /// The preview window goes with this window, and with it the stand-ins and Share's copies.
    func windowWillClose(_ notification: Notification) {
        previewSource.windowWillClose()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(addFiles(_:)):
            return actions.canAdd
        case #selector(delete(_:)):
            return actions.canRemoveSelection && actions.hasNoSheet
        case #selector(copySelection(_:)):
            let copy = #selector(NSText.copy(_:))
            return rowsAreTheTarget(of: copy, from: menuItem) ? canCopyRows
                : standardEdit.validate(copy, for: menuItem)
        case #selector(cutSelection(_:)):
            let cut = #selector(NSText.cut(_:))
            return rowsAreTheTarget(of: cut, from: menuItem) ? actions.canCut
                : standardEdit.validate(cut, for: menuItem)
        case #selector(newFolder(_:)):
            return actions.canNewFolder
        case #selector(rename(_:)):
            return actions.canRename
        case #selector(extract(_:)):
            return actions.canExtract
        case #selector(performFind(_:)), #selector(showInfo(_:)):
            return state.model != nil
        case #selector(openSelection(_:)):
            return actions.canOpenSelection
        case #selector(toggleQuickLook(_:)):
            return actions.canToggleQuickLook
        default:
            return true
        }
    }
}

extension NSWindow {
    /// Runs `body` once no sheet is attached: AppKit drops a sheet, such as an error alert, begun
    /// while SwiftUI is still ending its own. Runs at once without a sheet; stops waiting after `timeout`.
    func whenNoSheetAttached(timeout: Duration = .seconds(2), _ body: @escaping @MainActor () -> Void) {
        guard attachedSheet != nil else {
            body()
            return
        }
        Task {
            let deadline = ContinuousClock.now + timeout
            while attachedSheet != nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            body()
        }
    }
}
