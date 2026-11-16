import Foundation
import Observation
import os
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import KernirCore

/// A long operation shown in `ProgressSheet`.
struct OperationProgress {
    var title: String
    /// nil while the amount of work is unknown.
    var fraction: Double?
    /// nil when the operation can't be cancelled.
    var cancel: (@MainActor () -> Void)?
    /// Tells this operation's progress updates from a later operation's.
    var id = UUID()
}

/// A message shown in a stock alert with an OK button.
struct AlertContent {
    var title: String
    var message: String
}

/// Picked items that would replace items with the same names, waiting for the user's answer.
struct PendingReplacement {
    /// Staged copies.
    var urls: [URL]
    var directory: String
    /// The archive paths they would replace.
    var conflicts: [String]
    /// A move's items (`ScreenState.move(_:into:)`), moving into `directory`, instead of `urls`.
    var moving: [String] = []
    /// The cut pasted (`ScreenState.paste(into:)`) when `moving` came from one: cleared once Replace moved them.
    var pastedCut: PastedCut?

    /// "Replace “name”?", or "Replace 3 objects?".
    var title: String {
        if conflicts.count == 1 {
            String(localized: "Replace “\((conflicts[0] as NSString).lastPathComponent)”?")
        } else {
            String(localized: "Replace \(conflicts.count) objects?")
        }
    }
}

/// An extraction into a picked folder that already holds items of the same names, waiting for the
/// user's answer on each, in order. Nothing is written until every conflict has an answer.
struct PendingExtraction {
    /// What to extract (nil: everything).
    var paths: [String]?
    /// The folder picked in Files (security-scoped).
    var folder: URL
    /// The folder's name as Files shows it.
    var folderName: String
    /// What is in the way in `folder` (`ArchiveModel.extractionConflictScan`).
    var scan: ExtractionConflictScan
    /// The requested items already in `folder`, as `ArchiveModel.extractionConflicts` returns them.
    var conflicts: [String] { scan.conflicts }
    /// The conflicts asked about as case-only twins of another requested item, nothing on disk yet:
    /// each later twin's path -> the first twin on its name (`ExtractionConflictScan.twins`).
    var twins: [String: String] { scan.twins }
    /// The conflict being asked about.
    var index = 0
    /// Answers so far, keyed by conflict path.
    var resolutions: [String: ExtractionConflictResolution] = [:]

    var current: String { conflicts[index] }

    /// The question about the current conflict; a case-only twin's question names both items: the
    /// twin and the one holding the name after the answers so far (`ExtractionConflictScan.earlierTwin`).
    var question: ExtractionQuestion {
        let title: String
        let ask: String
        if let earlierPath = scan.earlierTwin(of: current, answers: resolutions) {
            let (name, earlier) = ArchiveModel.twinNames(of: current, earlier: earlierPath)
            title = String(localized: "“\(name)” and “\(earlier)” would get the same name in “\(folderName)”.",
                           comment: "Alert title when two items in the archive differ only in letter case (Readme / README) and are extracted to a folder that ignores case, so the later one would take the earlier one's name. Neither is in the folder yet. %1$@ = the later item's name, %2$@ = the earlier item's name (either may be a file or a folder, or a path when the names alone read the same), %3$@ = the folder's name.")
            ask = String(localized: "Do you want to replace “\(earlier)” with “\(name)”?",
                         comment: "Alert message under the case-only twin title (Readme / README). %1$@ = the earlier item's name, %2$@ = the later item's name; either may be a file or a folder. Buttons: Keep Both, Replace, Stop.")
        } else {
            let name = (current as NSString).lastPathComponent
            title = String(localized: "An item named “\(name)” already exists in “\(folderName)”.")
            ask = String(localized: "Do you want to replace it with the one you’re extracting?")
        }
        // With several conflicts the position goes under the question ("2 of 5").
        let message = if conflicts.count > 1 {
            String(localized: "\(ask)\n\(index + 1) of \(conflicts.count)",
                   comment: "Alert message of an extraction conflict question when there are several: %1$@ = the question's text (already translated, e.g. “Do you want to replace it with the one you’re extracting?”), then a new line and the position of this question: %2$lld = its number, %3$lld = how many conflicts there are in all (e.g. “2 of 5”).")
        } else {
            ask
        }
        return ExtractionQuestion(
            index: index,
            title: title,
            message: message,
            // "Keep Both for All" and "Replace for All" are offered while 2+ conflicts are unanswered.
            offersApplyToAll: conflicts.count - index >= 2)
    }
}

extension PendingExtraction: SequencedQuestions {
    var step: Int { index }
    var isAnswered: Bool { index >= conflicts.count }
}

/// One conflict question as its alert shows it. It never changes while the alert is up: the next
/// question is a new value, published after this one's alert has gone.
struct ExtractionQuestion: Equatable {
    /// Which conflict it asks about; an answer carries it back.
    let index: Int
    /// "An item named “name” already exists in “folder”.", or for a case-only twin
    /// "“Readme” and “README” would get the same name in “folder”."
    let title: String
    /// The question, with "k of n" on a second line when there are several conflicts.
    let message: String
    let offersApplyToAll: Bool
}

/// Where a share sheet points from, which also says which folder level presents it.
enum ShareAnchor: Hashable {
    /// The row of the item at this archive path.
    case row(String)
    /// The toolbar of the folder level at this path ("" for the top level).
    case toolbar(String)

    /// The folder level the anchor is on.
    var folder: String {
        switch self {
        case .row(let path): (path as NSString).deletingLastPathComponent
        case .toolbar(let path): path
        }
    }
}

/// Files ready for the share sheet.
struct ShareRequest: Identifiable {
    let id = UUID()
    var urls: [URL]
    var anchor: ShareAnchor
}

/// Save As Copy's options sheet, for one request.
struct SaveAsCopyRequest: Identifiable {
    let id = UUID()
    var settings: ArchiveSaveSettings
}

/// The name alert of Rename, or of New Folder right after the folder is added.
struct RenameRequest: Identifiable {
    let id = UUID()
    /// The item being renamed.
    var path: String
    /// Its name when the alert came up.
    var name: String
    /// The item is the folder New Folder just added: Cancel keeps it, under its untitled name.
    var isNewFolder: Bool
    /// The alert's text field.
    var text: String
}

/// What every folder level of one open document shares: search, selection, progress,
/// alerts and the editing gates.
@MainActor @Observable
final class ScreenState {
    private static let logger = Logger(subsystem: "com.kernir.app", category: "share")
    /// Extract's conflict questions: each answer, the alert going, each question published, the extraction.
    private static let extractionLogger = Logger(subsystem: "com.kernir.app", category: "extraction")
    /// The progress sheet's going taken as reported by its fallback (`progressSheetFallback`).
    private static let sheetLogger = Logger(subsystem: "com.kernir.app", category: "progress-sheet")

