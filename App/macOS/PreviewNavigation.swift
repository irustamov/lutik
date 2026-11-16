import AppKit
import Observation
import UniformTypeIdentifiers

/// The preview window's rules that need no window: which keys it handles, its
/// title, paging through a multi-selection, the index sheet (a grid of the items) and full screen,
/// and the order of its Open With menu.
enum PreviewNavigation {
    /// What a key typed into the preview window does.
    enum Key: Equatable {
        /// ↓ (+1) or ↑ (-1): selects the next or previous row in the archive window's table; the
        /// preview follows the selection, as in Finder.
        case move(Int)
        /// → (+1) or ← (-1): shows the next or previous item of a multi-selection.
        case page(Int)
        /// Space or Esc: closes the preview.
        case close
    }

    /// The preview window's key for `keyCode`; nil for any other key, or with a modifier. Arrow
    /// keys always carry the function and numeric-pad flags, and Caps Lock doesn't count.
    static func key(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Key? {
        guard isUnmodified(modifierFlags) else { return nil }
        switch keyCode {
        case 125: return .move(1)   // kVK_DownArrow
        case 126: return .move(-1)  // kVK_UpArrow
        case 123: return .page(-1)  // kVK_LeftArrow
        case 124: return .page(1)   // kVK_RightArrow
        case 49, 53: return .close  // kVK_Space, kVK_Escape
        default: return nil
        }
    }

    /// No modifier held: arrow keys always carry the function and numeric-pad flags, keypad keys
    /// the numeric-pad flag, and Caps Lock doesn't count.
    private static func isUnmodified(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock]).isEmpty
    }

    // MARK: - Modes

    /// What the window shows: one item, or the index sheet (a grid of all of them).
    enum Mode: Equatable {
        case single
        case grid
    }

    /// A move in the index sheet.
    enum GridMove: Equatable {
        case left, right, up, down
    }

    /// What a key does in the preview window, given what it shows and whether it is full screen.
    enum Command: Equatable {
        /// The preview ends (Space or Esc in the single view).
        case close
        /// ↑/↓ in the single view: the archive window's selection moves.
        case moveSelection(Int)
        /// ←/→ in the single view: the next or previous item of a multi-selection.
        case page(Int)
        /// Esc in full screen: the window leaves full screen, and nothing else happens.
        case exitFullScreen
        /// Esc in the index sheet: back to the single view of the selected item.
        case showSingle
        /// An arrow key in the index sheet.
        case gridMove(GridMove)
        /// Space, Return or Enter in the index sheet: the selected item in the single view.
        case openSelected
    }

    /// The window's command for a key; nil for keys it leaves to its views. Esc undoes one thing
    /// at a time: full screen first, then the index sheet, then the preview itself.
    static func command(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, mode: Mode,
                        isFullScreen: Bool) -> Command? {
        guard let key = key(keyCode: keyCode, modifierFlags: modifierFlags) else {
            // Return (36) and keypad Enter (76) open the index sheet's item; nothing in the single view.
            guard mode == .grid, keyCode == 36 || keyCode == 76, isUnmodified(modifierFlags) else { return nil }
            return .openSelected
        }
        let isEscape = keyCode == 53
        if isEscape && isFullScreen { return .exitFullScreen }
        switch (mode, key) {
        case (.single, .move(let step)): return .moveSelection(step)
        case (.single, .page(let step)): return .page(step)
        case (.single, .close): return .close
        case (.grid, .move(let step)): return .gridMove(step > 0 ? .down : .up)
        case (.grid, .page(let step)): return .gridMove(step > 0 ? .right : .left)
        case (.grid, .close): return isEscape ? .showSingle : .openSelected
        }
    }

    /// Whether the window offers the index sheet: only for more than one item.
    static func offersGrid(count: Int) -> Bool {
        count > 1
    }

    /// The mode once the window shows `count` items: the index sheet goes when there is only one
    /// item left (or none).
    static func mode(_ mode: Mode, forItemCount count: Int) -> Mode {
        offersGrid(count: count) ? mode : .single
    }

    /// The item an arrow key selects in an index sheet of `count` items in rows of `columns`; nil
    /// when nothing moves. ←/→ step through the items in order, across rows; ↑/↓ move a row, and
    /// ↓ into a shorter last row lands on its last item, as in Finder.
    static func gridIndex(from index: Int, moving move: GridMove, columns: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard (0..<count).contains(index) else { return 0 }
        let columns = max(1, columns)
        let target: Int
        switch move {
        case .left: target = index - 1
        case .right: target = index + 1
        case .up: target = index - columns
        case .down:
            guard index / columns < (count - 1) / columns else { return nil }
            target = min(index + columns, count - 1)
        }
        return (0..<count).contains(target) ? target : nil
    }

    /// The window title over the index sheet: "5 items".
    static func gridTitle(count: Int) -> String {
        String(localized: "\(count) items")
    }

    /// The type whose icon stands for an item in the index sheet until (or unless) its thumbnail
    /// comes: by the entry's real name, so a stand-in never shows as text or an image.
    static func iconType(forName name: String, isDirectory: Bool) -> UTType {
        if isDirectory { return .folder }
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty else { return .data }
        return UTType(filenameExtension: pathExtension) ?? .data
    }

    // MARK: - Full screen

    /// How the window behaves in and out of full screen.
    struct WindowTraits: Equatable {
        /// Floating above the archive windows, as the system panel did; normal in full screen,
        /// where a floating window takes no Space of its own.
        let level: NSWindow.Level
        /// Hides while Lutik is inactive; never in full screen, where hiding would strand an
        /// empty Space.
        let hidesOnDeactivate: Bool
        /// Never main out of full screen, so the archive window keeps its menu commands; a full
        /// screen window has to become main in its Space.
        let canBecomeMain: Bool
    }

    static func windowTraits(isFullScreen: Bool) -> WindowTraits {
        isFullScreen
            ? WindowTraits(level: .normal, hidesOnDeactivate: false, canBecomeMain: true)
            : WindowTraits(level: .floating, hidesOnDeactivate: true, canBecomeMain: false)
    }

    /// The item `step` items from `index` in a preview of `count` items; nil past either end (no
    /// wrapping, as in the system panel).
    static func page(from index: Int, by step: Int, count: Int) -> Int? {
        let target = index + step
        return (0..<count).contains(target) ? target : nil
    }

    /// The window title: the entry's real name, and "2 of 5" for a multi-selection.
    static func title(name: String, index: Int, count: Int) -> String {
        guard count > 1 else { return name }
        return String(localized: "\(name) — \(index + 1) of \(count)")
    }

    /// The Open With menu's apps: the default app first, then the rest by name, each once (an
    /// app that can open the file but isn't in `apps` still leads when it's the default).
    static func openWithApps(_ apps: [URL], defaultApp: URL?, name: (URL) -> String) -> [URL] {
        func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        var seen = Set<String>()
        var result: [URL] = []
        if let defaultApp {
            seen.insert(key(defaultApp))
            result.append(defaultApp)
        }
        let rest = apps.filter { seen.insert(key($0)).inserted }
            .map { (url: $0, name: name($0)) }
            .sorted { a, b in
                switch a.name.localizedStandardCompare(b.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: key(a.url) < key(b.url)
                }
            }
        return result + rest.map(\.url)
    }

    /// An app's name as Finder shows it, without ".app".
    static func appName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

