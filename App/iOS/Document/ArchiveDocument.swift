import Foundation
import KernirCore
import os
import UIKit

/// An archive opened by URL: listing comes from the engine, entries stay on disk.
///
/// Saves happen only when asked: the Save button (`commitSave()`), closing, or backgrounding.
/// UIKit's timer autosave is skipped (see `autosave(completionHandler:)`).
///
/// `@unchecked Sendable`: mutable state is behind `state` (an `OSAllocatedUnfairLock`);
/// `session` and the model are main-actor confined; `observers` is written only in `init`.
final class ArchiveDocument: UIDocument, @unchecked Sendable {
    /// The engine new documents use. Tests swap it before creating a document.
    nonisolated(unsafe) static var engine: DocumentEngine = .live

    /// What `contents(forType:)` hands to `writeContents`: the model's edits at save time.
    /// Kept current on main so UIKit can read it on any thread.
    struct SaveSnapshot: Sendable {
        var reader: (any ArchiveReading)?
        var changes: ArchiveChangeSet
        var format: ArchiveFormat
        var options: ArchiveWriteOptions?
        /// Why the edited comment can't be written (`ArchiveModel.commentProblem`): the Save button's save is
        /// refused before anything is written, others write without it (`contents(of:withoutCommentFor:)`).
        /// nil when it can be.
        var commentProblem: String?
    }

    private struct State: Sendable {
        /// Explicit save requests in flight (Save button, close). Autosave runs only while > 0.
        var saveGate = 0
        /// Save button saves in flight (`commitSave`): the only saves a comment Lutik won't write refuses.
        var explicitSaves = 0
        var isClosing = false
        var lastSaveError: (any Error)?
        /// Saves `save(to:for:completionHandler:)` refused before UIKit's save (`saveInput()`).
        var refusedSaves = 0
        /// The `.write` `save(to:for:completionHandler:)` accepted, taken once by the `contents(forType:)` that
        /// follows, so the two can't disagree (the Save button's state or the snapshot may change in between).
        /// `saveID` lets that save's completion clear only its own leftover, if UIKit skipped `contents`.
        var acceptedSave: (saveID: UInt64, input: SaveInput)?
        /// The last `saveID` handed out.
        var saveCount: UInt64 = 0
        /// The file ID of the file the last `writeContents` wrote, before UIKit swapped it in, reset at the
        /// start of each write: the remember after the save stores a Remove only while the file at the path
        /// is still that one.
        var savedFileID: UInt64?
        /// The `.ready` model's save input; nil while locked, failed or loading.
        var snapshot: SaveSnapshot?
        /// The password that last opened the archive, reused when UIKit re-reads it (revert).
        var password: String?
        /// A new archive's creation settings, adopted by every model this document makes, so a
        /// revert of the still empty archive keeps them too.
        var creationSettings: ArchiveSaveSettings?
        /// The folder the user granted for a multi-volume set, accessed until the document closes.
        var grantedFolder: URL?
        /// The "Exclude Mac metadata" default a plain save follows (`plainSaveDefaultExcludesMacMetadata`).
        var plainSaveDefaultExcludesMacMetadata = ArchiveSaveSettings.excludesMacMetadataByDefault
    }

    private static let logger = Logger(subsystem: "com.kernir.app", category: "document")

    @MainActor let session: DocumentSession
    let staging: StagingArea
    /// Copies extracted for sharing. Kept until the document closes: a share can still be
    /// reading them after the share sheet has gone.
    let scratch: StagingArea
    /// This document's engine (`ArchiveDocument.engine` when it was created).
    let engine: DocumentEngine
    /// Where remembered passwords live; tests pass a service of their own.
    private let keychainService: String
    /// Where the answers to "Remove Mac metadata?" are remembered per file; tests pass a store of their own.
    private let macMetadataChoices: MacMetadataChoiceStore
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Set once in `init`, removed in `deinit`.
    private var observers: [any NSObjectProtocol] = []

    /// The "Exclude Mac metadata" default a plain save follows: the app's,
    /// `ArchiveSaveSettings.excludesMacMetadataByDefault`. Tests set it, before the edits they save,
    /// to pin the plain-save options whatever the platform's default.
    var plainSaveDefaultExcludesMacMetadata: Bool {
        get { state.withLock { $0.plainSaveDefaultExcludesMacMetadata } }
        set { state.withLock { $0.plainSaveDefaultExcludesMacMetadata = newValue } }
    }

