import AppKit
import Testing
@testable import Kernir

/// ⌘↓ opens the selected rows, as in Finder. A hidden File menu item carries the shortcut:
/// menu key equivalents run before the table sees the key, so the outline can't swallow it.
@MainActor
@Test func commandDownArrowOpensSelection() throws {
    let menu = MainMenu.fileMenu()
    let item = try #require(menu.items.first { $0.action == #selector(ArchiveWindowController.openSelection(_:)) })
    let downArrow = try #require(UnicodeScalar(UInt32(NSDownArrowFunctionKey)))
    #expect(item.keyEquivalent == String(Character(downArrow)))
    #expect(item.keyEquivalentModifierMask == .command)
    #expect(item.isHidden)
    #expect(item.allowsKeyEquivalentWhenHidden)
}

/// The Size column shows "--" for an unknown size, as in Finder; VoiceOver says what it means.
@MainActor
@Test func unknownSizeIsSpokenAsWords() {
    #expect(ArchiveTableView.sizeText(nil) == "--")
    #expect(ArchiveTableView.sizeText(2048) == KernirFormat.size(2048))
    #expect(ArchiveTableView.spokenSize(nil) == String(localized: "Unknown size"))
    #expect(ArchiveTableView.spokenSize(2048) == KernirFormat.size(2048))
}
