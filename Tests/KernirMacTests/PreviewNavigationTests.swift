import AppKit
import Testing
@testable import Kernir

/// The preview window's rules that need no window: keys, paging, the title
/// and the order of the Open With menu.
@MainActor
struct PreviewNavigationTests {
    /// What arrow keys always carry.
    private let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]

    @Test("↑/↓ move the selection, ←/→ page, Space and Esc close")
    func keys() {
        #expect(PreviewNavigation.key(keyCode: 125, modifierFlags: arrowFlags) == .move(1))
        #expect(PreviewNavigation.key(keyCode: 126, modifierFlags: arrowFlags) == .move(-1))
        #expect(PreviewNavigation.key(keyCode: 124, modifierFlags: arrowFlags) == .page(1))
        #expect(PreviewNavigation.key(keyCode: 123, modifierFlags: arrowFlags) == .page(-1))
        #expect(PreviewNavigation.key(keyCode: 49, modifierFlags: []) == .close)
        #expect(PreviewNavigation.key(keyCode: 53, modifierFlags: []) == .close)
        #expect(PreviewNavigation.key(keyCode: 124, modifierFlags: arrowFlags.union(.capsLock)) == .page(1))
        #expect(PreviewNavigation.key(keyCode: 49, modifierFlags: .capsLock) == .close)
    }

    @Test("Modified keys and other keys are left alone (⌘W, ⇧Space, ⌥→…)")
    func otherKeys() {
        for modifier: NSEvent.ModifierFlags in [.shift, .control, .option, .command] {
            for keyCode: UInt16 in [123, 124, 125, 126, 49, 53] {
                #expect(PreviewNavigation.key(keyCode: keyCode, modifierFlags: arrowFlags.union(modifier)) == nil)
            }
        }
        for keyCode: UInt16 in [0, 13, 36, 48, 51, 116, 121] {  // a, w, Return, Tab, Delete, Page Up/Down
            #expect(PreviewNavigation.key(keyCode: keyCode, modifierFlags: []) == nil)
        }
    }

    @Test("The archive window's ↑/↓ step agrees with the preview window's keys")
    func previewStepAgrees() {
        #expect(ArchiveActions.previewStep(keyCode: 125, modifierFlags: arrowFlags) == 1)
        #expect(ArchiveActions.previewStep(keyCode: 126, modifierFlags: arrowFlags) == -1)
        #expect(ArchiveActions.previewStep(keyCode: 124, modifierFlags: arrowFlags) == nil)
        #expect(ArchiveActions.previewStep(keyCode: 49, modifierFlags: []) == nil)
    }

    @Test("Paging stops at either end")
    func page() {
        #expect(PreviewNavigation.page(from: 0, by: 1, count: 3) == 1)
        #expect(PreviewNavigation.page(from: 2, by: 1, count: 3) == nil)
        #expect(PreviewNavigation.page(from: 0, by: -1, count: 3) == nil)
        #expect(PreviewNavigation.page(from: 2, by: -1, count: 3) == 1)
        #expect(PreviewNavigation.page(from: 0, by: 1, count: 1) == nil)
        #expect(PreviewNavigation.page(from: 0, by: 1, count: 0) == nil)
    }

    @Test("The title is the entry's name, with \"2 of 5\" for a multi-selection")
    func title() {
        #expect(PreviewNavigation.title(name: "Budget.csv", index: 0, count: 1) == "Budget.csv")
        #expect(PreviewNavigation.title(name: "Budget.csv", index: 1, count: 5) == "Budget.csv — 2 of 5")
        #expect(PreviewNavigation.title(name: "Deck.pptx", index: 4, count: 5) == "Deck.pptx — 5 of 5")
    }

    @Test("Open With lists the default app first, then the rest by name, each once")
    func openWithOrder() {
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        let numbers = URL(fileURLWithPath: "/Applications/Numbers.app")
        let names = [preview: "Preview", textEdit: "TextEdit", xcode: "Xcode", numbers: "Numbers"]
        let name = { (url: URL) in names[url] ?? url.lastPathComponent }

        #expect(PreviewNavigation.openWithApps([xcode, textEdit, numbers, preview], defaultApp: textEdit, name: name)
                == [textEdit, numbers, preview, xcode])
        // Duplicates (and a differently spelled path to the same app) appear once.
        let textEditAgain = URL(fileURLWithPath: "/System/Applications/../Applications/TextEdit.app")
        #expect(PreviewNavigation.openWithApps([textEdit, xcode, textEditAgain, xcode], defaultApp: nil, name: name)
                == [textEdit, xcode])
        // The default leads even when the list misses it.
        #expect(PreviewNavigation.openWithApps([xcode], defaultApp: preview, name: name) == [preview, xcode])
        #expect(PreviewNavigation.openWithApps([], defaultApp: nil, name: name).isEmpty)
        // Names compare as Finder does: "Numbers 2" after "Numbers", case aside.
        let numbers2 = URL(fileURLWithPath: "/Applications/Numbers 2.app")
        let lower = URL(fileURLWithPath: "/Applications/numbers old.app")
        let byName = { (url: URL) in url.deletingPathExtension().lastPathComponent }
        #expect(PreviewNavigation.openWithApps([numbers2, lower, numbers], defaultApp: nil, name: byName)
                == [numbers, numbers2, lower])
    }

    @Test("An app's name has no .app")
    func appName() {
        let name = PreviewNavigation.appName(URL(fileURLWithPath: "/System/Applications/TextEdit.app"))
        #expect(!name.hasSuffix(".app"))
        #expect(!name.isEmpty)
    }

    // MARK: - Pager (what an index grid will read and set)

    @Test("The pager pages, clamps and tells the window")
    func pager() {
        let pager = PreviewPager<String>()
        var changes = 0
        pager.onChange = { changes += 1 }
        #expect(pager.current == nil)
        #expect(pager.title { $0 } == nil)

        pager.replace(with: ["a", "b", "c"], at: 1)
        #expect(pager.current == "b")
        #expect(pager.title { $0 } == "b — 2 of 3")
        #expect(changes == 1)

        #expect(pager.page(by: 1))
        #expect(pager.current == "c")
        #expect(!pager.page(by: 1))
        #expect(pager.current == "c")
        #expect(changes == 2)

        // A grid sets the index; out of range is ignored.
        pager.index = 0
        #expect(pager.current == "a")
        pager.index = 7
        #expect(pager.current == "a")
        pager.index = -1
        #expect(pager.current == "a")
        #expect(changes == 3)

        // New items at the same index still tell the window; an index they lack starts at the top.
        pager.replace(with: ["x"], at: 0)
        #expect(pager.current == "x")
        #expect(changes == 4)
        pager.replace(with: ["p", "q"], at: 5)
        #expect(pager.current == "p")
        #expect(pager.title { $0 } == "p — 1 of 2")
        #expect(changes == 5)

        pager.replace(with: [], at: 0)
        #expect(pager.current == nil)
        #expect(changes == 6)
    }

    // MARK: - Index sheet and full screen

    private func command(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], _ mode: PreviewNavigation.Mode,
                         fullScreen: Bool = false) -> PreviewNavigation.Command? {
        PreviewNavigation.command(keyCode: keyCode, modifierFlags: flags, mode: mode, isFullScreen: fullScreen)
    }

    @Test("Single view: ↑/↓ move the selection, ←/→ page, Space and Esc close; Return does nothing")
    func singleViewCommands() {
        #expect(command(125, arrowFlags, .single) == .moveSelection(1))
        #expect(command(126, arrowFlags, .single) == .moveSelection(-1))
        #expect(command(124, arrowFlags, .single) == .page(1))
        #expect(command(123, arrowFlags, .single) == .page(-1))
        #expect(command(49, [], .single) == .close)
        #expect(command(53, [], .single) == .close)
        #expect(command(36, [], .single) == nil)
        #expect(command(76, .numericPad, .single) == nil)
    }

    @Test("Index sheet: arrows move in the grid, Space/Return/Enter open the item, Esc goes back")
    func gridCommands() {
        #expect(command(123, arrowFlags, .grid) == .gridMove(.left))
        #expect(command(124, arrowFlags, .grid) == .gridMove(.right))
        #expect(command(126, arrowFlags, .grid) == .gridMove(.up))
        #expect(command(125, arrowFlags, .grid) == .gridMove(.down))
        #expect(command(49, [], .grid) == .openSelected)
        #expect(command(36, [], .grid) == .openSelected)
        #expect(command(76, .numericPad, .grid) == .openSelected)
        #expect(command(36, .capsLock, .grid) == .openSelected)
        #expect(command(53, [], .grid) == .showSingle)
        for modifier: NSEvent.ModifierFlags in [.shift, .control, .option, .command] {
            for keyCode: UInt16 in [36, 76, 49, 53, 123, 124, 125, 126] {
                #expect(command(keyCode, arrowFlags.union(modifier), .grid) == nil)
            }
        }
        #expect(command(0, [], .grid) == nil)
    }

    @Test("Esc undoes one thing at a time: full screen, then the index sheet, then the preview")
    func escapeOrder() {
        #expect(command(53, [], .grid, fullScreen: true) == .exitFullScreen)
        #expect(command(53, [], .grid) == .showSingle)
        #expect(command(53, [], .single, fullScreen: true) == .exitFullScreen)
        #expect(command(53, [], .single) == .close)
        // Space isn't Esc: in full screen it still closes (the window leaves full screen as it goes).
        #expect(command(49, [], .single, fullScreen: true) == .close)
        #expect(command(49, [], .grid, fullScreen: true) == .openSelected)
        #expect(command(124, arrowFlags, .single, fullScreen: true) == .page(1))
    }

    @Test("The index sheet is offered for more than one item, and goes when one is left")
    func gridOffer() {
        #expect(!PreviewNavigation.offersGrid(count: 0))
        #expect(!PreviewNavigation.offersGrid(count: 1))
        #expect(PreviewNavigation.offersGrid(count: 2))
        #expect(PreviewNavigation.mode(.grid, forItemCount: 5) == .grid)
        #expect(PreviewNavigation.mode(.grid, forItemCount: 1) == .single)
        #expect(PreviewNavigation.mode(.grid, forItemCount: 0) == .single)
        #expect(PreviewNavigation.mode(.single, forItemCount: 5) == .single)
    }

    @Test("Arrow keys in the index sheet: across rows with ←/→, a row with ↑/↓, no wrapping off either end")
    func gridMoves() {
        // 7 items in rows of 3:  0 1 2 / 3 4 5 / 6
        func move(_ index: Int, _ direction: PreviewNavigation.GridMove, columns: Int = 3, count: Int = 7) -> Int? {
            PreviewNavigation.gridIndex(from: index, moving: direction, columns: columns, count: count)
        }
        #expect(move(0, .right) == 1)
        #expect(move(2, .right) == 3, "→ at a row's end goes on to the next row")
        #expect(move(3, .left) == 2)
        #expect(move(0, .left) == nil)
        #expect(move(6, .right) == nil)
        #expect(move(1, .down) == 4)
        #expect(move(4, .down) == 6, "↓ into a shorter last row lands on its last item")
        #expect(move(5, .down) == 6)
        #expect(move(6, .down) == nil)
        #expect(move(4, .up) == 1)
        #expect(move(1, .up) == nil)
        #expect(move(6, .up) == 3)
        // One column, a row per item; zero columns count as one.
        #expect(move(0, .down, columns: 1, count: 3) == 1)
        #expect(move(2, .down, columns: 1, count: 3) == nil)
        #expect(move(1, .up, columns: 0, count: 3) == 0)
        // Nothing to move in, or a stale index: the first item.
        #expect(move(0, .right, count: 0) == nil)
        #expect(move(9, .left) == 0)
    }

    @Test("The title over the index sheet counts the items")
    func gridTitle() {
        #expect(PreviewNavigation.gridTitle(count: 5) == "5 items")
        #expect(PreviewNavigation.gridTitle(count: 12) == "12 items")
    }

    @Test("An index-sheet item without a thumbnail shows the icon of its real name's type")
    func iconType() {
        #expect(PreviewNavigation.iconType(forName: "Budget.csv", isDirectory: false) == .commaSeparatedText)
        #expect(PreviewNavigation.iconType(forName: "Pixel.png", isDirectory: false) == .png)
        #expect(PreviewNavigation.iconType(forName: "docs", isDirectory: true) == .folder)
        #expect(PreviewNavigation.iconType(forName: "photos.png", isDirectory: true) == .folder)
        #expect(PreviewNavigation.iconType(forName: "README", isDirectory: false) == .data)
        #expect(PreviewNavigation.iconType(forName: ".hidden", isDirectory: false) == .data)
    }

    @Test("Full screen: normal level, never hidden on deactivation, may become main; floating otherwise")
    func windowTraits() {
        let full = PreviewNavigation.windowTraits(isFullScreen: true)
        #expect(full.level == .normal)
        #expect(!full.hidesOnDeactivate)
        #expect(full.canBecomeMain)
        let windowed = PreviewNavigation.windowTraits(isFullScreen: false)
        #expect(windowed.level == .floating)
        #expect(windowed.hidesOnDeactivate)
        #expect(!windowed.canBecomeMain)
    }
}
