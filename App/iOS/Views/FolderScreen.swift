import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// One folder level of an open archive. The root level shares the document view controller's
/// navigation item, so it sets no title: the document title shows the archive's name.
struct FolderScreen: View {
    @Bindable var state: ScreenState
    let path: String
    let isRoot: Bool

    /// Only the level on screen presents sheets and alerts; the levels under it in the
    /// navigation stack can't.
    @State private var isVisible = false
    /// The Files picker is up, for `importPurpose`. One picker serves both purposes: a second
    /// `.fileImporter` on the same view would not come up.
    @State private var isImporting = false
    @State private var importPurpose = ImportPurpose.add
    /// The Photos picker is up. It is presented from here, not from a `PhotosPicker` inside the Add
    /// menu: the menu dismisses itself on tap and takes that picker with it (nothing came up on iPad).
    @State private var isPickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// More > Text Encoding…'s sheet is up.
    @State private var isChoosingNameEncoding = false
    /// Compact width (iPhone) gets the short subtitle: "14 items · 415 KB", without "uncompressed".
    /// Follows horizontal size class: iPad Slide Over and narrow Split View
    /// get the short form too, and a large iPhone in landscape (regular) gets the long one.
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// More > Sort By, the same on every level.
    @AppStorage(FolderSortOrder.defaultsKey) private var sortOrder = FolderSortOrder.default
    /// The level's sorted rows, kept between body rebuilds that don't change them.
    @State private var sortedRows = SortedLevelCache()
    /// The rows' bottom edges on screen, for the drop layer below them.
    @State private var rowBottoms = ArchiveRowBottoms()

    init(state: ScreenState, path: String, isRoot: Bool) {
        self.state = state
        self.path = path
        self.isRoot = isRoot
    }