    let document: ArchiveDocument
    /// Names this open document in the marker of every row dragged out of it, so a drop back
    /// onto it is refused while one from another window's archive is taken.
    nonisolated let dragSourceID: UUID
    /// `dragMarkerType` as a type, made once: a hovering drop asks for it on every update.
    nonisolated let dragMarkerUTType: UTType
    var searchText = ""
    /// The search field is active on the level on screen. Find (⌘F) sets it.
    var isSearchPresented = false
    var isSelecting = false {
        didSet {
            guard !isSelecting else { return }
            selection = []
            // The toolbar's Share button, the share sheet's anchor, goes with Select mode.
            dropShares { if case .toolbar = $0 { true } else { false } }
        }
    }
    var selection: Set<String> = []
    var progress: OperationProgress? {
        // A new operation's sheet: the old one's going is no longer waited for. Not on the same
        // operation's fraction updates (`perform`), which keep its `id`.
        didSet { if let progress, progress.id != oldValue?.id { cancelProgressSheetFallback() } }
    }
    var alert: AlertContent?
    /// Set by `add` when the picked items have the names of items already in the folder.
    var pendingReplacement: PendingReplacement?
    /// How long a move's Replace question asked again (`confirmReplacement`) waits once the answered one
    /// went: published while UIKit is still taking that alert down, SwiftUI drops it (`extractionAlertSettle`).
    @ObservationIgnored var replacementAlertSettle: Duration = .milliseconds(350)
    /// The Replace question asked again, until it is up. Tests await it.
    @ObservationIgnored var replacementAskedAgain: Task<Void, Never>?
    /// The Move sheet up now, if any (`beginMove`).
    var moveRequest: MoveRequest?
    /// Move Here's folder, moved into once the sheet has gone (`moveSheetDidDismiss`).
    @ObservationIgnored var confirmedMove: (paths: [String], folder: String)?
    /// What reaches the model's move: a test seam.
    @ObservationIgnored var moveOperations = MoveOperations.model
    /// The paths of rows dragged out of this document, by their drag's item marker type
    /// (`dragItemMarkerPrefix`): a drop delegate decides before it can load a marker's data.
    @ObservationIgnored var draggedRows: [String: String] = [:]
    /// The keys of `draggedRows`, oldest first, to cap it.
    @ObservationIgnored var draggedRowOrder: [String] = []
    /// Set by `extract` when the picked folder already holds items of the same names.
    var pendingExtraction: PendingExtraction? { extractionQuestions.run }
    /// The question the conflict alert shows; nil between an answer and the next question.
    var extractionQuestion: ExtractionQuestion? { extractionQuestions.question }
    /// Asks `pendingExtraction`'s questions one alert at a time, and hands over between them.
    let extractionQuestions: QuestionSequence<PendingExtraction>
    /// How long the next conflict question waits once the answered one's alert has gone
    /// (`extractionAlertDidGo`): published while UIKit is still taking that alert down, SwiftUI drops
    /// the new presentation and never retries it (iPad "no question 4 of 4"). Most tests set it to zero.
    var extractionAlertSettle: Duration {
        get { extractionQuestions.settle }
        set { extractionQuestions.settle = newValue }
    }
    /// After an answer, how long the next question or the extraction waits for the alert's going to be
    /// reported before going on without it; nil: no limit. A backstop: without it a lost report would
    /// leave the extraction pending, and editing off, until the document closes.
    var extractionAlertFallback: Duration? {
        get { extractionQuestions.fallback }
        set { extractionQuestions.fallback = newValue }
    }
    /// The hand-off scheduled by the last answer or `extractionAlertDidGo`: its wait, then the next
    /// question or the extraction. Tests await it.
    var nextQuestion: Task<Void, Never>? { extractionQuestions.next }
    /// Extract Here's Files picker or question while one is up (ScreenState+ExtractHere.swift).
    var extractHereRequest: ExtractHereRequest?
    /// How long an answered Extract Here question's picker waits once its alert has gone
    /// (`extractHereAlertDidGo`): asked for while UIKit is still taking the alert down, the picker may
    /// never come up, as with the conflict questions (`extractionAlertSettle`). Most tests set it to zero.
    @ObservationIgnored var extractHereAlertSettle: Duration = .milliseconds(350)
    /// After an answer, how long the picker waits for the alert's going to be reported before coming
    /// without it; nil: no limit. A backstop, as `extractionAlertFallback`.
    @ObservationIgnored var extractHereAlertFallback: Duration? = .seconds(2)
    /// The hand-off scheduled by the last answer or `extractHereAlertDidGo`: its wait, then
    /// `extractHereAlertDidDismiss`. Tests await it.
    @ObservationIgnored var extractHereHandOff: Task<Void, Never>?
    /// `extractHereHandOff` waits for `extractHereAlertSettle`: the alert's going was reported.
    @ObservationIgnored var extractHereHandOffSettles = false
    /// Archives in these folders get no Extract Here: the app's tmp/ and Documents/Inbox.
    /// Tests set their own, as `Fixture.copy` puts every fixture in tmp.
    var extractHereExcludedFolders: [URL] = ExtractHereLocation.excludedFolders
    /// Extract Here's folder grants. Tests pass a store with fakes.
    @ObservationIgnored var folderAccessStore: FolderAccessStore = ExtractHereEffects.folderAccessStore()
    /// Extract Here's file work into a folder: the archive's, or one picked after a read-only error.
    /// Tests throw from it.
    @ObservationIgnored var extractHereRun: ExtractHereRun = { plan, model, directory, progress in
        try await ExtractHereService.extract(plan, from: model, in: directory, progress: progress)
    }
    /// Whether the archive's URL is outside `extractHereExcludedFolders`, worked out again only
    /// when either changes: the menus read `canExtractHere` on every redraw, and the check reads
    /// the disk.
    @ObservationIgnored var extractHereLocation = ExtractHereLocationCache()
    /// Counts changes of the document's `fileURL` (a move or rename in Files), which views can't
    /// observe on UIDocument: `canExtractHere` reads it, so the Extract menus update.
    private(set) var fileURLChanges = 0
    @ObservationIgnored private var fileURLObservation: NSKeyValueObservation?
    /// The file the preview shows: a temporary copy, or a staged file waiting to be added.
    var previewURL: URL? {
        didSet { if previewURL == nil { previewedPath = nil } }
    }
    /// The archive path `previewURL` shows. Its folder level presents the preview.
    private(set) var previewedPath: String?
    /// Set by `share`: the share sheet comes up for these files.
    var shareRequest: ShareRequest?
    /// Set by `beginSaveAsCopy`: Save As Copy's options sheet is up.
    var saveAsCopyRequest: SaveAsCopyRequest?
    /// Set by Save: "Remove Mac metadata?" waits for the answer (`MacMetadataSaveQuestion`).
    var macMetadataQuestion = false
    /// The copy Save As Copy wrote, waiting for the file mover to put it where the user chooses.
    private(set) var movingCopy: URL?
    /// Save on the options sheet: the copy is written once the sheet has gone.
    @ObservationIgnored private var confirmedCopy: ArchiveSaveSettings?
    /// A preview or share sheet waiting for the progress sheet to finish going away (see `present`).
    @ObservationIgnored private var pendingPresentation: Presentation?
    /// The progress sheet has come up and hasn't finished going away. Observed: the conflict question's
    /// alert waits for it (`canShowExtractionQuestion`).
    private(set) var isProgressSheetShown = false
    /// Saves started so far: work begun before a save can tell its result shows the old archive.
    @ObservationIgnored private var saveStarts = 0
    /// The folder holding the last share's copies.
    @ObservationIgnored private var shareFolder: URL?
    /// Set by the document view controller: pushes a `FolderScreen` for that folder path.
    @ObservationIgnored var openFolder: (@MainActor (String) -> Void)?
    /// Set by the document view controller: closes the document and returns to the browser.
    @ObservationIgnored var closeDocument: (@MainActor () -> Void)?

    /// The undo manager's `canUndo` / `canRedo`, kept current from its notifications.
    private var undoManagerCanUndo = false
    private var undoManagerCanRedo = false
    @ObservationIgnored private let undoObservers = ObserverBag()

    init(document: ArchiveDocument) {
        self.document = document
        let sourceID = UUID()
        dragSourceID = sourceID
        dragMarkerUTType = UTType(importedAs: Self.dragMarkerPrefix + sourceID.uuidString)
        extractionQuestions = QuestionSequence(settle: .milliseconds(350), fallback: .seconds(2),
                                               logger: Self.extractionLogger)
        observeUndoManager()
        document.session.saveDidStart = { [weak self] in self?.saveDidStart() }
        document.session.modelDidChange = { [weak self] in self?.modelDidChange() }
        // UIDocument sets `fileURL` on a move (`presentedItemDidMove(to:)`), on any thread.
        fileURLObservation = document.observe(\.fileURL) { [weak self] _, _ in
            guard let state = self else { return }
            Task { @MainActor in state.fileURLChanges += 1 }
        }
    }

    var session: DocumentSession { document.session }
    var model: ArchiveModel? { session.model }
    var name: String { document.localizedName }

    // MARK: - Editing gates

    /// The archive's format can be written and the document isn't a developer package (an APK is
    /// a ZIP inside, but only viewed). RAR, encrypted or not, is never written.
    /// An encrypted ZIP or 7z is editable once unlocked: a save keeps its encryption
    /// and password, and a 7z comes back AES-256 with an encrypted header.
    /// Goes by the model's format, not the document type: UIDocument types `x.tar.gz` by its last
    /// extension, as plain gzip.
    var canEdit: Bool {
        guard let model else { return false }
        return model.isEditable && !isDeveloperPackage
    }

    private var isDeveloperPackage: Bool {
        guard let type = document.fileType.flatMap(UTType.init) else { return false }
        return KernirDocumentTypes.packageTypes.contains { type.conforms(to: $0) }
    }

    /// A save is writing the archive.
    var isSaving: Bool { session.saveFraction != nil }

    /// A save is writing the archive, or Text Encoding is reading it again. Either starts over from
    /// the archive on disk, so an item added meanwhile would be lost.
    var isBusy: Bool { isSaving || nameEncodingTask != nil }

    /// Edits now. Off while saving: the save writes a snapshot and then starts over from the
    /// saved archive, so an edit made meanwhile would be lost. Off while Text Encoding reads the
    /// archive again, for the same reason. Off while Extract's conflict questions are open
    /// (`pendingExtraction`), between them too: the extraction writes the archive as it was asked about.
    var allowsEditing: Bool { canEdit && !isBusy && pendingExtraction == nil }

    /// Preview, Share, Extract and Save As Copy can start: not while Extract's conflict questions are
    /// open (`pendingExtraction`), between them too. Each brings up a sheet of its own (the preview, the
    /// share sheet, Files, the options sheet), and the next question, published under it, would be
    /// lost as one published while the progress sheet goes away is.
    var allowsPresenting: Bool { pendingExtraction == nil }

