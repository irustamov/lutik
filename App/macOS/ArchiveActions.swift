import AppKit
import KernirCore
import OSLog

/// Commands on one archive window, shared by the toolbar, menus, keyboard and drag and drop.
@MainActor
final class ArchiveActions {
    /// How an error shows when the window is gone. Tests swap it and restore the default afterwards.
    static var presentError: @MainActor (any Error) -> Void = { NSApp.presentError($0) }

    /// Hands copies made by `copyForOpening` to another app: `app`, or each file's default app
    /// when nil. Every open goes through here (double-click, the preview's Open With, the row menu's
    /// Open With with all its files at once), so tests swap it and restore `launchInApp` afterwards;
    /// they never launch another app.
    static var launch: @MainActor (_ files: [URL], _ app: URL?) -> Void = launchInApp

    /// The real `launch`: with an app, one `NSWorkspace.open` for all the files, as Finder opens a
    /// selection. In Debug builds `-KernirOpenWithDryRun YES` (UI tests) only reports what it would
    /// open, in an alert, and launches nothing.
    static func launchInApp(_ files: [URL], _ app: URL?) {
        guard !files.isEmpty else { return }
        #if DEBUG
        if LaunchOverrides.openWithDryRun {
            reportDryRun(files, app)
            return
        }
        #endif
        guard let app else {
            for file in files { NSWorkspace.shared.open(file) }
            return
        }
        NSWorkspace.shared.open(files, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            Task { @MainActor in presentError(error) }
        }
    }

    #if DEBUG
    /// `-KernirOpenWithDryRun`: an alert on the key window names the files and the app, so a UI
    /// test can read what would have opened. English only; never in a release build.
    private static func reportDryRun(_ files: [URL], _ app: URL?) {
        let appName = app.map(PreviewNavigation.appName) ?? "the default app"
        let names = files.map { "“\($0.lastPathComponent)”" }.joined(separator: ", ")
        let text = "Open With dry run: \(names) in “\(appName)”"
        Logger(subsystem: "com.kernir.app", category: "OpenWithDryRun").notice("\(text, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = text
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
    #endif

    private(set) weak var document: ArchiveDocument?
    weak var window: NSWindow?

    /// Resolving the selection for Quick Look; Space again cancels it.
    private var previewTask: Task<Void, Never>?

    /// Extraction and open tasks still running, by id; each removes itself when it ends.
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(document: ArchiveDocument) {
        self.document = document
        observeUndoAndRedo()
        Self.byMoveToken.setObject(self, forKey: moveToken as NSString)
    }

    /// The undo and redo observers; removed when the actions go.
    private let undoObservers = UndoObserverBag()

    /// Undo and redo can take a selected row out of the search results (a rename under a search undone or
    /// redone): only the rows the search shows then stay selected. The notifications come once the whole
    /// step ran: on undo, a rename's remap runs before the model's part of the step.
    private func observeUndoAndRedo() {
        guard let undoManager = document?.undoManager else { return }
        undoObservers.tokens = [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange].map {
            NotificationCenter.default.addObserver(forName: $0, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepOnlyShownRowsSelected() }
            }
        }
    }

    /// Under a search, only the rows it shows stay selected, as when the search changes
    /// (`ArchiveWindowView.applySearch`): Delete never removes a row the search hides.
    private func keepOnlyShownRowsSelected() {
        guard let state, let model, !state.selection.isEmpty,
              !state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let shown = Set(model.items.filtered(matching: state.searchText).flattened().map(\.id))
        if !state.selection.isSubset(of: shown) { state.selection.formIntersection(shown) }
    }

    /// True while an extraction, an open, a Quick Look resolve or a drag-out write is running or waiting, or
    /// another window copies items out of this archive (`copyIn`): View > Text Encoding waits for it as for this
    /// window's own jobs.
    var hasRunningTasks: Bool {
        !tasks.isEmpty || previewTask != nil || hasFilePromiseWork || !outgoingCopies.isEmpty
    }

    /// Runs `body` as a task that `cancelAll()` can cancel.
    func track(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            await body()
            self?.tasks[id] = nil
        }
        tasks[id] = task
        return task
    }

