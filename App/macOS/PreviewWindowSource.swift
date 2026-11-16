import AppKit
import OSLog
import QuickLookThumbnailing

/// Drives the preview window (`PreviewWindowController`) for one archive window.
/// Each item is titled with the entry's own name and shows the extracted file, or a
/// stand-in (`PreviewStrategy`) for types whose preview would hang in Lutik's sandbox. Share and
/// Open With act on the entry itself, never on the stand-in.
///
/// `ArchiveActions` still owns the preview: it sets `previewURL` and `previewEntries` and clears
/// them. This source follows that state. Stand-ins live in a `PreviewStandInStore` of this
/// window's own: a render that is superseded or outlives the preview is cancelled and writes
/// nothing, the previous stand-ins go when new ones show, and all of them go when the preview
/// closes. Share's copies stay until the archive window closes, which removes the whole store.
@MainActor
final class PreviewWindowSource: NSObject {
    nonisolated private static let log = Logger(subsystem: "com.kernir.app", category: "QuickLook")

    /// At most this many stand-ins are made at once for a multi-selection: each may be a
    /// 1600×1200 page rendered out of process.
    nonisolated static let maxConcurrentRenders = 3

    private let state: ArchiveWindowState
    /// The archive window. The preview opens only while it is key (or main, with the preview
    /// key): a render that ends after the user moved to another window, or closed this one,
    /// opens nothing. While it shows, the preview ends when another window becomes main.
    weak var window: NSWindow?
    /// Moves the selection, opens files: the archive window's actions.
    weak var actions: ArchiveActions?
    /// Made with the first preview; torn down when the archive window closes.
    private var controller: PreviewWindowController?
    /// For each of the controller's items, its index in the preview's entries.
    private var itemOrigins: [Int] = []
    /// Bumped on every change, so a slow stand-in never shows a stale selection.
    private var generation = 0
    /// Making the current preview's stand-ins; cancelled when the preview changes or ends.
    private var render: Task<Void, Never>?
    private let standIns: PreviewStandInStore
    /// Watches for another window becoming main; removed when the archive window closes, or in
    /// `deinit` if the source goes first (a window that never closed). `nonisolated(unsafe)` only so
    /// `deinit`, which is nonisolated, can remove it: it is set in `init` and cleared on the main actor.
    nonisolated(unsafe) private var becomeMainObserver: (any NSObjectProtocol)?
    /// An operation runs (`state.progress`): Open With and Share wait for it
    /// (`previewWindowCanOpen`, `previewWindowCanShare`).
    private var isOperationRunning = false

    init(state: ArchiveWindowState, standIns: PreviewStandInStore = PreviewStandInStore()) {
        self.state = state
        self.standIns = standIns
        super.init()
        observe()
        observeProgress()
        observeMainWindow()
    }

    deinit {
        if let becomeMainObserver { NotificationCenter.default.removeObserver(becomeMainObserver) }
        standIns.close()
    }

    /// The preview window, if one was made; for tests.
    var previewWindow: PreviewWindowController? { controller }

    // MARK: - Following the window state

