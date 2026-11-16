import AppKit
import OSLog
import QuickLookThumbnailing

/// The preview window's index sheet: every item of a multi-selection as
/// a thumbnail with the entry's real name under it, in a grid. A click picks an item (`onPick`);
/// the window handles the keys (`PreviewNavigation.command`) and sets the selection (`select`).
///
/// Each thumbnail is `QLThumbnailGenerator`'s rendering of the file the single view shows for
/// that item (the extracted file, or its stand-in), made out of process, only for cells the
/// grid shows, and cancelled when the sheet goes or the items change. Until it comes, or if it
/// can't be made, the cell shows the icon of the entry's real type.
@MainActor
final class PreviewGridView: NSScrollView, NSCollectionViewDataSource {
    nonisolated private static let log = Logger(subsystem: "com.kernir.app", category: "QuickLook")
    nonisolated static let itemSize = NSSize(width: 164, height: 164)
    /// The thumbnail's box in a cell, in points.
    nonisolated static let thumbnailSize = CGSize(width: 128, height: 112)

    let collectionView = PreviewGridCollectionView(frame: .zero)
    /// A click on an item, by its index.
    var onPick: ((Int) -> Void)?
    private(set) var items: [PreviewItem] = []
    /// Thumbnails made so far, by the file they show.
    private var thumbnails: [URL: NSImage] = [:]
    /// Files no thumbnail could be made for: they keep their icon.
    private var failed: Set<URL> = []
    /// Thumbnails being made, by file.
    private var requests: [URL: Task<Void, Never>] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = Self.itemSize
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(PreviewGridItem.self, forItemWithIdentifier: PreviewGridItem.identifier)
        collectionView.dataSource = self
        collectionView.setAccessibilityIdentifier("preview.grid.sheet")
        collectionView.onClick = { [weak self] index in self?.onPick?(index) }
        documentView = collectionView
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Items

    /// Shows `items` with `selected` selected. New files reload the grid: thumbnails of files no
    /// longer shown are cancelled and dropped, the others kept. The same files only move the
    /// selection.
    func show(_ items: [PreviewItem], selected: Int) {
        let changed = items.map(\.url) != self.items.map(\.url) || items.map(\.title) != self.items.map(\.title)
        self.items = items
        if changed {
            let kept = Set(items.map(\.url))
            for (url, task) in requests where !kept.contains(url) {
                task.cancel()
                requests[url] = nil
            }
            thumbnails = thumbnails.filter { kept.contains($0.key) }
            failed.formIntersection(kept)
            collectionView.reloadData()
        }
        select(selected)
    }

    /// Selects the item at `index` and scrolls it into view.
    func select(_ index: Int) {
        guard items.indices.contains(index) else {
            collectionView.selectionIndexPaths = []
            return
        }
        let path = IndexPath(item: index, section: 0)
        guard collectionView.selectionIndexPaths != [path] else { return }
        collectionView.selectionIndexPaths = [path]
        collectionView.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
    }

    /// The sheet is put away: thumbnails still being made are cancelled (those made stay).
    func stopThumbnails() {
        for task in requests.values { task.cancel() }
        requests = [:]
    }

    /// The preview ended: nothing is shown or kept.
    func clear() {
        stopThumbnails()
        thumbnails = [:]
        failed = []
        items = []
        collectionView.reloadData()
    }

    /// The items in a row, as the grid lays them out now: those level with the first.
    var columns: Int {
        guard let layout = collectionView.collectionViewLayout, !items.isEmpty,
              let top = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.minY
        else { return 1 }
        var columns = 0
        for index in items.indices {
            guard layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.minY == top else { break }
            columns += 1
        }
        return max(1, columns)
    }

