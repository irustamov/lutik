import UIKit

/// An archive window's navigation controller, and the responder for the document's keyboard and
/// menu bar commands (`ArchiveCommands`): Save, Delete, Select All, Find, Get Info, Close, Undo,
/// Redo and Extract Here, and the stock Copy, Cut and Paste.
/// While no document is open it takes none of them, so the launch browser keeps its own.
final class ArchiveNavigationController: UINavigationController {
    /// Set by the document view controller when a document opens, nil once it closes.
    weak var screenState: ScreenState?

    /// The name alert's own while it is up (`ScreenState.renameUndoManager`): the alert may be presented
    /// from here, and its text field finds its undo manager up the responder chain.
    override var undoManager: UndoManager? { screenState?.renameUndoManager ?? super.undoManager }

    /// The folder level on screen: "" at the root, else the top pushed level's path.
    var currentPath: String {
        (topViewController as? FolderHostingController)?.path ?? ""
    }

    /// The open document, once its archive is listed and nothing (a sheet, a preview, a picker)
    /// is presented over it.
    private var readyState: ScreenState? {
        guard let screenState, screenState.model != nil, presentedViewController == nil else { return nil }
        return screenState
    }

    // MARK: - Commands

    @objc func saveArchive(_ sender: Any?) {
        guard let state = readyState, state.canSaveNow else { return }
        Task { await state.save() }
    }

    /// Get Info ⌘I: the Info sheet, when nothing is presented over the document.
    @objc func getInfo(_ sender: Any?) {
        readyState?.showInfo()
    }

    /// New Folder (⇧⌘N) in the folder on screen, then its name alert.
    @objc func newFolder(_ sender: Any?) {
        guard let state = readyState, state.canAdd else { return }
        state.newFolder(in: currentPath)
    }

    /// File > Rename: the one item selected in Select mode.
    @objc func renameItem(_ sender: Any?) {
        guard let state = readyState, state.canRenameSelection, let path = state.selection.first else { return }
        state.beginRename(path)
    }

    /// Extract Here (⌥⌘E) on the selection while selecting, else everything, as the toolbar's menu.
    /// A Files picker it needs comes up on the level on screen (`FolderScreen`).
    @objc func extractHere(_ sender: Any?) {
        guard let state = readyState, state.canExtractHere else { return }
        Task { await state.extractHere(state.extractTargets()) }
    }

    /// The selection, in Select mode. Not while the search field is up: there ⌘⌫ is the field's
    /// (delete to the line start), and the field doesn't take `delete:`, so it would land here.
    override func delete(_ sender: Any?) {
        guard let state = readyState, Self.canDeleteByCommand(state) else { return }
        state.delete(state.deleteTargets())
    }

    /// Copy (⌘C) of the selection, in Select mode (`deleteTargets()`); read-only archives too. A focused
    /// search or name field is first responder and takes ⌘C, ⌘X and ⌘V first; with only a caret there it
    /// declines Copy and Cut, which then come here: not while the search or the name alert is up
    /// (`allowsClipboardCommands`).
    override func copy(_ sender: Any?) {
        guard let state = readyState, Self.allowsClipboardCommands(state) else { return }
        let paths = ScreenState.topmost(state.deleteTargets())
        guard state.canCopy(paths) else { return }
        Task { await state.copy(paths) }
    }

    /// Cut (⌘X) of the selection, in Select mode.
    override func cut(_ sender: Any?) {
        guard let state = readyState, Self.allowsClipboardCommands(state) else { return }
        state.cut(ScreenState.topmost(state.deleteTargets()))
    }

    /// Paste (⌘V) into the folder on screen.
    override func paste(_ sender: Any?) {
        guard let state = readyState, Self.allowsClipboardCommands(state), state.canPaste else { return }
        let folder = currentPath
        Task { await state.paste(into: folder) }
    }

    override func selectAll(_ sender: Any?) {
        readyState?.selectAll(in: currentPath)
    }

    override func find(_ sender: Any?) {
        readyState?.isSearchPresented = true
    }

    /// Undo and Redo go through `ScreenState`, which refuses them while a save writes.
    @objc func undo(_ sender: Any?) {
        readyState?.undo()
    }

    @objc func redo(_ sender: Any?) {
        readyState?.redo()
    }

