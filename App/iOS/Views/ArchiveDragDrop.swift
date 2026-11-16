import Foundation
import SwiftUI
import UniformTypeIdentifiers
import KernirCore

// Drag and drop (iPad; iOS 13.4 `onDrag` / `onDrop`). A row drags out as a file extracted only
// when the drop asks for it; files dropped on the list or on a folder row are added the way ＋
// adds them. The wiring sits behind two modifiers, so the row's structure can change around it.

extension View {
    /// Drags the entry at `path` out of the archive.
    func archiveDragSource(_ state: ScreenState, path: String) -> some View {
        onDrag { state.dragProvider(for: path) }
    }

    /// Takes drops into the archive folder `directory`. A folder row (`highlightsRow`) shows it
    /// is the target while a drop it would take hovers over it.
    func archiveDropTarget(_ state: ScreenState, directory: String, isEnabled: Bool = true,
                           highlightsRow: Bool = false) -> some View {
        modifier(ArchiveDropTarget(state: state, directory: directory, isEnabled: isEnabled,
                                   highlightsRow: highlightsRow))
    }
}

private struct ArchiveDropTarget: ViewModifier {
    let state: ScreenState
    let directory: String
    let isEnabled: Bool
    let highlightsRow: Bool
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if isEnabled {
            let target = content
                .onDrop(of: [.item], delegate: FolderDropDelegate(state: state, directory: directory,
                                                                  isTargeted: $isTargeted))
            if highlightsRow {
                target.listRowBackground(isTargeted ? Color.accentColor.opacity(0.2) : nil)
            } else {
                target
            }
        } else {
            content
        }
    }
}

// MARK: - The space below the rows

// On the iPad the List's UICollectionView takes a drop over its empty space below the rows itself
// and refuses it: neither the List's `.onDrop` nor a view behind the List ever sees it (found on a
// device). A layer above the list does, as the empty level's layer does: a level that
// lists rows gets one over the space below its lowest row on screen. Rows report their bottom
// edges for it; it never covers a row, so rows keep their taps and their own drop targets.

extension View {
    /// Reports this row's bottom edge to `bottoms` while the row is on screen.
    func archiveRowBottom(_ id: String, in bottoms: ArchiveRowBottoms) -> some View {
        modifier(ArchiveRowBottomReport(id: id, bottoms: bottoms))
    }
}

/// A row leaves when a subfolder is pushed or a full-screen preview covers it, and comes back
/// unmoved on the way back: no geometry change then, so it reports its last bottom edge again.
private struct ArchiveRowBottomReport: ViewModifier {
    let id: String
    let bottoms: ArchiveRowBottoms
    @State private var last: CGFloat?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom in
                last = bottom
                bottoms.set(id, bottom)
            }
            .onAppear { if let last { bottoms.set(id, last) } }
            .onDisappear { bottoms.set(id, nil) }
    }
}

/// The bottom edges (global) of one level's rows on screen, for its drop layer below them.
@MainActor @Observable final class ArchiveRowBottoms {
    /// A row's cell reaches a little below its content (the row's inset): the layer starts below that.
    nonisolated static let rowBottomInset: CGFloat = 8
    /// A shorter gap gets no layer: too small to aim a drop at, and a scroll that starts there scrolls.
    nonisolated static let minimumLayerHeight: CGFloat = 44

    private var bottoms: [String: CGFloat] = [:]

    var lowestRowBottom: CGFloat? { bottoms.values.max() }

    /// `bottom` nil: the row went (scrolled away, deleted, hidden by a search).
    func set(_ id: String, _ bottom: CGFloat?) {
        if bottoms[id] != bottom { bottoms[id] = bottom }
    }

    /// The layer's height at the bottom of the list (`list`, global): nil with no row on screen (an
    /// empty level has its own layer) or a gap shorter than `minimumLayerHeight`.
    nonisolated static func dropLayerHeight(lowestRowBottom: CGFloat?, in list: CGRect) -> CGFloat? {
        guard let lowestRowBottom else { return nil }
        let top = max(0, lowestRowBottom + rowBottomInset - list.minY)
        let height = list.height - top
        return height >= minimumLayerHeight ? height : nil
    }
}

/// The drop layer over the space below a level's rows, into the folder on screen (`directory`). A long
/// press on it shows ＋'s Paste. Its own view, so only it redraws as the rows move.
struct ArchiveDropLayerBelowRows: View {
    let state: ScreenState
    let directory: String
    let rowBottoms: ArchiveRowBottoms

