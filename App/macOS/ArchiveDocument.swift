import AppKit
import KernirCore
import os

/// One open archive. Reads by URL through `ArchiveEngine`, so the archive is never loaded
/// into memory; the edit model and window state live in `state`.
final class ArchiveDocument: NSDocument {
    /// The engine every document uses. Tests swap it and restore `.live` afterwards.
    nonisolated(unsafe) static var engine: ArchiveEngine = .live
    /// Where remembered passwords live. Tests swap it and restore the default afterwards.
    nonisolated(unsafe) static var keychainService = KeychainPasswordStore.service

    /// Owned per document (one window per document). Nonisolated so `read(from:ofType:)` can
    /// reach it from a background thread.
    nonisolated let state: ArchiveWindowState

    var model: ArchiveModel? { state.model }

    /// The file `read(from:ofType:)` last read; `unlock` reopens it before `fileURL` is set.
    private var readURL: URL?
    /// The type `read(from:ofType:)` last read: the type of the file `unlock` reopens.
    private var readType: String?

    /// The window's commands, set by its controller; closing the document cancels what they started.
    weak var actions: ArchiveActions?

    /// Files opened from this window in other apps: the document's until it closes, whichever
    /// model it has (Revert to Saved makes a new one; a failed reopen after a save leaves none).
    let openedFiles = OpenedFiles()

    /// For an inner archive opened as an untitled copy: the folder holding the copy it reads
    /// from, deleted on close. (Its parent window doesn't track it.)
    var ownedTemporaryDirectory: URL?

    /// The options of the save panel last shown, until the save it starts takes them.
    var savePanelOptions: SavePanelOptions?

    /// For the untitled archive a Dock drop made (`OpenRequest`), the name and folder
    /// its save panel proposes while it has no file. nil for every other document. A change
    /// renames the save panel it named while that is up and unedited (`NewArchiveSavePanel`).
    var newArchiveProposal: CompressPlan.Destination? {
        didSet { newArchivePanel.propose(newArchiveProposal?.name) }
    }
    /// The save panel `newArchiveProposal` named.
    let newArchivePanel = NewArchiveSavePanel()
    /// A split save succeeded. It leaves the document untitled (Save To semantics),
    /// but the user saved it, so later Dock drops open a new window (`takesMoreItems`).
    var savedSplitSet = false

    /// The type the document was read as while it is one part of a multi-volume set
    /// (`reader.volumeURLs.count > 1`); nil otherwise. Set on the main actor with the model, so
    /// `writableTypes(for:)` can read it from any thread.
    private nonisolated let volumeSetType = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Handed from `save(to:…)` on the main actor to `write(to:…)` on NSDocument's saving thread.
    private nonisolated let pendingSave = OSAllocatedUnfairLock<SaveSnapshot?>(initialState: nil)

    /// Nonisolated: with concurrent reading, NSDocumentController calls `init(contentsOf:ofType:)`,
    /// and so this, on a background thread; a main-actor init traps there. NSDocument's `init()`
    /// runs on that thread by AppKit's design, though the SDK marks it main-actor, so the
    /// `super.init()` call draws a (preconcurrency) warning that cannot be silenced locally.
    nonisolated override init() {
        state = ArchiveWindowState()
        super.init()
    }

    /// File > New: an empty ZIP.
    convenience init(type typeName: String) throws {
        self.init()
        // The chosen type when it is writable; anything else starts as a ZIP.
        if let format = KernirDocumentTypes.format(forTypeIdentifier: typeName), format.isWritable {
            fileType = typeName
            state.model = ArchiveModel(newArchiveFormat: format, undoManager: undoManager, openedFiles: openedFiles)
        } else {
            fileType = "public.zip-archive"
            state.model = ArchiveModel(newArchiveFormat: .zip, undoManager: undoManager, openedFiles: openedFiles)
        }
    }

    // MARK: - NSDocument configuration

    /// Every save is a full repack, so no autosave and no Versions.
    // Nonisolated: constants that AppKit may ask for from its reading and saving threads.
    nonisolated override class var autosavesInPlace: Bool { false }
    nonisolated override class var preservesVersions: Bool { false }