    /// iPadOS 26's File > Close (⌘W): with a document open, closes it, as the back chevron does.
    /// With none, the window closes (`UIWindowScene` further up the chain).
    @available(iOS 26.0, *)
    override func performClose(_ sender: Any?) {
        guard screenState != nil else {
            let action = #selector(UIResponderStandardEditActions.performClose(_:))
            if let target = next?.target(forAction: action, withSender: sender) {
                UIApplication.shared.sendAction(action, to: target, from: sender, for: nil)
            }
            return
        }
        closeArchive(sender)
    }

    /// Close (⌘W) before iPadOS 26. Not over a sheet or preview: it would stay up over the browser.
    @objc func closeArchive(_ sender: Any?) {
        guard let screenState, presentedViewController == nil else { return }
        screenState.closeDocument?()
    }

    // MARK: - Validation

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if Self.isClose(action) { return screenState != nil }
        guard let state = readyState else {
            return Self.documentActions.contains(action) ? false : super.canPerformAction(action, withSender: sender)
        }
        switch action {
        case #selector(saveArchive(_:)): return state.canSaveNow
        case #selector(getInfo(_:)): return state.canShowInfo
        case #selector(UIResponderStandardEditActions.delete(_:)): return Self.canDeleteByCommand(state)
        case #selector(UIResponderStandardEditActions.selectAll(_:)),
             #selector(UIResponderStandardEditActions.find(_:)): return true
        case #selector(UIResponderStandardEditActions.copy(_:)):
            return Self.allowsClipboardCommands(state) && state.canCopy(ScreenState.topmost(state.deleteTargets()))
        case #selector(UIResponderStandardEditActions.cut(_:)):
            return Self.allowsClipboardCommands(state) && state.canCut(ScreenState.topmost(state.deleteTargets()))
        case #selector(UIResponderStandardEditActions.paste(_:)):
            return Self.allowsClipboardCommands(state) && state.canPaste
        case #selector(undo(_:)): return state.canUndo && state.renameUndoManager == nil
        case #selector(redo(_:)): return state.canRedo && state.renameUndoManager == nil
        case #selector(extractHere(_:)): return state.canExtractHere
        case #selector(newFolder(_:)): return state.canAdd
        case #selector(renameItem(_:)): return state.canRenameSelection
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    /// While a document is open, Undo and Redo stop here even when disabled: `UIWindow` further
    /// up the chain would otherwise undo through the first responder's undo manager, which is the
    /// document's, during a save too. Not while the name alert is up: then the first responder's undo
    /// manager is the rename's own (`ScreenState.renameUndoManager`), and ⌘Z and ⇧⌘Z go on up the chain
    /// to undo and redo the field's typing; the document's steps are not ours to undo then
    /// (`canPerformAction`).
    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if let screenState, screenState.renameUndoManager == nil,
           action == #selector(undo(_:)) || action == #selector(redo(_:)) {
            return canPerformAction(action, withSender: sender) ? self : nil
        }
        return super.target(forAction: action, withSender: sender)
    }

    /// The actions this controller implements for the document, besides Close.
    private static let documentActions: Set<Selector> = [
        #selector(saveArchive(_:)),
        #selector(getInfo(_:)),
        #selector(UIResponderStandardEditActions.delete(_:)),
        #selector(UIResponderStandardEditActions.selectAll(_:)),
        #selector(UIResponderStandardEditActions.find(_:)),
        #selector(UIResponderStandardEditActions.copy(_:)),
        #selector(UIResponderStandardEditActions.cut(_:)),
        #selector(UIResponderStandardEditActions.paste(_:)),
        #selector(undo(_:)),
        #selector(redo(_:)),
        #selector(extractHere(_:)),
        #selector(newFolder(_:)),
        #selector(renameItem(_:)),
    ]

    private static func canDeleteByCommand(_ state: ScreenState) -> Bool {
        state.canDeleteSelection && !state.isSearchPresented
    }

    /// ⌘C, ⌘X and ⌘V act on the items: not while the search field or the name alert (Rename, New Folder)
    /// is up, whose text field declines them with only a caret, as Delete (`canDeleteByCommand`).
    private static func allowsClipboardCommands(_ state: ScreenState) -> Bool {
        !state.isSearchPresented && state.renameRequest == nil && state.renameUndoManager == nil
    }

    private static func isClose(_ action: Selector) -> Bool {
        if action == #selector(closeArchive(_:)) { return true }
        if #available(iOS 26.0, *) {
            return action == #selector(UIResponderStandardEditActions.performClose(_:))
        }
        return false
    }
}
