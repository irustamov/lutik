import AppKit
import KernirCore
import Observation

/// Edit > Copy, Cut and Paste (⌘C, ⌘X, ⌘V) on the archive window's rows. The rules are
/// `ArchivePaste`'s (App/Shared/ArchiveClipboard.swift); this part reads and writes the pasteboard.
///
/// - Copy extracts the selection into a fresh `Kernir-Clipboard-<process>/<UUID>` folder under the progress sheet
///   ("Copying…", Cancel), then puts the copies' file URLs (Finder ⌘V pastes them) and the Lutik item on the
///   pasteboard. A pending addition of a pasted copy reads its file at save, so the folders stay until quit
///   (`AppDelegate` sweeps them at launch and quit).
/// - Cut puts the Lutik item only: a paste in this window moves the items, anywhere else it is refused.
/// - Paste adds files through `add(_:to:)` (Replace / Stop; never `addDropped`, which drops `Kernir-*`
///   temporary files and so the copies), moves a cut through `move(_:into:)` (the move with Replace and the
///   selection remap), or says why not in one alert.
extension ArchiveActions {
    /// What a window keeps for its clipboard (an extension has no stored property: an associated object,
    /// released with the window's actions, as `ArchiveActions+FilePromise.swift`). Observable for
    /// `copyInFlight`: the table's ⌘C (`canCopy`, read in its body) comes back once a Copy ends.
    @MainActor @Observable
    fileprivate final class ClipboardState {
        /// This window's ID in the Lutik item (`ArchiveClipboard.source`): it outlives a model a Revert or
        /// Text Encoding replaces, and a cut from a previous run is never ours.
        let source = UUID()
        @ObservationIgnored var pasteboard = NSPasteboard.general
        @ObservationIgnored var temporaryDirectory = FileManager.default.temporaryDirectory
        /// A Copy export runs: set by `copySelection`, cleared on its every way out. The progress sheet alone
        /// doesn't hold off a second Copy: a ⌘S under it replaces it, and then goes.
        var copyInFlight = false
    }