    var body: some View {
        // Read here, in `body`, so Observation redraws the layer when the lowest row moves.
        let lowestRowBottom = rowBottoms.lowestRowBottom
        GeometryReader { proxy in
            if let height = ArchiveRowBottoms.dropLayerHeight(lowestRowBottom: lowestRowBottom,
                                                              in: proxy.frame(in: .global)) {
                Color.clear
                    .contentShape(Rectangle())
                    .archiveEmptySpaceMenu(state, folder: directory)
                    .archiveDropTarget(state, directory: directory)
                    .accessibilityHidden(true)
                    .frame(height: height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

/// Drops on one archive folder. A refused drop shows the forbidden badge: read-only, locked,
/// saving, Text Encoding reading the archive again, or an entry dragged out of this same archive
/// (by design) unless every item is a row of it that this folder takes: those move.
struct FolderDropDelegate: DropDelegate {
    let state: ScreenState
    let directory: String
    var isTargeted: Binding<Bool>?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let proposal = state.dropProposal(hovering: info.itemProviders(for: [.item]),
                                          conforms: info.hasItemsConforming(to:), into: directory)
        setTargeted(proposal.operation == .copy || proposal.operation == .move)
        return proposal
    }

    func dropExited(info: DropInfo) {
        setTargeted(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        setTargeted(false)
        let providers = info.itemProviders(for: [.item])
        // This archive's own rows move (in-archive move); anything else goes the way ＋ adds it.
        if state.performMoveDrop(providers, into: directory) { return true }
        return state.acceptDrop(providers, to: directory)
    }

    private func setTargeted(_ targeted: Bool) {
        if isTargeted?.wrappedValue != targeted { isTargeted?.wrappedValue = targeted }
    }
}

// MARK: - ScreenState

extension ScreenState {
    /// The start of every drag marker's type; the rest is the source document's `dragSourceID`.
    nonisolated static let dragMarkerPrefix = "com.kernir.app.entry."

    /// This document's drag marker. The ID is in the type itself, not only in its data: a drop
    /// delegate must decide synchronously, and it can read a provider's types but not its data.
    nonisolated var dragMarkerType: String { Self.dragMarkerPrefix + dragSourceID.uuidString }

    /// The entry at `path` as a file for the drop: extracted only when the drop asks for it (a
    /// folder through `ArchiveModel.extract`, never into memory), plus the `.ownProcess` marker.
    func dragProvider(for path: String) -> NSItemProvider {
        guard let item = model?.item(at: path) else { return NSItemProvider() }
        let ext = (item.name as NSString).pathExtension
        let type: UTType = if item.isDirectory {
            .folder
        } else {
            ext.isEmpty ? .data : UTType(filenameExtension: ext) ?? .data
        }
        // The model at drop time: a save meanwhile replaces it.
        return Self.makeDragProvider(name: item.name, type: type, marker: dragMarkerType,
                                     itemMarker: registerDraggedRow(item.path), path: item.path) { [weak self] in
            guard let model = await self?.model else { throw ArchiveError.entryNotFound(path) }
            return try await model.localFileURL(for: path)
        }
    }

    /// Nonisolated, so the handlers UIKit calls off the main thread aren't main-actor closures.
    private nonisolated static func makeDragProvider(
        name: String, type: UTType, marker: String, itemMarker: String, path: String,
        file: @escaping @Sendable () async throws -> URL
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            let completion = DragCompletion(call: completion)
            let progress = Progress(totalUnitCount: 1)
            let task = Task {
                do {
                    let url = try await file()
                    progress.completedUnitCount = 1
                    completion.call(url, false, nil)
                } catch {
                    completion.call(nil, false, error)
                }
            }
            progress.cancellationHandler = { task.cancel() }
            return progress
        }
        // Both markers carry the row's path; the item marker's type also finds it at once (`draggedRows`).
        for marker in [marker, itemMarker] {
            provider.registerDataRepresentation(forTypeIdentifier: marker, visibility: .ownProcess) { completion in
                completion(Data(path.utf8), nil)
                return nil
            }
        }
        return provider
    }

    /// Whether any of `providers` was dragged out of this document.
    func isFromThisDocument(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { $0.registeredTypeIdentifiers.contains(dragMarkerType) }
    }

    /// Copy, or the forbidden badge when ＋ couldn't add either (`canAdd`) or the drag came out of
    /// this same archive. Move when every item is a row of this archive (`moving`, from `draggedPaths`)
    /// that `directory` takes (`canMove`): not into itself or a descendant, not where they already are.
    func dropProposal(isFromThisDocument: Bool, offersFile: Bool = true,
                      moving paths: [String]? = nil, into directory: String = "") -> DropProposal {
        if let paths {
            return DropProposal(operation: canMove(paths, into: directory) ? .move : .forbidden)
        }
        return DropProposal(operation: canAdd && !isFromThisDocument && offersFile ? .copy : .forbidden)
    }

    /// The proposal while a drop hovers. SwiftUI hands out a drop's item providers only in
    /// `performDrop`: a drag from another app (Files) has none before, so `conforms` (the drop's
    /// `hasItemsConforming(to:)`, valid throughout) decides then by the types the drag offers.
    /// This archive's own rows propose a move into `directory` when it takes them (`canMove`); without
    /// providers they are found by their item markers' types (`hoveringDraggedPaths`).
    func dropProposal(hovering providers: [NSItemProvider], conforms: ([UTType]) -> Bool,
                      into directory: String = "") -> DropProposal {
        guard providers.isEmpty else {
            return dropProposal(isFromThisDocument: isFromThisDocument(providers), offersFile: Self.offersFile(providers),
                                moving: draggedPaths(providers), into: directory)
        }
        let isFromThisDocument = conforms([dragMarkerUTType])
        return dropProposal(isFromThisDocument: isFromThisDocument, offersFile: Self.hoverOffersFile(conforms),
                            moving: isFromThisDocument ? hoveringDraggedPaths(conforms) : nil, into: directory)
    }

    /// Whether a drag without providers offers a file or folder. A link and a text snippet conform
    /// to `public.data` too, so that alone proves nothing: a drag that offers a link (`public.url`)
    /// and no file URL, folder or file-like type (image, movie, audio, archive, pdf) is a web link,
    /// refused; an image dragged out of Safari (image data plus its URL) or a Files zip dragged
    /// with a web link is not. A real file drag has a type of its own (a zip, a photo), and a file
    /// URL or a folder type beside it when the source gives one.
    /// A bare text snippet can't be told from a text file Files offers by its type alone: it is
    /// left to `acceptDrop`, which looks at the providers (`offersFile`).
    nonisolated static func hoverOffersFile(_ conforms: ([UTType]) -> Bool) -> Bool {
        guard conforms([.data, .directory]) else { return false }
        return conforms([.fileURL, .directory, .image, .movie, .audio, .archive, .pdf]) || !conforms([.url])
    }

    /// Where a drop on `item`'s row goes: a folder row into that folder, a file row into the level
    /// it is listed in (`level`). Every row is a drop target, through `FolderDropDelegate` as the
    /// empty level's layer and the list's own area: once a level lists anything that layer goes, and
    /// the `onInsert` the list had didn't take a drop from Files on the iPad (the second drop into a
    /// new archive).
    func dropDirectory(forRow item: ArchiveItem, in level: String) -> String {
        item.isDirectory ? item.path : level
    }

    /// Takes a drop into `directory` when its proposal is copy: a row's `performDrop` (a folder row,
    /// a file row for its level), the list's own area's, the layer's below the rows and the empty
    /// level's layer's, all into the folder on screen. False when refused.
    func acceptDrop(_ providers: [NSItemProvider], to directory: String) -> Bool {
        guard dropProposal(isFromThisDocument: isFromThisDocument(providers),
                           offersFile: Self.offersFile(providers)).operation == .copy else { return false }
        receiveDrop(providers, to: directory)
        return true
    }

    /// Whether any of `providers` is a file or folder (not a link or a text snippet).
    nonisolated static func offersFile(_ providers: [NSItemProvider]) -> Bool {
        providers.contains { DroppedItem.fileType(of: $0) != nil }
    }

    /// Receives dropped items into a temporary folder, then adds them to `directory` through
    /// `add(_:to:)`: staging, and the Replace alert for same-named items, as for ＋. Items dragged
    /// out of this document are left out.
    func addDropped(_ providers: [NSItemProvider], to directory: String) async {
        guard let items = startReceiving(providers) else { return }
        await addReceived(items, to: directory)
    }

    /// The drop delegate's `performDrop`: starts loading at once, while UIKit still hands out the
    /// drop's items, and adds them once they have arrived.
    func receiveDrop(_ providers: [NSItemProvider], to directory: String) {
        guard let items = startReceiving(providers) else { return }
        Task { await addReceived(items, to: directory) }
    }

    /// Starts loading each provider's file; nil when nothing can be added. While a save writes the
    /// archive, or Text Encoding reads it again, the user is told so and nothing loads. Nothing either,
    /// silently, while Extract's conflict questions are open (`pendingExtraction`; the drop proposal
    /// forbids it then, through `canAdd`).
    private func startReceiving(_ providers: [NSItemProvider]) -> DroppedItems? {
        let foreign = providers.filter { !$0.registeredTypeIdentifiers.contains(dragMarkerType) }
        guard canEdit, !isLocked, pendingExtraction == nil, !foreign.isEmpty else { return nil }
        guard !isBusy else {
            refuseAddingWhileBusy(count: foreign.count)
            return nil
        }
        return DroppedItems(foreign)
    }

    /// A search that hides a received item clears, as after New Folder: the item was added but would
    /// be listed nowhere.
    private func clearSearchHidingReceived(_ urls: [URL], in directory: String) {
        guard !searchText.isEmpty, let model else { return }
        let visible = Set(model.children(of: directory, matching: searchText).map(\.name))
        let hidden = model.children(of: directory).contains { child in
            !visible.contains(child.name)
                && urls.contains { $0.lastPathComponent.precomposedStringWithCanonicalMapping == child.name }
        }
        if hidden { searchText = "" }
    }

    /// Waits (under the progress sheet, when it takes a while) for the copies, then stages and
    /// adds them. The copies go once staged; a failure adds nothing.
    private func addReceived(_ items: DroppedItems, to directory: String) async {
        defer { items.discard() }
        let urls: [URL]
        do {
            urls = try await perform(String(localized: "Adding files…"), showingAfter: .milliseconds(300)) { _ in
                try await items.urls()
            }
        } catch {
            if error is CancellationError { return }
            alert = AlertContent(title: String(localized: "Couldn't add files"), message: error.localizedDescription)
            return
        }
        // A save (or Text Encoding's reopen) started meanwhile: `add` refuses and says so. An Extract
        // that started meanwhile and asks its conflict questions: `add` refuses, silently.
        add(urls, to: directory)
        clearSearchHidingReceived(urls, in: directory)
        if items.skipped > 0, alert == nil {
            alert = AlertContent(title: String(localized: "Couldn't add \(items.skipped) items"),
                                 message: String(localized: "\(items.skipped) dropped items didn't provide files to copy.",
                                                 comment: "Alert message under “Couldn't add %lld items” when dropped items (e.g. a text snippet or a link) offered no file to copy; any other dropped items are still added. %lld = number of those items. The English “one” form leaves the number out. Other languages’ “one” form can also cover 21, 31… and must then keep %lld."))
        }
    }
}

/// UIKit's completion handler for a file representation, carried into the extraction task.
private struct DragCompletion: @unchecked Sendable {
    let call: (URL?, Bool, (any Error)?) -> Void
}

// MARK: - Receiving dropped items

/// The items of one drop, loading. Providers without a file are counted in `skipped`.
struct DroppedItems: Sendable {
    let items: [DroppedItem]
    let skipped: Int

    init(_ providers: [NSItemProvider]) {
        var items: [DroppedItem] = []
        var skipped = 0
        for provider in providers {
            if let type = DroppedItem.fileType(of: provider) {
                items.append(DroppedItem(provider, type: type))
            } else {
                skipped += 1
            }
        }
        self.items = items
        self.skipped = skipped
    }

    /// The received copies, in order. Throws when any of them failed.
    func urls() async throws -> [URL] {
        var urls: [URL] = []
        for item in items {
            urls.append(try await item.url())
        }
        return urls
    }

    /// Removes the copies, and those still arriving once they do.
    func discard() {
        for item in items { item.discard() }
    }
}

/// One dropped item, copied out of the file UIKit hands over inside the load callback (UIKit
/// deletes that file once the callback returns), as `PickedMedia.receive` does for photos.
final class DroppedItem: @unchecked Sendable {
    /// The temporary folders the copies go in.
    static let folderPrefix = "Dropped-"

    /// The folder the copy goes in; it holds nothing else.
    let folder: URL
    private let lock = NSLock()
    // Guarded by `lock`.
    private var result: Result<URL, any Error>?
    private var waiters: [CheckedContinuation<URL, any Error>] = []
    private var progress: Progress?

    /// Starts loading `provider`'s file of `type` now, copied under the provider's suggested name.
    convenience init(_ provider: NSItemProvider, type: String) {
        self.init(provider, type: type, suggestedName: provider.suggestedName)
    }

    /// Starts loading `provider`'s file of `type` now, copied under `name` (a test seam: a name
    /// NSItemProvider can't name its own copy by makes it fail the load before `name` is used).
    init(_ provider: NSItemProvider, type: String, suggestedName name: String?) {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.folderPrefix + UUID().uuidString, isDirectory: true)
        let loading = provider.loadFileRepresentation(forTypeIdentifier: type) { [self] url, error in
            finish(Result { try copy(url, error: error, suggestedName: name) })
        }
        lock.withLock { if result == nil { progress = loading } }
    }

    /// The type to load: the provider's most faithful (first) file or folder type, or nil when
    /// the provider isn't a file (a link, a text snippet, a drag marker, an unknown type). The one
    /// place that decides what counts as a file: a type conforming to `public.directory`, or to
    /// `public.data` but not `public.url`; a text type only when the provider is named like a
    /// file (a suggested name, or a file URL beside it), as a text snippet carries neither.
    static func fileType(of provider: NSItemProvider) -> String? {
        fileType(in: provider.registeredTypeIdentifiers, named: !(provider.suggestedName ?? "").isEmpty)
    }

    /// `fileType(of:)` on a provider's or a pasteboard item's types; `named`: it has a suggested name. A
    /// pasteboard item's types are metadata: Paste's gate reads them without the paste prompt.
    static func fileType(in identifiers: [String], named: Bool) -> String? {
        let types = identifiers.filter { !$0.hasPrefix(ScreenState.dragMarkerPrefix) }
        let named = named || types.contains(UTType.fileURL.identifier)
        return types.first { identifier in
            guard let type = UTType(identifier), !type.conforms(to: .url) else { return false }
            if type.conforms(to: .directory) { return true }
            return type.conforms(to: .data) && (named || !type.conforms(to: .text))
        }
    }

    /// The copy, once it has arrived. Cancelling stops waiting; `discard` stops the load.
    func url() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let done = lock.withLock {
                    if result == nil { waiters.append(continuation) }
                    return result
                }
                if let done { continuation.resume(with: done) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    /// Stops the load and removes the copy; one arriving later is removed then.
    func discard() {
        finish(.failure(CancellationError()))
        let loading = lock.withLock {
            defer { progress = nil }
            return progress
        }
        loading?.cancel()
        try? FileManager.default.removeItem(at: folder)
    }

    /// The first outcome counts and resumes the waiters. A copy arriving after another outcome
    /// (a cancel or `discard`) is removed.
    private func finish(_ outcome: Result<URL, any Error>) {
        let resumed: [CheckedContinuation<URL, any Error>]? = lock.withLock {
            guard result == nil else { return nil }
            result = outcome
            defer { waiters = [] }
            return waiters
        }
        guard let resumed else {
            if case .success = outcome { try? FileManager.default.removeItem(at: folder) }
            return
        }
        for waiter in resumed { waiter.resume(with: outcome) }
    }

    /// Copies the received file (or folder) into `folder` under the name it was dropped as.
    private func copy(_ received: URL?, error: (any Error)?, suggestedName: String?) throws -> URL {
        guard let received else { throw error ?? CocoaError(.fileReadUnknown) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(Self.name(suggested: suggestedName, received: received))
        try FileManager.default.copyItem(at: received, to: target)
        return target
    }

    /// The provider's suggested name, with the received file's extension when it lacks it (a
    /// suggested name may leave the extension out); the received file's name without one. Every
    /// "/" scalar is replaced, also one a combining mark follows (`.literal`: a plain search
    /// compares whole characters and skips it).
    static func name(suggested: String?, received: URL) -> String {
        let suggested = (suggested ?? "").replacingOccurrences(of: "/", with: "-", options: .literal)
        guard !suggested.isEmpty, suggested != ".", suggested != ".." else { return received.lastPathComponent }
        let ext = received.pathExtension
        if ext.isEmpty || suggested.lowercased().hasSuffix("." + ext.lowercased()) {
            return suggested
        }
        return suggested + "." + ext
    }
}