    nonisolated override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    nonisolated override func canAsynchronouslyWrite(to url: URL, ofType typeName: String,
                                                     for saveOperation: NSDocument.SaveOperationType) -> Bool {
        true
    }

    nonisolated override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        let types = KernirDocumentTypes.writable.map(\.identifier)
        // A set has a writable format, but saving in place would overwrite one of its parts, so Save is
        // disabled (its own type isn't writable here, as with RAR). Save As and Save To keep every type.
        guard saveOperation == .saveOperation, let own = volumeSetType.withLock({ $0 }) else { return types }
        return types.filter { $0 != own }
    }

    /// Nothing to save without a model: the archive is locked, or couldn't be reread after a save.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        // Not while View > Text Encoding reads the archive again: the save would race its reopen.
        case #selector(save(_:)), #selector(saveAs(_:)):
            model != nil && nameEncodingTask == nil && super.validateUserInterfaceItem(item)
        case #selector(selectNameEncoding(_:)):
            canChooseNameEncoding
        default:
            super.validateUserInterfaceItem(item)
        }
    }

    override func makeWindowControllers() {
        addWindowController(ArchiveWindowController(document: self))
    }

    /// NSDocumentController calls this again when the user opens the file of a document that is
    /// already open (Finder, Open Recent, File > Open). With a volume error showing, that is the
    /// user saying "I put the parts together, open it again": read the archive again. A window
    /// already on screen (or in the Dock) tells that reopen from the document's first showing,
    /// whether it was opened fresh or restored at launch (restoration never calls this).
    override func showWindows() {
        let reopened = windowControllers.contains { $0.window?.isVisible == true || $0.window?.isMiniaturized == true }
        super.showWindows()
        noteWindowsShown(reopened: reopened)
    }

    /// Retries after a volume error, or after a retry that failed, when the document was
    /// `reopened`. Returns the retry, if one started.
    @discardableResult
    func noteWindowsShown(reopened: Bool) -> Task<Void, Never>? {
        guard reopened, canRetryVolumeOpen else { return nil }
        return Task { await retryVolumeOpen() }
    }

    /// Set by `close()`: a retry still running then shows nothing, and no other window copies from it
    /// (`ArchiveActions.canCopyIn`).
    private(set) var isClosed = false

    /// Asks about files opened from this archive and changed in another app (`reviewOpenedFiles`)
    /// before AppKit's own "save the changes?" question. A View > Text Encoding reopen still running
    /// stops first, so the review, and the save it may start, see the listing as it is.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        nameEncodingTask?.cancel()
        reviewOpenedFiles { proceed in
            guard proceed else {
                Self.report(false, to: delegate, selector: shouldCloseSelector, from: self, contextInfo: contextInfo)
                return
            }
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
        }
    }

    /// Stops extractions and previews still running, then deletes the model's temporary folders,
    /// the copies opened in other apps and, for an inner archive opened as an untitled copy, the
    /// copy it reads from.
    override func close() {
        isClosed = true
        actions?.cancelAll()
        nameEncodingTask?.cancel()
        model?.removeTemporaryFiles()
        openedFiles.close()
        if let ownedTemporaryDirectory { try? FileManager.default.removeItem(at: ownedTemporaryDirectory) }
        super.close()
    }

    /// Revert to Saved with a name field showing ends it without its typed name: the listing it named goes.
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        actions?.cancelRename()
        try super.revert(toContentsOf: url, ofType: typeName)
    }

    // MARK: - Edited state

    /// Mirrors `isDocumentEdited` into the window state: the subtitle replaces AppKit's "Edited".
    /// Edits, undo and redo (through the undo manager) and revert all count changes here.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        state.isEdited = isDocumentEdited
    }

    /// A finished save settles the count through its token. AppKit currently passes that on to
    /// `updateChangeCount(_:)` as well, but doesn't document it.
    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        state.isEdited = isDocumentEdited
    }

    // MARK: - Text encoding

    /// The View > Text Encoding reopen running now, if any.
    private(set) var nameEncodingTask: Task<Void, Never>?

    /// View > Text Encoding can be used: the archive has names stored without a declared encoding (nothing
    /// to reinterpret otherwise), no unsaved changes, and nothing else is running on it,
    /// including a file still being opened in another app or previewed (`ArchiveActions.hasRunningTasks`):
    /// a reopen finishing before that copy is tracked would leave it under its old name.
    /// Not while a name field shows either: the menu leaves it focused, and it would commit into the new listing.
    var canChooseNameEncoding: Bool {
        model?.reader?.legacyNameEncoding != nil && !isDocumentEdited && state.progress == nil
            && nameEncodingTask == nil && actions?.hasRunningTasks != true && state.renamingPath == nil
    }

    /// An item of View > Text Encoding: its encoding's raw value as an NSNumber, or nil for Automatic.
    static func nameEncoding(of item: NSMenuItem) -> ArchiveNameEncoding {
        (item.representedObject as? NSNumber).map { .specific(String.Encoding(rawValue: $0.uintValue)) }
            ?? .automatic
    }

    /// The menu's checkmark is on the encoding the names are read with as requested (Automatic included).
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(selectNameEncoding(_:)) else { return super.validateMenuItem(menuItem) }
        let requested = model?.reader?.nameEncoding ?? .automatic
        menuItem.state = Self.nameEncoding(of: menuItem) == requested ? .on : .off
        return canChooseNameEncoding
    }

    /// View > Text Encoding: lists the archive again with the chosen encoding and remembers the choice for
    /// the file (Automatic forgets it). Choosing the current one does nothing.
    ///
    /// The reopen adopts the new listing, which would drop any edit made meanwhile, so it runs under the
    /// progress sheet: that disables adding, deleting, undo and redo (`ArchiveActions.canAdd`, the window's
    /// gated undo manager), and Save waits for `nameEncodingTask`. Cancel stops the reopen.
    @objc func selectNameEncoding(_ sender: NSMenuItem) {
        guard canChooseNameEncoding, let model, let url = model.reader?.url else { return }
        let encoding = Self.nameEncoding(of: sender)
        guard encoding != model.reader?.nameEncoding else { return }
        let title = String(localized: "Reading “\(url.lastPathComponent)”…", table: "Shared",
                           comment: "Progress title while the archive is listed again after another text encoding was chosen (Text Encoding menu). %@ = the archive's file name. The ellipsis shows work in progress.")
        let operation = OperationProgress(title: title, fraction: nil,
                                          cancel: { [weak self] in self?.nameEncodingTask?.cancel() })
        state.progress = operation
        nameEncodingTask = Task {
            await applyNameEncoding(encoding)
            if state.progress?.id == operation.id { state.progress = nil }
            nameEncodingTask = nil
        }
    }

    /// Reopens with `encoding`. The selection clears (its paths may name nothing now), and so does the
    /// preview, whose entries do too; expanded folders that are still listed stay expanded.
    /// A failure keeps the listing as it was and is reported on the window.
    func applyNameEncoding(_ encoding: ArchiveNameEncoding) async {
        guard let model else { return }
        do {
            try await model.reopen(nameEncoding: encoding)
        } catch {
            Self.logger.error("Reopen with another name encoding failed: \(error.localizedDescription, privacy: .public)")
            // Cancelled, or the archive changed while it was read (`ArchiveModel.reopen`): nothing to report.
            if !Task.isCancelled, !(error is CancellationError) { presentInWindow(error) }
            return
        }
        guard state.model === model else { return }
        state.selection = []
        actions?.endPreview()
        state.expanded = model.listedFolders(among: state.expanded)
    }

    // MARK: - Reading

    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        let engine = Self.engine
        // A revert reads the same URL again: its cached size may predate the change.
        let fileSize = Self.currentFileSize(of: url)
        // `.unsupportedEncryption` and every other error propagate: NSDocument presents them
        // through ArchiveError's LocalizedError. A volume error doesn't: a throw here is the open
        // alert with no window, so the window opens and explains it.
        let result = try Self.openReader(at: url, engine: engine)

        let show = { @MainActor in
            self.readURL = url
            self.readType = typeName
            self.state.resetWrongPasswords()
            self.state.fileSize = fileSize
            self.apply(result)
        }
        // Never `main.sync` from the main thread (tests, some NSDocumentController paths): it deadlocks.
        if Thread.isMainThread {
            MainActor.assumeIsolated { show() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { show() } }
        }
    }

    /// What opening a file found.
    private enum OpenResult {
        case opened(any ArchiveReading, password: String?)
        /// Needs a password the user must type.
        case locked
        /// A split archive that can't be read whole.
        case volumeError(ArchiveVolumeError)
    }

    /// Shows `result` in the window: the model, the password sheet or the volume error.
    private func apply(_ result: OpenResult) {
        // A new listing (Revert To Saved reads the file again): a preview of the old one ends.
        actions?.endPreview()
        volumeRetryFailed = false
        state.passwordError = nil
        state.loadError = nil
        state.volumeError = nil
        switch result {
        case .opened(let reader, let password):
            install(reader, password: password)
            state.isLocked = false
        case .locked:
            state.model = nil
            volumeSetType.withLock { $0 = nil }
            state.isLocked = true
        case .volumeError(let error):
            state.model = nil
            volumeSetType.withLock { $0 = nil }
            state.isLocked = false
            state.volumeError = error
        }
    }

    /// Opens `url`, with a remembered password when it needs one. `.locked` means the window asks
    /// for the password.
    private nonisolated static func openReader(at url: URL, engine: ArchiveEngine) throws -> OpenResult {
        do {
            return try openReaderUnchecked(at: url, engine: engine)
        } catch let error as ArchiveVolumeError {
            return .volumeError(error)
        }
    }

    private nonisolated static func openReaderUnchecked(at url: URL, engine: ArchiveEngine) throws -> OpenResult {
        do {
            let reader = try runBlocking { try await engine.open(url, nil) }
            // An encrypted ZIP or 7z lists without a password, but its entries can't be read without
            // one, so it asks like an archive that won't open without one (as on iOS). RAR's
            // encryption can't be decrypted, so it opens read-only: its format isn't
            // writable.
            guard locksOnOpen(reader) else { return .opened(reader, password: nil) }
        } catch ArchiveError.passwordRequired {}
        // A password the user chose to remember; otherwise (or if it's stale) ask.
        guard let saved = KeychainPasswordStore.password(for: url, service: keychainService), !saved.isEmpty else {
            return .locked
        }
        do {
            return .opened(try runBlocking { try await engine.open(url, saved) }, password: saved)
        } catch ArchiveError.wrongPassword {
            // The archive's password changed: forget the old one instead of trying it on every open.
            KeychainPasswordStore.remove(for: url, service: keychainService)
            return .locked
        } catch ArchiveError.passwordRequired {
            return .locked
        }
    }

    /// An encrypted archive of a format the core can decrypt asks for its password.
    private nonisolated static func locksOnOpen(_ reader: any ArchiveReading) -> Bool {
        reader.isEncrypted && (reader.format == .zip || reader.format == .sevenZip)
    }

    // MARK: - Save panel

    /// Our accessory has its own format popup, so NSDocument's is hidden.
    override var shouldRunSavePanelWithAccessoryView: Bool { false }

    /// The format chosen in our accessory decides the type NSDocument saves as.
    /// Nonisolated in the SDK; NSDocument asks for it on the main thread when the panel closes.
    nonisolated override var fileTypeFromLastRunSavePanel: String? {
        guard Thread.isMainThread else { return super.fileTypeFromLastRunSavePanel }
        let identifier = MainActor.assumeIsolated {
            savePanelOptions.map { KernirDocumentTypes.utType(for: $0.settings.format).identifier }
        }
        return identifier ?? super.fileTypeFromLastRunSavePanel
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        // No model, no options: nothing may linger from an earlier panel.
        savePanelOptions = model.map { model in
            let parts = model.reader?.volumeURLs ?? []
            // What a split save must never replace, as `saveSplit` checks it again before the move.
            return SavePanelOptions(settings: ArchiveSaveSettings(model: model), volumeURLs: parts,
                                    sourceURLs: splitSaveSources(of: model), comment: model.commentText)
        }
        // A Dock drop's untitled archive proposes its own name and folder.
        let proposal = fileURL == nil ? newArchiveProposal : nil
        if let proposal { savePanel.directoryURL = proposal.directory }
        savePanelOptions?.attach(to: savePanel, fileName: fileURL?.lastPathComponent ?? proposal?.name)
        if proposal != nil { newArchivePanel.track(savePanel) }
        return super.prepareSavePanel(savePanel)
    }

    /// ⌘S, and Save when closing. Forgets the options of a panel that was cancelled; if this save
    /// needs a panel, `prepareSavePanel` sets fresh ones.
    override func save(withDelegate delegate: Any?, didSave didSaveSelector: Selector?,
                       contextInfo: UnsafeMutableRawPointer?) {
        savePanelOptions = nil
        super.save(withDelegate: delegate, didSave: didSaveSelector, contextInfo: contextInfo)
    }

    // MARK: - Writing

    /// Every save funnels through here. Snapshots the model and shows progress on the main
    /// actor (NSDocument blocks the main thread while it writes, until `unblockUserInteraction`),
    /// then adopts the written file once NSDocument has moved it into place.
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        // A set is read-only: nothing may land on one of its parts. The engine's own check can't
        // see this, because NSDocument writes to a temporary file and swaps it in afterwards.
        if let parts = model?.reader?.volumeURLs, ArchiveSaveSettings.isVolumePart(url, of: parts) {
            savePanelOptions = nil
            let error = SaveOntoVolumePartError(name: url.lastPathComponent)
            // Presented as a sheet: wait for the save panel's to go (see `finishSave`).
            guard let window = windowControllers.first?.window else { return completionHandler(error) }
            window.whenNoSheetAttached { completionHandler(error) }
            return
        }
        // Split on in the save panel: the set goes into the folder `url` names, without NSDocument's
        // save (`saveSplit`). Keyed on the panel's settings, not `typeName`, which stays the archive's
        // type ("public.zip-archive") for the folder a split save names (q2).
        let isSplitting = savePanelOptions.map { $0.isSplitting || $0.settings.options.volumeSize != nil } ?? false
        let targetFormat = isSplitting ? savePanelOptions?.settings.format
                                       : KernirDocumentTypes.format(forTypeIdentifier: typeName)
        // A comment Kernir won't write (too long, a ZIP end-record signature, typed for a split set) refuses
        // the save with the Info popover's message, before anything is written.
        if let problem = model?.saveProblem(as: targetFormat, split: isSplitting) {
            savePanelOptions = nil
            let recovery = isSplitting ? ArchiveModel.splitSaveRecoverySuggestion : nil
            return finishSave(CommentSaveError(message: problem, recoverySuggestion: recovery), completionHandler)
        }
        if let options = savePanelOptions, isSplitting {
            savePanelOptions = nil
            saveSplit(to: url, settings: options.settings, completionHandler: completionHandler)
            return
        }
        let cancellation = TaskCancellation()
        // Set when this save comes from the save panel; a plain ⌘S uses the model's options, or the
        // app's "Exclude Mac metadata" default when no panel has saved it. It writes
        // the format of `typeName`, which comes from the file's extension, not its content.
        let panelSettings = savePanelOptions?.settings
        savePanelOptions = nil
        let operation = OperationProgress(title: String(localized: "Saving “\(url.lastPathComponent)”…"),
                                          fraction: nil, cancel: { cancellation.cancel() })
        let snapshot = model.map {
            // A format without comments drops a comment edit (`saveChanges(as:)`).
            SaveSnapshot(reader: $0.reader, changes: $0.saveChanges(as: targetFormat),
                         options: ArchiveSaveSettings.writeOptions(for: $0, panelOptions: panelSettings?.options,
                                                                   targetFormat: targetFormat),
                         password: panelSettings.map(\.password) ?? $0.password, cancellation: cancellation,
                         progressID: operation.id)
        }
        pendingSave.withLock { $0 = snapshot }
        state.progress = operation
        // Read before the save replaces the original: an archive saved from a downloaded one stays
        // quarantined, the sandbox no longer marks what it writes (QuarantinePropagation).
        let quarantine = model.flatMap { QuarantinePropagation.Mark(of: $0.quarantineSources) }

        super.save(to: url, ofType: typeName, for: saveOperation) { error in
            if error == nil { quarantine?.apply(to: [url], recursive: false) }
            // Unused when NSDocument failed before writing.
            self.pendingSave.withLock { $0 = nil }
            // Only these move the document to the written file; Save To leaves it as it was.
            guard error == nil, saveOperation == .saveOperation || saveOperation == .saveAsOperation,
                  let snapshot, let fileURL = self.fileURL else {
                self.finishSave(error, completionHandler)
                return
            }
            Task {
                var reopenError: (any Error)?
                do {
                    if let panelSettings { self.model?.apply(panelSettings) }
                    if let saved = self.model {
                        // The name encoding chosen for the archive goes with the written file only if
                        // its names are still stored that way.
                        let engine = Self.engine
                        let reader = try await saved.openSaved(fileURL) { url, nameEncoding in
                            try await engine.openWithNameEncoding(url, snapshot.password, nameEncoding)
                        }
                        if let model = self.model, model.saveChanges(as: targetFormat) != snapshot.changes {
                            Self.logger.notice("Adopting the saved archive dropped edits made during the save")
                        }
                        // The old snapshot and its undo history refer to the file that was replaced.
                        self.model?.didSave(reader: reader)
                    }
                    // The saved file is one ordinary archive.
                    self.volumeSetType.withLock { $0 = nil }
                } catch {
                    Self.logger.error("Reopen after save failed: \(error.localizedDescription, privacy: .public)")
                    reopenError = error
                    // The file already holds the changes; keeping them would apply them twice on
                    // the next save. Drop the stale model; reopening the document reads it again.
                    self.state.model = nil
                    // Its undo steps would edit it, and move opened copies, out of sight.
                    self.undoManager?.removeAllActions()
                    self.volumeSetType.withLock { $0 = nil }
                    self.state.selection = []
                    self.state.loadError = error.localizedDescription
                }
                // The listing was replaced (or dropped), and the reader's extracted files with it: a
                // preview of the old one ends.
                self.actions?.endPreview()
                // The file is on disk whether or not it could be reread.
                // Not from the cache: `fileURL` may hold the size from before the save.
                self.state.fileSize = Self.currentFileSize(of: fileURL)
                // The save itself succeeded, so NSDocument must treat it as saved: an error here
                // would say "could not be saved" about a file that was written.
                self.finishSave(nil, completionHandler)
                if let reopenError {
                    self.presentInWindow(ReopenAfterSaveError(name: fileURL.lastPathComponent, underlying: reopenError))
                }
            }
        }
    }

    /// Reports a problem in a sheet on the window, once any other sheet (the progress sheet of a save) has gone.
    private func presentInWindow(_ error: any Error) {
        guard let window = windowControllers.first?.window else {
            ArchiveActions.presentError(error)
            return
        }
        window.whenNoSheetAttached {
            NSAlert(error: self.willPresentError(error)).beginSheetModal(for: window)
        }
    }

    /// Ends the progress sheet, then reports the outcome. NSDocument presents a save error as
    /// a sheet, and one begun while SwiftUI is still dismissing the progress sheet never appears.
    func finishSave(_ error: (any Error)?, _ completionHandler: @escaping (Error?) -> Void) {
        state.progress = nil
        guard error != nil, let window = windowControllers.first?.window else {
            completionHandler(error)
            return
        }
        window.whenNoSheetAttached { completionHandler(error) }
    }

    /// Runs on NSDocument's saving thread and writes to a temporary file that NSDocument then
    /// swaps in, so a failed or cancelled write never touches the original.
    nonisolated override func write(to url: URL, ofType typeName: String,
                                    for saveOperation: NSDocument.SaveOperationType,
                                    originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        let snapshot = pendingSave.withLock { pending in
            defer { pending = nil }
            return pending
        }
        // Everything this write needs is in the snapshot; let the user back in.
        unblockUserInteraction()
        // No snapshot: the archive is locked, so there is nothing to repack.
        guard let snapshot else { throw ArchiveError.passwordRequired }
        guard let format = KernirDocumentTypes.format(forTypeIdentifier: typeName) else {
            throw ArchiveError.unsupportedFormat
        }
        guard format.isWritable else { throw ArchiveError.readOnlyFormat(format) }

        let engine = Self.engine
        let progress = state.progressHandler(for: snapshot.progressID)
        do {
            try Self.runBlocking(cancellation: snapshot.cancellation) {
                // Explicit options from `ArchiveSaveSettings.writeOptions`, a plain ⌘S's included: the
                // Mac's strip default is on, so it never passes nil (which would keep the source's settings).
                try await engine.write(snapshot.reader, snapshot.changes, format, url, snapshot.options, progress)
            }
        } catch ArchiveError.cancelled, is CancellationError {
            // The one error NSDocument never presents.
            throw CocoaError(.userCancelled)
        } catch {
            // A format that can't carry the encryption refuses in save words, not the open-side text.
            let encryption = snapshot.options?.encryption ?? snapshot.reader?.encryption ?? .none
            throw SaveEncryptionError.reporting(error, encryption: encryption, format: format)
        }
    }

    // MARK: - Password

    /// Reopens a locked archive with `password`. A wrong password keeps the document locked
    /// and sets `state.passwordError` so the window can ask again. Any other error is thrown:
    /// another password won't help. `remember` saves the password in the Keychain once it works.
    func unlock(password: String, remember: Bool = false) async throws {
        guard let url = fileURL ?? readURL else { return }
        do {
            let reader = try await Self.engine.open(url, password)
            // The core doesn't verify an empty password, so an encrypted ZIP or 7z stays locked (as on iOS).
            if Self.locksOnOpen(reader), password.isEmpty { throw ArchiveError.wrongPassword }
            install(reader, password: password)
            state.isLocked = false
            state.resetWrongPasswords()
            state.passwordError = nil
            state.loadError = nil
            if remember { KeychainPasswordStore.save(password, for: url, service: Self.keychainService) }
        } catch ArchiveError.wrongPassword, ArchiveError.passwordRequired {
            state.passwordError = String(localized: "Wrong password. Try again.")
            // 7zAES has no check value, so a damaged first file also lands here: the sheet hints at it.
            // The type `read` saw: `fileType` can still be NSDocument's default type here.
            let typeName = readType ?? fileType
            state.recordWrongPassword(
                isSevenZip: typeName.flatMap(KernirDocumentTypes.format(forTypeIdentifier:)) == .sevenZip)
        } catch {
            Self.logger.error("Unlock failed: \(error.localizedDescription, privacy: .public)")
            state.passwordError = nil
            throw error
        }
    }

    // MARK: - Volume sets

    /// The last retry after a volume error failed otherwise (`state.loadError`): opening the file
    /// again may still read it, e.g. once a part has finished copying. Cleared by `apply`.
    private var volumeRetryFailed = false

    /// A volume error shows, or the retry after one failed and left no model.
    private var canRetryVolumeOpen: Bool { state.volumeError != nil || (volumeRetryFailed && model == nil) }

    /// Reopens the archive after the user granted access to the folder of a split archive. Opens
    /// off the main thread, then shows the result as `read` does: the model, the password sheet,
    /// or, when the engine still refuses (the grant may have revealed another missing part), the
    /// new volume error. Any other error goes to `state.loadError`. Does nothing without a volume
    /// error (or a failed retry) to retry, and shows nothing once the document has closed.
    /// Returns the new volume error when it is the same failure as the one the retry started from
    /// (Grant Access then says it's still unreadable); nil otherwise: opened, locked, another part,
    /// another error, nothing retried, or closed.
    @discardableResult
    func retryVolumeOpen() async -> ArchiveVolumeError? {
        guard !state.isRetrying, canRetryVolumeOpen, let url = fileURL ?? readURL else { return nil }
        let previous = state.volumeError
        state.isRetrying = true
        defer { state.isRetrying = false }
        let engine = Self.engine
        let (result, fileSize) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(Result<OpenResult, any Error>, Int64?), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Off the main thread: a network volume can take a while to answer. `read` read
                // the size through this URL already, so it must not come from the cache.
                let fileSize = Self.currentFileSize(of: url)
                continuation.resume(returning: (Result { try Self.openReader(at: url, engine: engine) }, fileSize))
            }
        }
        // Closed meanwhile: a model now would only keep the document alive and leave its temporary
        // folders behind.
        guard !isClosed else { return nil }
        switch result {
        case .success(let opened):
            state.fileSize = fileSize
            state.resetWrongPasswords()
            apply(opened)
            if case .volumeError(let next) = opened, let previous, next.isSameFailure(as: previous) {
                return next
            }
            return nil
        case .failure(let error):
            Self.logger.error("Retry after granting access failed: \(error.localizedDescription, privacy: .public)")
            state.volumeError = nil
            state.loadError = error.localizedDescription
            volumeRetryFailed = true
            return nil
        }
    }

    /// The size of the file at `url` now, nil when it can't be read. Foundation caches resource
    /// values on a URL (and every copy of it) until the run loop turns, so a size read through the
    /// same URL earlier, e.g. by `read` before the file changed, would come back stale. A new URL
    /// for the path has no cache, and the shared one is left alone (other threads may read it).
    private nonisolated static func currentFileSize(of url: URL) -> Int64? {
        let fresh = url.isFileURL ? URL(filePath: url.path(percentEncoded: false), directoryHint: .notDirectory) : url
        return (try? fresh.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    // MARK: - Helpers

    private static let logger = Logger(subsystem: "com.kernir.app", category: "document")

    private func install(_ reader: any ArchiveReading, password: String?) {
        let model = ArchiveModel(reader: reader, undoManager: undoManager, openedFiles: openedFiles)
        model.password = password
        state.model = model
        let setType = reader.volumeURLs.count > 1 ? readType : nil
        volumeSetType.withLock { $0 = setType }
    }

    /// Runs async engine work to completion from synchronous NSDocument entry points.
    /// The work runs detached, so it never needs the thread that waits for it.
    /// `cancellation`, if given, cancels the work.
    private nonisolated static func runBlocking<T: Sendable>(
        cancellation: TaskCancellation? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        // Same QoS as the waiting thread (a semaphore donates none), so it never waits on lower-priority work.
        let qos = UInt8(truncatingIfNeeded: qos_class_self().rawValue)
        let task = Task.detached(priority: qos == 0 ? nil : TaskPriority(rawValue: qos)) {
            do {
                box.result = .success(try await operation())
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        cancellation?.register(task)
        semaphore.wait()
        // The semaphore orders the write before this read.
        return try box.result!.get()
    }
}

/// What one save writes, captured on the main actor.
private struct SaveSnapshot: Sendable {
    let reader: (any ArchiveReading)?
    let changes: ArchiveChangeSet
    /// nil keeps the source's method, encryption and password.
    let options: ArchiveWriteOptions?
    /// Opens the written file; saving never touches the Keychain.
    let password: String?
    let cancellation: TaskCancellation
    /// The progress sheet this save shows; the write's updates only move that one.
    let progressID: UUID
}

/// Cancels a task from the progress sheet, even if Cancel comes before the task exists.
final class TaskCancellation: Sendable {
    private let state = OSAllocatedUnfairLock<(task: Task<Void, Never>?, isCancelled: Bool)>(
        initialState: (nil, false))

    func cancel() {
        state.withLock { state in
            state.isCancelled = true
            return state.task
        }?.cancel()
    }

    func register(_ task: Task<Void, Never>) {
        if state.withLock({ state in
            state.task = task
            return state.isCancelled
        }) {
            task.cancel()
        }
    }
}

/// Hands a result from the detached task to the waiting thread (ordered by a semaphore).
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, any Error>?
}

/// The archive comment can't be written (`ArchiveModel.saveProblem(as:split:)`): the save is refused and the
/// file left as it was. `message` is the one the Info popover shows; a split save adds what to do about it.
struct CommentSaveError: LocalizedError {
    let message: String
    var recoverySuggestion: String?

    var errorDescription: String? { message }
}

/// The file was written but could not be opened again; the save itself succeeded.
struct ReopenAfterSaveError: LocalizedError {
    let name: String
    let underlying: any Error

    var errorDescription: String? {
        String(localized: "“\(name)” was saved, but Lutik couldn't open it again.")
    }

    var recoverySuggestion: String? { underlying.localizedDescription }
}