    nonisolated(unsafe) private static let clipboardStateKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    private var clipboardState: ClipboardState {
        if let existing = objc_getAssociatedObject(self, Self.clipboardStateKey) as? ClipboardState { return existing }
        let state = ClipboardState()
        objc_setAssociatedObject(self, Self.clipboardStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    /// The pasteboard's change count right after Lutik last wrote it, by pasteboard name: a cut pasted once,
    /// and the general pasteboard at quit, are cleared only while it is still ours.
    private static var clipboardWrites: [NSPasteboard.Name: Int] = [:]

    /// This window's ID in the Lutik item it puts on the pasteboard.
    var clipboardSource: UUID { clipboardState.source }

    /// The pasteboard Copy, Cut and Paste use: the general one; tests set a named one.
    var pasteboard: NSPasteboard {
        get { clipboardState.pasteboard }
        set { clipboardState.pasteboard = newValue }
    }

    /// Where Copy makes its `Kernir-Clipboard-<process>/<UUID>` folder: the temporary folder; tests set their own.
    var clipboardTemporaryDirectory: URL {
        get { clipboardState.temporaryDirectory }
        set { clipboardState.temporaryDirectory = newValue }
    }

    private static var itemType: NSPasteboard.PasteboardType { .init(ArchiveClipboard.typeIdentifier) }

    // MARK: - Availability

    /// `paths` (the selection, or the rows under the context menu) can be copied: it extracts, so read-only
    /// archives too; not while an operation runs (the progress sheet) nor while a Copy still exports
    /// (`copyInFlight`): one Copy export at a time.
    func canCopy(_ paths: Set<String>) -> Bool { !clipboardState.copyInFlight && canOpen(paths) }

    /// The selection can be copied (⌘C).
    var canCopy: Bool { canCopy(document?.state.selection ?? []) }

    /// The selection can be cut: names can change and no name field is showing.
    var canCut: Bool {
        guard let state = document?.state else { return false }
        return canNewFolder && !state.selection.isEmpty && state.renamingPath == nil
    }

    /// Something to paste: files can be added and the pasteboard offers file URLs or a Lutik item. Its types
    /// only, never its contents: no paste-privacy prompt while the menu validates.
    var canPaste: Bool {
        guard canAdd, let types = pasteboard.types else { return false }
        return types.contains(.fileURL) || types.contains(Self.itemType)
    }

    /// The row menu's Copy and Paste for the rows under it (`paths`; empty on empty space). Empty space's Paste
    /// shows where its New Folder does (`canAdd`); Paste is disabled while a name field shows, as ⌘V.
    func clipboardMenu(for paths: Set<String>) -> ArchiveClipboardMenu {
        let pasteFolder: String?
        if document?.state.model?.isEditable != true {
            pasteFolder = nil
        } else if paths.isEmpty {
            pasteFolder = canAdd ? "" : nil
        } else if paths.count == 1, let path = paths.first, isFolder(path) {
            pasteFolder = path
        } else {
            pasteFolder = nil
        }
        return ArchiveClipboardMenu(showsCopy: !paths.isEmpty, canCopy: canCopy(paths), pasteFolder: pasteFolder,
                                    canPaste: canPaste && document?.state.renamingPath == nil)
    }

    // MARK: - Copy, Cut, Paste

    /// ⌘C: copies the selection (`copyItems`). The task, for tests to await.
    @discardableResult
    func copySelection() -> Task<Void, Never>? {
        copyItems(document?.state.selection ?? [])
    }

    /// ⌘C and the row menu's Copy: extracts `paths` under the progress sheet ("Copying…", Cancel) and puts the
    /// copies and the Lutik item on the pasteboard. A Cancel (or a cancel from closing the window) is silent; a
    /// failure gets one alert. When a save or a Text Encoding reopen landed meanwhile (the sheet replaced, the
    /// snapshot adopted, the model swapped), the copies are dropped instead. The task, for tests to await.
    @discardableResult
    func copyItems(_ paths: Set<String>) -> Task<Void, Never>? {
        guard canCopy(paths), hasNoSheet, let state = document?.state, let model = state.model else { return nil }
        let clipboard = ArchiveClipboard(source: clipboardSource, operation: .copy, paths: ordered(paths))
        guard !clipboard.paths.isEmpty else { return nil }
        let temporary = clipboardTemporaryDirectory
        var operation = OperationProgress(title: ArchiveClipboard.progressTitle, fraction: nil, cancel: nil)
        let progress = state.progressHandler(for: operation.id)
        let id = operation.id
        // The Mac's save and Text Encoding counters: a save puts up its own sheet over this one
        // (`ArchiveDocument.save(to:…)` sets `state.progress`), and an adopted save or reopen bumps
        // `snapshotGeneration` (`ArchiveModel.didSave`).
        let generation = model.snapshotGeneration
        let clipboardState = self.clipboardState
        clipboardState.copyInFlight = true
        let task = track { [weak self] in
            defer { clipboardState.copyInFlight = false }
            let exported: (folder: URL, urls: [URL])
            do {
                exported = try await ArchiveClipboard.export(clipboard.paths, from: model, in: temporary,
                                                             progress: progress)
            } catch {
                if state.progress?.id == id { state.progress = nil }
                if !Self.isCancellation(error) { self?.present(error) }
                return
            }
            let sheetWasOurs = state.progress?.id == id
            if sheetWasOurs { state.progress = nil }
            guard let self, !Task.isCancelled, sheetWasOurs, state.model === model,
                  model.snapshotGeneration == generation, !exported.urls.isEmpty else {
                // Never on the pasteboard: only this export's folder goes.
                ArchiveClipboard.removeExport(exported.folder)
                return
            }
            // The previous Copy's folder stays (no `removeExports(keeping:)` here, unlike iOS): a pending addition
            // of its files (pasted into this or another window, not yet saved) reads them only at save. The
            // folders go at quit (`AppDelegate`), and at the next launch after a crash.
            let pasteboard = self.pasteboard
            pasteboard.clearContents()
            pasteboard.writeObjects(exported.urls as [NSURL])
            pasteboard.setData(clipboard.encoded(), forType: Self.itemType)
            Self.clipboardWrites[pasteboard.name] = pasteboard.changeCount
        }
        operation.cancel = { task.cancel() }
        state.progress = operation
        return task
    }

    /// ⌘X: puts the Lutik item (no files) on the pasteboard; a paste in this window moves the items.
    func cutSelection() {
        guard canCut, hasNoSheet, let state = document?.state else { return }
        let clipboard = ArchiveClipboard(source: clipboardSource, operation: .cut, paths: ordered(state.selection))
        guard !clipboard.paths.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setData(clipboard.encoded(), forType: Self.itemType)
        Self.clipboardWrites[pasteboard.name] = pasteboard.changeCount
    }

    /// ⌘V into the one selected folder, else the top level; the row menu's Paste into `folder` (its folder row,
    /// "" on empty space). Either goes beside a folder that is itself on this window's clipboard
    /// (`ArchivePaste.destination`). Files add with Replace / Stop; a cut from this window moves (one "Move" undo
    /// step) and is cleared from the pasteboard once the items moved (not on Stop), while the pasteboard is still
    /// ours; a refusal gets one alert. The plan it followed, nil when there was nothing to paste.
    @discardableResult
    func paste(into folder: String? = nil) -> PastePlan? {
        guard canPaste, hasNoSheet, let model = document?.state.model else { return nil }
        let pasteboard = self.pasteboard
        let clipboard = pasteboard.data(forType: Self.itemType).flatMap(ArchiveClipboard.decoded)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?
            .compactMap { $0 as? URL } ?? []
        let here = clipboardSource
        let folder = ArchivePaste.destination(selectedFolder: folder ?? destinationForAdd(), clipboard: clipboard,
                                              here: here)
        guard let plan = ArchivePaste.plan(clipboard, hasFiles: !urls.isEmpty, here: here, into: folder,
                                           exists: { model.item(at: $0) != nil })
        else { return nil }
        switch plan {
        case .add(let directory):
            add(urls, to: directory)
        case .move(let roots, let directory):
            // All already there: nothing to do, and the cut stays. Stop in the Replace question, or a move the
            // model refuses, keeps it too: it is used up only once the items moved.
            if !roots.isEmpty {
                move(roots, into: directory) { Self.clearIfStillOurs(pasteboard) }
            }
        case .refuse(let refusal):
            presentPasteRefusal(refusal)
        }
        return plan
    }

    /// The launch sweep of Copy's export folders (`AppDelegate`): those of runs that are gone (a crash skips the
    /// quit sweep, a quit sweep can run out of time); never one another running instance holds, as its lock
    /// ends only with its process (`ArchiveClipboard.removeExports`). Skipped for the real temporary folder
    /// while tests host the app (`PreviewLeftoverSweeper.refuses(parent:)`), so a test run's launch and quit
    /// never touch a live Lutik's copies.
    static func sweepClipboardExports(in temporary: URL = FileManager.default.temporaryDirectory) {
        guard !PreviewLeftoverSweeper.refuses(parent: temporary) else { return }
        ArchiveClipboard.removeExports(in: temporary, keeping: nil)
    }

    /// How long the quit sweep may take before it leaves the rest to the next launch.
    static let quitSweepBudget = Duration.seconds(2)

    /// The quit sweep (`AppDelegate.applicationWillTerminate`): only this process's export parent, and only for
    /// `budget` (`ArchiveClipboard.removeExportParent(in:before:)`), so a huge copy never holds up quit; what is
    /// left goes at the next launch. Another instance's folders, held or not, are not touched. Skipped as
    /// `sweepClipboardExports` is under tests.
    static func removeOwnClipboardExports(in temporary: URL = FileManager.default.temporaryDirectory,
                                          budget: Duration = quitSweepBudget) {
        guard !PreviewLeftoverSweeper.refuses(parent: temporary) else { return }
        ArchiveClipboard.removeExportParent(in: temporary, before: .now + budget)
    }

    /// Clears `pasteboard` when Lutik's last write is still what it holds; at quit, the general pasteboard
    /// (`AppDelegate.applicationWillTerminate`): no URLs of removed copies left for Finder.
    static func clearIfStillOurs(_ pasteboard: NSPasteboard) {
        guard let written = clipboardWrites[pasteboard.name], written == pasteboard.changeCount else { return }
        pasteboard.clearContents()
        clipboardWrites[pasteboard.name] = nil
    }

    /// One alert sheet ("Couldn't Paste") once no other sheet is up; nothing without a window.
    private func presentPasteRefusal(_ refusal: PasteRefusal) {
        guard let window else { return }
        window.whenNoSheetAttached {
            let alert = NSAlert()
            alert.messageText = ArchivePaste.refusalTitle
            alert.informativeText = ArchivePaste.message(for: refusal)
            alert.beginSheetModal(for: window)
        }
    }
}

/// The row menu's clipboard items, as Finder's: Copy on rows (no Cut: ⌘X only), Paste on empty
/// space (the top level) and on a folder row (into it). `ArchiveActions.clipboardMenu(for:)` makes it.
struct ArchiveClipboardMenu: Equatable {
    /// Copy shows on rows; it is enabled where `canCopy(_:)` is, read-only archives too.
    var showsCopy: Bool
    var canCopy: Bool
    /// Where Paste pastes: "" (the top level) on empty space, the folder on its own row; nil: no Paste item (a
    /// file row, several rows, an archive that can't change). Shown disabled when there is nothing to paste.
    var pasteFolder: String?
    var canPaste: Bool
}