/// What the preview window shows: its items, and which one. The window's view, its title and
/// ←/→ all go through here, and so can an index grid of the items (a later view sets `index`).
/// `onChange` tells the window to show the item the index now names.
@MainActor @Observable
final class PreviewPager<Item> {
    private(set) var items: [Item] = []
    private var shownIndex = 0
    /// The shown item's index in `items`; 0 when there are none. Out-of-range values are ignored.
    var index: Int {
        get { shownIndex }
        set {
            guard newValue != shownIndex, items.indices.contains(newValue) else { return }
            shownIndex = newValue
            onChange?()
        }
    }
    /// Called after `items` or `index` changed.
    @ObservationIgnored var onChange: (() -> Void)?

    init() {}

    var current: Item? {
        items.indices.contains(index) ? items[index] : nil
    }

    /// Shows `items` from `index` on (the first item if `index` isn't one of them).
    func replace(with items: [Item], at index: Int) {
        self.items = items
        shownIndex = items.indices.contains(index) ? index : 0
        onChange?()
    }

    /// Moves `step` items on (→ +1, ← -1); false, and nothing moves, past either end.
    @discardableResult
    func page(by step: Int) -> Bool {
        guard let next = PreviewNavigation.page(from: index, by: step, count: items.count) else { return false }
        index = next
        return true
    }

    /// The window title for the shown item, named by `name`; nil with no items.
    func title(_ name: (Item) -> String) -> String? {
        current.map { PreviewNavigation.title(name: name($0), index: index, count: items.count) }
    }
}