    /// Extract's buttons can bring up its Files picker: presenting is allowed (`allowsPresenting`) and no
    /// operation is running, including a preview or share whose progress sheet hasn't come up yet
    /// (`runningOperations`), as for Text Encoding: that preview, share sheet or progress sheet would
    /// come up over the picker. A gate on the picker only: `extract(_:to:)`
    /// comes once the picker has gone, and an Extract a drop's files arrive under still asks.
    var canExtract: Bool { allowsPresenting && runningOperations == 0 }

    /// ＋ and drops add now: edits are allowed and the archive is unlocked. One gate for both, so
    /// the button and the drop target never disagree.
    var canAdd: Bool { allowsEditing && !isLocked }

    var canDeleteSelection: Bool { allowsEditing && isSelecting && !selection.isEmpty }

    var canUndo: Bool { allowsEditing && undoManagerCanUndo }

    var canRedo: Bool { allowsEditing && undoManagerCanRedo }

    /// The archive has edits that aren't saved yet.
    var hasChanges: Bool { model?.hasChanges == true }

    /// The bar shows Undo and Redo: on an editable archive except while a save writes it, and while
    /// a save writes pending edits. Disabled while edits aren't allowed (`canUndo`), so they stay on
    /// the bar, and it doesn't lay out twice, while Text Encoding reads the archive again.
    /// A read-only or locked archive shows neither.
    var showsUndoRedo: Bool { (canEdit && !isSaving) || hasChanges }

    func undo() {
        guard canUndo else { return }
        document.undoManager?.undo()
    }

    func redo() {
        guard canRedo else { return }
        document.undoManager?.redo()
    }

