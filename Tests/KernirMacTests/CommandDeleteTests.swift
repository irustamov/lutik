import AppKit
import Testing
@testable import Kernir

/// ⌘⌫ deletes the selected items, as Finder's Move to Trash, and keeps deleting to
/// the line start in a text field (rename, search, comment). The plain Delete key stays with the outline's
/// `onDeleteCommand`; both run Edit > Delete's rules (`ArchiveActions.canRemoveSelection`).
@MainActor
@Suite struct CommandDeleteTests {
    /// A key-down of ⌫ with `modifiers`, as the keyboard sends it.
    private static func deleteKey(_ modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                      windowNumber: 0, context: nil, characters: "\u{7f}",
                                      charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
    }

    /// Counts the Delete item's action, standing in for the window's responder chain.
    private final class Recorder: NSObject {
        var deletes = 0
        @objc func delete(_ sender: Any?) { deletes += 1 }
    }

    /// The Edit menu on its own: `MainMenu.make()` would also set the test host's `NSApp.servicesMenu`.
    @Test func editMenuDeleteIsCommandDelete() throws {
        let item = try #require(MainMenu.editMenu().items.first { $0.action == #selector(ArchiveWindowController.delete(_:)) })
        // NSBackspaceCharacter: "\u{7f}" would be Forward Delete, which the keyboard's ⌘⌫ never matches.
        #expect(item.keyEquivalent == "\u{8}")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    /// A ⌘⌫ item a synthesized event matches: AppKit matches Edit > Delete's `NSBackspaceCharacter` to the
    /// keyboard's ⌘⌫ only (WindowUITests `testCommandDeleteRemovesRowsButEditsText` covers it), not to an
    /// event made here, so this stands in for it to see what the menu bar lets through.
    private static func addProbe(to menu: NSMenu, target: Recorder) {
        let probe = NSMenuItem(title: "Probe", action: #selector(Recorder.delete(_:)), keyEquivalent: "\u{7f}")
        probe.keyEquivalentModifierMask = .command
        probe.target = target
        menu.addItem(probe)
    }

    /// Outside text, ⌘⌫ goes to the menu; the plain Delete key is the outline's own (`onDeleteCommand`).
    @Test func commandDeleteGoesToTheMenuOutsideText() throws {
        let menu = MainMenuBar()
        let recorder = Recorder()
        Self.addProbe(to: menu, target: recorder)
        menu.keyResponder = { nil }
        #expect(try menu.performKeyEquivalent(with: Self.deleteKey()))
        #expect(recorder.deletes == 1)
        #expect(try !menu.performKeyEquivalent(with: Self.deleteKey([])))
        #expect(recorder.deletes == 1)
    }

    /// In a name or search field ⌘⌫ deletes to the line start, selection or not: the menu leaves the key to the
    /// field. Edit > Delete would delete the selected text at best, and at a caret swallow the key disabled.
    @Test func commandDeleteInATextFieldDeletesToLineStart() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        field.stringValue = "abc def"
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)

        let menu = MainMenuBar()
        let recorder = Recorder()
        Self.addProbe(to: menu, target: recorder)
        menu.keyResponder = { window.firstResponder }
        let commandDelete = try Self.deleteKey()

        editor.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(!menu.performKeyEquivalent(with: commandDelete))
        editor.keyDown(with: commandDelete)
        #expect(editor.string == "ef")

        editor.string = "abc def"
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        #expect(!menu.performKeyEquivalent(with: commandDelete))
        #expect(recorder.deletes == 0)
    }
}