    private func observe() {
        withObservationTracking {
            _ = state.previewURL
            _ = state.previewEntries
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observe()
                self?.sync()
            }
        }
    }

    /// An operation started or ended (an extraction, a save): the preview's Open With and Share
    /// follow, whatever item it shows. Only the start and the end count, not each
    /// progress update.
    private func observeProgress() {
        let isRunning = withObservationTracking {
            state.progress != nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeProgress() }
        }
        guard isRunning != isOperationRunning else { return }
        isOperationRunning = isRunning
        controller?.updateButtons()
    }

    /// Another window became main (another archive window, Settings): this window's preview ends,
    /// as the system panel moved on to that window. The preview window itself doesn't count, and
    /// switching to another app and back leaves the preview alone (it hides meanwhile).
    private func observeMainWindow() {
        becomeMainObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let other = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, self.state.previewURL != nil, let other, other !== self.window,
                      other !== self.controller?.window else { return }
                self.state.previewURL = nil
            }
        }
    }

    /// Stops the render in flight; whatever it would still show is stale.
    private func stopRendering() {
        generation += 1
        render?.cancel()
        render = nil
    }

    /// Opens, updates or closes the preview window to match `previewURL` and `previewEntries`.
    private func sync() {
        stopRendering()
        let generation = generation
        guard let current = state.previewURL else {
            endPreview()
            return
        }
        let entries = state.previewEntries.isEmpty
            ? [PreviewEntry(path: current.lastPathComponent, url: current)] : state.previewEntries
        let urls = entries.map(\.url)
        let index = urls.firstIndex(of: current) ?? 0
        let standIns = standIns
        let batch = standIns.beginBatch()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        render = Task { [weak self] in
            // The current item first, so the preview opens without waiting for the rest.
            let first = await Self.firstPass(urls, current: index, standIns: standIns, batch: batch, scale: scale)
            guard self?.show(first, of: entries, current: index, batch: batch, generation: generation) == true,
                  first.contains(nil) else { return }
            let all = await Self.rest(first, of: urls, standIns: standIns, batch: batch, scale: scale)
            self?.show(all, of: entries, current: index, batch: batch, generation: generation, keepingPosition: true)
        }
    }

    /// The preview ended: the window closes and every stand-in goes (Share's copies stay).
    private func endPreview() {
        controller?.hide()
        itemOrigins = []
        standIns.removeAll()
    }

    /// Puts `shown` in the preview window, leaving out the stand-ins not made yet (nil), and opens
    /// the window if it isn't open. False when the render is stale, or when this archive window
    /// isn't the one the user is in any more: then it stops previewing. `keepingPosition`: the
    /// window stays on the item it shows (the rest of the same render arrived), else it moves to
    /// `current`.
    @discardableResult
    private func show(_ shown: [URL?], of entries: [PreviewEntry], current: Int, batch: PreviewStandInStore.Batch,
                      generation: Int, keepingPosition: Bool = false) -> Bool {
        guard generation == self.generation, !Task.isCancelled, state.previewURL != nil else {
            standIns.discard(batch)
            return false
        }
        let isOpen = controller?.isOpen == true
        if !isOpen {
            // Closed, or the user went to another window during the render (Settings, say, key
            // while this one stays main).
            guard let window, window.isVisible,
                  window.isKeyWindow || (window.isMainWindow && controller != nil && NSApp.keyWindow === controller?.window)
            else {
                standIns.discard(batch)
                state.previewURL = nil
                return false
            }
        }
        guard standIns.install(batch) else { return false }
        let controller = controller ?? makeController()
        // The item the window shows now, to stay on when the rest of this render arrives.
        let showing = keepingPosition && isOpen && itemOrigins.indices.contains(controller.index)
            ? itemOrigins[controller.index] : current
        itemOrigins = shown.indices.filter { shown[$0] != nil }
        let items = itemOrigins.map { origin in
            PreviewItem(url: shown[origin]!, title: Self.name(of: entries[origin]), entry: entries[origin])
        }
        controller.show(items, at: itemOrigins.firstIndex(of: showing) ?? 0, over: window)
        return true
    }

    /// Made by the first preview that opens; tests make it directly.
    @discardableResult
    func makeController() -> PreviewWindowController {
        let controller = PreviewWindowController()
        controller.delegate = self
        self.controller = controller
        return controller
    }

    /// The entry's own name: the last part of its archive path.
    nonisolated static func name(of entry: PreviewEntry) -> String {
        entry.path.split(separator: "/").last.map(String.init) ?? entry.url.lastPathComponent
    }

    // MARK: - Stand-ins

    /// What the preview can show at once: the stand-in for `urls[current]`, made first, and every
    /// file shown as it is. nil for the stand-ins still to make.
    nonisolated private static func firstPass(
        _ urls: [URL], current: Int, standIns: PreviewStandInStore, batch: PreviewStandInStore.Batch,
        scale: CGFloat
    ) async -> [URL?] {
        var shown: [URL?] = urls.map { PreviewStrategy(fileAt: $0) == .original ? $0 : nil }
        shown[current] = await previewFile(for: urls[current], standIns: standIns, batch: batch, scale: scale)
        return shown
    }

    /// `shown` with the stand-ins `firstPass` left out made, at most `maxConcurrentRenders` at a time.
    nonisolated private static func rest(
        _ shown: [URL?], of urls: [URL], standIns: PreviewStandInStore, batch: PreviewStandInStore.Batch,
        scale: CGFloat
    ) async -> [URL?] {
        var shown = shown
        let pending = shown.indices.filter { shown[$0] == nil }
        let make: @Sendable (Int) async -> (Int, URL) = { index in
            (index, await Self.previewFile(for: urls[index], standIns: standIns, batch: batch, scale: scale))
        }
        await withTaskGroup(of: (Int, URL).self) { group in
            for index in pending.prefix(maxConcurrentRenders) {
                group.addTask { await make(index) }
            }
            var queue = pending.dropFirst(maxConcurrentRenders).makeIterator()
            while let made = await group.next() {
                shown[made.0] = made.1
                if !Task.isCancelled, let index = queue.next() {
                    group.addTask { await make(index) }
                }
            }
        }
        return shown
    }

    /// The file the preview shows for the extracted item at `url`: a stand-in when `PreviewStrategy`
    /// asks for one and it can be made, otherwise `url` itself.
    nonisolated private static func previewFile(
        for url: URL, standIns: PreviewStandInStore, batch: PreviewStandInStore.Batch, scale: CGFloat
    ) async -> URL {
        let strategy = PreviewStrategy(fileAt: url)
        // UI tests only (`-KernirPreviewStandInDelay`): a slow stand-in, so a window closed or left
        // right after Space is reliably closed or left while its render still runs.
        if strategy != .original, let delay = LaunchOverrides.previewStandInDelay {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return url }
        }
        switch strategy {
        case .original:
            return url
        case .textCopy:
            return textCopy(of: url, standIns: standIns, batch: batch) ?? url
        case .thumbnail(let fallback):
            if let page = await image(of: url, .thumbnail, standIns: standIns, batch: batch, scale: scale) {
                return page
            }
            guard !Task.isCancelled else { return url }
            switch fallback {
            case .textCopy:
                return textCopy(of: url, standIns: standIns, batch: batch) ?? url
            case .icon:
                return await image(of: url, .icon, standIns: standIns, batch: batch, scale: scale) ?? url
            }
        }
    }

    /// A `.txt` copy of `url`; nil if it can't be made, or the render was cancelled.
    nonisolated private static func textCopy(
        of url: URL, standIns: PreviewStandInStore, batch: PreviewStandInStore.Batch
    ) -> URL? {
        do {
            return try standIns.textCopy(of: url, in: batch)
        } catch is CancellationError {
            return nil
        } catch {
            log.error("Quick Look text copy failed: \(error)")
            return nil
        }
    }

    /// `QLThumbnailGenerator.Request` isn't Sendable; the generator's `cancel(_:)` takes it from
    /// any thread.
    private struct PendingRequest: @unchecked Sendable {
        let request: QLThumbnailGenerator.Request
    }

    /// The thumbnail service's rendering of `url` as a `.png`: with `.thumbnail` a page (up to
    /// 1600×1200 points), with `.icon` the file's icon. It runs out of process, where WebKit works.
    /// Cancelling the render cancels the request; nil then, and nothing is written.
    nonisolated private static func image(
        of url: URL, _ representation: QLThumbnailGenerator.Request.RepresentationTypes,
        standIns: PreviewStandInStore, batch: PreviewStandInStore.Batch, scale: CGFloat
    ) async -> URL? {
        let pending = PendingRequest(request: QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 1600, height: 1200), scale: scale,
            representationTypes: representation))
        do {
            let thumbnail = try await withTaskCancellationHandler {
                try await QLThumbnailGenerator.shared.generateBestRepresentation(for: pending.request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(pending.request)
            }
            try Task.checkCancellation()
            let bitmap = NSBitmapImageRep(cgImage: thumbnail.cgImage)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            let name = PreviewStrategy.standInName(for: url.lastPathComponent, pathExtension: "png")
            return try standIns.write(png, named: name, in: batch)
        } catch {
            if !(error is CancellationError) && !Task.isCancelled {
                log.notice("Quick Look rendering \(representation.rawValue) failed: \(error)")
            }
            return nil
        }
    }

    // MARK: - Share

    /// A copy of the extracted file at `file` to share, named `name` (`PreviewStandInStore.shareCopy`), made off
    /// the main actor: the preview's Share and the row menu's (`ArchiveActions.share`). It stays
    /// until the archive window closes; after that, `CancellationError`.
    func shareCopy(of file: URL, named name: String) async throws -> URL {
        let standIns = standIns
        return try await Task.detached { try standIns.shareCopy(of: file, named: name) }.value
    }

    // MARK: - Closing

    /// The archive window is closing: the preview window goes for good, and with it every
    /// stand-in and Share's copies (the whole `Kernir-Preview-<UUID>` root).
    func windowWillClose() {
        if let becomeMainObserver { NotificationCenter.default.removeObserver(becomeMainObserver) }
        becomeMainObserver = nil
        stopRendering()
        controller?.tearDown()
        controller = nil
        itemOrigins = []
        standIns.close()
        if state.previewURL != nil { state.previewURL = nil }
    }
}