    private func observeUndoManager() {
        let names: [Notification.Name] = [.NSUndoManagerCheckpoint, .NSUndoManagerDidCloseUndoGroup,
                                          .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange]
        let undoOrRedo: Set<Notification.Name> = [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange]
        undoObservers.tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: document.undoManager,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshUndoState()
                    // Undo and redo can take away a folder a level shows (a rename undone, a delete redone).
                    if undoOrRedo.contains(name) {
                        self?.closeUnlistedFoldersWhenSheetGone()
                        self?.pruneRemovedSelection()
                    }
                }
            }
        }
    }

    /// Undo and redo can take selected rows away (a rename undone, a delete redone): Select mode keeps only
    /// the rows still listed, and shares of rows gone go. As after Delete, Select mode ends when
    /// its last selected row goes.
    private func pruneRemovedSelection() {
        dropSharesOfRemovedRows()
        guard let model else { return }
        let listed = selection.filter { model.item(at: $0) != nil }
        guard listed != selection else { return }
        selection = listed
        if isSelecting, listed.isEmpty { isSelecting = false }
    }

    /// Checkpoints arrive on every run loop pass, so only real changes are written: each write
    /// redraws every view reading them.
    private func refreshUndoState() {
        let canUndo = document.undoManager?.canUndo == true
        let canRedo = document.undoManager?.canRedo == true
        if canUndo != undoManagerCanUndo { undoManagerCanUndo = canUndo }
        if canRedo != undoManagerCanRedo { undoManagerCanRedo = canRedo }
        // Undo and redo, from any button or the keyboard, can take a shared row away.
        dropSharesOfRemovedRows()
    }

    // MARK: - Adding and deleting

    /// Adds files and folders (from Files) to `directory`: copies them into staging, since the
    /// picker's access ends long before the save, then asks before replacing same-named items.
    /// Nothing, as on a read-only archive, while Extract's conflict questions are open
    /// (`pendingExtraction`): a picker's answer or a drop's files that arrive after Extract started
    /// would change the archive the extraction was asked about. The same holds for every way in
    /// below (`addPhotos`, `addStaged`, `confirmReplacement`).
    func add(_ urls: [URL], to directory: String) {
        guard canEdit, pendingExtraction == nil, !urls.isEmpty else { return }
        guard !isBusy else { return refuseAddingWhileBusy(urls.map(\.lastPathComponent)) }
        do {
            addStaged(try document.staging.stage(urls), to: directory)
        } catch {
            alert = AlertContent(title: String(localized: "Couldn't add files"), message: error.localizedDescription)
        }
    }

    /// Adds photos and videos to `directory`, each received as a file when Photos offers one.
    /// Only an image may come as data instead; a video without a file is left out and the user
    /// told, so a large one is never loaded into memory. Staged together, so equal names get a
    /// " 2" suffix.
    func addPhotos(_ items: [some PickedItem], to directory: String) async {
        guard canEdit, pendingExtraction == nil, !items.isEmpty else { return }
        guard !isBusy else { return refuseAddingWhileBusy(count: items.count) }
        // Modal, so nothing starts a save until the photos are in.
        progress = OperationProgress(title: String(localized: "Adding photos…"))
        var received: [PickedMedia] = []
        defer {
            progress = nil
            for media in received { try? FileManager.default.removeItem(at: media.folder) }
        }
        do {
            var data: [(bytes: Data, name: String)] = []
            var skipped = 0
            for item in items {
                let types = item.supportedContentTypes
                if let media = try await item.loadFile() {
                    received.append(media)
                    let name = PickedMedia.fileName(received: media.url.lastPathComponent, contentTypes: types)
                    received[received.count - 1] = try media.renamed(to: name)
                } else if PickedMedia.mayLoadIntoMemory(types), let bytes = try await item.loadData() {
                    data.append((bytes, PickedMedia.fileName(received: nil, contentTypes: types)))
                } else {
                    skipped += 1
                }
            }
            var staged = try document.staging.stage(received.map(\.url))
            var names = Set(staged.map { $0.lastPathComponent.lowercased() })
            for (bytes, name) in data {
                staged.append(try document.staging.stage(
                    data: bytes, suggestedName: StagingArea.uniqueName(name, among: &names)))
            }
            addStaged(staged, to: directory)
            if skipped > 0, alert == nil {
                alert = AlertContent(title: String(localized: "Couldn't add \(skipped) items"),
                                     message: String(localized: "\(skipped) items from Photos didn't provide files to copy.",
                                                     comment: "Alert message under “Couldn't add %lld items” when items picked in the Photos picker offered no file to copy; any other picked items are still added. %lld = number of those items. The English “one” form leaves the number out. Other languages’ “one” form can also cover 21, 31… and must then keep %lld."))
            }
        } catch {
            alert = AlertContent(title: String(localized: "Couldn't add files"), message: error.localizedDescription)
        }
    }

    private func addStaged(_ urls: [URL], to directory: String) {
        guard canEdit, pendingExtraction == nil, let model, !urls.isEmpty else { return }
        guard !isBusy else { return refuseAddingWhileBusy(urls.map(\.lastPathComponent)) }
        let conflicts = model.conflicts(adding: urls, to: directory)
        if conflicts.isEmpty {
            model.add(urls, to: directory)
        } else {
            pendingReplacement = PendingReplacement(urls: urls, directory: directory, conflicts: conflicts)
        }
    }

    /// Replace on the conflict alert.
    func confirmReplacement() {
        guard let replacement = pendingReplacement else { return }
        pendingReplacement = nil
        guard canEdit, pendingExtraction == nil, let model else { return }
        guard replacement.moving.isEmpty else {
            // Busy still gets performMove's alert; otherwise the move must still be allowed (the archive
            // may have been reopened, reverted or locked while the question was up).
            guard isBusy || canMove(replacement.moving, into: replacement.directory) else { return }
            // The move replaces what the folder holds when it runs: Replace covers only the items it named,
            // so a changed set is asked about again (none left: nothing to replace, it just moves).
            if !isBusy {
                let conflicts = moveOperations.conflicts(model, replacement.moving, replacement.directory)
                if !conflicts.isEmpty, Set(conflicts) != Set(replacement.conflicts) {
                    var again = replacement
                    again.conflicts = conflicts
                    return askReplacementAgain(again)
                }
            }
            performMove(replacement.moving, into: replacement.directory)
            if let cut = replacement.pastedCut { clearPastedCut(cut, moved: replacement.moving) }
            return
        }
        guard !isBusy else { return refuseAddingWhileBusy(replacement.urls.map(\.lastPathComponent)) }
        model.add(replacement.urls, to: replacement.directory)
    }

    /// `question` as a new Replace alert once the answered one has had `replacementAlertSettle` to go;
    /// dropped when another question came up meanwhile.
    private func askReplacementAgain(_ question: PendingReplacement) {
        replacementAskedAgain?.cancel()
        let settle = replacementAlertSettle
        replacementAskedAgain = Task { [weak self] in
            if settle > .zero { try? await Task.sleep(for: settle) }
            guard let self, !Task.isCancelled, self.pendingReplacement == nil else { return }
            self.pendingReplacement = question
        }
    }

    /// A save (or Text Encoding's reopen) started while a picker or the Replace alert was up, or
    /// runs while items are dropped in: the items can't be added now (it would lose them), and the
    /// user is told so rather than left guessing. Internal for the drop path (ArchiveDragDrop).
    func refuseAddingWhileBusy(_ names: [String] = [], count: Int? = nil) {
        let title = if names.count == 1 {
            String(localized: "Couldn't add “\(names[0])”")
        } else {
            String(localized: "Couldn't add \(count ?? names.count) items")
        }
        alert = AlertContent(title: title, message: busyMessage)
    }

    /// Why an edit or an extraction can't go ahead while `isBusy`. Internal for Extract Here's
    /// alert (ScreenState+ExtractHere.swift).
    var busyMessage: String { busyMessage(saving: isSaving) }

    /// `busyMessage` for a save (`saving`) or a Text Encoding reopen; Copy's alert names the one that landed
    /// during its export, which may have ended since.
    func busyMessage(saving: Bool) -> String {
        if saving {
            String(localized: "The archive is being saved. Try again.")
        } else {
            String(localized: "The archive is being read again. Try again.",
                   comment: "Alert message, while Text Encoding re-reads the archive: the files picked or dropped weren't added, or the items of an Extract weren't extracted")
        }
    }

    /// Cancel on the conflict alert: nothing is added.
    func cancelReplacement() {
        pendingReplacement = nil
    }

    /// Removes items (undoable). Selection mode ends when the deletion empties the selection. Refused, nothing
    /// removed, when it would drop items moved out of a deleted folder (`MoveProblem.holdsMovedOutItems`): said so.
    func delete(_ paths: Set<String>) {
        guard allowsEditing, let model, !paths.isEmpty else { return }
        if let problem = model.remove(paths) {
            alert = AlertContent(title: String(localized: "Couldn't delete \(paths.count) items",
                                               comment: "Alert title when deleting items from the archive is refused; the reason is shown below it. %lld = number of items. In languages whose “one” form also covers 21, 31…, it must keep %lld."),
                                 message: MovePlanning.message(for: problem))
            return
        }
        dropSharesOfRemovedRows()
        let hadSelection = !selection.isEmpty
        selection = selection.filter { model.item(at: $0) != nil }
        if isSelecting, hadSelection, selection.isEmpty { isSelecting = false }
    }

    /// What the toolbar's Delete removes: the selection while selecting.
    func deleteTargets() -> Set<String> {
        isSelecting ? selection : []
    }

    // MARK: - Rename and New Folder

    /// The name alert up now, if any. While there is one the levels hand out `renameUndoManager`.
    var renameRequest: RenameRequest? {
        didSet { renameUndoManager = renameRequest == nil ? nil : renameUndoManager ?? UndoManager() }
    }
    /// The name alert's own undo manager while it is up, new for each rename (the Mac's name field has one
    /// too, `ArchiveActions.renameUndoManager`). The alert's text field finds its undo manager up the
    /// responder chain (alert, presenting level, navigation, document view controller), and every level
    /// hands out this one meanwhile (`responderUndoManager`): its "Typing" steps never enable Undo, mark the
    /// document changed or mix with the model's steps. The model, Undo and Redo use the document's directly.
    @ObservationIgnored private(set) var renameUndoManager: UndoManager?

    /// What the levels' `undoManager` hands out: the name alert's own while it is up, else the document's.
    var responderUndoManager: UndoManager? { renameUndoManager ?? document.undoManager }
    /// The listing the name alert was shown on: the model, and how many times Text Encoding had read it
    /// again. A commit for another listing (a revert's new model, a reopen) names an item that may be gone.
    @ObservationIgnored private weak var renamingModel: ArchiveModel?
    @ObservationIgnored private var renamingReopens = 0

    /// File > Rename: the one item selected in Select mode, while edits are allowed.
    var canRenameSelection: Bool {
        guard allowsEditing, isSelecting, selection.count == 1, let path = selection.first else { return false }
        return model?.item(at: path) != nil
    }

    /// Asks for a new name for the item at `path` (the row's Rename, File > Rename).
    func beginRename(_ path: String) {
        beginRename(path, isNewFolder: false)
    }

    private func beginRename(_ path: String, isNewFolder: Bool) {
        guard allowsEditing, let model, let item = model.item(at: path) else { return }
        renamingModel = model
        renamingReopens = document.nameEncodingReopens
        renameUndoManager = UndoManager()
        renameRequest = RenameRequest(path: item.path, name: item.name, isNewFolder: isNewFolder, text: item.name)
    }

    /// What Save on the name alert would do with `name`: Save is off while it is `.invalid(.empty)`.
    func renameCheck(_ name: String) -> EntryNameCheck {
        guard let request = renameRequest, let model else { return .invalid(.unavailable) }
        return model.check(renaming: request.path, to: name)
    }

    /// Save on the name alert: renames the item to `name`, as typed (one undo step "Rename"); the selection
    /// follows. The same name changes nothing; a refused one changes nothing and says why, then the name
    /// alert comes back with `name` (`canShowRename` waits for that alert to go). An item no longer
    /// there, or on a listing replaced meanwhile (a revert's new model, Text Encoding's reopen), changes
    /// nothing, silently. A save or a reopen running now: nothing is renamed, and the user is told.
    func commitRename(_ name: String) {
        guard var request = renameRequest else { return }
        renameRequest = nil
        guard let model, model === renamingModel, document.nameEncodingReopens == renamingReopens,
              model.item(at: request.path) != nil else { return }
        guard allowsEditing else {
            if canEdit, isBusy { alert = AlertContent(title: renameFailureTitle(request), message: busyMessage) }
            return
        }
        switch model.rename(request.path, to: name) {
        case .success(let newPath):
            guard newPath != request.path else { return }
            selection = ArchiveModel.remap(selection, from: request.path, to: newPath)
            dropSharesOfRemovedRows()
        case .failure(let problem):
            alert = AlertContent(title: renameFailureTitle(request),
                                 message: EntryNameValidation.message(for: problem))
            request.text = name
            renameRequest = request
        }
    }

    /// Cancel on the name alert: the name stays, and so does a new folder (as in Files).
    func cancelRename() {
        renameRequest = nil
    }

    /// Add > New Folder, File > New Folder (⇧⌘N): an "untitled folder" in `directory` ("" = the top
    /// level), one undo step "New Folder", then the name alert for it. Where ＋ adds (`canAdd`).
    func newFolder(in directory: String) {
        guard canAdd, let model else { return }
        do {
            let path = try model.newFolder(in: directory)
            // A search that hides "untitled folder" clears, as on the Mac: after Cancel or a name it doesn't
            // match, the new folder would be listed nowhere.
            if !searchText.isEmpty, !model.children(of: directory, matching: searchText).contains(where: { $0.path == path }) {
                searchText = ""
            }
            beginRename(path, isNewFolder: true)
        } catch {
            alert = AlertContent(title: String(localized: "Couldn't add the folder"),
                                 message: error.localizedDescription)
        }
    }

    private func renameFailureTitle(_ request: RenameRequest) -> String {
        String(localized: "Couldn't rename “\(request.name)”")
    }

    /// Select All (⌘A): Select mode, with every row of the folder at `path` that the search shows.
    func selectAll(in path: String) {
        guard let model else { return }
        isSelecting = true
        selection = Set(model.children(of: path, matching: searchText).map(\.path))
    }

    // MARK: - Preview, extract, share

    /// The folder level whose row was previewed; it presents the preview.
    var previewFolder: String? {
        previewedPath.map { ($0 as NSString).deletingLastPathComponent }
    }

    /// Shows a file in the preview. The file is extracted to a temporary file first, never read
    /// into memory; the progress sheet (with Cancel) comes up only when that takes a while.
    func preview(_ path: String) async {
        guard allowsPresenting, let model, let item = model.item(at: path), !item.isDirectory else { return }
        let saves = saveStarts
        let reopens = document.nameEncodingReopens
        do {
            let url = try await perform(String(localized: "Preparing “\(item.name)”…"),
                                        showingAfter: preparingSheetDelay) { _ in
                try await model.localFileURL(for: path)
            }
            // A save started meanwhile replaces the reader, and its temporary files with it. Text Encoding
            // reading the archive again replaces the reader too, and may have renamed the item.
            // A model replaced meanwhile (read again after a change elsewhere) has sent its previews away.
            guard saveStarts == saves, document.nameEncodingReopens == reopens, self.model === model else { return }
            present(.preview(url, path: item.path))
        } catch {
            report(error, title: String(localized: "Couldn't preview “\(item.name)”"))
        }
    }

    /// The files the preview up now swipes through: `listing`'s, its folder level's rows as shown
    /// (`PreviewQueue`). Each file swiped to is extracted as `preview` does, without the progress
    /// sheet. Once a save or Text Encoding has replaced the reader (and its temporary files) the
    /// preview started from, nothing more is: that throws `CancellationError`, and the save (or the
    /// model's replacement, `modelDidChange`) sends the preview away. nil while no preview is up.
    func previewQueue(listing: [ArchiveItem]) -> PreviewQueue? {
        guard let url = previewURL, let path = previewedPath, let model else { return nil }
        let saves = saveStarts
        let reopens = document.nameEncodingReopens
        return PreviewQueue(listing: listing, previewing: path, url: url) { [weak self] path in
            @MainActor func check() throws {
                guard let self, self.saveStarts == saves, self.document.nameEncodingReopens == reopens,
                      self.model === model else { throw CancellationError() }
            }
            try check()
            let url = try await model.localFileURL(for: path)
            try check()
            return url
        }
    }

    /// What the toolbar's Extract and Share act on: the selection while selecting, else nil
    /// (everything).
    func extractTargets() -> [String]? {
        isSelecting ? Self.topmost(selection) : nil
    }

    /// `paths` without those inside another of them, sorted: a selected folder brings its
    /// contents along (as on macOS, `ArchiveActions.topmost`). "Inside" is decided by
    /// `ArchiveModel.isCovered` on the "/" scalar (`ArchiveModel.parentPath(of:)`), never on
    /// Characters: `a/\u{301}b` is inside `a`. Canonically equivalent spellings match; letter case
    /// is the model's rule (`isCovered`), not decided here.
    nonisolated static func topmost(_ paths: Set<String>) -> [String] {
        paths.filter { !ArchiveModel.isCovered(ArchiveModel.parentPath(of: $0), by: paths) }.sorted()
    }

    /// Extracts `paths` (nil: everything) into `folder`, a folder picked in Files, as the user
    /// sees them: pending additions included, Finder metadata left out. Never replaces anything
    /// without asking: when items of the same names are already there, `pendingExtraction` asks
    /// about each (Keep Both / Replace / Stop) and nothing is written until all are answered.
    /// While the questions are open, between two of them too, another Extract is ignored: its buttons
    /// are off then (`allowsPresenting`), so only a stray call gets here. The open questions and their
    /// answers stay.
    func extract(_ paths: [String]?, to folder: URL) async {
        guard let model, paths?.isEmpty != true, pendingExtraction == nil else { return }
        let (scan, folderName) = withAccess(to: folder) {
            (model.extractionConflictScan(paths, in: folder),
             (try? folder.resourceValues(forKeys: [.localizedNameKey]))?.localizedName ?? folder.lastPathComponent)
        }
        if scan.conflicts.isEmpty {
            await extract(paths, to: folder, resolutions: [:])
        } else {
            let pending = PendingExtraction(paths: paths, folder: folder, folderName: folderName,
                                            scan: scan)
            extractionQuestions.start(pending) { [weak self] in await self?.finishExtraction($0) }
        }
    }

    /// An answer on the conflict alert showing question `index`, for that conflict or, `forAll`,
    /// for it and every one after it. The question goes at once; once its alert has gone
    /// (`extractionAlertDidGo`) and `extractionAlertSettle` has passed, the next one is asked or,
    /// after the last answer, the extraction runs. An answer to any other question than the one
    /// asked is dropped.
    func answerExtractionConflict(_ resolution: ExtractionConflictResolution, forAll: Bool = false, at index: Int) {
        extractionQuestions.answer(at: index) { pending in
            let answered = forAll ? pending.conflicts[pending.index...] : [pending.current]
            for path in answered { pending.resolutions[path] = resolution }
            pending.index += answered.count
        }
    }

    /// The conflict alert's condition has gone false (`FolderScreen`'s `onChange`): the alert is
    /// going. After an answer: the next question, as a new alert, once UIKit has finished taking the
    /// old one down, or after the last answer the extraction with all of them. Without an answer
    /// (something else took the screen) the same question stays and its alert comes back.
    func extractionAlertDidGo() {
        Self.extractionLogger.info("signal: the conflict alert's condition went false")
        extractionQuestions.alertDidGo()
    }

    /// After the last answer, once its alert has gone: the extraction with every answer.
    private func finishExtraction(_ pending: PendingExtraction) async {
        // As with Replace on Add: a save, or a Text Encoding reread, that started while the alert
        // was up replaces the reader.
        guard !isBusy else {
            Self.extractionLogger.info("extract refused: busy")
            alert = AlertContent(title: extractionFailureTitle(pending.paths), message: busyMessage)
            return
        }
        Self.extractionLogger.info("extract: \(pending.conflicts.count) conflicts answered")
        await extract(pending.paths, to: pending.folder, resolutions: pending.resolutions)
    }

    /// Stop on the conflict alert: nothing is extracted.
    func stopExtraction() {
        cancelExtraction()
    }

    /// Stop, or the document closing: the open questions go, and a next question or an extraction
    /// still waiting for the alert to go never comes. An extraction already under its progress sheet
    /// is that sheet's to cancel.
    func cancelExtraction() {
        if pendingExtraction != nil { Self.extractionLogger.info("extraction cancelled") }
        extractionQuestions.cancel()
    }

    /// Extracts under the progress sheet with the user's answers. An item that appeared after the
    /// question is never replaced: at a path with no answer the model throws a conflict, and the alert
    /// says so; at the Keep Both name an answered item was to take, that item takes the next free one
    /// ("Readme 3" when "Readme 2" appeared), up to `ArchiveModel.keepBothAttempts` names.
    private func extract(_ paths: [String]?, to folder: URL,
                         resolutions: [String: ExtractionConflictResolution]) async {
        guard let model else { return }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let title = if let name = targetName(paths) {
            String(localized: "Extracting “\(name)”…")
        } else {
            String(localized: "Extracting \(paths?.count ?? 0) items…")
        }
        do {
            _ = try await perform(title) { progress in
                try await model.extract(paths, to: folder, resolutions: resolutions, progress: progress)
            }
        } catch {
            report(error, title: extractionFailureTitle(paths))
        }
    }

    private func extractionFailureTitle(_ paths: [String]?) -> String {
        if let name = targetName(paths) {
            String(localized: "Couldn't extract “\(name)”")
        } else {
            String(localized: "Couldn't extract \(paths?.count ?? 0) items")
        }
    }

    /// Runs `body` with access to `folder`, a security-scoped folder picked in Files.
    private func withAccess<T>(to folder: URL, _ body: () -> T) -> T {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        return body()
    }

    /// Extracts `paths` into a new folder in the document's scratch area and returns the copies,
    /// in order. Goes through `ArchiveModel.extract`, like Extract, so Finder metadata is left
    /// out here too. Case-only twins (README, Readme) keep both without asking, the later one
    /// under Keep Both's name ("Readme 2"): the folder is fresh, so they are its only conflicts.
    /// Folder twins (Docs, docs) that extract as one folder go once, where the
    /// first of them is. The previous share's copies go now; these go with the next share, on
    /// failure or cancel, or when the document closes.
    func shareURLs(for paths: [String], progress: ArchiveProgressHandler? = nil) async throws -> [URL] {
        guard let model else { throw ArchiveError.entryNotFound(paths.first ?? "") }
        removeShareCopies()
        let folder = try document.scratch.makeFolder()
        shareFolder = folder
        let keepBoth = model.extractionConflicts(paths, in: folder).map { ($0, ExtractionConflictResolution.keepBoth) }
        do {
            let urls = try await model.extract(paths, to: folder, resolutions: Dictionary(keepBoth) { $1 },
                                               progress: progress)
            var shared = Set<String>()
            let unique = urls.filter { shared.insert($0.standardizedFileURL.path).inserted }
            // No link out of an item reaches the share sheet (`ExportLinkSweep`); only links: the share fails.
            let kept = try await Task.detached(priority: Task.currentPriority) { try ExportLinkSweep.sanitize(unique) }.value
            if kept.isEmpty, !unique.isEmpty { throw ExportedLinksError(names: unique.map(\.lastPathComponent)) }
            return kept
        } catch {
            removeShareCopies(in: folder)
            throw error
        }
    }

    /// Removes the copies in `folder` (default: the last share's).
    private func removeShareCopies(in folder: URL? = nil) {
        guard let folder = folder ?? shareFolder else { return }
        if shareFolder == folder { shareFolder = nil }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            Self.logger.error("Cannot remove shared copies: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Prepares `paths` for sharing, then asks for the share sheet at `anchor`. Nothing while
    /// `allowsPresenting` is off.
    func share(_ paths: [String], from anchor: ShareAnchor) async {
        guard allowsPresenting, !paths.isEmpty else { return }
        let saves = saveStarts
        let reopens = document.nameEncodingReopens
        let title = if let name = targetName(paths) {
            String(localized: "Preparing “\(name)”…")
        } else {
            String(localized: "Preparing \(paths.count) items…")
        }
        do {
            let urls = try await perform(title, showingAfter: preparingSheetDelay) { progress in
                try await self.shareURLs(for: paths, progress: progress)
            }
            // The copies show the archive as it was before a save started meanwhile, or before Text
            // Encoding read it again (the row it points from may have another name now).
            guard saveStarts == saves, document.nameEncodingReopens == reopens else { return removeShareCopies() }
            present(.share(ShareRequest(urls: urls, anchor: anchor)))
        } catch {
            let title = if let name = targetName(paths) {
                String(localized: "Couldn't share “\(name)”")
            } else {
                String(localized: "Couldn't share \(paths.count) items")
            }
            report(error, title: title)
        }
    }

    /// The name an operation on `paths` goes by: the item's for one, the archive's for nil
    /// (everything), nil for several.
    private func targetName(_ paths: [String]?) -> String? {
        guard let paths else { return name }
        guard paths.count == 1 else { return nil }
        return model?.item(at: paths[0])?.name ?? (paths[0] as NSString).lastPathComponent
    }

    /// Once up, the progress sheet stays at least this long, so it is never sent away while still
    /// coming up: UIKit then mishandles what is presented next.
    static let minimumSheetTime: Duration = .milliseconds(700)

    /// How long a preview or share prepares before its progress sheet comes up. Tests lengthen it, so
    /// the sheet stays down while they look.
    @ObservationIgnored var preparingSheetDelay: Duration = .milliseconds(300)

    /// Operations running under `perform` now, their progress sheet up or not yet (a preview's or
    /// share's comes up only after `preparingSheetDelay`).
    private(set) var runningOperations = 0

    /// Runs `operation` under the progress sheet, whose Cancel cancels it. With a delay, the
    /// sheet comes up only if the operation is still running by then.
    func perform<T: Sendable>(
        _ title: String, showingAfter delay: Duration = .zero,
        _ operation: @escaping @MainActor @Sendable (ArchiveProgressHandler?) async throws -> T
    ) async throws -> T {
        runningOperations += 1
        defer { runningOperations -= 1 }
        let id = UUID()
        let handler: ArchiveProgressHandler = { [weak self] fraction, _ in
            Task { @MainActor in
                guard let self, self.progress?.id == id else { return }
                self.progress?.fraction = fraction
            }
        }
        let task = Task { @MainActor in try await operation(handler) }
        let sheet = OperationProgress(title: title, cancel: { task.cancel() }, id: id)
        // When the sheet came up, if it did.
        var shownAt: ContinuousClock.Instant?
        let showing: Task<ContinuousClock.Instant?, Never>?
        if delay > .zero {
            showing = Task { @MainActor [weak self] in
                // Cancelled by the time it wakes: the operation is over (both run on main).
                guard (try? await Task.sleep(for: delay)) != nil, !Task.isCancelled, let self else { return nil }
                self.progress = sheet
                return .now
            }
        } else {
            showing = nil
            progress = sheet
            shownAt = .now
        }
        let result: Result<T, any Error>
        do {
            result = .success(try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            })
        } catch {
            result = .failure(error)
        }
        showing?.cancel()
        if let shown = await showing?.value { shownAt = shown }
        if let shownAt, progress?.id == id {
            await Self.sleep(until: shownAt + Self.minimumSheetTime)
        }
        if progress?.id == id { progress = nil }
        return try result.get()
    }

    /// Sleeps until `deadline`, even in a cancelled task.
    private static func sleep(until deadline: ContinuousClock.Instant) async {
        await Task { try? await Task.sleep(until: deadline, clock: .continuous) }.value
    }

    // MARK: - Presenting after the progress sheet

    /// A preview or share sheet to bring up.
    private enum Presentation {
        case preview(URL, path: String)
        case share(ShareRequest)
        /// The file mover, for a copy Save As Copy wrote.
        case move(URL)
    }

    /// Brings up a preview or share sheet now, or, while the progress sheet is on screen, once it
    /// has gone (`progressSheetDidDismiss`): UIKit can't present it while the sheet is still
    /// going away, and SwiftUI then leaves it stuck or never shows it.
    private func present(_ presentation: Presentation) {
        if isProgressSheetShown {
            pendingPresentation = presentation
        } else {
            show(presentation)
        }
    }

    private func show(_ presentation: Presentation) {
        switch presentation {
        case .preview(let url, let path):
            previewedPath = path
            previewURL = url
        case .share(let request):
            shareRequest = request
        case .move(let url):
            movingCopy = url
        }
    }

    /// The progress sheet has started coming up (`FolderScreen`). Its operation already over (it
    /// ended while the sheet came up), the sheet is already going: its fallback starts.
    func progressSheetDidAppear() {
        isProgressSheetShown = true
        cancelProgressSheetFallback()
        if activeProgress == nil { progressDidEnd() }
    }

    /// The progress sheet has finished going away (`FolderScreen`): what waited for it comes up.
    func progressSheetDidDismiss() {
        cancelProgressSheetFallback()
        isProgressSheetShown = false
        if pendingFolderClose {
            pendingFolderClose = false
            closeUnlistedFolders?()
        }
        guard let presentation = pendingPresentation else { return }
        pendingPresentation = nil
        show(presentation)
    }

    // MARK: - The progress sheet's fallback

    typealias Sleep = @MainActor @Sendable (Duration) async throws -> Void

    /// How long after its operation has ended (`progressDidEnd`) the progress sheet's going waits to be
    /// reported (`progressSheetDidDismiss`) before it is taken as gone without that. A backstop: sent away
    /// while still coming up (a save's sheet has no `minimumSheetTime`), the sheet's `onDismiss` can be
    /// lost, and `isProgressSheetShown` would then hold back alerts, the conflict question and what
    /// waits to be presented until the document closes.
    @ObservationIgnored var progressSheetFallback: Duration = .seconds(2)
    /// How the fallback sleeps: `Task.sleep`. Tests put in one they drive.
    @ObservationIgnored var progressSheetSleep: Sleep = { try await Task.sleep(for: $0) }
    /// The fallback waiting now, if any. Tests read it right after it starts and await its value.
    @ObservationIgnored private(set) var progressSheetFallbackTask: Task<Void, Never>?

    /// The progress sheet's operation has ended: `activeProgress` went nil (`FolderScreen`), and the
    /// sheet, if up, goes. Its going is reported by `progressSheetDidDismiss`; should that never come,
    /// `progressSheetFallback` later the sheet is taken as gone. Nothing while the sheet isn't up, an
    /// operation is shown again, or the fallback already waits (every folder level reports it).
    func progressDidEnd() {
        guard isProgressSheetShown, activeProgress == nil, progressSheetFallbackTask == nil else { return }
        let delay = progressSheetFallback
        progressSheetFallbackTask = Task { [weak self, sleep = progressSheetSleep] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.progressSheetFallbackTask = nil
            guard self.isProgressSheetShown, self.activeProgress == nil else { return }
            Self.sheetLogger.info("progress sheet: its dismissal wasn't reported; taken as gone")
            self.progressSheetDidDismiss()
        }
    }

    /// The fallback stops: the sheet's going was reported, another operation's sheet is asked for or
    /// came up, or the document's content goes (the document view controller's `removeContent`).
    func cancelProgressSheetFallback() {
        progressSheetFallbackTask?.cancel()
        progressSheetFallbackTask = nil
    }

    /// A save has started: it replaces the archive and the reader whose temporary files a
    /// preview shows, so the preview and the share sheet go and don't come back afterwards.
    /// Its progress sheet is asked for: the last one's going is no longer waited for.
    private func saveDidStart() {
        cancelProgressSheetFallback()
        saveStarts += 1
        // A written copy is a file of its own; it still goes to the file mover.
        if case .move = pendingPresentation {} else { pendingPresentation = nil }
        previewURL = nil
        shareRequest = nil
    }

    /// The document's model was replaced (read again after a change elsewhere, say) or went: the
    /// preview shows its reader's temporary files and swipes through its items, so it goes, and one
    /// waiting for the progress sheet doesn't come.
    private func modelDidChange() {
        if case .preview = pendingPresentation { pendingPresentation = nil }
        previewURL = nil
    }

    /// A folder level has left the screen (`FolderScreen`): share sheets anchored there go.
    func levelDidDisappear(_ path: String) {
        dropShares { $0.folder == path }
    }

    /// Share sheets (shown or waiting) whose row is no longer in the archive go.
    func dropSharesOfRemovedRows() {
        guard let model else { return }
        dropShares { anchor in
            if case .row(let path) = anchor { model.item(at: path) == nil } else { false }
        }
    }

    private func dropShares(where isStale: (ShareAnchor) -> Bool) {
        if let request = shareRequest, isStale(request.anchor) { shareRequest = nil }
        if case .share(let request) = pendingPresentation, isStale(request.anchor) { pendingPresentation = nil }
    }

    /// Shows `error` in an alert, except a cancellation: the user asked for that.
    func report(_ error: any Error, title: String) {
        if error is CancellationError || error as? ArchiveError == .cancelled { return }
        alert = AlertContent(title: title, message: error.localizedDescription)
    }

    // MARK: - Saving

    /// Save (the bar button and ⌘S) has something to write and isn't writing already. Never during
    /// Text Encoding's reopen: it starts only without changes, and edits are off until it ends.
    var canSaveNow: Bool { hasChanges && !isSaving }

    /// The Save button: writes pending edits in place, or first asks about the archive's Mac metadata.
    func save() async {
        guard !isSaving else { return }
        await saveOrAskAboutMacMetadata()
    }

    // MARK: - Save As Copy

    /// Save As Copy is offered on every level, read-only formats included (it is how a RAR
    /// becomes a ZIP), except while a save is writing the archive or Text Encoding reads it again, and
    /// while Extract's conflict questions are open (`allowsPresenting`).
    var canSaveAsCopy: Bool { model != nil && !isBusy && allowsPresenting }

    /// Save As Copy in the More menu: the options sheet, starting from the archive's own format,
    /// encryption, method and password (a read-only format starts as the first writable one), and
    /// "Exclude Mac metadata" from the file's answer, if any (`DocumentSession.saveAsCopySettings(for:)`).
    func beginSaveAsCopy() {
        guard canSaveAsCopy, let model else { return }
        saveAsCopyRequest = SaveAsCopyRequest(settings: session.saveAsCopySettings(for: model))
    }

    /// Cancel on the options sheet.
    func cancelSaveAsCopy() {
        confirmedCopy = nil
        saveAsCopyRequest = nil
    }

    /// Save on the options sheet: the sheet goes, then `saveOptionsSheetDidDismiss` writes the copy.
    /// The settings are this copy's only: the model's saved options stay nil, and in-place saves
    /// use `ArchiveSaveSettings.writeOptions(for:)`.
    func confirmSaveAsCopy(_ settings: ArchiveSaveSettings) {
        guard SaveOptionsSheet.canConfirm(settings) else { return }
        confirmedCopy = settings
        saveAsCopyRequest = nil
    }

    /// The options sheet has gone (`FolderScreen`): a confirmed copy is written under the progress
    /// sheet, then handed to the file mover once that sheet has gone too. A failure shows the
    /// error and leaves the document as it was.
    func saveOptionsSheetDidDismiss() async {
        guard let settings = confirmedCopy else { return }
        confirmedCopy = nil
        do {
            present(.move(try await saveAsCopy(settings)))
        } catch {
            report(error, title: String(localized: "Couldn't save a copy of “\(name)”"))
        }
    }

    /// Writes the archive as it looks now, pending edits included, to a temporary
    /// "<name> copy.<ext>" with `settings`, under the progress sheet, and returns the file.
    /// The temporary folder goes on failure, after the file mover, or when the document closes.
    func saveAsCopy(_ settings: ArchiveSaveSettings) async throws -> URL {
        guard model != nil else { throw CocoaError(.fileWriteUnknown) }
        let folder = try document.scratch.makeFolder()
        let url = folder.appendingPathComponent(copyName(for: settings.format))
        do {
            try await perform(String(localized: "Saving “\(url.lastPathComponent)”…")) { [document] progress in
                try await document.writeCopy(to: url, settings: settings, progress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return url
    }

    /// "<name> copy.<ext>": the document's file name, its archive extension replaced by `format`'s.
    /// A split archive's copy is named after the set: "s7 copy.7z" for s7.7z.001.
    func copyName(for format: ArchiveFormat) -> String {
        let isVolumeSet = (model?.reader?.volumeURLs.count ?? 0) > 1
        let fileName = ArchiveSaveSettings.fileName(document.fileURL.lastPathComponent, for: format,
                                                    isVolumeSet: isVolumeSet)
        let base = String(fileName.dropLast(format.fileExtension.count + 1))
        return String(localized: "\(base) copy",
                                 comment: "Default file name of a copy made with Save As Copy, without the extension (the app appends it). %@ = the original archive's name without its extension. Must stay a valid file name: no slashes or colons.") + "." + format.fileExtension
    }

    /// The file mover has finished (moved, cancelled or failed): the temporary copy goes. A failure
    /// other than a cancellation is shown.
    func copyMoveDidFinish(error: (any Error)? = nil) {
        guard let url = movingCopy else { return }
        movingCopy = nil
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        if let error, (error as? CocoaError)?.code != .userCancelled {
            report(error, title: String(localized: "Couldn't save a copy of “\(name)”"))
        }
    }

    /// The operation `ProgressSheet` shows: a save, or another task's `progress`.
    var activeProgress: OperationProgress? {
        if let fraction = session.saveFraction {
            return OperationProgress(title: String(localized: "Saving “\(name)”…"), fraction: fraction)
        }
        return progress
    }

    // MARK: - Info

    /// The Info sheet is up: the bar's Info, File > Get Info (⌘I).
    private(set) var isShowingInfo = false

    /// Info can open: the archive is listed, no save writes it nor Text Encoding reads it again (`isBusy`), Extract's
    /// conflict questions aren't open (`allowsPresenting`), and no operation runs whose progress sheet would come
    /// up over the sheet (`runningOperations`), as for Save As Copy and Text Encoding, nor has Extract Here asked for
    /// its Files picker or question (`extractHereRequest`), which the sheet would otherwise take the place of.
    var canShowInfo: Bool {
        model != nil && !isBusy && allowsPresenting && runningOperations == 0 && extractHereRequest == nil
    }

    func showInfo() {
        guard canShowInfo else { return }
        isShowingInfo = true
    }

    /// Done, or the sheet swiped down: the comment's typing ends as one undo step ("Edit Comment"), which the
    /// bar's Undo then takes back whole. The field ends editing first: a word still being composed is committed
    /// then and joins that step, rather than opening a second one after it.
    func closeInfo() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isShowingInfo = false
        model?.endCommentTyping()
    }

    /// The comment can be changed in this document: a comment the model can write (`ArchiveModel.canEditComment`:
    /// a single-file ZIP) in an archive this document edits (`canEdit`: not an APK).
    private var isCommentWritable: Bool { canEdit && model?.canEditComment == true }

    /// The Info sheet has a Comment section: the archive has a comment, or can get one.
    var showsComment: Bool {
        guard let model, model.showsComment else { return false }
        return model.reader?.comment != nil || isCommentWritable
    }

    /// The comment field takes typing now: a writable comment while edits are allowed (`allowsEditing`). Read-only
    /// while a save writes the archive: the save adopts the saved archive when it ends, which would drop text typed
    /// meanwhile; the same while Text Encoding reads it again.
    var canEditCommentNow: Bool { allowsEditing && isCommentWritable }

    /// The comment field's text changed: an undo step "Edit Comment" that further typing joins until `closeInfo`
    /// (`ArchiveModel.setComment`). Ignored unless `canEditCommentNow`. The save snapshot follows each keystroke:
    /// a joined one registers no undo, so nothing else would take it in (`ArchiveDocument.refreshSaveSnapshot`).
    func setComment(_ text: String) {
        guard canEditCommentNow, let model else { return }
        model.setComment(text)
        document.refreshSaveSnapshot()
    }

    /// One line under a comment shown read-only, saying why it can't be changed; nil when it can be (or isn't shown).
    /// None for the moment a save makes it read-only.
    var commentReadOnlyNote: String? {
        guard showsComment, !isCommentWritable else { return nil }
        if (model?.reader?.volumeURLs.count ?? 1) > 1 {
            return String(localized: "The comment of a split archive can’t be changed.",
                          comment: "Info sheet, under the read-only comment of a split (multi-part) ZIP archive.")
        }
        return String(localized: "This comment can’t be changed in Lutik.",
                      comment: "Info sheet, under a read-only archive comment that Lutik can't write back (for example in an APK, which Lutik only views).")
    }

    // MARK: - Text Encoding

    /// The More menu's Text Encoding reopen running now, if any.
    private(set) var nameEncodingTask: Task<Void, Never>?
    /// Set by the document view controller: closes the folder levels the archive no longer lists,
    /// after Text Encoding has read it again, and after undo and redo.
    @ObservationIgnored var closeUnlistedFolders: (@MainActor () -> Void)?
    /// `closeUnlistedFolders` waits for the progress sheet to go (`closeUnlistedFoldersWhenSheetGone`).
    @ObservationIgnored private var pendingFolderClose = false

    /// The encoding the names are read with, as requested (Automatic included): Text Encoding's
    /// selected item.
    var nameEncoding: ArchiveNameEncoding { model?.reader?.nameEncoding ?? .automatic }

    /// Text Encoding can be used: the archive has names stored without a declared encoding (nothing
    /// to reinterpret otherwise), no unsaved changes, and nothing else is running,
    /// including a preview or share whose progress sheet hasn't come up yet (`runningOperations`): the
    /// reopen would rename the item it prepares. Nor while Extract's conflict
    /// questions are open (`pendingExtraction`): their answers are keyed by the old names. Nor under the
    /// name alert (`renameRequest`): it names an item of the listing the reopen replaces.
    var canChooseNameEncoding: Bool {
        model?.reader?.legacyNameEncoding != nil && !hasChanges && activeProgress == nil
            && nameEncodingTask == nil && runningOperations == 0 && pendingExtraction == nil
            && renameRequest == nil
    }

    /// Text Encoding: lists the archive again with `encoding` under the progress sheet, and remembers
    /// the choice for the file (Automatic forgets it). Choosing the current one does nothing. Editing
    /// and saving are off until it ends: adopting the new listing would drop an edit made meanwhile.
    /// The selection clears (its paths may name nothing now); a failure keeps the listing and says so.
    func chooseNameEncoding(_ encoding: ArchiveNameEncoding) {
        guard canChooseNameEncoding, encoding != nameEncoding else { return }
        let title = String(localized: "Reading “\(name)”…", table: "Shared",
                           comment: "Progress title while the archive is listed again after another text encoding was chosen (Text Encoding menu). %@ = the archive's file name. The ellipsis shows work in progress.")
        nameEncodingTask = Task {
            defer { nameEncodingTask = nil }
            do {
                try await perform(title) { [document] _ in try await document.reopen(nameEncoding: encoding) }
            } catch {
                return report(error, title: String(localized: "Couldn't open “\(name)”"))
            }
            selection = []
            closeUnlistedFoldersWhenSheetGone()
        }
    }

    /// Closes the folder levels the archive no longer lists (`closeUnlistedFolders`). The level on screen
    /// may present the progress sheet: it can't go while the sheet is still going away, so it goes
    /// once the sheet has (`progressSheetDidDismiss`).
    private func closeUnlistedFoldersWhenSheetGone() {
        if isProgressSheetShown { pendingFolderClose = true } else { closeUnlistedFolders?() }
    }

    /// The document is closing: a reopen still running stops, adopting and remembering nothing.
    func cancelNameEncoding() {
        nameEncodingTask?.cancel()
    }

    // MARK: - Password and alerts

    /// The archive needs a password before it can be shown.
    var isLocked: Bool {
        if case .locked = session.phase { true } else { false }
    }

    /// The part a multi-volume set is missing or can't read; the view offers to grant the folder.
    var volumeError: ArchiveVolumeError? {
        if case .volume(let error) = session.phase { error } else { nil }
    }

    /// A folder grant is retrying the open; the view disables Choose Folder… meanwhile.
    var isGrantingFolder: Bool { session.isGrantingFolder }

    /// The user picked the folder holding the set's other parts. Another folder can't help: the
    /// alert asks for the right one. The right one that still can't open the set says so too.
    func grantFolder(_ folder: URL) async {
        switch await document.grantFolder(folder) {
        case .wrongFolder(let error):
            alert = AlertContent(title: error.wrongFolderTitle, message: error.wrongFolderMessage)
        case .stillUnreadable(let error):
            alert = AlertContent(title: error.stillUnreadableTitle, message: error.stillUnreadableMessage)
        case nil:
            break
        }
    }

    /// Why the last password was rejected.
    var passwordError: String? {
        if case .locked(let error) = session.phase { error } else { nil }
    }

    /// `remember` saves the password in the Keychain once it opens the archive.
    func unlock(password: String, remember: Bool) async {
        await document.unlock(password: password, remember: remember)
        if case .locked(let error?) = session.phase, !error.isEmpty {
            wrongPasswordCount += 1
        } else {
            wrongPasswordCount = 0
        }
    }

    /// Cancel on the password prompt: closes the document; the next open counts from zero.
    func cancelUnlock() {
        wrongPasswordCount = 0
        closeDocument?()
    }

    /// Passwords the user typed in a row that were rejected. The Keychain retry while opening
    /// doesn't go through `unlock`, so it never counts; a new open makes a new `ScreenState`.
    private(set) var wrongPasswordCount = 0

    /// Shown under the error from the second wrong password in a row on a 7z: 7z
    /// keeps no password check, so damage in the first encrypted entry looks like a wrong
    /// password. ZIP checks the password, so a wrong one there is just wrong. Only with the
    /// error line: a re-read while locked clears the error, and the hint goes with it.
    var passwordHint: String? {
        guard wrongPasswordCount >= 2, passwordError != nil, isSevenZipDocument else { return nil }
        return String(localized: "If the password is right, the archive may be damaged.")
    }

    /// Goes by the document type: a 7z with encrypted headers has no reader (and no model) until
    /// it is unlocked. Falls back to the extension when UIKit gave no type.
    private var isSevenZipDocument: Bool {
        // A part of a split 7z ("s7e.7z.001") is typed as a part: the set's format is in its name.
        if document.fileURL.pathExtension.wholeMatch(of: #/\d{3}/#) != nil {
            return document.fileURL.deletingPathExtension().pathExtension.lowercased() == "7z"
        }
        if let type = document.fileType.flatMap(UTType.init) {
            return type.conforms(to: UTType(importedAs: "org.7-zip.7-zip-archive"))
        }
        return document.fileURL.pathExtension.lowercased() == "7z"
    }

    /// The conflict question's alert can be up: a question is asked, and neither another alert nor the
    /// progress sheet is in the way, from when it is asked for (`activeProgress`) until it has finished
    /// going away (`isProgressSheetShown`). Published while that sheet still goes away, the alert would
    /// be dropped and, its condition staying true, never retried; the question would stay asked and
    /// editing off. Once the sheet has gone the condition turns true, and the alert
    /// comes up. `FolderScreen` adds the level being on screen.
    var canShowExtractionQuestion: Bool {
        extractionQuestion != nil && presentedAlert == nil && isProgressSheetGone
    }

    /// `presentedAlert` can be up: as for the conflict question, not while the progress sheet is asked
    /// for or still going away. Published then, the alert would be dropped, and still set it would hold
    /// back the conflict question until the document closes.
    var canShowAlert: Bool { presentedAlert != nil && isProgressSheetGone }

    /// The Replace question on Add (`pendingReplacement`) can be up: after `presentedAlert`, and not while
    /// the progress sheet is asked for or still going away (`canShowAlert`).
    var canShowReplacement: Bool { pendingReplacement != nil && presentedAlert == nil && isProgressSheetGone }

    /// The name alert (`renameRequest`) can be up: after `presentedAlert` and the Replace question, and not
    /// while the progress sheet is asked for or still going away (`canShowAlert`).
    var canShowRename: Bool {
        renameRequest != nil && presentedAlert == nil && pendingReplacement == nil && !macMetadataQuestion
            && isProgressSheetGone
    }

    /// Extract Here's question (`extractHereAlert`) can be up: as for the conflict question, not while
    /// another alert, the Mac metadata question or the progress sheet is in the way. A read-only failure
    /// asks it while its sheet still goes away; published then, the alert would be dropped and, its
    /// condition staying true, never retried.
    var canShowExtractHereAlert: Bool {
        extractHereAlert != nil && presentedAlert == nil && !macMetadataQuestion && isProgressSheetGone
    }

    /// No progress sheet is asked for (`activeProgress`) or still going away (`isProgressSheetShown`).
    private var isProgressSheetGone: Bool { activeProgress == nil && !isProgressSheetShown }

    /// The alert to show: an archive that can't be opened, a failed save, or `alert`.
    var presentedAlert: AlertContent? {
        if case .failed(let message) = session.phase {
            return AlertContent(title: String(localized: "Couldn't open “\(name)”"), message: message)
        }
        if let message = session.saveError {
            return AlertContent(title: String(localized: "Couldn't save “\(name)”"), message: message)
        }
        return alert
    }

    /// OK on `presentedAlert`. An archive that can't be opened closes.
    func dismissAlert() {
        if case .failed = session.phase {
            closeDocument?()
        } else if session.saveError != nil {
            session.saveError = nil
        } else {
            alert = nil
        }
    }

    // MARK: - Text

    /// "12 items · 4.2 MB" for the archive ("") or a folder's subtree. When a file's size is
    /// unknown (a single-stream .gz, .bz2, .xz or .zst) the size is left out: "1 item", never "0 KB".
    /// `compact` (compact width, iPhone) drops "uncompressed" so the subtitle fits: "14 items · 415 KB".
    func subtitle(for path: String, compact: Bool = false) -> String {
        guard let model else { return "" }
        // `model.totalSize` and a folder's `size` are the engine's totals; nil when any file below is unknown.
        if path.isEmpty {
            return KernirFormat.summary(itemCount: model.itemCount, size: model.totalSize,
                                        compressedSize: nil, format: nil, compact: compact)
        }
        let folder = model.item(at: path)
        return KernirFormat.summary(itemCount: folder?.children?.flattened().count ?? 0, size: folder?.size,
                                    compressedSize: nil, format: nil, compact: compact)
    }

    /// A folder's child count ("2 objects") or a file's size; "--" when the size is unknown, as in
    /// the Mac's Size column (and Finder).
    func rowDetail(for item: ArchiveItem) -> String {
        if item.isDirectory {
            return String(localized: "\(item.children?.count ?? 0) objects")
        }
        return item.size.map(KernirFormat.size) ?? "--"
    }

    /// What VoiceOver reads for `rowDetail`: words, not "--".
    func rowSpokenDetail(for item: ArchiveItem) -> String {
        if !item.isDirectory, item.size == nil { return String(localized: "Unknown size") }
        return rowDetail(for: item)
    }
}

extension PhotosPickerItem: PickedItem {
    func loadFile() async throws -> PickedMedia? {
        try await loadTransferable(type: PickedMedia.self)
    }

    func loadData() async throws -> Data? {
        try await loadTransferable(type: Data.self)
    }
}

/// Notification observers removed when their owner goes away.
private final class ObserverBag: @unchecked Sendable {
    var tokens: [any NSObjectProtocol] = []

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
