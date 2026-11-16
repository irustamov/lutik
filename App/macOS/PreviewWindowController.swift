import AppKit
import OSLog
import QuickLookUI
import UniformTypeIdentifiers

/// One item the preview window shows: the file to show (the extracted file, or a stand-in made
/// by `PreviewStrategy`), the entry's own name, and the entry Share and Open With act on.
final class PreviewItem: NSObject, QLPreviewItem {
    let url: URL
    let title: String
    /// The archive entry: its path and its extracted file under its real name.
    let entry: PreviewEntry
    /// The type of `url`, the file shown (a stand-in's own: a rendered page is a `.png`): from the file, else
    /// from its extension; `.data` when neither tells. Looked up once, when first asked (only the shown item's is:
    /// `PreviewWindowController.shownContentType`), not for every item of every pass.
    private(set) lazy var contentType: UTType = Self.contentType(of: url)

    init(url: URL, title: String, entry: PreviewEntry) {
        self.url = url
        self.title = title
        self.entry = entry
    }

    /// The type of the file at `url`, a link's target's (as `ServicesRequest`), else by its extension.
    static func contentType(of url: URL) -> UTType {
        if let type = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension) ?? .data
    }

    var previewItemURL: URL! { url }
    var previewItemTitle: String! { title }
}

/// What the preview window asks its archive window for.
@MainActor
protocol PreviewWindowControllerDelegate: AnyObject {
    /// Space, Esc, the close button or ⌘W: the preview ends.
    func previewWindowDidRequestClose()
    /// ↓ (+1) or ↑ (-1): the archive window's selection moves, and the preview follows it.
    func previewWindowMoveSelection(by step: Int)
    /// Whether `item` can be opened in an app now: a file, not a folder, and no operation running.
    func previewWindowCanOpen(_ item: PreviewItem) -> Bool
    /// Whether `item` can be shared now: no operation running.
    func previewWindowCanShare(_ item: PreviewItem) -> Bool
    /// Opens `item`'s entry in `app`, or in its default app when nil, as a double-click does.
    func previewWindowOpen(_ item: PreviewItem, withApplicationAt app: URL?)
    /// The files to share for `item`: a copy of its entry made now, under its real name (the
    /// entry extracted again if its file is gone). Empty when that fails.
    func previewWindowShareItems(for item: PreviewItem) async -> [URL]
}