    /// Saves refused before UIKit's save, so before `contents(forType:)` (`save(to:for:completionHandler:)`).
    /// Tests read it.
    var refusedSaves: Int { state.withLock { $0.refusedSaves } }

    override convenience init(fileURL url: URL) {
        self.init(fileURL: url, keychainService: KeychainPasswordStore.service)
    }

    init(fileURL url: URL, keychainService: String, macMetadataChoices: MacMetadataChoiceStore = .shared) {
        engine = Self.engine
        self.keychainService = keychainService
        self.macMetadataChoices = macMetadataChoices
        session = DocumentSession()
        staging = StagingArea(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        scratch = StagingArea(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("Shared", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true))
        super.init(fileURL: url)
        observers = modelChangeObservers()
    }

    deinit {
        releaseGrant()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Every model edit, undo and redo goes through the undo manager (on main), so its
    /// notifications are when the save snapshot changes. UIKit may post them off main (for
    /// example while saving); those hop to main asynchronously, so the posting thread never
    /// waits for main, which may itself be waiting for that thread (a background close).
    private func modelChangeObservers() -> [any NSObjectProtocol] {
        let session = session
        let state = state
        let names: [Notification.Name] = [.NSUndoManagerCheckpoint, .NSUndoManagerDidCloseUndoGroup,
                                          .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange]
        return names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: nil) { _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { Self.refreshSnapshot(of: session, in: state) }
                } else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { Self.refreshSnapshot(of: session, in: state) }
                    }
                }
            }
        }
    }

    @MainActor private static func refreshSnapshot(of session: DocumentSession, in state: OSAllocatedUnfairLock<State>) {
        let plainSaveDefaultExcludesMacMetadata = state.withLock { $0.plainSaveDefaultExcludesMacMetadata }
        let snapshot = session.model.map { model in
            // A plain save has no options sheet: the file's Mac metadata choice (keep
            // while unanswered and the source holds Mac metadata) over the options a sheet saved (a new
            // archive's), else the app's "Exclude Mac metadata" default with the source's settings.
            // It writes the source's own format, so no target format.
            SaveSnapshot(reader: model.reader, changes: model.changes, format: model.format,
                         options: session.plainSaveOptions(for: model, default: plainSaveDefaultExcludesMacMetadata),
                         commentProblem: model.saveProblem(as: model.format, split: false))
        }
        state.withLock { $0.snapshot = snapshot }
    }

    // MARK: - Reading

    private enum OpenOutcome: Sendable {
        case opened(any ArchiveReading, password: String?)
        case locked(error: String?)
        /// A multi-volume set the engine refuses: a part is missing or not readable.
        case volume(ArchiveVolumeError)
        case failed(String)
    }

    /// Runs on UIKit's background queue. Only lists the archive; never throws for archive
    /// errors, so the document stays open and the UI shows the locked or failed phase.
    override func read(from url: URL) throws {
        let engine = engine
        let service = keychainService
        let state = state
        let outcome = try runBlocking { await Self.openOutcome(url, engine: engine, state: state, keychainService: service) }
        // Off main, next to the open: the store reads the file's identity. Not ordered with the remember
        // after one of our saves, which runs on main once the save is done: a revert that reads between
        // the two finds the record still on the old file's ID and drops a Remove. Accepted: a dropped
        // Remove only keeps the Mac metadata and asks again at the next Save. That remember never strips
        // unasked either: it stores a Remove only for the file the save wrote (`savedFileID`), so a file
        // iCloud or another app put at the path meanwhile gets no Remove (`save(to:for:completionHandler:)`).
        let remembered = macMetadataChoices.choice(for: url)
        // Enqueued before UIKit's open completion, which also runs on main.
        let session = session
        let undoManager = undoManager
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                session.adoptMacMetadataChoice(readWithFile: remembered)
                Self.apply(outcome, to: session, undoManager: undoManager, state: state, url: url)
            }
        }
    }

    /// The first open and every reopen of a set after a folder grant: the password this document
    /// knows (or its new archive's), else one the user chose to remember.
    private static func openOutcome(_ url: URL, engine: DocumentEngine, state: OSAllocatedUnfairLock<State>,
                                    keychainService: String) async -> OpenOutcome {
        // A new encrypted archive opens with the password it was just created with.
        let password = state.withLock { $0.password } ?? Self.newArchiveSettings(for: url)?.password
        var outcome = await Self.open(url, password: password, engine: engine)
        // No password yet (a revert reuses the known one): try a password the user chose to
        // remember. A stale one locks without an error, as if none were stored: nothing was typed.
        if password == nil, case .locked = outcome,
           let remembered = KeychainPasswordStore.password(for: url, service: keychainService) {
            switch await Self.open(url, password: remembered, engine: engine) {
            case .locked: break
            case let retried: outcome = retried
            }
        }
        return outcome
    }

    /// Lists `url` with `password`.
    private static func open(_ url: URL, password: String?, engine: DocumentEngine) async -> OpenOutcome {
        do {
            let reader = try await engine.open(url, password)
            return outcome(opening: reader, password: password)
        } catch {
            return outcome(for: error)
        }
    }

    /// Opens again with `password`. A wrong password keeps the document locked with an error.
    /// Does nothing unless the document is locked, so it never discards a ready model's edits.
    /// `remember` saves the password in the Keychain once it opens the archive.
    @MainActor func unlock(password: String, remember: Bool) async {
        guard case .locked = session.phase else { return }
        let outcome: OpenOutcome
        do {
            outcome = Self.outcome(opening: try await engine.open(fileURL, password), password: password)
        } catch {
            outcome = Self.outcome(for: error)
        }
        if remember, case .opened = outcome {
            KeychainPasswordStore.save(password, for: fileURL, service: keychainService)
        }
        Self.apply(outcome, to: session, undoManager: undoManager, state: state, url: fileURL)
    }

    /// What a folder grant ends with that the screen must still say. nil from `grantFolder` means
    /// the set opened, the phase changed, the document closed, the grant was ignored, or the
    /// reopen put a new error (another part) on screen.
    enum FolderGrantResult: Equatable {
        /// Another folder than the one holding the parts: nothing was kept or retried.
        case wrongFolder(ArchiveVolumeError)
        /// The right folder, but the reopen failed again on the same part.
        case stillUnreadable(ArchiveVolumeError)
    }

    /// After the user picks the folder that holds the other parts of a set: keeps access to it until
    /// the document closes, makes the system download the part the error names (iCloud), then reopens.
    /// Repeats while the error names a new part (at most 999 rounds); the same part again stays on
    /// screen as `.volume` and returns `.stillUnreadable`. Does nothing unless the document is
    /// showing a `.volume` error. A folder other than the error's isn't kept or retried: returns
    /// `.wrongFolder`, so the screen can ask for the right folder.
    @MainActor @discardableResult func grantFolder(_ folder: URL) async -> FolderGrantResult? {
        guard case .volume(var previous) = session.phase, !session.isGrantingFolder else { return nil }
        // Closed: a scope started now would be held until deinit.
        if documentState.contains(.closed) { return nil }
        // Before the first await: a second grant meanwhile returns at the guard above.
        session.isGrantingFolder = true
        defer { session.isGrantingFolder = false }
        // False for a plain folder (tests): the retry still runs.
        let isScoped = folder.startAccessingSecurityScopedResource()
        let isFolderOfParts = await Self.isFolder(folder, ofPartsOf: previous)
        // Closed or moved on during the check: keep nothing.
        guard !documentState.contains(.closed), case .volume = session.phase else {
            if isScoped { folder.stopAccessingSecurityScopedResource() }
            return nil
        }
        // Another folder can't reach the parts: nothing to retry, and an earlier grant stays.
        guard isFolderOfParts else {
            if isScoped { folder.stopAccessingSecurityScopedResource() }
            return .wrongFolder(previous)
        }
        releaseGrant()
        if isScoped {
            state.withLock { $0.grantedFolder = folder }
        }
        for _ in 0..<999 {
            if documentState.contains(.closed) { return nil }
            await Self.download(folder.appendingPathComponent(previous.fileName))
            let outcome = await Self.openOutcome(fileURL, engine: engine, state: state, keychainService: keychainService)
            // The document closed meanwhile: its session is gone from the screen, apply nothing.
            if documentState.contains(.closed) { return nil }
            // A UIKit revert changed the phase meanwhile (it may have opened the set): its result stands.
            guard case .volume = session.phase else { return nil }
            Self.apply(outcome, to: session, undoManager: undoManager, state: state, url: fileURL)
            guard case .volume(let next) = outcome else { return nil }
            if next.isSameFailure(as: previous) { return .stillUnreadable(next) }
            previous = next
        }
        return nil
    }

    /// `ArchiveVolumeError.isFolderOfParts` reads both folders' identities: off main, as a File
    /// Provider can be slow to answer.
    private static func isFolder(_ folder: URL, ofPartsOf error: ArchiveVolumeError) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: error.isFolderOfParts(folder))
            }
        }
    }

    /// Waits for the system to make `url` readable (downloads a cloud part). A coordination
    /// error is ignored: the reopen decides.
    private static func download(_ url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { _ in }
                continuation.resume()
            }
        }
    }

    private func releaseGrant() {
        state.withLock { state -> URL? in
            defer { state.grantedFolder = nil }
            return state.grantedFolder
        }?.stopAccessingSecurityScopedResource()
    }

    /// An encrypted ZIP or 7z lists without a password, but its entries can't be read without
    /// one, so it stays locked until the user gives one; the engine verifies it on open.
    /// A 7z with encrypted headers can't list at all and arrives as `.passwordRequired`, which
    /// locks too. RAR: one with encrypted data opens ready, read-only, and one
    /// with encrypted headers fails to open (`unsupportedEncryption`).
    private static func outcome(opening reader: any ArchiveReading, password: String?) -> OpenOutcome {
        if passwordFormats.contains(reader.format), reader.isEncrypted, password?.isEmpty ?? true {
            return .locked(error: nil)
        }
        return .opened(reader, password: password)
    }

    /// The formats whose encrypted archives ask for a password before they open.
    private static let passwordFormats: Set<ArchiveFormat> = [.zip, .sevenZip]

    private static func outcome(for error: any Error) -> OpenOutcome {
        if let volume = error as? ArchiveVolumeError { return .volume(volume) }
        return switch error as? ArchiveError {
        case .passwordRequired:
            .locked(error: nil)
        case .wrongPassword:
            .locked(error: error.localizedDescription)
        default:
            .failed(error.localizedDescription)
        }
    }

    // Static, like the other main-actor helpers here: Swift 6.3 region checking rejects
    // capturing a UIDocument subclass in main-actor closures despite `@unchecked Sendable`.
    /// `url` is the file that was opened: a new archive's model adopts its creation settings. The
    /// file's Mac metadata answer is not touched: `read(from:)` adopts it first (an unlock or a folder
    /// grant reads none and keeps the session's).
    @MainActor private static func apply(_ outcome: OpenOutcome, to session: DocumentSession,
                                         undoManager: UndoManager?, state: OSAllocatedUnfairLock<State>,
                                         url: URL) {
        switch outcome {
        case .opened(let reader, let password):
            state.withLock { $0.password = password }
            // The old model's undo steps refer to a snapshot that is gone.
            undoManager?.removeAllActions()
            let model = ArchiveModel(reader: reader, undoManager: undoManager)
            model.password = password
            if let settings = takeNewArchiveSettings(for: url) {
                state.withLock { $0.creationSettings = settings }
            }
            if let settings = state.withLock({ $0.creationSettings }) { model.apply(settings) }
            session.detectMacMetadata(in: reader)
            session.phase = .ready(model)
        case .locked(let error):
            session.detectMacMetadata(in: nil)
            session.phase = .locked(error: error)
        case .volume(let error):
            session.detectMacMetadata(in: nil)
            session.phase = .volume(error)
        case .failed(let message):
            session.detectMacMetadata(in: nil)
            session.phase = .failed(message)
        }
        refreshSnapshot(of: session, in: state)
    }

    // MARK: - Save gate

    /// On iOS 26 UIKit's edit timer is the only caller (close and backgrounding save through a
    /// private path), so it is skipped unless an explicit save opened the gate. Backgrounding
    /// opens the gate itself (`saveForBackground`), in case UIKit routes that save here.
    override func autosave(completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        if state.withLock({ $0.saveGate > 0 }) {
            super.autosave(completionHandler: completionHandler)
        } else {
            completionHandler?(false)
        }
    }

    /// The Save button: saves pending edits in place and reports success.
    @MainActor func commitSave() async -> Bool {
        state.withLock {
            $0.saveGate += 1
            $0.explicitSaves += 1
        }
        defer {
            state.withLock {
                $0.saveGate -= 1
                $0.explicitSaves -= 1
            }
        }
        return await withCheckedContinuation { continuation in
            autosave { ok in continuation.resume(returning: ok) }
        }
    }

    /// Takes the model's edits into the save snapshot now. For an edit the undo manager doesn't hear of:
    /// comment typing after its first keystroke joins that keystroke's undo step without registering
    /// anything (`ArchiveModel.setComment`), so no notification refreshes the snapshot, and a save would
    /// write the comment as it was at that first keystroke.
    @MainActor func refreshSaveSnapshot() {
        Self.refreshSnapshot(of: session, in: state)
    }

    /// The user's answer to "Remove Mac metadata?" at a Save (true is Remove): this document's choice
    /// from now on, remembered for the file, and in the save snapshot at once, so the save that follows
    /// writes it. It changes no entry: nothing to undo, no unsaved change.
    @MainActor func setMacMetadataChoice(_ strips: Bool) {
        session.answerMacMetadataQuestion(strips: strips, for: fileURL, in: macMetadataChoices)
        Self.refreshSnapshot(of: session, in: state)
    }

    /// A window going to the background (its scene's `sceneDidEnterBackground`; each window has
    /// its own) saves pending edits with the gate open, under a background task so the write can
    /// finish after the window leaves the screen. When the whole app backgrounds on iOS 26.5, UIKit
    /// has usually saved already through its private path, while the app is still inactive, so
    /// this finds nothing to save; an autosave issued while that save is in flight is coalesced
    /// by UIKit and does not write again (both checked in the simulator).
    @MainActor func saveForBackground() {
        guard hasUnsavedChanges, !documentState.contains(.closed) else { return }
        let endBackgroundTask = Self.beginBackgroundTask(named: "Save archive")
        let state = state
        state.withLock { $0.saveGate += 1 }
        autosave { _ in
            state.withLock { $0.saveGate -= 1 }
            endBackgroundTask()
        }
    }

    /// Starts a background task and returns the call that ends it; it also ends on expiry.
    @MainActor private static func beginBackgroundTask(named name: String) -> @Sendable () -> Void {
        let identifier = OSAllocatedUnfairLock(initialState: UIBackgroundTaskIdentifier.invalid)
        let end: @MainActor @Sendable () -> Void = {
            let current = identifier.withLock { id in
                defer { id = .invalid }
                return id
            }
            if current != .invalid { UIApplication.shared.endBackgroundTask(current) }
        }
        let started = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: end)
        identifier.withLock { $0 = started }
        return { Task { @MainActor in end() } }
    }

    override func close(completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        state.withLock {
            $0.saveGate += 1
            $0.isClosing = true
        }
        super.close { ok in
            self.state.withLock {
                $0.saveGate -= 1
                $0.isClosing = false
            }
            self.staging.remove()
            self.scratch.remove()
            self.releaseGrant()
            completionHandler?(ok)
        }
    }

    // MARK: - Writing

    /// The edits to write; the archive itself stays on disk. UIKit calls this on the thread
    /// that started the save, so it only reads the snapshot kept current on main.
    /// It writes what `save(to:for:completionHandler:)` accepted before UIKit's save (`acceptedSave`), else, for
    /// a call that didn't go through it, decides now. The refusal is the backstop for those calls: the override
    /// refuses before UIKit's save. The error reaches `saveError` through `lastSaveError`.
    override func contents(forType typeName: String) throws -> Any {
        let accepted = state.withLock { state -> SaveInput? in
            defer { state.acceptedSave = nil }
            return state.acceptedSave?.input
        }
        switch accepted ?? saveInput() {
        case .write(let snapshot, droppedComment: let problem):
            if let problem {
                Self.logger.info("Saving without the comment edit, which can't be written: \(problem, privacy: .public)")
            }
            return snapshot
        case .refused(let error):
            state.withLock { $0.lastSaveError = error }
            throw error
        }
    }

    /// What a save would write now, or why it writes nothing.
    private enum SaveInput: Sendable {
        /// `droppedComment`: why the comment edit is left out (`saveInput()`), nil when it is written.
        case write(SaveSnapshot, droppedComment: String?)
        case refused(any Error)
    }

    /// The one place that decides whether a save writes, asked by both `save(to:for:completionHandler:)` (before
    /// UIKit's save) and `contents(forType:)` (the backstop, for calls the override didn't accept), so they can't
    /// drift. No snapshot (locked, failed,
    /// loading) refuses. A multi-volume set is read-only: never write over one of its parts.
    ///
    /// A comment Lutik won't write (too long, a ZIP end-record signature). The Save button's save is refused, as
    /// on the Mac, with the Info sheet's message, and the edit stays to be fixed. UIKit's own saves (closing,
    /// backgrounding) can't be refused for it: UIDocument closes whatever its save does, which would lose every
    /// other edit too. Those write the other edits with the comment as the file has it, and the
    /// saved archive's reopen drops the comment edit (logged); with no other edit they are refused, as the Save
    /// button's, and write nothing.
    private func saveInput() -> SaveInput {
        guard let snapshot = state.withLock({ $0.snapshot }) else { return .refused(CocoaError(.fileWriteUnknown)) }
        if (snapshot.reader?.volumeURLs.count ?? 1) > 1 { return .refused(ArchiveVolumeError.saveInPlaceError) }
        guard let problem = snapshot.commentProblem else { return .write(snapshot, droppedComment: nil) }
        var kept = snapshot
        kept.changes.comment = .keep
        kept.commentProblem = nil
        let isSaveButton = state.withLock { $0.explicitSaves > 0 && !$0.isClosing }
        guard isSaveButton || kept.changes.isEmpty else { return .write(kept, droppedComment: problem) }
        return .refused(CommentSaveError(message: problem))
    }

    /// UIKit's background queue. Streams kept entries plus edits to `url`, UIKit's safe-save
    /// location, which UIKit swaps in only after this returns.
    override func writeContents(_ contents: Any, to url: URL, for saveOperation: UIDocument.SaveOperation,
                                originalContentsURL: URL?) throws {
        // Reset per write, not in `save(to:)`: that narrows the overlap race but does not close it. A second
        // save's reset here can still land before the first one's completion reads the ID; that save then
        // refuses its Remove and the next Save asks again, the safe direction. A failed write leaves it nil,
        // so only a file this document wrote ever authorizes a Remove.
        state.withLock { $0.savedFileID = nil }
        guard let snapshot = contents as? SaveSnapshot else { throw CocoaError(.fileWriteUnknown) }
        let engine = engine
        let session = session
        let progress: ArchiveProgressHandler = { fraction, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { session.saveFraction = fraction }
            }
        }
        do {
            try runBlocking {
                try await engine.write(snapshot.reader, snapshot.changes, snapshot.format, url,
                                       snapshot.options, progress)
            }
        } catch {
            state.withLock { $0.lastSaveError = error }
            throw error
        }
        // UIKit's safe save moves this file into place, which keeps its file ID: what the remember after the
        // save checks. `KeepMacMetadataTests.answerRefreshesTheSnapshotAndFollowsTheSavedFile` checks that.
        let savedFileID = macMetadataChoices.fileID(of: url)
        state.withLock { $0.savedFileID = savedFileID }
    }

    /// After a successful save the file on disk is a new archive, so the model reopens it
    /// (unless the document is closing), and the file's Mac metadata answer, if any, is remembered
    /// again for the new file (closing too). On failure the model keeps its edits and the
    /// session gets the error.
    ///
    /// A save `saveInput()` refuses never reaches UIKit's save (iOS 17 hang, below), so it also skips UIKit's
    /// failure path: `documentState` never shows `.savingError` and `handleError(_:userInteractionPermitted:)`
    /// isn't called for it. Nothing in App/iOS reads either; the user sees `saveError`, as on a failed write.
    override func save(to url: URL, for saveOperation: UIDocument.SaveOperation,
                       completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        state.withLock { $0.lastSaveError = nil }
        let session = session
        let engine = engine
        let state = state
        let macMetadataChoices = macMetadataChoices
        // Decided once, before UIKit's save: a write is handed to this save's `contents(forType:)`
        // (`acceptedSave`), a refusal ends the save below.
        let input = saveInput()
        let acceptedID = state.withLock { state -> UInt64? in
            guard case .write = input else { return nil }
            state.saveCount += 1
            state.acceptedSave = (saveID: state.saveCount, input: input)
            return state.saveCount
        }
        // Ahead of the progress updates and the completion below, which also go through main.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { session.saveFraction = 0 }
        }
        let finish: @Sendable (Bool) -> Void = { ok in
            // A leftover means UIKit didn't ask for `contents`: dropped, so a later save decides afresh.
            let (isClosing, error, savedFileID) = state.withLock { state -> (Bool, (any Error)?, UInt64?) in
                if let acceptedID, state.acceptedSave?.saveID == acceptedID { state.acceptedSave = nil }
                return (state.isClosing, state.lastSaveError, state.savedFileID)
            }
            let savedURL = ok ? self.fileURL : nil
            let reopenURL = ok && !isClosing && !self.documentState.contains(.closed) ? self.fileURL : nil
            Task { @MainActor in
                // UIDocument's safe save swapped in the file `writeContents` wrote, a new file ID, which a
                // remembered Remove matches by: remembered again for that file only. iCloud or another app may
                // have replaced it since the swap: then the Remove goes and the next Save asks, so their file
                // is never stripped unasked. A revert's read off main may get in before this (`read(from:)`).
                if let savedURL {
                    session.rememberMacMetadataChoiceAfterSave(of: savedURL, savedFileID: savedFileID,
                                                               in: macMetadataChoices)
                }
                if let reopenURL { await Self.reopen(reopenURL, in: session, engine: engine, state: state) }
                session.saveFraction = nil
                if !ok {
                    session.saveError = (error ?? CocoaError(.fileWriteUnknown)).localizedDescription
                }
                completionHandler?(ok)
            }
        }
        // iOS 17's UIDocument never calls the completion of a save whose `contents(forType:)` throws (26.5 calls it
        // with false), so a save that would be refused there is refused here, before UIKit's, and ends as UIKit's
        // failed save does on 26.5: `saveError` set once, the edits kept, the completion called with false on main.
        if case .refused(let error) = input {
            state.withLock {
                $0.lastSaveError = error
                $0.refusedSaves += 1
            }
            finish(false)
            return
        }
        super.save(to: url, for: saveOperation, completionHandler: finish)
    }

    /// Text Encoding reopens adopted (`reopen(nameEncoding:open:)`): a preview or share begun before one
    /// drops its result, since the item may have another name now. A reopen that fails or is cancelled
    /// changes nothing, so it doesn't count.
    @MainActor private(set) var nameEncodingReopens = 0

    /// Text Encoding: lists the archive again with its names read as `nameEncoding` asks
    /// (`ArchiveModel.reopen(nameEncoding:)`), then updates the save snapshot, which holds the reader.
    /// Throws `CancellationError` when the document has read its file again meanwhile (UIDocument
    /// reverting after a change from outside): the model on screen is another one, still reading
    /// Automatic, so the old one adopts nothing and the choice isn't remembered. `open` reads the file;
    /// nil reads it through the document's engine (`openWithNameEncoding`), like the reopen after a save,
    /// so a test engine or `-KernirSlowExtract`'s slow reader applies after the reopen too.
    @MainActor func reopen(
        nameEncoding: ArchiveNameEncoding,
        open: ((URL, String?, ArchiveNameEncoding) async throws -> any ArchiveReading)? = nil
    ) async throws {
        guard let model = session.model else { return }
        let session = session
        let open = open ?? engine.openWithNameEncoding
        try await model.reopen(nameEncoding: nameEncoding) { url, password, encoding in
            let reader = try await open(url, password, encoding)
            // Checked here, after the read: `model.reopen` adopts and remembers right after.
            guard session.model === model else { throw CancellationError() }
            return reader
        }
        // Counted in the same main-actor turn as the adoption, so no preview or share can finish between.
        nameEncodingReopens += 1
        session.detectMacMetadata(in: model.reader)
        Self.refreshSnapshot(of: session, in: state)
    }

    @MainActor private static func reopen(_ url: URL, in session: DocumentSession, engine: DocumentEngine,
                                          state: OSAllocatedUnfairLock<State>) async {
        guard let model = session.model else { return }
        let password = model.password
        do {
            // The name encoding chosen for the archive goes with the saved file only if its names are
            // still stored that way.
            model.didSave(reader: try await model.openSaved(url) {
                try await engine.openWithNameEncoding($0, password, $1)
            })
            // A save with Remove leaves no Mac metadata to ask about.
            session.detectMacMetadata(in: model.reader)
        } catch {
            Self.logger.error("Cannot reopen saved archive: \(error.localizedDescription, privacy: .public)")
            session.phase = .failed(error.localizedDescription)
        }
        refreshSnapshot(of: session, in: state)
    }
}