extension PreviewWindowSource: PreviewWindowControllerDelegate {
    func previewWindowDidRequestClose() {
        if state.previewURL != nil { state.previewURL = nil }
    }

    func previewWindowMoveSelection(by step: Int) {
        actions?.movePreviewSelection(by: step)
    }

    func previewWindowCanOpen(_ item: PreviewItem) -> Bool {
        actions?.canOpenFile(item.entry.path) == true
    }

    /// Not while an operation runs: a save or View > Text Encoding's reopen replaces the reader
    /// whose extracted file Share copies, and a vanished entry isn't extracted again meanwhile
    /// (`ArchiveActions.localFileURL`).
    func previewWindowCanShare(_ item: PreviewItem) -> Bool {
        state.progress == nil
    }

    func previewWindowOpen(_ item: PreviewItem, withApplicationAt app: URL?) {
        actions?.openFile(item.entry.path, withApplicationAt: app)
    }

    /// A copy of the entry to share, made now. The extracted file may be gone by now (a save or
    /// a reader swap deletes the reader's cache): then the entry is extracted again, the way the
    /// preview got it. Empty, and the error logged, if that fails too: the window beeps rather
    /// than show an empty picker. The copy is made off the main actor.
    func previewWindowShareItems(for item: PreviewItem) async -> [URL] {
        let name = Self.name(of: item.entry)
        var file = item.entry.url
        do {
            if !FileManager.default.fileExists(atPath: file.path) {
                guard let actions else { throw CancellationError() }
                Self.log.notice("Share: the extracted file is gone; extracting it again")
                file = try await actions.localFileURL(for: item.entry.path)
            }
            return [try await shareCopy(of: file, named: name)]
        } catch {
            Self.log.error("Share copy failed: \(error)")
            return []
        }
    }
}