/// Lutik's own Quick Look window for one archive window: a plain
/// `QLPreviewView` in a window, with Share and Open With buttons that act on the archive entry
/// itself, its real name and bytes, never on the stand-in the view may show. The system
/// `QLPreviewPanel`'s own buttons can't be retargeted without private API, hence this window.
///
/// Keys (`PreviewNavigation.command`): ↑/↓ move the archive window's selection, ←/→ page through
/// a multi-selection ("2 of 5" in the title), Space and Esc close. `PreviewWindowSource` fills it.
/// What it shows is `pager`'s.
///
/// A multi-selection also has an index sheet: a grid of every item (`PreviewGridView`,
/// "5 items" in the title), toggled from the toolbar. A click, Return or Space there shows that
/// item; arrows move in the grid; Esc goes back to the single view.
///
/// Full screen: the toolbar button, ⌃⌘F (View > Enter Full Screen) or the green button.
/// The window is floating, hides on deactivation and never becomes main out of full screen; in
/// full screen it is a normal window that stays put and may become main
/// (`PreviewNavigation.windowTraits`). Esc leaves full screen before anything else. Whenever the
/// window goes away while in full screen (Space, ⌘W, another window, the archive window closing),
/// it leaves full screen first and goes once that is done (`leaveFullScreen`), so no empty Space
/// is left behind.
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuDelegate {
    /// Name under which the preview window autosaves its frame; nil autosaves none. The unit-test
    /// bundle sets nil, as for archive windows.
    static var frameAutosaveName: String? = "PreviewWindow"

    nonisolated private static let log = Logger(subsystem: "com.kernir.app", category: "QuickLook")
    static let gridIdentifier = NSToolbarItem.Identifier("preview.grid")
    static let fullScreenIdentifier = NSToolbarItem.Identifier("preview.fullScreen")
    static let openWithIdentifier = NSToolbarItem.Identifier("preview.openWith")
    static let shareIdentifier = NSToolbarItem.Identifier("preview.share")
    /// How long a window may take to leave full screen before it goes anyway (logged).
    private static let fullScreenExitTimeout: Duration = .seconds(5)
    /// Controllers whose window is leaving full screen before it goes: kept alive until it has.
    private static var leavingFullScreen: [PreviewWindowController] = []

    weak var delegate: (any PreviewWindowControllerDelegate)?
    private let previewView: QLPreviewView
    /// The index sheet; hidden in the single view.
    let gridView: PreviewGridView
    /// The items and the one shown.
    let pager = PreviewPager<PreviewItem>()
    /// The single view or the index sheet.
    private(set) var mode: PreviewNavigation.Mode = .single
    /// Between `show` and `hide`. Not `isVisible`: the window hides while Lutik is inactive and
    /// comes back with it, and is still open meanwhile.
    private(set) var isOpen = false
    /// The window has a frame of its own: autosaved, or placed over the archive window once.
    private var isPlaced = false
    /// The archive window the preview opened over: main again once full screen ends.
    private weak var parentWindow: NSWindow?
    private weak var openWithItem: NSMenuToolbarItem?
    private weak var shareItem: NSToolbarItem?
    /// The Share button, which the share picker shows under.
    private weak var shareButton: NSButton?
    /// Share was clicked and its copy is being made: a second click waits for it.
    private var isPreparingShare = false
    private weak var gridItem: NSToolbarItem?
    private weak var fullScreenItem: NSToolbarItem?
    /// Where the window is between windowed and full screen.
    private var fullScreenPhase = FullScreenPhase.windowed
    /// What runs once the window has left full screen (`leaveFullScreen`).
    private var afterFullScreenExit: [@MainActor () -> Void] = []
    /// The timeout of the exit `afterFullScreenExit` waits for; cancelled once that exit is done.
    private var exitTimeout: Task<Void, Never>?

    private enum FullScreenPhase {
        case windowed, entering, fullScreen, exiting
    }

    var items: [PreviewItem] { pager.items }
    /// The index in `items` of the item shown (or selected in the index sheet).
    var index: Int { pager.index }
    var currentItem: PreviewItem? { pager.current }
    /// The type of the item the single view shows (`PreviewItem.contentType`); nil in the index sheet.
    var shownContentType: UTType? { mode == .single ? currentItem?.contentType : nil }
    /// Full screen, or on the way in or out.
    var isFullScreen: Bool {
        fullScreenPhase != .windowed || window?.styleMask.contains(.fullScreen) == true
    }

    init() {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        let window = PreviewWindow(contentRect: frame,
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: true)
        // Floating above the archive windows, as the system panel is (`windowTraits`).
        window.applyTraits(PreviewNavigation.windowTraits(isFullScreen: false))
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 240)
        window.toolbarStyle = .unified
        window.setAccessibilityIdentifier("preview")
        let content = NSView(frame: frame)
        previewView = QLPreviewView(frame: frame, style: .normal) ?? QLPreviewView(frame: frame)
        // The view lives as long as this controller, across many previews; closed in `tearDown`.
        previewView.shouldCloseWithWindow = false
        previewView.autoresizingMask = [.width, .height]
        gridView = PreviewGridView(frame: frame)
        gridView.autoresizingMask = [.width, .height]
        gridView.isHidden = true
        content.addSubview(previewView)
        content.addSubview(gridView)
        window.contentView = content
        super.init(window: window)
        window.delegate = self
        window.handleKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }
        window.didAskToEnterFullScreen = { [weak self] in self?.checkFullScreenStarted() }
        pager.onChange = { [weak self] in self?.update() }
        gridView.onPick = { [weak self] index in self?.pick(index) }

        // An identifier of its own: toolbars that share one are a family, and AppKit copies every
        // insert and remove (by index) to the rest. Each preview window adds and removes its
        // index-sheet button for its own items (`updateGridItem`), so a shared identifier put the
        // button in other archive windows' previews, removed the wrong item from a toolbar whose
        // controller had gone, and in the end asserted on an index past its items.
        let toolbar = NSToolbar(identifier: "KernirPreview-\(UUID().uuidString)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        if let name = Self.autosaveName(Self.frameAutosaveName, disabled: LaunchOverrides.previewFrameAutosaveDisabled) {
            isPlaced = window.setFrameUsingName(name)
            windowFrameAutosaveName = name
        }
    }

    /// The autosave name for a new preview window: `name`, but none when the UI tests turned
    /// autosaving off (`-KernirPreviewFrameAutosave NO`), so it opens over the archive window.
    nonisolated static func autosaveName(_ name: String?, disabled: Bool) -> String? {
        disabled ? nil : name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Showing

    /// Shows `items` from `index` on: the window opens (and becomes key) if it isn't open yet,
    /// over `parent` the first time; an open one shows the new items in place.
    func show(_ items: [PreviewItem], at index: Int, over parent: NSWindow?) {
        if let parent { parentWindow = parent }
        pager.replace(with: items, at: index)
        guard !isOpen, let window else { return }
        isOpen = true
        if !isPlaced, let parent {
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                          y: parent.frame.midY - window.frame.height / 2))
            isPlaced = true
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window without asking anyone: the preview ended. The next preview opens in the
    /// single view. In full screen the window leaves it first and goes once it has.
    func hide() {
        isOpen = false
        // No items: `update` puts the single view back (the next preview opens in it).
        pager.replace(with: [], at: 0)
        previewView.previewItem = nil
        gridView.clear()
        leaveFullScreen { [weak self] in
            // Shown again meanwhile: it stays.
            guard let self, !self.isOpen else { return }
            self.window?.orderOut(nil)
        }
    }

    /// The archive window closed: the view lets go of its preview for good, and the window goes
    /// (after leaving full screen, if it was).
    func tearDown() {
        delegate = nil
        hide()
        leaveFullScreen { [self] in
            previewView.close()
            window?.close()
        }
    }

    /// Shows the current item (or, in the index sheet, selects it), and the title and buttons for it.
    private func update() {
        let fitting = PreviewNavigation.mode(mode, forItemCount: items.count)
        if fitting != mode {
            // One item left: no index sheet. `setMode` comes back here.
            setMode(fitting)
            return
        }
        updateGridItem()
        guard let item = currentItem else {
            previewView.previewItem = nil
            updateButtons()
            return
        }
        switch mode {
        case .single:
            // The same file again (the rest of a render arrived): no reload, so no flicker.
            if (previewView.previewItem as? PreviewItem)?.url != item.url {
                previewView.previewItem = item
            }
            window?.title = pager.title(\.title) ?? item.title
        case .grid:
            gridView.show(items, selected: index)
            window?.title = PreviewNavigation.gridTitle(count: items.count)
        }
        updateButtons()
    }

    /// Open With and Share for the item shown. Both wait for no operation to run
    /// (`previewWindowCanOpen`, `previewWindowCanShare`), so the source calls this again whenever
    /// one starts or ends, not only when the item changes.
    func updateButtons() {
        guard let item = currentItem else {
            openWithItem?.isEnabled = false
            openWithItem?.toolTip = nil
            setShareEnabled(false)
            return
        }
        let canOpen = delegate?.previewWindowCanOpen(item) ?? false
        openWithItem?.isEnabled = canOpen
        openWithItem?.toolTip = canOpen ? defaultApp(for: item).map {
            String(localized: "Open with \(PreviewNavigation.appName($0))")
        } : nil
        setShareEnabled(!isPreparingShare && delegate?.previewWindowCanShare(item) == true)
    }

    // MARK: - Index sheet

    /// Shows the single view or the index sheet; the sheet only for more than one item.
    func setMode(_ requested: PreviewNavigation.Mode) {
        let newMode = PreviewNavigation.mode(requested, forItemCount: items.count)
        guard newMode != mode else { return }
        mode = newMode
        let isGrid = newMode == .grid
        gridView.isHidden = !isGrid
        previewView.isHidden = isGrid
        if isGrid {
            // Nothing plays or renders behind the sheet; the item loads again when picked.
            previewView.previewItem = nil
            window?.makeFirstResponder(gridView.collectionView)
        } else {
            gridView.stopThumbnails()
            window?.makeFirstResponder(previewView)
        }
        update()
    }

    /// The toolbar's index-sheet button.
    @objc func toggleGrid(_ sender: Any?) {
        setMode(mode == .grid ? .single : .grid)
    }

    /// Shows the item at `index` in the single view: a click, Return or Space in the index sheet.
    func pick(_ index: Int) {
        guard items.indices.contains(index) else { return }
        pager.index = index
        setMode(.single)
    }

    /// The index-sheet button is in the toolbar only for more than one item, and shows whether
    /// the sheet is up. (Removed rather than hidden: `NSToolbarItem.isHidden` needs macOS 15.)
    /// Only this window's toolbar changes: its identifier is its own (`init`).
    private func updateGridItem() {
        guard let toolbar = window?.toolbar else { return }
        let offered = PreviewNavigation.offersGrid(count: items.count)
        let present = toolbar.items.firstIndex { $0.itemIdentifier == Self.gridIdentifier }
        if offered, present == nil {
            let after = toolbar.items.firstIndex { $0.itemIdentifier == .flexibleSpace }.map { $0 + 1 } ?? 0
            toolbar.insertItem(withItemIdentifier: Self.gridIdentifier, at: after)
        } else if !offered, let present {
            toolbar.removeItem(at: present)
        }
        let label = String(localized: "Index Sheet")
        gridItem?.image = NSImage(systemSymbolName: mode == .grid ? "square.grid.2x2.fill" : "square.grid.2x2",
                                  accessibilityDescription: label)
    }

    // MARK: - Keys

    /// Returns whether the key was handled; the rest go to the views (scrolling, say).
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let command = PreviewNavigation.command(keyCode: event.keyCode, modifierFlags: event.modifierFlags,
                                                      mode: mode, isFullScreen: isFullScreen)
        else { return false }
        return perform(command)
    }

    /// Does what a key asks for; false leaves the key to the views.
    @discardableResult
    func perform(_ command: PreviewNavigation.Command) -> Bool {
        switch command {
        case .close:
            delegate?.previewWindowDidRequestClose()
        case .moveSelection(let step):
            delegate?.previewWindowMoveSelection(by: step)
        case .page(let step):
            // A single item leaves ←/→ to the view.
            guard items.count > 1 else { return false }
            pager.page(by: step)
        case .exitFullScreen:
            leaveFullScreen {}
        case .showSingle:
            setMode(.single)
        case .gridMove(let move):
            if let next = PreviewNavigation.gridIndex(from: index, moving: move, columns: gridView.columns,
                                                      count: items.count) {
                pager.index = next
            }
        case .openSelected:
            pick(index)
        }
        return true
    }

    /// Pages by `step` items, as ←/→ do; for tests.
    func page(by step: Int) {
        perform(.page(step))
    }

    // MARK: - Full screen

    /// The toolbar's full-screen button.
    @objc func toggleFullScreenFromToolbar(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    /// The window asked AppKit to enter full screen and took its full-screen traits for it. If
    /// AppKit started no transition (during another Space's transition, say), no willEnter or
    /// didFailToEnter follows, and the windowed preview could become main and take the archive
    /// window's menu commands. So on the next turn of the run loop a window still windowed takes
    /// its windowed traits back, and the archive window is main again.
    private func checkFullScreenStarted() {
        Task { @MainActor [weak self] in
            guard let self, self.fullScreenPhase == .windowed, let window = self.window as? PreviewWindow,
                  !window.styleMask.contains(.fullScreen) else { return }
            window.applyTraits(PreviewNavigation.windowTraits(isFullScreen: false))
            if window.isMainWindow, let parentWindow = self.parentWindow, parentWindow.isVisible, self.isOpen {
                parentWindow.makeMain()
            }
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        fullScreenPhase = .entering
        (window as? PreviewWindow)?.applyTraits(PreviewNavigation.windowTraits(isFullScreen: true))
        updateFullScreenItem()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenPhase = .fullScreen
        updateFullScreenItem()
        // Asked to go while it was still entering: it leaves now.
        if !afterFullScreenExit.isEmpty { window?.toggleFullScreen(nil) }
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenPhase = .windowed
        (window as? PreviewWindow)?.applyTraits(PreviewNavigation.windowTraits(isFullScreen: false))
        updateFullScreenItem()
        finishLeavingFullScreen()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        fullScreenPhase = .exiting
        updateFullScreenItem()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenPhase = .windowed
        (window as? PreviewWindow)?.applyTraits(PreviewNavigation.windowTraits(isFullScreen: false))
        updateFullScreenItem()
        // The window was main in its Space; out of it the archive window is main again, so its
        // menu commands work while the preview is key, as before full screen.
        if window?.isMainWindow == true, let parentWindow, parentWindow.isVisible, isOpen {
            parentWindow.makeMain()
        }
        finishLeavingFullScreen()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        fullScreenPhase = window.styleMask.contains(.fullScreen) ? .fullScreen : .windowed
        updateFullScreenItem()
        // Not an error: it happens when the archive window closes with the preview in full screen, and the
        // fallback below closes the preview anyway, so no empty Space is left.
        Self.log.notice("The preview window failed to leave full screen")
        finishLeavingFullScreen()
    }

    /// Runs `action` once the window is out of full screen: at once if it isn't in it (or isn't
    /// on screen), else after it has left, which this asks for. Until then the controller stays
    /// alive, and the window stays on screen, so its Space closes with the usual animation
    /// instead of being left empty. If leaving takes too long, `action` runs anyway (logged).
    func leaveFullScreen(then action: @escaping @MainActor () -> Void) {
        guard let window, window.isVisible, isFullScreen else {
            action()
            return
        }
        afterFullScreenExit.append(action)
        guard afterFullScreenExit.count == 1 else { return }
        Self.leavingFullScreen.append(self)
        // Entering: `windowDidEnterFullScreen` asks to leave; exiting: it is already on its way.
        if fullScreenPhase == .fullScreen || (fullScreenPhase == .windowed && window.styleMask.contains(.fullScreen)) {
            window.toggleFullScreen(nil)
        }
        // This exit's timer only: `finishLeavingFullScreen` cancels it, so a timer left from an
        // earlier exit never ends a later one mid-animation.
        exitTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.fullScreenExitTimeout)
            guard !Task.isCancelled, let self, !self.afterFullScreenExit.isEmpty else { return }
            Self.log.error("The preview window didn't leave full screen in time; closing it anyway")
            self.finishLeavingFullScreen()
        }
    }

    private func finishLeavingFullScreen() {
        exitTimeout?.cancel()
        exitTimeout = nil
        let actions = afterFullScreenExit
        afterFullScreenExit = []
        Self.leavingFullScreen.removeAll { $0 === self }
        for action in actions { action() }
    }

    /// The full-screen button reads as the View menu's item does: "Enter Full Screen" windowed,
    /// "Exit Full Screen" in full screen. It turns as the transition starts (`windowWillEnter…`,
    /// `windowWillExit…`), the way AppKit's own menu item reads during it.
    private func updateFullScreenItem() {
        let entering: Bool
        switch fullScreenPhase {
        case .entering, .fullScreen: entering = false
        case .exiting: entering = true
        case .windowed: entering = !(window?.styleMask.contains(.fullScreen) ?? false)
        }
        let label = entering ? String(localized: "Enter Full Screen") : String(localized: "Exit Full Screen")
        fullScreenItem?.label = label
        fullScreenItem?.paletteLabel = label
        fullScreenItem?.toolTip = label
        fullScreenItem?.image = NSImage(
            systemSymbolName: entering ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
            accessibilityDescription: label)
    }

    // MARK: - Closing

    /// The close button or ⌘W in full screen: the window leaves full screen first, then closes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.isVisible, isFullScreen else { return true }
        leaveFullScreen { [weak self] in self?.window?.close() }
        return false
    }

    /// The close button or ⌘W; never `hide()`, which only orders the window out.
    func windowWillClose(_ notification: Notification) {
        guard isOpen else { return }
        isOpen = false
        delegate?.previewWindowDidRequestClose()
    }

    // MARK: - Toolbar

    /// The title on the left, the buttons on the right. The index-sheet button goes first, for a
    /// multi-selection only (`updateGridItem`).
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.fullScreenIdentifier, Self.openWithIdentifier, Self.shareIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.gridIdentifier] + toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.gridIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            let label = String(localized: "Index Sheet")
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.image = NSImage(systemSymbolName: mode == .grid ? "square.grid.2x2.fill" : "square.grid.2x2",
                                 accessibilityDescription: label)
            item.isBordered = true
            item.autovalidates = false
            item.target = self
            item.action = #selector(toggleGrid(_:))
            gridItem = item
            return item
        case Self.fullScreenIdentifier:
            // Its label, tool tip and image: `updateFullScreenItem`.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.isBordered = true
            item.autovalidates = false
            item.target = self
            item.action = #selector(toggleFullScreenFromToolbar(_:))
            fullScreenItem = item
            updateFullScreenItem()
            return item
        case Self.openWithIdentifier:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            let label = String(localized: "Open With")
            item.label = label
            item.paletteLabel = label
            item.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: label)
            item.showsIndicator = true
            item.autovalidates = false
            // The button opens in the default app; its menu lists every app that can open the file.
            item.target = self
            item.action = #selector(openInDefaultApp(_:))
            let menu = NSMenu(title: label)
            menu.delegate = self
            item.menu = menu
            openWithItem = item
            return item
        case Self.shareIdentifier:
            // A button of our own, not NSSharingServicePickerToolbarItem: that one asks for its
            // items synchronously, and the entry may have to be extracted again first.
            let item = NSToolbarItem(itemIdentifier: identifier)
            let label = String(localized: "Share")
            item.label = label
            item.paletteLabel = label
            item.toolTip = label
            item.autovalidates = false
            let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: label)
                                  ?? NSImage(), target: self, action: #selector(share(_:)))
            button.bezelStyle = .toolbar
            button.setAccessibilityLabel(label)
            button.setAccessibilityIdentifier(identifier.rawValue)
            item.view = button
            shareItem = item
            shareButton = button
            return item
        default:
            return nil
        }
    }

    // MARK: - Share

    /// The Share item and its button (a view item's button keeps its own state).
    private func setShareEnabled(_ isEnabled: Bool) {
        shareItem?.isEnabled = isEnabled
        shareButton?.isEnabled = isEnabled
    }

    /// Share: a copy of the entry is made now (never the stand-in), then the system's share
    /// picker shows it under the button. If no copy can be made, a beep (the source logs why)
    /// instead of an empty picker. Nothing shows if the preview moved on or closed meanwhile.
    @objc private func share(_ sender: Any?) {
        guard let item = currentItem, let delegate, !isPreparingShare else { return }
        guard delegate.previewWindowCanShare(item) else {
            refuse()
            return
        }
        isPreparingShare = true
        setShareEnabled(false)
        Task { @MainActor [weak self] in
            let files = await delegate.previewWindowShareItems(for: item)
            guard let self else { return }
            self.isPreparingShare = false
            self.updateButtons()
            guard self.isOpen, self.currentItem?.entry == item.entry, let button = self.shareButton, button.window != nil
            else { return }
            guard !files.isEmpty else {
                NSSound.beep()
                return
            }
            NSSharingServicePicker(items: files).show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Open With

    private func defaultApp(for item: PreviewItem) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: item.entry.url)
    }

    /// The apps for the Open With menu, the default first (`PreviewNavigation.openWithApps`).
    func openWithApps(for item: PreviewItem) -> (apps: [URL], defaultApp: URL?) {
        let defaultApp = defaultApp(for: item)
        let apps = PreviewNavigation.openWithApps(NSWorkspace.shared.urlsForApplications(toOpen: item.entry.url),
                                                  defaultApp: defaultApp, name: PreviewNavigation.appName)
        return (apps, defaultApp)
    }

    /// Built each time the menu opens, for the item shown then.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let item = currentItem, delegate?.previewWindowCanOpen(item) == true else { return }
        let (apps, defaultApp) = openWithApps(for: item)
        for app in apps {
            let name = PreviewNavigation.appName(app)
            let isDefault = app == defaultApp
            let menuItem = NSMenuItem(title: isDefault ? String(localized: "\(name) (default)") : name,
                                      action: #selector(openWithApp(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            menuItem.image = icon
            menu.addItem(menuItem)
            if isDefault, apps.count > 1 { menu.addItem(.separator()) }
        }
    }

    @objc private func openInDefaultApp(_ sender: Any?) {
        guard let item = currentItem, delegate?.previewWindowCanOpen(item) == true else {
            refuse()
            return
        }
        delegate?.previewWindowOpen(item, withApplicationAt: nil)
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let item = currentItem, let app = sender.representedObject as? URL,
              delegate?.previewWindowCanOpen(item) == true else {
            refuse()
            return
        }
        delegate?.previewWindowOpen(item, withApplicationAt: app)
    }

    /// A click on Open With or Share that can't act (an operation started since the buttons were
    /// last updated): a beep, as Share gives when it has nothing to share, and the buttons catch up.
    private func refuse() {
        NSSound.beep()
        updateButtons()
    }
}

