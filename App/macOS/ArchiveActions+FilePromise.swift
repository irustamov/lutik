import AppKit
import KernirCore

/// Drag out of the archive window as a file promise: the table (`ArchiveTableDragSource`) calls
/// `filePromise(for:)` for each dragged row. The window's line of promise writes (`QueuedOperations`) lives here, beside
/// `ArchiveActions` and not in it: a window takes one operation at a time, so a drop waits while a
/// save, an extraction, another drop or an alert has the window, and none is ever dropped.
extension ArchiveActions {
    /// What a window keeps for its promise writes.
    @MainActor
    private final class FilePromiseState {
        let queue: QueuedOperations
        /// Failure alerts begun and not yet answered: the next write waits for them (an alert sheet
        /// is `attachedSheet` only once begun, and AppKit drops a sheet begun while one ends).
        var pendingAlerts = 0
        /// The drops (drag sessions) whose rows are alive, by id: a row's Cancel stops its drop's
        /// rows. Weak: a drop lives as long as its rows' promises.
        var drops: [UUID: WeakDrop] = [:]
        /// Called with each failure alert just before it is begun (a test seam: tests count them).
        var alertWillBegin: (@MainActor (NSAlert) -> Void)?
        /// The plain files of the current drag out (`ArchiveDragOutFiles`) and its drop id. Their folder
        /// outlives it: `ArchiveDragOutFolders` deletes it.
        var dragOut: (drop: UUID, files: ArchiveDragOutFiles)?
        var makeDragOutFiles: (@MainActor (any ArchiveReading) -> ArchiveDragOutFiles)?

        init(canStart: @escaping @MainActor () -> Bool) {
            queue = QueuedOperations(canStart: canStart)
        }

        /// The drop `id`, made on its first row.
        func drop(_ id: UUID) -> ArchiveFilePromiseDrop {
            if let drop = drops[id]?.drop { return drop }
            drops = drops.filter { $0.value.drop != nil }
            let drop = ArchiveFilePromiseDrop(id: id)
            drops[id] = WeakDrop(drop: drop)
            return drop
        }
    }

    private struct WeakDrop { weak var drop: ArchiveFilePromiseDrop? }

    /// Per `ArchiveActions` (an extension has no stored property): an associated object, so it is
    /// released with the window's actions. (A weak-to-strong `NSMapTable` does not reliably release a
    /// value whose key is gone: every closed window would leak its state and queue.)
    nonisolated(unsafe) private static let filePromiseStateKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    private var existingFilePromiseState: FilePromiseState? {
        objc_getAssociatedObject(self, Self.filePromiseStateKey) as? FilePromiseState
    }