    // MARK: - Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: PreviewGridItem.identifier, for: indexPath)
        guard let cell = cell as? PreviewGridItem, items.indices.contains(indexPath.item) else { return cell }
        let item = items[indexPath.item]
        cell.configure(title: item.title, image: thumbnails[item.url] ?? Self.icon(for: item))
        makeThumbnail(for: item.url)
        return cell
    }

    /// The icon of the entry's real type (never the stand-in's).
    static func icon(for item: PreviewItem) -> NSImage {
        let isDirectory = (try? item.entry.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            ?? item.entry.url.hasDirectoryPath
        return NSWorkspace.shared.icon(for: PreviewNavigation.iconType(forName: item.title, isDirectory: isDirectory))
    }

    // MARK: - Thumbnails

    /// Starts the thumbnail of `url` unless it is made, being made, or failed.
    private func makeThumbnail(for url: URL) {
        guard thumbnails[url] == nil, requests[url] == nil, !failed.contains(url) else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        requests[url] = Task { [weak self] in
            let image = await Self.thumbnail(of: url, scale: scale)
            guard let self, !Task.isCancelled else { return }
            self.requests[url] = nil
            guard let image else {
                self.failed.insert(url)
                return
            }
            let thumbnail = NSImage(cgImage: image.cgImage, size: .zero)
            self.thumbnails[url] = thumbnail
            for index in self.items.indices where self.items[index].url == url {
                (self.collectionView.item(at: IndexPath(item: index, section: 0)) as? PreviewGridItem)?.setImage(thumbnail)
            }
        }
    }

    /// `QLThumbnailGenerator.Request` isn't Sendable; the generator's `cancel(_:)` takes it from
    /// any thread.
    private struct PendingRequest: @unchecked Sendable {
        let request: QLThumbnailGenerator.Request
    }

    /// A made thumbnail, handed back to the main actor.
    private struct Thumbnail: @unchecked Sendable {
        let cgImage: CGImage
    }

    /// The thumbnail service's rendering of `url`; nil if it can't make one or the task was
    /// cancelled (which cancels the request).
    nonisolated private static func thumbnail(of url: URL, scale: CGFloat) async -> Thumbnail? {
        let pending = PendingRequest(request: QLThumbnailGenerator.Request(
            fileAt: url, size: thumbnailSize, scale: scale, representationTypes: .thumbnail))
        do {
            let representation = try await withTaskCancellationHandler {
                try await QLThumbnailGenerator.shared.generateBestRepresentation(for: pending.request)
            } onCancel: {
                QLThumbnailGenerator.shared.cancel(pending.request)
            }
            return Task.isCancelled ? nil : Thumbnail(cgImage: representation.cgImage)
        } catch {
            if !(error is CancellationError) && !Task.isCancelled {
                log.debug("Index sheet thumbnail failed: \(error)")
            }
            return nil
        }
    }
}

/// The index sheet's collection view: a click on an item picks it, after the usual selection.
final class PreviewGridCollectionView: NSCollectionView {
    var onClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let path = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if let path { onClick?(path.item) }
    }
}

/// One cell of the index sheet: a thumbnail (or icon) and the entry's real name.
final class PreviewGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PreviewGridItem")

    private let thumbnailView = NSImageView()
    private let captionField = NSTextField(labelWithString: "")

    override func loadView() {
        let cell = NSView(frame: NSRect(origin: .zero, size: PreviewGridView.itemSize))
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 8
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        captionField.alignment = .center
        captionField.lineBreakMode = .byTruncatingMiddle
        captionField.maximumNumberOfLines = 2
        captionField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        captionField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(thumbnailView)
        cell.addSubview(captionField)
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            thumbnailView.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: PreviewGridView.thumbnailSize.width),
            thumbnailView.heightAnchor.constraint(equalToConstant: PreviewGridView.thumbnailSize.height),
            captionField.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 6),
            captionField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            captionField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
        ])
        // One element per cell for VoiceOver and the UI tests, named by the entry.
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.cell)
        cell.setAccessibilityIdentifier("preview.grid.cell")
        view = cell
        imageView = thumbnailView
        textField = captionField
    }

    func configure(title: String, image: NSImage) {
        captionField.stringValue = title
        thumbnailView.image = image
        view.setAccessibilityLabel(title)
        updateHighlight()
    }

    func setImage(_ image: NSImage) {
        thumbnailView.image = image
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    private func updateHighlight() {
        view.setAccessibilitySelected(isSelected)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = isSelected
                ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).cgColor
                : NSColor.clear.cgColor
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateHighlight()
    }
}