    var body: some View {
        contentWithInfo
            // Apart from `.fileImporter`: like two importers (see `isImporting`), two file pickers on one
            // view may not both come up. The Photos picker is apart too, in `contentWithInfo`.
            .fileMover(isPresented: movingCopy, file: state.movingCopy) { result in
                if case .failure(let error) = result {
                    state.copyMoveDidFinish(error: error)
                } else {
                    state.copyMoveDidFinish()
                }
            } onCancellation: {
                state.copyMoveDidFinish()
            }
            .modifier(Titles(title: isRoot ? nil : folderName, subtitle: state.subtitle(for: path, compact: sizeClass == .compact)))
            .modifier(Search(text: $state.searchText, isPresented: searchPresented, isEnabled: state.model != nil))
            .toolbar {
                if state.model != nil { toolbar }
            }
            .environment(\.editMode, .constant(state.isSelecting ? .active : .inactive))
            .onAppear {
                isVisible = true
                // A level coming on screen with Extract Here waiting on a picker that isn't up.
                closeExtractHerePickerLater()
            }
            .onDisappear {
                isVisible = false
                // Its sheet went with the level, without the binding's setter: it must not come
                // back up when the level is on screen again.
                isChoosingNameEncoding = false
                state.levelDidDisappear(path)
            }
            .sheet(isPresented: presented(state.isLocked)) {
                PasswordSheet(name: state.name, error: state.passwordError, hint: state.passwordHint,
                              unlock: { await state.unlock(password: $0, remember: $1) },
                              cancel: { state.cancelUnlock() })
            }
            // A preview or share sheet finished meanwhile waits for this sheet to go, and so do the
            // alerts (`ScreenState.canShowAlert`, `canShowReplacement`) and the conflict question
            // (`ScreenState.canShowExtractionQuestion`).
            .sheet(isPresented: presented(state.activeProgress != nil),
                   onDismiss: { state.progressSheetDidDismiss() }) {
                if let progress = state.activeProgress {
                    ProgressSheet(progress: progress)
                        .onAppear { state.progressSheetDidAppear() }
                }
            }
            // Its operation has ended: should the sheet's `onDismiss` be lost, its fallback takes the
            // sheet as gone (`ScreenState.progressSheetFallback`).
            .onChange(of: state.activeProgress == nil) { _, ended in
                if ended { state.progressDidEnd() }
            }
            // Text Encoding's choices; the archive is read again once the sheet has gone.
            .modifier(TextEncodingSheetPresenter(state: state, isPresented: choosingNameEncoding))
            // Save As Copy's options. Once the sheet has gone, a confirmed copy is written.
            .sheet(item: saveAsCopyRequest, onDismiss: {
                Task { await state.saveOptionsSheetDidDismiss() }
            }) { request in
                SaveOptionsSheet(purpose: .saveAsCopy, settings: request.settings,
                                 onCancel: { state.cancelSaveAsCopy() },
                                 onConfirm: { state.confirmSaveAsCopy($0) })
            }
            // Alerts wait for the progress sheet to go, until it has finished going away: one can't come
            // up over it, nor while it goes.
            .alert(state.presentedAlert?.title ?? "",
                   isPresented: presented(state.canShowAlert),
                   presenting: state.presentedAlert) { _ in
                Button("OK") { state.dismissAlert() }
            } message: { alert in
                Text(alert.message)
            }
            .alert(state.pendingReplacement?.title ?? "",
                   isPresented: presented(state.canShowReplacement),
                   presenting: state.pendingReplacement) { _ in
                Button("Replace", role: .destructive) { state.confirmReplacement() }
                Button("Cancel", role: .cancel) { state.cancelReplacement() }
            }
            // Rename, and New Folder's name: Cancel keeps the name (and a new folder, as Files does).
            .modifier(RenameAlert(state: state, isPresented: presented(state.canShowRename)))
            // Save in an archive with Mac metadata asks once whether to keep it (`MacMetadataSaveQuestion`).
            .modifier(MacMetadataQuestionAlert(state: state, isPresented: presented(
                state.macMetadataQuestion && state.presentedAlert == nil && state.activeProgress == nil)))
            // Extract into a folder that already has these names: one question per item, as Finder asks.
            // Each question is an alert of its own: an answer takes it away, and the next one comes
            // only once the alert's condition has gone false, here, and UIKit has had a moment to take
            // it down (`ScreenState.extractionAlertSettle`). Not from the binding's setter: UIKit calls
            // it while still dismissing, or not at all.
            .modifier(ExtractionConflictAlert(state: state, isPresented: Binding(
                get: { showsExtractionQuestion }, set: { _ in })))
            .onChange(of: showsExtractionQuestion) { _, shows in
                if !shows { state.extractionAlertDidGo() }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: importPurpose.contentTypes,
                          allowsMultipleSelection: importPurpose == .add) { result in
                imported(result, for: importPurpose)
            } onCancellation: {
                if importPurpose == .extractHere { Task { await state.extractHereFolderPicked(nil) } }
            }
            // Choose Folder… starts in the folder that holds the parts; Extract Here's picker for
            // the archive's folder starts there.
            .fileDialogDefaultDirectory(defaultDirectory)
            // Extract Here asks for a folder (`ScreenState.extractHereRequest`): the archive's, or
            // any after a read-only error. Its menu items and ⌥⌘E get here, and the alerts' OK and
            // Choose Another Folder… once the alert has gone.
            .modifier(ExtractHereFlow(state: state, isVisible: isVisible, isImporting: isImporting,
                                      presentPicker: presentExtractHerePicker,
                                      pickerDidClose: closeExtractHerePickerLater))
            // `ScreenState.present` holds the preview back until the progress sheet has gone.
            // It swipes through this level's files as listed, each extracted only when shown.
            .background(FilePreview(url: state.previewFolder == path ? state.previewURL : nil,
                                    makeQueue: { state.previewQueue(listing: items) },
                                    dismiss: { state.previewURL = nil }))
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                pickedPhotos = []
                Task { await state.addPhotos(items, to: path) }
            }
    }

    private func imported(_ result: Result<[URL], any Error>, for purpose: ImportPurpose) {
        switch (result, purpose) {
        case (.success(let urls), .add):
            state.add(urls, to: path)
        case (.success(let urls), .extract(let paths)):
            guard let folder = urls.first else { return }
            Task { await state.extract(paths, to: folder) }
        case (.success(let urls), .grantFolder):
            guard let folder = urls.first else { return }
            Task { await state.grantFolder(folder) }
        case (.success(let urls), .extractHere):
            Task { await state.extractHereFolderPicked(urls.first) }
        case (.failure(let error), .add):
            state.alert = AlertContent(title: String(localized: "Couldn't add files"),
                                       message: error.localizedDescription)
        case (.failure(let error), .extract):
            state.alert = AlertContent(title: String(localized: "Couldn't extract"),
                                       message: error.localizedDescription)
        case (.failure(let error), .grantFolder):
            state.alert = AlertContent(title: String(localized: "Couldn't open the folder"),
                                       message: error.localizedDescription)
        case (.failure(let error), .extractHere):
            state.cancelExtractHere()
            state.alert = AlertContent(title: String(localized: "Couldn't extract"),
                                       message: error.localizedDescription)
        }
    }

    /// Where the Files picker opens: the parts' folder for Choose Folder…, the archive's folder for
    /// Extract Here's first pick, else where the system likes.
    private var defaultDirectory: URL? {
        switch importPurpose {
        case .grantFolder: state.volumeError?.folder
        case .extractHere: state.extractHereRequest?.step == .grant ? state.extractHereRequest?.folder : nil
        case .add, .extract: nil
        }
    }

    /// Brings up the Files picker Extract Here's request waits on (`.grant`, `.otherFolder`), on
    /// the level on screen, unless the picker is already up.
    private func presentExtractHerePicker() {
        guard isVisible, !isImporting, state.extractHereRequest?.waitsOnPicker == true else { return }
        #if DEBUG
        // UI tests: the folder from `-KernirExtractHereGrant`, as if picked in Files, once per launch.
        if state.extractHereRequest?.step == .grant, let folder = ExtractHereTestHooks.takeGrant() {
            Task { await state.extractHereFolderPicked(folder) }
            return
        }
        #endif
        importPurpose = .extractHere
        isImporting = true
    }

    /// The safety net for a picker that never came up, or went without calling back: a turn
    /// later, so the picker's own callbacks (which hand the pick or the cancel over in a task of
    /// their own) are handled first, and only if no picker is up by then, Extract Here's request
    /// is cancelled if it still waits on one (`ScreenState.extractHerePickerDidClose`).
    /// Cancelling, not bringing the picker up again: that can't tell a picker that failed from one
    /// whose answer is still on its way, so it could come back after Cancel, or again and again.
    private func closeExtractHerePickerLater() {
        Task {
            guard !isImporting else { return }
            state.extractHerePickerDidClose()
        }
    }

    /// Asks for a destination folder, then extracts `paths` (nil: everything) into it. Nothing while
    /// Extract's conflict questions are open or another operation runs (`ScreenState.canExtract`).
    private func chooseExtractionFolder(for paths: [String]?) {
        guard state.canExtract else { return }
        #if DEBUG
        // UI tests: the folder from `-KernirExtractDestination`, as if picked in Files.
        if let folder = SceneDelegate.extractDestination {
            return imported(.success([folder]), for: .extract(paths))
        }
        #endif
        importPurpose = .extract(paths)
        isImporting = true
    }

    /// Asks for the folder that holds the other parts of a split archive.
    private func chooseGrantFolder() {
        importPurpose = .grantFolder
        isImporting = true
    }

    private func share(_ paths: [String], from anchor: ShareAnchor) {
        Task { await state.share(paths, from: anchor) }
    }

    private var folderName: String {
        state.model?.item(at: path)?.name ?? (path as NSString).lastPathComponent
    }

    private var items: [ArchiveItem] {
        guard let model = state.model else { return [] }
        return sortedRows.rows(of: model, path: path, searchText: state.searchText, order: sortOrder)
    }

    @ViewBuilder private var content: some View {
        if state.model != nil {
            let items = items
            List(selection: $state.selection) {
                // No `onInsert`: it gives the list's UICollectionView a drop delegate of its own, which
                // took every drop over the list and didn't add a drop from Files on the iPad. Rows
                // (`row(for:)`) and the list's own area (`.archiveDropTarget` below) take them instead.
                ForEach(items) { item in
                    row(for: item)
                }
            }
            .overlay {
                if items.isEmpty {
                    if state.searchText.isEmpty {
                        ContentUnavailableView("No Items", systemImage: "doc.zipper",
                                               description: state.canEdit
                                                   ? Text("Tap ＋ or drop files here to add them.") : nil)
                    } else {
                        ContentUnavailableView.search(text: state.searchText)
                    }
                }
            }
            // An empty level: a full-size, hit-testable layer above the list and its empty state takes
            // its drops, through the same gates (`acceptDrop`); the first drop into a new archive went in
            // through it on the iPad. Only while empty, so rows keep their own targets (every row takes
            // drops: `ScreenState.dropDirectory(forRow:in:)`). A long press on it shows ＋'s Paste.
            .overlay {
                if items.isEmpty {
                    Color.clear
                        .contentShape(Rectangle())
                        .archiveEmptySpaceMenu(state, folder: path)
                        .archiveDropTarget(state, directory: path)
                }
            }
            // A level that lists rows: a layer over the space below the lowest row takes its drops,
            // into this level; the list itself refuses them there on the iPad (`ArchiveRowBottoms`).
            .overlay {
                if !items.isEmpty {
                    ArchiveDropLayerBelowRows(state: state, directory: path, rowBottoms: rowBottoms)
                }
            }
            // The whole level, into the folder on screen, around the rows' own targets. UIKit hands
            // each drop to one target only (the innermost that takes it), so a drop never adds twice.
            // The space below the rows and an empty level drop through the layers above instead.
            .archiveDropTarget(state, directory: path)
        } else if let volumeError = state.volumeError {
            ContentUnavailableView {
                Label(volumeError.errorDescription ?? "", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text(volumeError.recoverySuggestion ?? "")
            } actions: {
                if volumeError.offersGrantAccess {
                    Button("Choose Folder…") { chooseGrantFolder() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isGrantingFolder)
                }
                // Reopening reads every part, and may download them first: show it's working.
                if state.isGrantingFolder {
                    ProgressView()
                }
            }
        } else if case .loading = state.session.phase {
            ProgressView()
        } else {
            Color.clear
        }
    }

    private func row(for item: ArchiveItem) -> some View {
        rowContent(for: item)
            .swipeActions {
                if state.canEdit {
                    deleteButton(for: item)
                }
            }
            .contextMenu {
                // Off while Extract's conflict questions are open: each brings up a sheet. Extract also
                // while another operation runs (`ScreenState.canExtract`).
                Group {
                    if !item.isDirectory {
                        Button("Preview", systemImage: "eye") {
                            Task { await state.preview(item.path) }
                        }
                    }
                    Button("Extract Here", systemImage: "arrow.down.doc") {
                        Task { await state.extractHere([item.path]) }
                    }
                    .disabled(!state.canExtractHere([item.path]))
                    Button("Extract To…", systemImage: "folder") {
                        chooseExtractionFolder(for: [item.path])
                    }
                    .disabled(!state.canExtract)
                    Button("Share", systemImage: "square.and.arrow.up") {
                        share([item.path], from: .row(item.path))
                    }
                    // Extracts the item under the progress sheet: read-only archives too.
                    Button("Copy", systemImage: "doc.on.doc") {
                        Task { await state.copy([item.path]) }
                    }
                    .disabled(!state.canCopy([item.path]))
                }
                .disabled(!state.allowsPresenting)
                if state.canEdit {
                    Divider()
                    Button("Rename", systemImage: "pencil") {
                        state.beginRename(item.path)
                    }
                    .disabled(!state.allowsEditing)
                    Button("Move…", systemImage: "folder") {
                        state.beginMove([item.path])
                    }
                    .disabled(!state.canAdd)
                    Button("Cut", systemImage: "scissors") {
                        state.cut([item.path])
                    }
                    .disabled(!state.canCut([item.path]))
                    deleteButton(for: item)
                }
            }
            // A long press without moving still opens the context menu; moving drags.
            .archiveDragSource(state, path: item.path)
            // Every row takes drops, as the empty level's layer does: a folder row into the folder
            // (and shows it), a file row into this level; around them, the list's own area.
            .archiveDropTarget(state, directory: state.dropDirectory(forRow: item, in: path),
                               highlightsRow: item.isDirectory)
            .archiveRowBottom(item.id, in: rowBottoms)
            .popover(isPresented: sharePresented(from: .row(item.path))) {
                shareSheet
            }
    }

    /// A folder opens; a file opens in the preview. In Select mode a tap selects instead.
    private func rowContent(for item: ArchiveItem) -> some View {
        Button {
            guard !state.isSelecting else { return }
            if item.isDirectory {
                state.openFolder?(item.path)
            } else {
                Task { await state.preview(item.path) }
            }
        } label: {
            EntryRow(item: item, detail: state.rowDetail(for: item),
                     spokenDetail: state.rowSpokenDetail(for: item))
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier(item.path)
    }

    /// The share sheet for `state.shareRequest`.
    @ViewBuilder private var shareSheet: some View {
        if let request = state.shareRequest {
            ShareSheet(activityItems: request.urls) { [state] in
                state.shareRequest = nil
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Shown while the share request points at `anchor`. `ScreenState.present` holds the
    /// request back until the progress sheet has gone.
    private func sharePresented(from anchor: ShareAnchor) -> Binding<Bool> {
        Binding(get: { state.shareRequest?.anchor == anchor },
                set: { if !$0, state.shareRequest?.anchor == anchor { state.shareRequest = nil } })
    }

    private func deleteButton(for item: ArchiveItem) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            state.delete([item.path])
        }
        .disabled(!state.allowsEditing)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if state.canEdit {
            ToolbarItemGroup(placement: .bottomBar) {
                Menu("Add", systemImage: "plus") {
                    Button("Choose Files…", systemImage: "folder") {
                        importPurpose = .add
                        isImporting = true
                    }
                    Button("Photos…", systemImage: "photo.on.rectangle") {
                        isPickingPhotos = true
                    }
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        state.newFolder(in: path)
                    }
                    // Into the folder on screen; reading the pasteboard may bring the system's paste prompt.
                    // A long press on the list's empty space has it too (`ArchiveEmptySpaceMenu`).
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        state.startPaste(into: path)
                    }
                    .disabled(!state.canPaste)
                }
                .disabled(!state.canAdd)
                Button("Move…", systemImage: "folder") {
                    state.beginMove(state.moveTargets())
                }
                .disabled(!state.canMoveSelection)
                Button("Delete", systemImage: "trash", role: .destructive) {
                    state.delete(state.deleteTargets())
                }
                .disabled(!state.canDeleteSelection)
            }
        }
        if #available(iOS 26.0, *) {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
        }
        if state.isSelecting {
            ToolbarItem(placement: .bottomBar) {
                Button("Share", systemImage: "square.and.arrow.up") {
                    share(state.extractTargets() ?? [], from: .toolbar(path))
                }
                .disabled(state.selection.isEmpty || !state.allowsPresenting)
                .popover(isPresented: sharePresented(from: .toolbar(path))) {
                    shareSheet
                }
            }
        }
        ToolbarItem(placement: .bottomBar) {
            // The selection while selecting, else everything. A plain menu: no primary
            // action, no long press.
            Menu("Extract", systemImage: "arrow.down.doc") {
                Button("Extract Here", systemImage: "arrow.down.doc") {
                    Task { await state.extractHere(state.extractTargets()) }
                }
                .disabled(!state.canExtractHere)
                Button("Extract To…", systemImage: "folder") {
                    chooseExtractionFolder(for: state.extractTargets())
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled((state.isSelecting && state.selection.isEmpty) || !state.canExtract)
        }
        // Undo, Redo and Save are UIKit items pinned to the bar on every level (TrailingEditItems).
        ToolbarItem(placement: .secondaryAction) {
            Button(state.isSelecting ? "Done" : "Select",
                   systemImage: state.isSelecting ? "checkmark" : "checkmark.circle") {
                state.isSelecting.toggle()
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            FolderSortMenu(order: $sortOrder)
        }
        ToolbarItem(placement: .secondaryAction) {
            // Text, not an icon: on iPad secondary items show inline, and the copy icon was unclear.
            Button("Save a Copy…") {
                state.beginSaveAsCopy()
            }
            .disabled(!state.canSaveAsCopy)
        }
        ToolbarItem(placement: .secondaryAction) {
            TextEncodingButton(state: state, isPresented: $isChoosingNameEncoding)
        }
        ToolbarItem(placement: .secondaryAction) {
            Button("Info", systemImage: "info.circle") {
                state.showInfo()
            }
            .disabled(!state.canShowInfo)
        }
    }

    /// The conflict question's alert is up on this level: on screen, and nothing else in the way, the
    /// progress sheet included until it has finished going away (`ScreenState.canShowExtractionQuestion`).
    /// The one place that checks `isVisible` for it, so the alert's binding takes it as it is (not
    /// through `presented`) and the `onChange` sees the level leave the screen.
    private var showsExtractionQuestion: Bool {
        isVisible && state.canShowExtractionQuestion
    }

    /// Save As Copy's options sheet, on the level on screen. Dismissal comes from the sheet's buttons.
    private var saveAsCopyRequest: Binding<SaveAsCopyRequest?> {
        Binding(get: { isVisible ? state.saveAsCopyRequest : nil }, set: { _ in })
    }

    /// `content` with the Info sheet: the archive's rows and its comment, and the Photos picker (Add >
    /// Photos…; what it picks is added in `body`). Out of `body`'s chain, which is at the type
    /// checker's limit; the Photos picker also stays apart from `.fileImporter`, as `.fileMover` does:
    /// two pickers on one view may not both come up.
    private var contentWithInfo: some View {
        content
            .sheet(isPresented: showingInfo) {
                ArchiveInfoSheet(state: state)
            }
            // Move…'s folders. Move Here's move runs once the sheet has gone, so its Replace question can come up.
            .sheet(item: moveRequest, onDismiss: { state.moveSheetDidDismiss() }) { request in
                MoveSheet(state: state, request: request)
            }
            .photosPicker(isPresented: $isPickingPhotos, selection: $pickedPhotos,
                          matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
    }

    /// The Move sheet, on the level on screen. Swiping it down cancels.
    private var moveRequest: Binding<MoveRequest?> {
        Binding(get: { isVisible ? state.moveRequest : nil },
                set: { if $0 == nil, isVisible { state.cancelMove() } })
    }

    /// The Info sheet, on the level on screen. Swiping it down closes it as Done does.
    private var showingInfo: Binding<Bool> {
        Binding(get: { isVisible && state.isShowingInfo },
                set: { if !$0, isVisible { state.closeInfo() } })
    }

    /// Text Encoding's sheet, on the level on screen. Swiping it down or Cancel closes it.
    private var choosingNameEncoding: Binding<Bool> {
        Binding(get: { isVisible && isChoosingNameEncoding },
                set: { if !$0 { isChoosingNameEncoding = false } })
    }

    /// The file mover for the copy Save As Copy wrote, on the level on screen. It reports how it
    /// ended through its callbacks, so the setter does nothing.
    private var movingCopy: Binding<Bool> {
        presented(state.movingCopy != nil)
    }

    /// The search field's active state, for the level on screen only: Find (⌘F) activates the
    /// search of the level the user sees.
    private var searchPresented: Binding<Bool> {
        Binding(get: { isVisible && state.isSearchPresented },
                set: { if isVisible { state.isSearchPresented = $0 } })
    }

    /// A presentation binding for this level: shown while `condition` holds and the level is
    /// on screen. Dismissal comes from the state, so the setter does nothing.
    private func presented(_ condition: Bool) -> Binding<Bool> {
        Binding(get: { isVisible && condition }, set: { _ in })
    }
}

/// Rename's name alert, and New Folder's (`ScreenState.renameRequest`): a text field, Cancel and Save.
/// Save is off while the field is empty.
private struct RenameAlert: ViewModifier {
    let state: ScreenState
    let isPresented: Binding<Bool>
    /// The last request's kind: Save and Cancel clear the request before the alert has gone, and its
    /// title stays as it was meanwhile.
    @State private var wasNewFolder = false

    private var isNewFolder: Bool { state.renameRequest?.isNewFolder ?? wasNewFolder }

    func body(content: Content) -> some View {
        content.alert(isNewFolder ? String(localized: "New Folder") : String(localized: "Rename"),
                      isPresented: isPresented, presenting: state.renameRequest) { _ in
            TextField("Name", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { state.cancelRename() }
            Button("Save") { state.commitRename(text.wrappedValue) }
                .disabled(state.renameCheck(text.wrappedValue) == .invalid(.empty))
        }
        .onChange(of: state.renameRequest?.isNewFolder) { _, kind in
            if let kind { wasNewFolder = kind }
        }
    }

    private var text: Binding<String> {
        Binding(get: { state.renameRequest?.text ?? "" }, set: { state.renameRequest?.text = $0 })
    }
}

/// The question Extract asks for each item already in the picked folder: Keep Both /
/// Replace, "for All" while 2+ remain, Stop.
private struct ExtractionConflictAlert: ViewModifier {
    let state: ScreenState
    let isPresented: Binding<Bool>

    func body(content: Content) -> some View {
        content.alert(state.extractionQuestion?.title ?? "", isPresented: isPresented,
                      presenting: state.extractionQuestion) { question in
            // Each answer names the question it answers, so it can never land on the next one.
            Button("Keep Both") { state.answerExtractionConflict(.keepBoth, at: question.index) }
            Button("Replace", role: .destructive) { state.answerExtractionConflict(.replace, at: question.index) }
            if question.offersApplyToAll {
                Button("Keep Both for All") {
                    state.answerExtractionConflict(.keepBoth, forAll: true, at: question.index)
                }
                Button("Replace for All", role: .destructive) {
                    state.answerExtractionConflict(.replace, forAll: true, at: question.index)
                }
            }
            Button("Stop", role: .cancel) { state.stopExtraction() }
        } message: { question in
            Text(question.message)
        }
    }
}

/// Extract Here's picker and alerts on a level: the picker comes up when the request steps to it
/// (`presentPicker`), and a request still waiting on it when it goes is cancelled (`pickerDidClose`).
/// The alert works as the conflict alert: it waits for the progress sheet to have gone and for any
/// other alert or question (`ScreenState.canShowExtractHereAlert`); a button answers (Cancel clears
/// the request), and once the alert's condition has gone false, here, and UIKit has had a moment to
/// take it down, the answer moves on to its picker (`ScreenState.extractHereAlertDidGo`). Not from
/// the binding's setter: UIKit calls it while still dismissing, or not at all.
private struct ExtractHereFlow: ViewModifier {
    let state: ScreenState
    let isVisible: Bool
    let isImporting: Bool
    let presentPicker: () -> Void
    let pickerDidClose: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: state.extractHereRequest?.step) { _, _ in
                presentPicker()
            }
            .onChange(of: isImporting) { _, importing in
                if !importing { pickerDidClose() }
            }
            .modifier(ExtractHereAlert(state: state, isPresented: Binding(
                get: { showsAlert }, set: { _ in })))
            .onChange(of: showsAlert) { _, shows in
                if !shows { state.extractHereAlertDidGo() }
            }
    }

    /// The alert is up on this level: on screen, and nothing else in the way.
    private var showsAlert: Bool {
        isVisible && state.canShowExtractHereAlert
    }
}

/// Extract Here's questions (`ScreenState.extractHereAlert`): a pick that doesn't hold the
/// archive (OK asks again), or a read-only volume (Choose Another Folder… or Cancel). The picker an
/// answer leads to comes once the alert has gone (`ExtractHereFlow`'s `onChange`).
private struct ExtractHereAlert: ViewModifier {
    let state: ScreenState
    let isPresented: Binding<Bool>

    func body(content: Content) -> some View {
        content.alert(state.extractHereAlert?.title ?? "", isPresented: isPresented,
                      presenting: state.extractHereAlert) { _ in
            if state.extractHereRequest?.step == .readOnly {
                Button("Choose Another Folder…") { state.chooseAnotherFolderForExtractHere() }
            } else {
                Button("OK") { state.pickAgainForExtractHere() }
            }
            Button("Cancel", role: .cancel) { state.cancelExtractHere() }
        } message: { alert in
            Text(alert.message)
        }
    }
}

/// The question an explicit Save asks in an archive with `__MACOSX` or `._*` entries: Keep or Remove saves and
/// remembers the answer for the whole archive, Cancel saves nothing. Keep is the preferred action because it loses
/// nothing.
private struct MacMetadataQuestionAlert: ViewModifier {
    let state: ScreenState
    let isPresented: Binding<Bool>

    func body(content: Content) -> some View {
        content.alert(String(localized: "“\(state.name)” contains Mac metadata",
                             comment: "Title of the alert shown before saving an archive that contains Mac metadata (__MACOSX folders and ._ files); the buttons Keep, Remove and Cancel follow. %@ = the archive's name."),
                      isPresented: isPresented) {
            Button {
                if state.takeMacMetadataAnswer(remove: false) { Task { _ = await state.commitSave() } }
            } label: {
                Text("Keep", comment: "Button in the “… contains Mac metadata” alert: saves the archive and keeps the Mac metadata (__MACOSX folders and ._ files) in it. Verb; the default button.")
            }
            .keyboardShortcut(.defaultAction)
            // SwiftUI alert actions may drop these; the UI tests find the buttons by label.
            .accessibilityIdentifier("macMetadataKeep")
            Button(role: .destructive) {
                if state.takeMacMetadataAnswer(remove: true) { Task { _ = await state.commitSave() } }
            } label: {
                Text("Remove", comment: "Button in the “… contains Mac metadata” alert: saves the archive without the Mac metadata (__MACOSX folders, ._ files and .DS_Store files); removed files can’t be restored. Verb; destructive button.")
            }
            .accessibilityIdentifier("macMetadataRemove")
            Button("Cancel", role: .cancel) { state.cancelMacMetadataQuestion() }
                .accessibilityIdentifier("macMetadataCancel")
        } message: {
            Text("""
                Finder adds __MACOSX folders and ._ files to archives made on a Mac. Other apps don’t need \
                them. Remove them, along with any .DS_Store files, when saving? Removed files can’t be \
                restored. Lutik remembers your choice for this archive.
                """, comment: "__MACOSX, ._ and .DS_Store are file names; don't translate.")
        }
    }
}

/// What the Files picker is choosing.
private enum ImportPurpose: Equatable {
    /// Files and folders to add.
    case add
    /// The folder to extract these paths (nil: everything) into.
    case extract([String]?)
    /// The folder that holds the other parts of a split archive.
    case grantFolder
    /// Extract Here's folder: the archive's (kept as a grant), or any after a read-only error.
    case extractHere

    var contentTypes: [UTType] {
        self == .add ? [.item, .folder] : [.folder]
    }
}

/// Search only once the archive is listed, not over a password prompt or an error.
/// On an iPad at compact width (Split View, Slide Over) the field stays under the bar on every
/// level: the automatic drawer hides it on a pushed level until the list is pulled down, while
/// iPhone shows it on every level (iOS 26, in the bottom bar). Elsewhere the system places it.
/// One `.searchable` call with a computed placement, at the root and on pushed levels, so a
/// window crossing compact/regular keeps the level (scroll position, popovers, file mover)
/// instead of building it again. iOS 26 only: that is where this was seen and verified.
/// `CompactWidthUITests.testCompactExtractPicker` guards Extract's Files picker at the root.
private struct Search: ViewModifier {
    @Binding var text: String
    @Binding var isPresented: Bool
    let isEnabled: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var keepsFieldOnScreen: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .compact
    }

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $text, isPresented: $isPresented,
                               placement: keepsFieldOnScreen ? .navigationBarDrawer(displayMode: .always) : .automatic)
        } else {
            content
        }
    }
}

/// Title for pushed levels, subtitle (iOS 26) for every level.
private struct Titles: ViewModifier {
    let title: String?
    let subtitle: String

    func body(content: Content) -> some View {
        let titled = Group {
            if let title {
                content.navigationTitle(title)
            } else {
                content
            }
        }
        if #available(iOS 26.0, *) {
            titled.navigationSubtitle(subtitle)
        } else {
            titled
        }
    }
}