    private var filePromiseState: FilePromiseState {
        if let existing = existingFilePromiseState { return existing }
        let state = FilePromiseState { [weak self] in self?.canStartFilePromiseWrite ?? true }
        objc_setAssociatedObject(self, Self.filePromiseStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    /// The window can take a promise write now: no progress sheet (a save, an extraction, a write),
    /// no other sheet attached, no failure alert unanswered. A window that is gone has nothing to
    /// wait for: the write runs and fails.
    private var canStartFilePromiseWrite: Bool {
        guard let document else { return true }
        return document.state.progress == nil && window?.attachedSheet == nil && filePromiseState.pendingAlerts == 0
    }

    /// Called with each failure alert just before it is begun on the window. Only tests set it: an
    /// alert sheet does not go through `NSWindow.beginSheet`, so they count the alerts here.
    var filePromiseAlertWillBegin: (@MainActor (NSAlert) -> Void)? {
        get { filePromiseState.alertWillBegin }
        set { filePromiseState.alertWillBegin = newValue }
    }

    /// A promise write waits or runs in this window.
    var hasFilePromiseWork: Bool {
        existingFilePromiseState?.queue.isIdle == false
    }

    /// Cancels every promise write of this window, the running one and the waiting ones: each
    /// promise's completion handler gets Cocoa's user-cancelled error, none an alert. Every live drop
    /// is cancelled too: a row of it whose write is asked for after the window closed gets
    /// the user-cancelled error once, no alert, rather than starting (and failing on a gone archive).
    func cancelFilePromises() {
        guard let state = existingFilePromiseState else { return }
        state.queue.cancelAll()
        for drop in state.drops.values.compactMap(\.drop) { drop.cancel() }
        state.dragOut = nil
    }

    /// The plain files of the drag `drop` (`ArchiveDragOutFiles`), made on its first row, with the row at
    /// `path` counted in (`dragOutRow`); nil when the window has no archive reader. A new drag (AppKit asks
    /// for one drag's writers at a time) deletes the folders of drags older than
    /// `ArchiveDragOut.dragOutFolderMaxAge`, never a recent one a slow receiver may still read.
    func dragOutFiles(for path: String, drop: UUID) -> ArchiveDragOutFiles? {
        guard let model = document?.state.model, let reader = model.reader else { return nil }
        let state = filePromiseState
        let files: ArchiveDragOutFiles
        if let current = state.dragOut, current.drop == drop {
            files = current.files
        } else {
            ArchiveDragOutFolders.shared.removeOlder()
            files = makeDragOutFiles?(reader) ?? ArchiveDragOutFiles(reader: reader)
            state.dragOut = (drop, files)
        }
        files.add(Self.dragOutRow(for: path, in: model))
        return files
    }

    /// Test seam: makes a drag's plain files from the window's reader in place of
    /// `ArchiveDragOutFiles(reader:)`.
    var makeDragOutFiles: (@MainActor (any ArchiveReading) -> ArchiveDragOutFiles)? {
        get { filePromiseState.makeDragOutFiles }
        set { filePromiseState.makeDragOutFiles = newValue }
    }

    /// The row at `path` as a plain file of a drag out, or nil when it may not be one (the whole drag then
    /// stays promises only): a folder, an addition, a row whose reader entry has another name (a renamed file;
    /// the reader would give its old name), a size unknown or over `ArchiveDragOut.maxBytes`, or no reader. A row inside a renamed folder
    /// keeps its name and comes from its old path.
    static func dragOutRow(for path: String, in model: ArchiveModel) -> ArchiveDragOutFiles.Row? {
        guard model.reader != nil, let item = model.item(at: path), !item.isDirectory, !item.isPendingAddition,
              let size = item.size, size >= 0, size <= ArchiveDragOut.maxBytes else { return nil }
        let source = RenameMap(model.changes.renamedPaths).sourcePath(ofFinal: item.path)
        guard ArchiveEntry.name(of: source).utf8.elementsEqual(ArchiveEntry.name(of: item.path).utf8) else { return nil }
        return ArchiveDragOutFiles.Row(path: path, readerPath: source,
                                       name: ArchiveDragOut.offeredName(forPath: item.path), size: size)
    }

    /// The promise for the row at `path`, or nil when the window has no archive open. Finder takes
    /// the drop as a file promise and asks for the file when it lands. The write then waits for
    /// the window to be free, shows the progress sheet ("Extracting “…”…", Cancel) and clears only
    /// that sheet when it ends. A failure other than a cancel gets exactly one alert on the window,
    /// or `presentError` when the window is gone; a Cancel gets none, and the completion handler
    /// hears Cocoa's user-cancelled error. Rows of one drag share its `drop` id: the sheet's Cancel
    /// stops every row of that drop (waiting rows never start), and no other drop. Each row
    /// keeps a sheet of its own; without a `drop`, Cancel stops this row only.
    func filePromise(for path: String, drop: UUID? = nil) -> NSFilePromiseProvider? {
        guard let document, let model = document.state.model else { return nil }
        let provider = ArchiveFilePromiseDelegate.provider(path: path, model: model)
        guard let delegate = provider.delegate as? ArchiveFilePromiseDelegate else { return nil }
        // The sheet's identity comes first: only its own updates may move its bar.
        let name = document.displayName ?? ArchiveDragOut.offeredName(forPath: path)
        var operation = OperationProgress(title: String(localized: "Extracting “\(name)”…",
                                                        comment: "Title of the progress sheet while extracting. %@ = the archive's name."),
                                          fraction: nil, cancel: nil)
        if let drop { filePromiseState.drop(drop).add(delegate) }
        operation.cancel = { [weak delegate] in
            guard let delegate else { return }
            if let drop = delegate.drop { drop.cancel() } else { delegate.cancel() }
        }
        let id = operation.id
        let shown = operation
        delegate.windowQueue = filePromiseState.queue
        // Weak throughout: a drag must not keep a closed window's document or archive alive.
        delegate.onStart = { [weak self, weak delegate] in
            guard let state = self?.document?.state else { return }
            state.progress = shown
            delegate?.progress = state.progressHandler(for: id)
        }
        delegate.onEnd = { [weak self, weak delegate] in
            delegate?.progress = nil
            // Not another operation's sheet, which may have replaced this one's.
            guard let state = self?.document?.state, state.progress?.id == id else { return }
            state.progress = nil
        }
        delegate.onFailure = { [weak self] error in
            guard let self else {
                ArchiveActions.presentError(error)
                return
            }
            self.presentFilePromiseFailure(error)
        }
        return provider
    }

    /// One alert sheet on the window for `error`, once the progress sheet is gone; `presentError`
    /// when the window is gone. The next write waits until the alert is answered.
    private func presentFilePromiseFailure(_ error: any Error) {
        guard let document, let window else {
            Self.presentError(error)
            return
        }
        let state = filePromiseState
        state.pendingAlerts += 1
        window.whenNoSheetAttached { [weak state] in
            let alert = NSAlert(error: document.willPresentError(error))
            state?.alertWillBegin?(alert)
            alert.beginSheetModal(for: window) { _ in
                if let state { state.pendingAlerts = max(0, state.pendingAlerts - 1) }
            }
        }
    }
}