/// The preview window: keys go to `handleKeyDown` before any view (the preview view would scroll
/// with the arrows, the index sheet would move on its own). Out of full screen it never becomes
/// the main window, as the system panel didn't: the archive window stays main while the preview
/// is key, so its menu commands (File > Quick Look, Edit) still reach it. `PreviewWindowSource`
/// doesn't rely on that: another main window ends the preview only when it isn't this one. In
/// full screen it may become main (`PreviewNavigation.windowTraits`): a full-screen window is the
/// main window of its Space.
final class PreviewWindow: NSWindow {
    var handleKeyDown: (@MainActor (NSEvent) -> Bool)?
    /// Runs right after `toggleFullScreen` asked AppKit to enter full screen.
    var didAskToEnterFullScreen: (@MainActor () -> Void)?
    private var allowsMain = false

    override var canBecomeMain: Bool { allowsMain }
    override var canBecomeKey: Bool { true }

    func applyTraits(_ traits: PreviewNavigation.WindowTraits) {
        level = traits.level
        hidesOnDeactivate = traits.hidesOnDeactivate
        allowsMain = traits.canBecomeMain
    }

    /// The toolbar button, ⌃⌘F and the green button all come here: entering, the window takes its
    /// full-screen traits before AppKit looks at it (a floating window that can't become main
    /// may not get a Space of its own); `windowWillEnterFullScreen` sets them again. Then
    /// `didAskToEnterFullScreen` runs, so the controller can take them back if AppKit started no
    /// transition.
    override func toggleFullScreen(_ sender: Any?) {
        let entering = !styleMask.contains(.fullScreen)
        if entering {
            applyTraits(PreviewNavigation.windowTraits(isFullScreen: true))
        }
        super.toggleFullScreen(sender)
        if entering { didAskToEnterFullScreen?() }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil, handleKeyDown?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}