    /// Cancels everything running, e.g. when the document closes. A cancelled task reveals and
    /// presents nothing, and the preview ends: a stand-in still rendering opens no preview window.
    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        shareJob = nil
        // Copies other windows are taking out of this archive stop too, and say why there.
        let outgoing = outgoingCopies.values
        outgoingCopies = [:]
        for stop in outgoing { stop() }
        cancelFilePromises()
        endPreview()
    }

    /// Ends the preview, and stops resolving one. Also when the listing is replaced (View > Text
    /// Encoding's reopen, the reopen after a save): the preview's entries name paths and extracted
    /// files of the old listing, which may be gone or renamed.
    func endPreview() {
        previewTask?.cancel()
        previewTask = nil
        if state?.previewURL != nil { state?.previewURL = nil }
        if state?.previewEntries.isEmpty == false { state?.previewEntries = [] }
    }

    private var state: ArchiveWindowState? { document?.state }
    private var model: ArchiveModel? { state?.model }

    // MARK: - Info

    /// The toolbar's Info item (`ToolbarItem(id:)` in `ArchiveWindowView`).
    static let infoItemID = "info"

    /// File > Get Info (⌘I) and the toolbar's Info button: opens the Info popover at the Info button while it is
    /// on screen, else at the footer; closes it when it is open.
    func toggleInfo() {
        state?.toggleInfo(at: Self.showsInfoButton(in: window?.toolbar) ? .toolbar : .footer)
    }

    /// Whether `toolbar` shows the Info button: it is visible and the button isn't in its overflow menu (a narrow
    /// window). A popover can't point at a button that isn't on screen.
    static func showsInfoButton(in toolbar: NSToolbar?) -> Bool {
        guard let toolbar, toolbar.isVisible else { return false }
        return toolbar.visibleItems?.contains { $0.itemIdentifier.rawValue == infoItemID } ?? false
    }

    // MARK: - Availability (toolbar, menus and keyboard all ask here)

    /// Files can be added: the archive is open in a writable format and no operation (save,
    /// extract) is running, so the model never changes under one.
    var canAdd: Bool { model?.isEditable == true && state?.progress == nil }
    /// `paths` (e.g. the rows under a context menu) can be deleted.
    func canRemove(_ paths: Set<String>) -> Bool { canAdd && !paths.isEmpty }
    /// The selection can be deleted.
    var canRemoveSelection: Bool { canRemove(state?.selection ?? []) }
    /// Names can change (Rename, New Folder): where Add works, and not while View > Text Encoding's reopen
    /// runs, which would adopt a listing without the change (the model drops a reopen that
    /// raced a rename, this keeps the user from starting one).
    var canNewFolder: Bool { canAdd && document?.nameEncodingTask == nil }
    /// `paths` (the rows under a context menu) is one item that can be renamed.
    func canRename(_ paths: Set<String>) -> Bool {
        guard canNewFolder, paths.count == 1, let path = paths.first else { return false }
        return model?.item(at: path) != nil
    }
    /// The selection is one item that can be renamed.
    var canRename: Bool { canRename(state?.selection ?? []) }
    /// `path` is a folder (the context menu offers New Folder in it).
    func isFolder(_ path: String) -> Bool { model?.item(at: path)?.isDirectory == true }
    /// There is something to extract, and no operation (save, extract, View > Text Encoding's
    /// reopen) is running: one started meanwhile would take over its progress sheet and Cancel, and
    /// the reopen renames the items it would extract.
    var canExtract: Bool { model?.items.isEmpty == false && state?.progress == nil }
    /// `paths` can be previewed or opened, and no operation is running: View > Text Encoding's reopen
    /// renames the items, and a copy made from the old listing would be tracked under a name that is gone,
    /// so Update would add a duplicate.
    func canOpen(_ paths: Set<String>) -> Bool { model != nil && !paths.isEmpty && state?.progress == nil }
    /// The selection can be previewed or opened.
    var canOpenSelection: Bool { canOpen(state?.selection ?? []) }
    /// Quick Look can open on the selection, or close (or stop resolving) the preview.
    var canToggleQuickLook: Bool {
        state?.previewURL != nil || previewTask != nil || canOpenSelection
    }

    // MARK: - Adding

    /// Where Add Files… puts files: the selected folder if exactly one folder is selected,
    /// otherwise the top level.
    func destinationForAdd() -> String {
        guard let state, let model, state.selection.count == 1, let path = state.selection.first,
              model.item(at: path)?.isDirectory == true
        else { return "" }
        return path
    }

    func addFiles() {
        guard canAdd, let window else { return }
        let destination = destinationForAdd()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Add",
                    comment: "Add (a verb): the label and VoiceOver label of the toolbar's ＋ button, and the default button of the file panel that adds the chosen files to the archive.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.add(panel.urls, to: destination)
        }
    }

    /// Adds `urls` to `directory`, asking first when that replaces items already there.
    func add(_ urls: [URL], to directory: String) {
        guard canAdd, let model, !urls.isEmpty else { return }
        let conflicts = model.conflicts(adding: urls, to: directory)
        if conflicts.isEmpty {
            model.add(urls, to: directory)
            return
        }
        // Never replace without asking.
        askToReplace(conflicts) { [weak self] in
            guard self?.canAdd == true else { return }
            model.add(urls, to: directory)
        }
    }

    /// Asks on the window whether to replace `conflicts` (paths in the archive, one or more) and runs `replace` on
    /// Replace; nothing on Stop, or without a window. Adding and moving ask the same. Whether it asked: false
    /// without a window.
    @discardableResult
    private func askToReplace(_ conflicts: [String], replace: @escaping @MainActor () -> Void,
                              stop: @escaping @MainActor () -> Void = {}) -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if conflicts.count == 1 {
            let name = ArchiveActionPaths.displayName(of: conflicts[0])
            alert.messageText = String(localized:
                "An item named “\(name)” already exists in this location. Do you want to replace it?",
                comment: "Alert title before adding a file to the archive, or moving an item inside it, over an item with the same name. %@ = that item's name; “this location” is the folder inside the archive. Buttons: Replace, Stop.")
        } else {
            alert.messageText = String(localized:
                "\(conflicts.count) items already exist in this location. Do you want to replace them?",
                comment: "Alert title before adding files to the archive, or moving items inside it, over items with the same names (two or more). %lld = number of those items. Never shown for a single item; in languages whose ‘one’ form also covers 21, 31…, it still means several items.")
        }
        alert.addButton(withTitle: String(localized: "Replace",
                    comment: "Replace (a verb): button of the alerts about an item with the same name when adding, extracting or moving (replaces the existing item), and of the alert about a changed file opened from the archive (replaces the archive's item of that name with it)."))
        // Esc stops, as in Finder.
        alert.addButton(withTitle: String(localized: "Stop",
                    comment: "Button of the alerts about an item with the same name when adding, extracting or moving, also pressed with Esc: stops the whole add, extraction or move.")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                stop()
                return
            }
            replace()
        }
        return true
    }

    /// A drop of files onto the table (`""`) or a folder row. Items dragged out of an archive
    /// window come back as our own temporary files and are ignored. Returns whether it added.
    @discardableResult
    func addDropped(_ urls: [URL], to directory: String) -> Bool {
        let urls = urls.filter { $0.isFileURL && !Self.isOwnTemporaryFile($0) }
        guard canAdd, !urls.isEmpty else { return false }
        add(urls, to: directory)
        return true
    }

    /// True for files `ArchiveModel.localFileURL` made: KernirCore extracts single files under
    /// `<tmp>/Kernir/`, and the model extracts folders under `<tmp>/Kernir-<UUID>/`.
    nonisolated static func isOwnTemporaryFile(_ url: URL) -> Bool {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().pathComponents
        let components = url.resolvingSymlinksInPath().pathComponents
        guard components.count > temporary.count, Array(components.prefix(temporary.count)) == temporary
        else { return false }
        let first = components[temporary.count]
        return first == "Kernir" || first.hasPrefix("Kernir-")
    }

    // MARK: - Copying in from another window

    /// Every window's actions by their move token, held weakly: a drop of rows dragged from another Lutik
    /// window finds that window's archive by the token on the rows (`ArchiveFilePromiseProvider.moveType`).
    private static let byMoveToken = NSMapTable<NSString, ArchiveActions>.strongToWeakObjects()

    /// The actions of the window whose rows carry `token`; nil once that window is gone.
    static func forMoveToken(_ token: String) -> ArchiveActions? {
        byMoveToken.object(forKey: token as NSString)
    }

    /// What a copy from another window asks for: the source's copies (`ArchiveClipboard.export`, into a fresh
    /// `Kernir-Clipboard-<process>/<UUID>` folder) and who answers the replace alert. Tests swap a part.
    struct Copier {
        var export: @MainActor ([String], ArchiveModel, ArchiveProgressHandler?) async throws
            -> (folder: URL, urls: [URL]) = { try await ArchiveClipboard.export($0, from: $1, progress: $2) }
        /// Asks whether to replace the items in the way, and calls back with the answer; nil: the window's alert.
        var confirmReplace: (@MainActor ([String], @escaping @MainActor (Bool) -> Void) -> Void)?
    }

    var copier = Copier()

    /// Stops for copies other windows are taking out of this archive (`copyIn`), by id: `cancelAll` (the
    /// document closing) runs them.
    private var outgoingCopies: [UUID: @MainActor () -> Void] = [:]

    /// The copy stopped because the window it was copying from closed.
    struct CopySourceClosed: LocalizedError {
        var errorDescription: String? {
            String(localized: "The items couldn’t be copied because their archive was closed.",
                   comment: "Alert title when items dragged from another archive window can't be copied in: that window closed while they were being copied.")
        }
    }

    /// `paths` of the archive in `source` (another window) can be copied into `folder` ("" the top level) of
    /// this one: files can be added here (`canAdd`: not read-only, no job running), no sheet is up and no name
    /// field showing, the folder is there, and the source is still open, with its archive, every item, and no
    /// job of its own. Never from this window itself: a drag inside a window moves.
    func canCopyIn(from source: ArchiveActions, paths: [String], into folder: String) -> Bool {
        guard source !== self, canAdd, hasNoSheet, let state, let model, state.renamingPath == nil,
              folder.isEmpty || model.item(at: folder)?.isDirectory == true,
              source.document?.isClosed == false, let sourceModel = source.model, source.state?.progress == nil,
              !paths.isEmpty
        else { return false }
        return paths.allSatisfy { sourceModel.item(at: $0) != nil }
    }

    /// `canCopyIn(from:paths:into:)` for the window whose rows carry `token`.
    func canCopyIn(_ paths: [String], fromMoveToken token: String, into folder: String) -> Bool {
        guard let source = Self.forMoveToken(token) else { return false }
        return canCopyIn(from: source, paths: paths, into: folder)
    }

    /// `copyIn(from:paths:into:)` for the window whose rows carry `token`; whether it started.
    @discardableResult
    func copyIn(_ paths: [String], fromMoveToken token: String, into folder: String) -> Bool {
        guard let source = Self.forMoveToken(token) else { return false }
        return copyIn(from: source, paths: paths, into: folder) != nil
    }

    /// Copies `paths` of the archive in `source` (another window) into `folder` of this one, with this window's
    /// progress sheet up (Cancel stops it silently): the source's model extracts them (`Copier.export`, its
    /// stored password for an encrypted archive), then they are added here as one "Add" undo step, asking
    /// first when that replaces items (Stop adds nothing). Runs as a task, never inside the drop's callbacks.
    /// The source closing meanwhile stops it, and an alert here says why. As Copy (`copyItems`), the copies are
    /// dropped silently when this window's sheet was replaced (a save here), this window closed, or the source
    /// adopted a save or a Text Encoding reopen (`snapshotGeneration`, its model swapped) meanwhile. While it
    /// runs, the source counts it among its jobs (`hasRunningTasks`). The copies stay on disk until a save reads
    /// them; a stopped or refused copy removes its folder. The task, or nil when `canCopyIn` refuses.
    @discardableResult
    func copyIn(from source: ArchiveActions, paths: [String], into folder: String) -> Task<Void, Never>? {
        guard canCopyIn(from: source, paths: paths, into: folder), let state, let sourceModel = source.model
        else { return nil }
        var operation = OperationProgress(title: ArchiveClipboard.progressTitle, fraction: nil, cancel: nil)
        let progress = state.progressHandler(for: operation.id)
        let operationID = operation.id
        let export = copier.export
        let id = UUID()
        let stopped = CopyStop()
        let generation = sourceModel.snapshotGeneration
        let task = track { [weak self, weak source] in
            defer { source?.outgoingCopies[id] = nil }
            let exported: (folder: URL, urls: [URL])
            do {
                exported = try await export(paths, sourceModel, progress)
            } catch {
                if state.progress?.id == operationID { state.progress = nil }
                if stopped.bySource {
                    self?.presentSourceClosed()
                } else if !Self.isCancellation(error) {
                    self?.present(error)
                }
                return
            }
            let sheetWasOurs = state.progress?.id == operationID
            if sheetWasOurs { state.progress = nil }
            // A reader that ignored the cancellation: its copies go, and nothing is added.
            if stopped.bySource {
                ArchiveClipboard.removeExport(exported.folder)
                self?.presentSourceClosed()
                return
            }
            guard let self, !Task.isCancelled, sheetWasOurs, source?.state?.model === sourceModel,
                  sourceModel.snapshotGeneration == generation else {
                ArchiveClipboard.removeExport(exported.folder)
                return
            }
            self.addCopies(exported.urls, from: exported.folder, to: folder)
        }
        source.outgoingCopies[id] = {
            stopped.bySource = true
            task.cancel()
        }
        operation.cancel = { task.cancel() }
        state.progress = operation
        return task
    }

    /// The "source closed" alert, unless this window is closing too (Quit, Close All closing the source first):
    /// `present` would fall back to an app-modal alert during shutdown.
    private func presentSourceClosed() {
        guard document?.isClosed == false else { return }
        present(CopySourceClosed())
    }

    /// Whether the source's closing stopped a copy (`copyIn`).
    @MainActor private final class CopyStop {
        var bySource = false
    }

    /// Adds the copies in `exportFolder` to `directory`, as `add` does but through `Copier.confirmReplace` when
    /// set; removes the folder when nothing is added (Stop, or no window to ask on).
    private func addCopies(_ urls: [URL], from exportFolder: URL, to directory: String) {
        guard canAdd, let model, !urls.isEmpty else {
            ArchiveClipboard.removeExport(exportFolder)
            return
        }
        let conflicts = model.conflicts(adding: urls, to: directory)
        if conflicts.isEmpty {
            model.add(urls, to: directory)
            return
        }
        let answer: @MainActor (Bool) -> Void = { [weak self] replace in
            guard replace, let self, self.canAdd, self.model === model else {
                ArchiveClipboard.removeExport(exportFolder)
                return
            }
            model.add(urls, to: directory)
        }
        if let confirm = copier.confirmReplace {
            confirm(conflicts, answer)
        } else if !askToReplace(conflicts, replace: { answer(true) }, stop: { answer(false) }) {
            ArchiveClipboard.removeExport(exportFolder)
        }
    }

    // MARK: - Removing

    /// Removes `paths` (undoable) and drops them, and anything selected inside them, from the selection. When the
    /// model refuses (`MoveProblem.holdsMovedOutItems`: nothing changed), it says why and the selection stays.
    func remove(_ paths: Set<String>) {
        guard canRemove(paths), let state, let model else { return }
        if let problem = model.remove(paths) {
            // The alert is the feedback: no beep on top of it.
            present(RefusedMove(problem: problem))
            return
        }
        // Ancestor lookups in `paths`, not a scan of it per selected path: ⌘A then Delete stays linear.
        state.selection = state.selection.filter { selected in
            !paths.contains(selected) && !ArchiveModel.isCovered(ArchiveModel.parentPath(of: selected), by: paths)
        }
    }

    /// No sheet (an alert, a panel, the progress sheet) is attached to the window. Edit > Delete (⌘⌫) still
    /// reaches the window with one up: the sheet is key, the archive window main, and a nil-target action
    /// falls through to it. AppKit doesn't publish `attachedSheet` to SwiftUI, so the delete path asks when
    /// it runs (and the menu when it validates), not the toolbar or `onDeleteCommand`, which would keep a
    /// value from a body drawn under the sheet once it ends.
    var hasNoSheet: Bool { window?.attachedSheet == nil }

    /// Removes the selected items (undoable) and clears the selection; nothing while a sheet is up.
    func removeSelection() {
        guard hasNoSheet else { return }
        remove(state?.selection ?? [])
    }

    // MARK: - Renaming

    /// Shows the name field on `path`, or on the one selected item when nil (Return, File > Rename), and
    /// selects it, as in Finder. The folders above it open, and a search that hides it clears (New Folder's
    /// "untitled folder" matches none): a row that never shows would leave the rename without a field to end it.
    func beginRename(_ path: String? = nil) {
        guard let state, let model else { return }
        let paths = path.map { [$0] } ?? state.selection
        guard canRename(paths), let path = paths.first else { return }
        // Already showing: a new undo manager under the live field would lose its typing's undo.
        guard state.renamingPath != path else { return }
        if !state.searchText.isEmpty,
           !model.items.filtered(matching: state.searchText).flattened().contains(where: { $0.path == path }) {
            state.searchText = ""
        }
        for parent in Self.folders(above: path) where !state.expanded.contains(parent) {
            state.expanded.insert(parent)
        }
        if state.selection != [path] { state.selection = [path] }
        renameUndoManager = UndoManager()
        renamingModel = model
        state.renamingPath = path
    }

    /// The folders `path` is in, innermost first.
    nonisolated static func folders(above path: String) -> [String] {
        var folders: [String] = []
        var parent = ArchiveModel.parentPath(of: path)
        while !parent.isEmpty {
            folders.append(parent)
            parent = ArchiveModel.parentPath(of: parent)
        }
        return folders
    }

    /// The listing the name field was shown on. Revert to Saved replaces it: a field still committing then
    /// names an item of a listing that is gone.
    private weak var renamingModel: ArchiveModel?

    /// The name field's own undo manager, new for each rename: the window hands it out while the field shows
    /// (`ArchiveWindowController.windowWillReturnUndoManager`), so ⌘Z there undoes typing and never an
    /// archive edit under the field, and the typing never reaches the document's undo manager.
    private(set) var renameUndoManager = UndoManager()

    /// Renames `path` (the item being renamed when nil) to `name`, as typed, and ends its name field. The
    /// same name changes nothing; an empty one puts the old name back with a beep; a refused one beeps and
    /// says why. Selection, expansion and a name field inside a renamed folder follow the new path. An item
    /// no longer there (a stale field's late commit) changes nothing, silently. A commit while a save runs
    /// (its sheet took the focus) changes nothing yet and returns false: the field stays, with its typed name,
    /// for Return once the save is done. True when the field ended.
    @discardableResult
    func commitRename(_ name: String, of path: String? = nil) -> Bool {
        guard let state, let path = path ?? state.renamingPath else { return true }
        // A save (or another operation under the progress sheet) began meanwhile: the model must not change
        // under it, and the field waits for it to end.
        if state.renamingPath == path, state.progress != nil, let model, model === renamingModel,
           model.item(at: path) != nil {
            return false
        }
        if state.renamingPath == path { state.renamingPath = nil }
        guard canNewFolder, let model, model === renamingModel, model.item(at: path) != nil else { return true }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            NSSound.beep()
            return true
        }
        switch model.rename(path, to: name) {
        case .success(let newPath):
            guard newPath != path else { return true }
            remapPaths(from: path, to: newPath)
            registerRemapUndo(from: path, to: newPath, on: model.undoManager)
            // Under a search, the new name may not match it ("a.txt" → "b.txt" while searching "a.txt").
            keepOnlyShownRowsSelected()
        case .failure(let problem):
            NSSound.beep()
            present(RefusedName(problem: problem))
        }
        return true
    }

    /// Moves the selection, the open folders (those open before a search too) and the name field across a
    /// rename of `oldPath` to `newPath`.
    private func remapPaths(from oldPath: String, to newPath: String) {
        guard let state else { return }
        state.selection = ArchiveModel.remap(state.selection, from: oldPath, to: newPath)
        state.expanded = ArchiveModel.remap(state.expanded, from: oldPath, to: newPath)
        if let expanded = state.expandedBeforeSearch {
            state.expandedBeforeSearch = ArchiveModel.remap(expanded, from: oldPath, to: newPath)
        }
        if let renaming = state.renamingPath {
            state.renamingPath = ArchiveModel.remap([renaming], from: oldPath, to: newPath).first
        }
    }

    /// Undo of the rename `oldPath` → `newPath` maps the paths back, and its redo forward again.
    /// Registered right after the model's "Rename" step, in the same undo group, so the two go together.
    private func registerRemapUndo(from oldPath: String, to newPath: String, on undoManager: UndoManager?) {
        guard let undoManager = Self.groupedUndoManager(undoManager) else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] actions in
            actions.remapPaths(from: newPath, to: oldPath)
            actions.registerRemapUndo(from: newPath, to: oldPath, on: undoManager)
        }
    }

    /// `undoManager` when a registration now lands in a group: one is open, or it opens one per event (every
    /// window's). Nil otherwise: a manager that doesn't group by event raises
    /// NSInternalInconsistencyException on a registration outside a group, which Swift can't catch.
    private static func groupedUndoManager(_ undoManager: UndoManager?) -> UndoManager? {
        guard let undoManager, undoManager.groupsByEvent || undoManager.groupingLevel > 0 else { return nil }
        return undoManager
    }

    // MARK: - Moving

    /// What a move inside the archive asks of the model (its `conflicts(moving:into:)` and `move(_:into:)`) and
    /// who answers the replace alert: tests swap a part for one that records, refuses or answers.
    struct Mover {
        var conflicts: @MainActor (ArchiveModel, [String], String) -> [String] = { $0.conflicts(moving: $1, into: $2) }
        var move: @MainActor (ArchiveModel, [String], String) -> Result<[String: String], MoveProblem> = {
            $0.move($1, into: $2)
        }
        /// Asks whether to replace the items in the way, and calls back with the answer; nil: the window's alert.
        var confirmReplace: (@MainActor ([String], @escaping @MainActor (Bool) -> Void) -> Void)?
    }

    var mover = Mover()

    /// The move the Move To… sheet's Move chose, run once the sheet is gone (`moveToSheetDidEnd`).
    private var chosenMove: (paths: [String], folder: String)?

    /// This window's mark on the rows it drags (`ArchiveFilePromiseProvider.moveType`): a drop takes a move
    /// only from its own window's table, never from another Lutik window's.
    let moveToken = UUID().uuidString

    /// `paths` can move into `folder` ("" the top level): names can change (`canNewFolder`), no name field is
    /// showing, no sheet is up (`hasNoSheet`: one can come up during the drag, and a conflict would queue a
    /// second), every item and the folder are there, and the move does something (not into a moved item or
    /// beneath one, not all already in `folder`).
    func canMove(_ paths: [String], into folder: String) -> Bool {
        hasNoSheet && canMoveUnderTheAlert(paths, into: folder)
    }

    /// `canMove` but for the sheet: the replace alert's answer comes while the alert may still be attached.
    private func canMoveUnderTheAlert(_ paths: [String], into folder: String) -> Bool {
        guard canMoveItems(paths), let model,
              folder.isEmpty || model.item(at: folder)?.isDirectory == true,
              case .success(let roots) = MovePlanning.roots(paths, into: folder), !roots.isEmpty
        else { return false }
        return true
    }

    /// The part of `canMoveUnderTheAlert` no folder changes: names can change, no name field is showing, and
    /// every item is there.
    private func canMoveItems(_ paths: [String]) -> Bool {
        guard canNewFolder, let state, let model, state.renamingPath == nil, !paths.isEmpty else { return false }
        return paths.allSatisfy { model.item(at: $0) != nil }
    }

    /// `canMove(paths, into:)` for every folder of one move (Move To…): what no folder changes is checked once,
    /// nil when that fails; each folder then costs O(its depth) (`MoveToFolders.Targets`), not O(paths).
    private func moveCheck(_ paths: [String]) -> (@MainActor (String) -> Bool)? {
        guard hasNoSheet, canMoveItems(paths), let model else { return nil }
        let targets = MoveToFolders.Targets(paths: paths)
        return { folder in
            (folder.isEmpty || model.item(at: folder)?.isDirectory == true) && targets.takes(folder)
        }
    }

    /// Moves `paths` into `folder` ("" the top level), as one undo step, asking first when that replaces items
    /// there (Stop moves nothing). The selection and the open folders follow the items. Whether it took them:
    /// false when it can't move them, the model refuses (it says why), or there are items in the way and no
    /// window to ask on; true once it asks about replacing. `moved` runs once at least one item did move (after
    /// the Replace answer when it asks; never on Stop, a refusal, or a move that moved nothing).
    @discardableResult
    func move(_ paths: [String], into folder: String, moved: (@MainActor () -> Void)? = nil) -> Bool {
        guard canMove(paths, into: folder), let model else { return false }
        let conflicts = mover.conflicts(model, paths, folder)
        if conflicts.isEmpty {
            let outcome = performMove(paths, into: folder, in: model)
            if outcome.moved { moved?() }
            return outcome.took
        }
        let replace: @MainActor () -> Void = { [weak self] in
            guard let self, self.model === model, canMoveUnderTheAlert(paths, into: folder) else { return }
            if performMove(paths, into: folder, in: model).moved { moved?() }
        }
        if let confirm = mover.confirmReplace {
            confirm(conflicts) { if $0 { replace() } }
            return true
        }
        return askToReplace(conflicts, replace: replace)
    }

    /// The one call of the model's move: it replaces the items in the way itself, in its one "Move" undo
    /// step. The remap undo registered after it lands in the same group, so one Undo takes back both. `took`
    /// false when the model refused (nothing moved): the alert says why, with no beep on top of it. `moved`
    /// only when the model moved at least one item (it can take a move and move nothing).
    private func performMove(_ paths: [String], into folder: String,
                             in model: ArchiveModel) -> (took: Bool, moved: Bool) {
        switch mover.move(model, paths, folder) {
        case .success(let moves):
            guard !moves.isEmpty, let state else { return (true, !moves.isEmpty) }
            remapPaths(moves: moves)
            // The undo restores this selection, taken before a search drops the moved rows it no longer
            // shows: a pruned row would otherwise stay unselected after the Undo.
            registerRemapUndo(moves: moves, selection: state.selection, on: model.undoManager)
            keepOnlyShownRowsSelected()
            return (true, true)
        case .failure(let problem):
            present(RefusedMove(problem: problem))
            return (false, false)
        }
    }

    /// Moves the selection and the open folders (those open before a search too) across `moves` (old path →
    /// new path, every moved item at once).
    private func remapPaths(moves: [String: String]) {
        guard let state else { return }
        state.selection = ArchiveModel.remap(state.selection, moves: moves)
        state.expanded = ArchiveModel.remap(state.expanded, moves: moves)
        if let expanded = state.expandedBeforeSearch {
            state.expandedBeforeSearch = ArchiveModel.remap(expanded, moves: moves)
        }
    }

    /// Undo of a move maps the paths back, and its redo forward again, in the model's "Move" undo group.
    /// `selection` is the selection right after the move, before a search pruned it: the step selects it again
    /// (mapped back), and the undo observer then keeps only the rows the search shows.
    private func registerRemapUndo(moves: [String: String], selection: Set<String>, on undoManager: UndoManager?) {
        guard let undoManager = Self.groupedUndoManager(undoManager) else { return }
        undoManager.registerUndo(withTarget: self) { [weak undoManager] actions in
            let back = Dictionary(moves.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            actions.remapPaths(moves: back)
            let restored = ArchiveModel.remap(selection, moves: back)
            actions.state?.selection = restored
            actions.registerRemapUndo(moves: back, selection: restored, on: undoManager)
        }
    }

    // MARK: - Move To…

    /// The Move To… sheet's folders for `paths` (the rows under the context menu) now; nil when no folder takes
    /// them (`canMove` refuses every one: read-only, a job or a sheet up, a name field showing, nothing to do).
    func moveToFolders(for paths: Set<String>) -> MoveToFolders? {
        guard let model, !paths.isEmpty else { return nil }
        let paths = paths.sorted()
        guard let canMoveInto = moveCheck(paths) else { return nil }
        let folders = MoveToFolders(paths: paths, items: model.items, archiveName: document?.displayName ?? "",
                                    canMove: { _, folder in canMoveInto(folder) })
        return folders.hasTarget ? folders : nil
    }

    /// The context menu's Move To…: some folder takes `paths` (`moveToFolders` without building the tree, and
    /// stopping at the first folder: the menu asks on every right-click, with ⌘A on a big archive too).
    func canMoveTo(_ paths: Set<String>) -> Bool {
        guard let model, !paths.isEmpty else { return false }
        let paths = paths.sorted()
        guard let canMoveInto = moveCheck(paths) else { return false }
        return MoveToFolders.hasTarget(paths: paths, items: model.items, canMove: { _, folder in canMoveInto(folder) })
    }

    /// Shows the Move To… sheet for `paths`; nothing when no folder takes them.
    func beginMoveTo(_ paths: Set<String>) {
        guard let state, state.moveTo == nil, let folders = moveToFolders(for: paths) else { return }
        chosenMove = nil
        state.moveTo = folders
    }

    /// The sheet's Move: closes the sheet; its items move into `folder` once it is gone (`moveToSheetDidEnd`), so
    /// the replace alert can attach. Nothing for a row the sheet shows disabled.
    func chooseMoveTo(_ folder: String) {
        guard let state, let folders = state.moveTo, folders.isEnabled(folder) else { return }
        chosenMove = (folders.paths, folder)
        state.moveTo = nil
    }

    /// The sheet's Cancel (Esc): closes it, moving nothing.
    func cancelMoveTo() {
        chosenMove = nil
        state?.moveTo = nil
    }

    /// Runs the chosen Move To once `window` has no sheet attached (`NSWindow.whenNoSheetAttached`, which gives
    /// up after 2 s); tests swap it to run the move at a moment they pick.
    var whenNoSheetAttached: @MainActor (NSWindow, @escaping @MainActor () -> Void) -> Void = {
        $0.whenNoSheetAttached($1)
    }

    /// The beep of a chosen Move To that can no longer run; tests count it.
    var beep: @MainActor () -> Void = { NSSound.beep() }

    private static let moveToLogger = Logger(subsystem: "com.kernir.app", category: "moveTo")

    /// The sheet's `onDismiss`: runs the chosen move, once AppKit no longer has the sheet attached (SwiftUI may
    /// still be ending it, and `canMove` refuses under a sheet). A move that can't run then (the sheet still
    /// attached when the wait gives up, or the archive changed meanwhile) beeps rather than go silently; one the
    /// model refuses says why in its alert, with no beep on top of it (as `performMove`). With no window there is
    /// no sheet to wait for: the move runs at once, and beeps the same when it can't.
    func moveToSheetDidEnd() {
        guard let chosen = chosenMove else { return }
        chosenMove = nil
        guard let window else {
            runChosenMove(chosen)
            return
        }
        whenNoSheetAttached(window) { [weak self] in
            self?.runChosenMove(chosen)
        }
    }

    /// Moves the sheet's chosen items, or beeps and logs why not when `canMove` refuses them now.
    private func runChosenMove(_ chosen: (paths: [String], folder: String)) {
        guard canMove(chosen.paths, into: chosen.folder) else {
            let count = chosen.paths.count, sheetAttached = !hasNoSheet
            Self.moveToLogger.notice(
                "Move To didn't run: \(count) item(s) can't move now, sheet attached: \(sheetAttached)")
            beep()
            return
        }
        _ = move(chosen.paths, into: chosen.folder)
    }

    /// A move, or a Delete, the model refused, presented as `MovePlanning.message(for:)`.
    private struct RefusedMove: LocalizedError {
        let problem: MoveProblem
        var errorDescription: String? { MovePlanning.message(for: problem) }
    }

    /// The drag's writer for the row at `path`: its file promise, or nil (the drag leaves the row out) for the
    /// row being renamed and the rows inside it. Its field commits as the drag takes the focus, after the
    /// promise took the old path, and the drop would ask for a path that is gone.
    /// Nil too for a path no longer there: a field that committed before AppKit asked for the writers has
    /// already moved its rows, which still name the old path.
    func dragWriter(for path: String, drop: UUID) -> NSFilePromiseProvider? {
        if let renaming = state?.renamingPath, path == renaming || Self.folders(above: path).contains(renaming) {
            return nil
        }
        guard model?.item(at: path) != nil else { return nil }
        let provider = filePromise(for: path, drop: drop)
        if let provider = provider as? ArchiveFilePromiseProvider {
            provider.moveToken = moveToken
            provider.dragOutFiles = dragOutFiles(for: path, drop: drop)
        }
        return provider
    }

    /// Ends the name field on `path` (the one being renamed when nil), keeping the old name (Esc).
    func cancelRename(_ path: String? = nil) {
        guard let state, path == nil || state.renamingPath == path else { return }
        state.renamingPath = nil
    }

    /// File > New Folder (⇧⌘N): a new folder where Add Files… would add, which opens, selected, with its
    /// name field showing.
    func newFolder() {
        newFolder(in: destinationForAdd())
    }

    /// New Folder in the folder `directory` ("" = the top level), e.g. the row under a context menu.
    func newFolder(in directory: String) {
        guard canNewFolder, let state, let model else { return }
        do {
            let path = try model.newFolder(in: directory)
            if !directory.isEmpty { state.expanded.insert(directory) }
            beginRename(path)
        } catch {
            present(error)
        }
    }

    /// A name Rename refused, presented as `EntryNameValidation.message(for:)`.
    private struct RefusedName: LocalizedError {
        let problem: EntryNameProblem
        var errorDescription: String? { EntryNameValidation.message(for: problem) }
    }

    // MARK: - Extracting

    /// Extracts the selection, or everything when nothing is selected.
    func extract(nextToArchive: Bool) {
        extract(state?.selection ?? [], nextToArchive: nextToArchive)
    }

    /// Extracts `paths` (everything when empty) into a folder the user picks, or with
    /// `nextToArchive` (Option) into a new folder named after the archive beside it.
    func extract(_ paths: Set<String>, nextToArchive: Bool) {
        guard canExtract else { return }
        let archiveFolder = document?.fileURL?.deletingLastPathComponent()
        if nextToArchive, let archiveURL = document?.fileURL, let archiveFolder {
            let isVolumeSet = (model?.reader?.volumeURLs.count ?? 0) > 1
            let name = Self.extractionFolderName(for: archiveURL, isVolumeSet: isVolumeSet)
            let destination = Self.uniqueFolder(named: name, in: archiveFolder)
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            } catch where Self.isPermissionError(error) {
                // Typically the sandbox (only the archive itself is ours, not its folder) or a
                // read-only volume such as a disk image.
                chooseExtractionFolder(for: paths, startingAt: archiveFolder)
                return
            } catch {
                present(error)
                return
            }
            startExtraction(paths, to: destination)
            return
        }
        chooseExtractionFolder(for: paths, startingAt: archiveFolder)
    }

    private func chooseExtractionFolder(for paths: Set<String>, startingAt directory: URL?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Extract",
                    comment: "Extract (a verb): the label and VoiceOver label of the toolbar's Extract button, and the default button of the folder panels that pick where to extract (also the panel opened by “Extract to Another Folder…” after Finder's “Extract Here with Lutik” couldn't write in the archive's folder).")
        if let directory { panel.directoryURL = directory }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.extractAskingAboutConflicts(paths, to: destination)
        }
    }

    /// Extracts into a folder the user picked. Items whose names are taken there are asked about
    /// one by one, as Finder does, before anything is written; Stop extracts nothing.
    private func extractAskingAboutConflicts(_ paths: Set<String>, to destination: URL) {
        guard let model else { return }
        let scan = model.extractionConflictScan(paths.isEmpty ? nil : Self.topmost(paths), in: destination)
        if scan.conflicts.isEmpty {
            startExtraction(paths, to: destination)
            return
        }
        // Never replace without asking.
        guard let window else { return }
        askAboutConflicts(scan.conflicts[...], of: scan, resolved: [:], in: window) { [weak self] resolutions in
            self?.startExtraction(paths, to: destination, resolutions: resolutions)
        }
    }

    /// Asks about `conflicts` in order, then hands every answer to `extract`. Apply to All answers
    /// the rest the same way. `conflicts` are what is left of `scan`'s; each question names what holds
    /// the name after the answers so far (`extractionConflictAlert(for:in:resolved:showsApplyToAll:)`).
    private func askAboutConflicts(_ conflicts: ArraySlice<String>, of scan: ExtractionConflictScan,
                                   resolved: [String: ExtractionConflictResolution], in window: NSWindow,
                                   then extract: @escaping @MainActor ([String: ExtractionConflictResolution]) -> Void) {
        guard let path = conflicts.first else {
            extract(resolved)
            return
        }
        let alert = Self.extractionConflictAlert(for: path, in: scan, resolved: resolved,
                                                 showsApplyToAll: conflicts.count > 1)
        window.whenNoSheetAttached {
            alert.beginSheetModal(for: window) { [weak self] response in
                let resolution: ExtractionConflictResolution
                switch response {
                case .alertFirstButtonReturn: resolution = .replace
                case .alertThirdButtonReturn: resolution = .keepBoth
                default: return  // Stop
                }
                var resolved = resolved
                if alert.suppressionButton?.state == .on {
                    for path in conflicts { resolved[path] = resolution }
                    extract(resolved)
                } else {
                    resolved[path] = resolution
                    self?.askAboutConflicts(conflicts.dropFirst(), of: scan, resolved: resolved, in: window,
                                           then: extract)
                }
            }
        }
    }

    /// The question about conflict `path` of `scan`, given the answers so far (`resolved`): a case-only
    /// twin's names it and the twin holding the name then (`ExtractionConflictScan.earlierTwin`), by their
    /// names or, when those read the same, their paths (`ArchiveModel.twinNames`).
    static func extractionConflictAlert(for path: String, in scan: ExtractionConflictScan,
                                        resolved: [String: ExtractionConflictResolution],
                                        showsApplyToAll: Bool) -> NSAlert {
        guard let earlier = scan.earlierTwin(of: path, answers: resolved) else {
            return extractionConflictAlert(name: ArchiveActionPaths.displayName(of: path),
                                           showsApplyToAll: showsApplyToAll)
        }
        let names = ArchiveModel.twinNames(of: path, earlier: earlier)
        return extractionConflictAlert(name: names.name, showsApplyToAll: showsApplyToAll, earlierTwin: names.earlier)
    }

    /// Finder's question when an item is in the way: Keep Both, Stop, Replace from left to right.
    /// Return replaces and Esc stops, as in Finder. With `earlierTwin`, the item `name` is a case-only
    /// twin of that one in the same archive (nothing is on disk yet), and the title names both.
    static func extractionConflictAlert(name: String, showsApplyToAll: Bool, earlierTwin: String? = nil) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let earlier = earlierTwin {
            alert.messageText = String(localized:
                "“\(name)” and “\(earlier)” would get the same name in this location. Do you want to replace “\(earlier)” with “\(name)”?",
                comment: "Alert title when two items in the archive differ only in letter case (Readme / README) and are extracted to a volume that ignores case, so the later one would take the earlier one's name. Neither is in the folder yet. %1$@ and %4$@ = the later item's name, %2$@ and %3$@ = the earlier item's name; either may be a file or a folder (or a path, when the names alone read the same). “this location” is the folder being extracted into. Buttons: Replace, Stop, Keep Both.")
        } else {
            alert.messageText = String(localized:
                "An item named “\(name)” already exists in this location. Do you want to replace it with the one you're extracting?",
                comment: "Alert title when an extracted item would overwrite one with the same name in the folder. %@ = that item's name; “this location” is the folder being extracted into. Buttons: Replace, Stop, Keep Both.")
        }
        alert.addButton(withTitle: String(localized: "Replace",
                    comment: "Replace (a verb): button of the alerts about an item with the same name when adding, extracting or moving (replaces the existing item), and of the alert about a changed file opened from the archive (replaces the archive's item of that name with it)."))
            .setAccessibilityIdentifier("extractConflict.replace")
        let stop = alert.addButton(withTitle: String(localized: "Stop",
                    comment: "Button of the alerts about an item with the same name when adding, extracting or moving, also pressed with Esc: stops the whole add, extraction or move."))
        stop.keyEquivalent = "\u{1b}"
        stop.setAccessibilityIdentifier("extractConflict.stop")
        alert.addButton(withTitle: String(localized: "Keep Both",
                    comment: "Keep Both (a button): in the alert about an extracted item with the same name, keeps the existing item and extracts the new one under a new name; in the alert about a file saved next to a file opened from the archive, adds the file to the archive under a new name."))
            .setAccessibilityIdentifier("extractConflict.keepBoth")
        if showsApplyToAll {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Apply to All",
                    comment: "Checkbox of the alert about an extracted item with the same name: gives the same answer for every later item with a taken name in this extraction.")
            alert.suppressionButton?.setAccessibilityIdentifier("extractConflict.applyToAll")
        }
        return alert
    }

    /// Extracts with the progress sheet up; Cancel cancels. Shows the result in Finder (`ExtractionReveal`).
    private func startExtraction(_ paths: Set<String>, to destination: URL,
                                 resolutions: [String: ExtractionConflictResolution] = [:]) {
        // A folder panel or conflict alert answered after another operation began: never two at once.
        guard let state, let model, state.progress == nil else { return }
        let request = paths.isEmpty ? nil : Self.topmost(paths)
        // The sheet's identity comes first: only its own updates may move its bar.
        let name = document?.displayName ?? destination.lastPathComponent
        var operation = OperationProgress(title: String(localized: "Extracting “\(name)”…",
                                                        comment: "Title of the progress sheet while extracting. %@ = the archive's name."),
                                          fraction: nil, cancel: nil)
        let progress = state.progressHandler(for: operation.id)
        let task = track { [weak self] in
            do {
                let placed = try await model.extract(request, to: destination, resolutions: resolutions, progress: progress)
                // A reader that ignored the cancellation must not reveal a half-done extraction.
                try Task.checkCancellation()
                state.progress = nil
                // Inside the destination, the new items selected; not the destination in its parent.
                ExtractionReveal.reveal(placed: placed, in: destination)
            } catch {
                state.progress = nil
                if !Self.isCancellation(error) { self?.present(error) }
                // A Replace that failed kept the original under another name or in a folder of its
                // own: show the user where it is.
                if let recovery = error as? ExtractionRecoveryError {
                    NSWorkspace.shared.activateFileViewerSelecting([recovery.kept])
                }
            }
        }
        operation.cancel = { task.cancel() }
        state.progress = operation
    }

    /// Extract Here's name (`ExtractHereNaming.folderName`), the archive's base name (`ArchiveBaseName`):
    /// “project” for project.zip and project.tar.gz. A split archive's is the set's name: “Photos” for
    /// Photos.zip.001 and Photos.part1.rar.
    nonisolated static func extractionFolderName(for archiveURL: URL, isVolumeSet: Bool = false) -> String {
        ExtractHereNaming.folderName(for: archiveURL, isVolumeSet: isVolumeSet)
    }

    /// `directory/name`, or the first free “name 2”, “name 3”… as Finder numbers copies.
    nonisolated static func uniqueFolder(named name: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(name, isDirectory: true)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(number)", isDirectory: true)
            number += 1
        }
        return candidate
    }

    /// Drops paths inside another selected folder: extracting the folder covers them.
    nonisolated static func topmost(_ paths: Set<String>) -> [String] {
        paths.filter { !ArchiveModel.isCovered(ArchiveModel.parentPath(of: $0), by: paths) }.sorted()
    }

    /// The location can't be written: no permission (e.g. the sandbox) or a read-only volume.
    nonisolated static func isPermissionError(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileWriteVolumeReadOnly.rawValue]
            .contains(error.code) {
            return true
        }
        let posix = error.domain == NSPOSIXErrorDomain ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
        guard let posix, posix.domain == NSPOSIXErrorDomain else { return false }
        return [EPERM, EACCES, EROFS].map(Int.init).contains(posix.code)
    }

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case ArchiveError.cancelled = error { return true }
        return false
    }

    // MARK: - Quick Look and opening

    /// Space and File > Quick Look: previews the selection, or closes the preview.
    func toggleQuickLook() {
        guard let state else { return }
        if state.previewURL != nil || previewTask != nil {
            previewTask?.cancel()
            previewTask = nil
            state.previewURL = nil
        } else {
            quickLook(state.selection)
        }
    }

    /// Extracts `paths` to temporary files and previews them, in the window's order.
    func quickLook(_ paths: Set<String>) {
        guard canOpen(paths), let state, let model else { return }
        let paths = ordered(paths)
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            var entries: [PreviewEntry] = []
            var firstError: (any Error)?
            for path in paths {
                do {
                    entries.append(PreviewEntry(path: path, url: try await model.localFileURL(for: path)))
                } catch {
                    firstError = firstError ?? error
                }
            }
            guard !Task.isCancelled else { return }
            self?.previewTask = nil
            guard let first = entries.first else {
                if let firstError { self?.present(firstError) }
                return
            }
            state.previewEntries = entries
            state.previewURL = first.url
        }
    }

    /// The selection changed: a name field on another row ends, and an open (or opening) preview shows the
    /// new selection instead.
    func selectionDidChange() {
        guard let state else { return }
        // The selection left the row being renamed: its field ends, committing as a click elsewhere does.
        if let renaming = state.renamingPath, state.selection != [renaming] { state.renamingPath = nil }
        guard state.previewURL != nil || previewTask != nil, canOpenSelection else { return }
        quickLook(state.selection)
    }

    /// Selects the visible row `step` rows below (or above) the selection, if there is one.
    func movePreviewSelection(by step: Int) {
        guard let state, let row = Self.row(movedBy: step, from: state.selection, in: visibleRows()) else { return }
        state.selection = [row]
    }

    /// The table's rows top to bottom: filtered and sorted as the table shows them, with the
    /// contents of open folders under them.
    func visibleRows() -> [String] {
        guard let state, let model else { return [] }
        var rows: [String] = []
        func append(_ items: [ArchiveItem]) {
            for item in items {
                rows.append(item.path)
                if let children = item.children, state.expanded.contains(item.id) { append(children) }
            }
        }
        append(state.tableItems(of: model))
        return rows
    }

    /// ↓ (+1) or ↑ (-1) in the preview window (`PreviewNavigation.key`); nil for any other key,
    /// or with a modifier.
    nonisolated static func previewStep(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Int? {
        guard case .move(let step) = PreviewNavigation.key(keyCode: keyCode, modifierFlags: modifierFlags)
        else { return nil }
        return step
    }

    /// The row `step` rows from the selection in `rows`: ↓ counts from the last selected row, ↑
    /// from the first. With no selected row in `rows`, ↓ starts at the top and ↑ at the bottom.
    /// nil past either end.
    nonisolated static func row(movedBy step: Int, from selection: Set<String>, in rows: [String]) -> String? {
        let selected = rows.indices.filter { selection.contains(rows[$0]) }
        guard let anchor = step > 0 ? selected.last : selected.first else {
            return step > 0 ? rows.first : rows.last
        }
        let target = anchor + step
        return rows.indices.contains(target) ? rows[target] : nil
    }

    /// Double-click: opens the selection.
    func openSelectionInDefaultApp() {
        open(state?.selection ?? [])
    }

    /// Folders open or close in place; files are extracted and opened in their default app.
    func open(_ paths: Set<String>) {
        guard canOpen(paths), let state, let model else { return }
        for path in ordered(paths) {
            guard let item = model.item(at: path) else { continue }
            if item.isDirectory {
                if state.expanded.contains(item.id) {
                    state.expanded.remove(item.id)
                } else {
                    state.expanded.insert(item.id)
                }
            } else {
                openFile(item.path)
            }
        }
    }

    /// The extracted file for the entry at `path` (`ArchiveModel.localFileURL(for:)`): the
    /// reader's cache file, extracted again if a save or a reader swap deleted it. Share's
    /// re-extract: like opening, it waits for no operation to run (`canOpen`), since a save or
    /// View > Text Encoding's reopen replaces the reader it would read; `CancellationError` then.
    func localFileURL(for path: String) async throws -> URL {
        guard let model, state?.progress == nil else { throw CancellationError() }
        return try await model.localFileURL(for: path)
    }

    /// Whether the file at `path` can be opened in an app: a file, not a folder, and no operation
    /// running, as for `canOpen`: the preview window's Open With comes here,
    /// not through `open(_:)`.
    func canOpenFile(_ path: String) -> Bool {
        state?.progress == nil && model?.item(at: path).map { !$0.isDirectory } == true
    }

    /// Opens the file at `path` in `app`, or in its default app when nil: double-click, ⌘↓ and
    /// the preview's Open With all come here. The app gets a copy (`copyForOpening`) whose
    /// changes come back on close; Lutik itself (an archive inside the archive) opens it as an
    /// untitled document of its own. Never the preview's stand-in: the entry's real file.
    func openFile(_ path: String, withApplicationAt app: URL? = nil) {
        guard let model, canOpenFile(path) else { return }
        _ = track { [weak self] in
            // An inner archive's extracted file can be the reader's cache, which goes with the reader: a save
            // meanwhile adopts a new one, so this one is kept until the file is copied.
            // Taken where the task starts, with no suspension before the extraction: the reader extracted from.
            let reader = model.reader
            defer { withExtendedLifetime(reader) {} }
            do {
                // An inner archive gets a copy of its own document's, not one this
                // window tracks: only files opened in other apps come back on close.
                let archive: URL
                if let app, Self.isKernir(app) {
                    archive = try await model.localFileURL(for: path)
                } else {
                    do {
                        // Copies off the main actor; a close or `cancelAll()` meanwhile, or once
                        // the copy is made, throws CancellationError and leaves no copy. The default
                        // app is asked about the extracted file inside the copy, which tracks its item
                        // from the start: a rename or a swap of names meanwhile never opens another
                        // item, nor fails to find this one.
                        let url = try await model.copyForOpening(path) { local in
                            if app == nil, Self.opensInKernir(local) { throw InnerArchive(local: local) }
                        }
                        return try Self.launchCopy(url, in: app, of: model.openedFiles)
                    } catch let inner as InnerArchive {
                        archive = inner.local
                    }
                }
                try Task.checkCancellation()
                try await Self.openAsUntitledCopy(of: archive, quarantinedLike: model.quarantineSources)
            } catch {
                if !Self.isCancellation(error) { self?.present(error) }
            }
        }
    }

    /// Ends `copyForOpening`'s check for a file Lutik itself opens: `local`, the extracted file, opens as an
    /// untitled document instead (`openAsUntitledCopy`), with no copy made or tracked.
    private struct InnerArchive: Error {
        let local: URL
    }

    /// Hands the copy at `url`, just made by `copyForOpening`, to `app` (`launch`). A task cancelled
    /// since the copy was tracked launches nothing: the copy is deleted and forgotten, so a closed
    /// window's file never opens in another app, and none is left behind or asked about on close.
    static func launchCopy(_ url: URL, in app: URL?, of openedFiles: OpenedFiles) throws {
        try launchCopies([url], in: app, of: openedFiles)
    }

    /// `launchCopy` for several copies, handed to `app` in one `launch`: a cancelled task launches none of
    /// them, and they all go.
    static func launchCopies(_ urls: [URL], in app: URL?, of openedFiles: OpenedFiles) throws {
        guard !Task.isCancelled else {
            for url in urls { openedFiles.discard(url) }
            throw CancellationError()
        }
        launch(urls, app)
    }

    /// Whether Lutik itself is the app `url` would open in (an archive inside the archive).
    static func opensInKernir(_ url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url).map(isKernir) ?? false
    }

    /// Whether the app at `app` is this Lutik.
    static func isKernir(_ app: URL) -> Bool {
        app.standardizedFileURL.resolvingSymlinksInPath() == Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Opens an archive as a new untitled document named after it, reading from a copy the new
    /// document owns and deletes on close. Never added to Open Recent; ⌘S runs the Save panel.
    /// The copy gets the quarantine of the archive it came out of, `outer` (`QuarantinePropagation`):
    /// in the sandbox it only has Lutik's own, which is never carried over.
    @discardableResult
    static func openAsUntitledCopy(of url: URL, quarantinedLike outer: [URL] = []) async throws -> ArchiveDocument {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kernir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        let controller = NSDocumentController.shared
        let document: ArchiveDocument
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            QuarantinePropagation.propagate(from: outer, to: [copy], recursive: false)
            let type = try controller.typeForContents(of: copy)
            guard let made = try controller.makeDocument(withContentsOf: copy, ofType: type) as? ArchiveDocument else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            document = made
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        document.ownedTemporaryDirectory = folder
        document.fileURL = nil
        document.displayName = url.deletingPathExtension().lastPathComponent
        controller.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
        return document
    }

    /// `paths` in the window's order, top to bottom as if every folder were open. Sorts only
    /// these items (by their chains of folders), never the whole tree.
    func ordered(_ paths: Set<String>) -> [String] {
        guard let state, let model else { return [] }
        let sortOrder = state.sortOrder
        // Each item with its ancestors, outermost first.
        let chains: [[ArchiveItem]] = paths.compactMap { ArchiveActionPaths.items(chainOf: $0, in: model) }
        // Siblings as the table orders them: folders first, then the sort order (ArchiveItem.sorted).
        func precedes(_ a: ArchiveItem, _ b: ArchiveItem) -> Bool {
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            for comparator in sortOrder {
                switch comparator.compare(a, b) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: continue
                }
            }
            return a.path.utf8.lexicographicallyPrecedes(b.path.utf8)
        }
        return chains.sorted { a, b in
            for (x, y) in zip(a, b) where x.path != y.path {
                return precedes(x, y)
            }
            return a.count < b.count  // a folder comes before what is inside it
        }.map { $0[$0.count - 1].path }
    }

    // MARK: - Open With and Share (row menu)

    /// The row menu's Open With and Share for `paths`, the clicked or selected rows, made each
    /// time the menu opens: in no order (`ordered` runs when an item is chosen), and the apps come from each
    /// file's type, by its name: nothing is extracted until an item is chosen.
    func rowMenu(for paths: Set<String>) -> ArchiveRowMenu {
        let rows = paths.compactMap { path in
            model?.item(at: path).map { ArchiveRowMenu.Row(path: $0.path, isDirectory: $0.isDirectory) }
        }
        return ArchiveRowMenu(rows: rows, canRun: canOpen(paths), isSharing: isSharing,
                              appsToOpen: { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
                              defaultApp: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
                              name: PreviewNavigation.appName)
    }

    /// Open With's app: the files open in `app` in the window's order, through copies whose changes come back
    /// on close (`copyForOpening`), all handed over in one `launch` as Finder does, in one job `cancelAll()`
    /// cancels. Lutik itself opens each one as a double-click does (`openFile`): an untitled document each.
    /// Files that can't be copied are left out; the first error shows after the rest opened.
    @discardableResult
    func open(_ paths: Set<String>, withApplicationAt app: URL) -> Task<Void, Never>? {
        let files = ordered(paths).filter(canOpenFile)
        guard let model, !files.isEmpty else { return nil }
        if Self.isKernir(app) {
            for path in files { openFile(path, withApplicationAt: app) }
            return nil
        }
        return track { [weak self] in
            var copies: [URL] = []
            var firstError: (any Error)?
            for path in files {
                do {
                    copies.append(try await model.copyForOpening(path))
                } catch {
                    // A close or `cancelAll()` meanwhile: the copies made so far go, and nothing opens.
                    if Task.isCancelled || Self.isCancellation(error) {
                        for copy in copies { model.openedFiles.discard(copy) }
                        return
                    }
                    firstError = firstError ?? error
                }
            }
            if !copies.isEmpty {
                do {
                    try Self.launchCopies(copies, in: app, of: model.openedFiles)
                } catch {
                    return
                }
            }
            if let firstError { self?.present(firstError) }
        }
    }

    /// Open With > Other…: the user picks an app, in Applications first, and the files open in it.
    func chooseAppToOpen(_ paths: Set<String>) {
        guard !paths.isEmpty, let window, hasNoSheet else {
            beep()
            return
        }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Open")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let app = panel.url else { return }
            MainActor.assumeIsolated { _ = self?.open(paths, withApplicationAt: app) }
        }
    }

    /// Makes Share's copy of an extracted file under its entry's name: the preview's share copies
    /// (`PreviewWindowSource.shareCopy`), which go when the window closes. Set by the window controller;
    /// tests set their own. With none, Share does nothing.
    var makeShareCopy: (@MainActor (_ file: URL, _ name: String) async throws -> URL)?

    /// Where Share's picker shows: a rectangle in a view of the window.
    struct ShareAnchor {
        weak var view: NSView?
        let rect: NSRect
    }

    /// Shows the system's share picker for `files` at `anchor`, and calls `dismissed` once it is gone (a
    /// service chosen, or none), or at once when it can't show. Tests swap it on their own actions.
    var showSharePicker: @MainActor (_ files: [URL], _ anchor: ShareAnchor?,
                                     _ dismissed: @escaping @MainActor () -> Void) -> Void = {
        files, anchor, dismissed in
        // No window, or it closed meanwhile: nothing shows.
        guard let anchor, let view = anchor.view, view.window != nil else {
            dismissed()
            return
        }
        SharePickerSession.show(files, relativeTo: anchor.rect, of: view, dismissed: dismissed)
    }

    /// The Share being prepared, if any: one at a time (`isSharing`).
    private var shareJob: UUID?

    /// A Share is being prepared (its items extracted and copied): the row menu's Share… is disabled, and
    /// `share` ignores another until the picker shows.
    var isSharing: Bool { shareJob != nil }

    private static let shareLog = Logger(subsystem: "com.kernir.app", category: "Share")

    /// Share…: each item, in the window's order, is extracted to a temporary file (`ArchiveModel.localFileURL(for:)`,
    /// as Quick Look and drag-out get it) and copied under its entry's name (`makeShareCopy`), never handing out
    /// the reader's cache, which a save deletes while AirDrop may still read it. A folder's extraction goes once
    /// its copy is made, off the main actor once the picker shows (`extractedFolder`): repeated Shares leave one
    /// copy each, not two. One job at a time, which `cancelAll()` cancels; the picker then shows at the row of
    /// the first item, `rows` being the table's rows as the menu was built (`ArchiveTableDragSelection.rowsTaken`),
    /// or the table's visible part if that row scrolled away meanwhile (`shownRect`). Items that fail are left
    /// out and the picker shows the rest; the first error shows once the picker is gone.
    @discardableResult
    func share(_ paths: Set<String>,
               rows: @MainActor () -> [ArchiveTableDragSelection.Row] = { [] }) -> Task<Void, Never>? {
        guard shareJob == nil, canOpen(paths), let model, let makeShareCopy else { return nil }
        let ordered = ordered(paths)
        // Taken now, while the table still shows the rows the menu was opened on.
        let anchor = shareAnchor(paths: paths, rows: rows())
        let job = UUID()
        shareJob = job
        return track { [weak self] in
            defer { if self?.shareJob == job { self?.shareJob = nil } }
            // A save meanwhile adopts a new reader, and the old one's cache goes with it: kept until copied.
            let reader = model.reader
            defer { withExtendedLifetime(reader) {} }
            var files: [URL] = []
            var firstError: (any Error)?
            // The folders' extractions whose copies are made: deleted off the main actor however the job ends.
            var extracted: [URL] = []
            defer { if !extracted.isEmpty { Self.removeExtractedFolders(extracted) } }
            for path in ordered {
                // The item extracted: `localFileURL` looks it up with no suspension before.
                let item = model.item(at: path)
                do {
                    let local = try await model.localFileURL(for: path)
                    try Task.checkCancellation()
                    let copy = try await makeShareCopy(local, ArchiveEntry.name(of: path))
                    files.append(copy)
                    if let item, let folder = Self.extractedFolder(of: local, path: item.path,
                                                                   isDirectory: item.isDirectory,
                                                                   isPendingAddition: item.isPendingAddition) {
                        extracted.append(folder)
                    }
                } catch {
                    // Cancelled, or the window closed (`makeShareCopy`): nothing shows.
                    if Task.isCancelled || Self.isCancellation(error) { return }
                    Self.shareLog.error("Share: \(path, privacy: .private) failed: \(error)")
                    firstError = firstError ?? error
                }
            }
            guard !Task.isCancelled, let self else { return }
            if files.isEmpty {
                if let firstError { self.present(firstError) }
            } else {
                // Not over the picker: an alert sheet would come up while it shows.
                let error = firstError
                self.showSharePicker(files, anchor.map(Self.current)) { [weak self] in
                    if let error { self?.present(error) }
                }
            }
            if self.shareJob == job { self.shareJob = nil }
            let folders = extracted
            extracted = []
            await Self.removeExtractedFolders(folders).value
        }
    }

    /// The folder to delete once the share copy of `local` is made, what `ArchiveModel.localFileURL(for:)` just
    /// extracted the item at `path` into for a Share: only a folder of the archive's own (not a pending
    /// addition, which can be the user's folder itself) at `<temporaryDirectory>/Kernir-<UUID>/<path>`, the fresh
    /// folder that call made and handed to no one else; its `Kernir-<UUID>` folder is returned. The share
    /// service reads the copy, never this. Anything else stays (nil): a file (the reader's cache, or a renamed
    /// file's extraction kept for reuse), the reader's cache folder `<temporaryDirectory>/Kernir/<UUID>/…`, a
    /// renamed addition's clone, a folder anywhere else.
    nonisolated static func extractedFolder(of local: URL, path: String, isDirectory: Bool, isPendingAddition: Bool,
                                            temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL? {
        guard isDirectory, !isPendingAddition, !path.isEmpty else { return nil }
        var folder = local.standardizedFileURL
        for _ in path.split(separator: "/", omittingEmptySubsequences: false) {
            folder.deleteLastPathComponent()
        }
        let name = folder.lastPathComponent
        guard name.hasPrefix("Kernir-"), UUID(uuidString: String(name.dropFirst("Kernir-".count))) != nil,
              folder.deletingLastPathComponent().path == temporaryDirectory.standardizedFileURL.path,
              folder.appendingPathComponent(path).path == local.standardizedFileURL.path else { return nil }
        return folder
    }

    /// Deletes `folders` (each one `extractedFolder` gave) off the main actor: a large folder takes a while.
    @discardableResult
    nonisolated static func removeExtractedFolders(_ folders: [URL]) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            for folder in folders { try? FileManager.default.removeItem(at: folder) }
        }
    }

    /// Where the picker shows at `rect` in a view whose visible part is `visible`: `rect`, the anchor taken when
    /// Share was chosen, while it still shows; `visible` once the view scrolled or shrank it away while the
    /// items were extracted.
    nonisolated static func shownRect(_ rect: NSRect, visible: NSRect) -> NSRect {
        rect.intersects(visible) ? rect : visible
    }

    /// `anchor` as its view is now (`shownRect`).
    private static func current(_ anchor: ShareAnchor) -> ShareAnchor {
        guard let view = anchor.view else { return anchor }
        return ShareAnchor(view: view, rect: shownRect(anchor.rect, visible: view.visibleRect))
    }

    /// The row of `paths` the table shows first, among `rows` (the table's rows, top to bottom); nil when
    /// `rows` don't match the table's `rowCount` (a table not caught up with its items) or show none of them.
    nonisolated static func firstRow(of paths: Set<String>, in rows: [ArchiveTableDragSelection.Row],
                                     rowCount: Int) -> Int? {
        guard rows.count == rowCount else { return nil }
        return rows.firstIndex { paths.contains($0.path) }
    }

    /// The row of the menu's first item (`firstRow`) in the window's table; the table's visible part if that
    /// row isn't known or doesn't show, and the window's content without a table.
    private func shareAnchor(paths: Set<String>, rows: [ArchiveTableDragSelection.Row]) -> ShareAnchor? {
        guard let content = window?.contentView else { return nil }
        let tables = ArchiveTableDragAnchor.tableViews(under: content)
        guard let table = tables.max(by: { $0.visibleRect.width * $0.visibleRect.height
                                         < $1.visibleRect.width * $1.visibleRect.height }) else {
            return ShareAnchor(view: content, rect: content.bounds)
        }
        if let row = Self.firstRow(of: paths, in: rows, rowCount: table.numberOfRows) {
            let rect = table.rect(ofRow: row).intersection(table.visibleRect)
            if !rect.isEmpty { return ShareAnchor(view: table, rect: rect) }
        }
        return ShareAnchor(view: table, rect: table.visibleRect)
    }

    // MARK: - Password

    /// The password sheet's Open. A wrong password leaves the sheet up for another try;
    /// any other failure explains why in a sheet on the window, then closes the document.
    func unlock(password: String, remember: Bool) async {
        guard let document else { return }
        do {
            try await document.unlock(password: password, remember: remember)
        } catch {
            guard let window else {
                document.close()
                Self.presentError(error)
                return
            }
            // The alert can only appear once the password sheet has gone.
            document.state.isLocked = false
            window.whenNoSheetAttached {
                NSAlert(error: document.willPresentError(error)).beginSheetModal(for: window) { _ in
                    document.close()
                }
            }
        }
    }

    /// The password sheet's Cancel: forgets the wrong-password count, then closes the document.
    func cancelUnlock() {
        state?.resetWrongPasswords()
        document?.close()
    }

    // MARK: - Volume sets

    /// Grant Access… in the locked view of a split archive: asks for the folder that holds the
    /// parts, then reopens. The grant lasts until the app quits. Another folder can't reach the
    /// parts: an alert says which one to choose, and nothing is retried. The right folder whose
    /// reopen fails on the same part again gets an alert saying it's still unreadable.
    func grantVolumeAccess() {
        guard let window, let document, let error = document.state.volumeError,
              !document.state.isRetrying else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.directoryURL = error.folder
        panel.message = String(localized: "Choose the folder that holds all parts of this archive.", table: "Shared")
        panel.prompt = String(localized: "Grant Access",
                              comment: "Default button of the folder panel that “Grant Access…” opens: gives Lutik access to the chosen folder of archive parts. No “…”, as it acts at once.")
        panel.beginSheetModal(for: window) { [weak document] response in
            guard response == .OK, let picked = panel.url else { return }
            guard error.isFolderOfParts(picked) else {
                Self.askForTheFolderOfParts(error, in: window)
                return
            }
            // After the panel's sheet has gone: an encrypted set asks for its password in a sheet,
            // which AppKit drops if it begins while this one is still ending.
            window.whenNoSheetAttached {
                Task {
                    guard let stillUnreadable = await document?.retryVolumeOpen() else { return }
                    Self.sayItIsStillUnreadable(stillUnreadable, in: window)
                }
            }
        }
    }

    /// The user granted the folder that holds the parts, but the reopen failed on the same part
    /// again: the locked view looks as before, so an alert says what is left, once no sheet is up.
    private static func sayItIsStillUnreadable(_ error: ArchiveVolumeError, in window: NSWindow) {
        window.whenNoSheetAttached {
            let alert = NSAlert()
            alert.messageText = error.stillUnreadableTitle
            alert.informativeText = error.stillUnreadableMessage
            alert.beginSheetModal(for: window)
        }
    }

    /// The user granted another folder than the one holding the parts: asks for the folder that
    /// holds them all, once the open panel's sheet has gone.
    private static func askForTheFolderOfParts(_ error: ArchiveVolumeError, in window: NSWindow) {
        window.whenNoSheetAttached {
            let alert = NSAlert()
            alert.messageText = error.wrongFolderTitle
            alert.informativeText = error.wrongFolderMessage
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: - Errors

    /// A failed operation, in a sheet on the window once the progress sheet has gone.
    func present(_ error: any Error) {
        guard let document else { return }
        guard let window else {
            Self.presentError(error)
            return
        }
        window.whenNoSheetAttached {
            NSAlert(error: document.willPresentError(error)).beginSheetModal(for: window)
        }
    }
}

/// One shown share picker: keeps the picker and itself alive until the picker is gone, a service chosen or
/// none, then calls `dismissed` once (`ArchiveActions.showSharePicker`).
@MainActor
private final class SharePickerSession: NSObject, NSSharingServicePickerDelegate {
    private var picker: NSSharingServicePicker?
    private var dismissed: (@MainActor () -> Void)?
    /// Itself while the picker shows: the picker holds its delegate weakly.
    private var keptAlive: SharePickerSession?

    static func show(_ files: [URL], relativeTo rect: NSRect, of view: NSView,
                     dismissed: @escaping @MainActor () -> Void) {
        let session = SharePickerSession()
        let picker = NSSharingServicePicker(items: files)
        picker.delegate = session
        session.picker = picker
        session.dismissed = dismissed
        session.keptAlive = session
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    /// AppKit calls this on the main thread, with a nil service when the picker was dismissed.
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                          didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            let dismissed = self.dismissed
            self.dismissed = nil
            picker?.delegate = nil
            picker = nil
            keptAlive = nil
            dismissed?()
        }
    }
}

/// Notification observers, removed when their owner goes (its deinit can't reach main-actor state).
private final class UndoObserverBag: @unchecked Sendable {
    var tokens: [any NSObjectProtocol] = []

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
