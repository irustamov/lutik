import Testing
import UIKit
@testable import Kernir

/// The archive's own key commands (`ArchiveCommands`): titled for the menu bar and the ⌘-hold
/// overlay, and never on a key the system's menus already use.
@MainActor @Suite struct ArchiveCommandsTests {
    struct Key: Hashable, CustomStringConvertible {
        var input: String
        var modifiers: UIKeyModifierFlags.RawValue

        init(_ input: String, _ modifiers: UIKeyModifierFlags) {
            self.input = input
            self.modifiers = modifiers.rawValue
        }

        @MainActor init(_ command: UIKeyCommand) {
            self.init(command.input ?? "", command.modifierFlags)
        }

        var description: String { "\(input.debugDescription) \(modifiers)" }
    }

    /// The keys of the system's own menu items, as a menu probe logged them from the built main
    /// menu on the iOS 26.5 simulator. iPhone and iPad have the
    /// same keyed items. iOS 17 and 18 were not observed (no runtime here).
    static var recordedStockKeys: [Key] {
        var keys: [Key] = [
            // Kernir (application)
            Key(",", .command),                   // Settings
            // File
            Key("o", .command),                   // Open
            // Edit
            Key("z", .command),                   // Undo
            Key("z", [.command, .shift]),         // Redo
            Key("x", .command),                   // Cut
            Key("c", .command),                   // Copy
            Key("v", .command),                   // Paste
            Key("v", [.command, .shift, .alternate]), // Paste and Match Style
            Key("a", .command),                   // Select All
            Key("f", .command),                   // Find
            Key("f", [.command, .alternate]),     // Find & Replace
            Key("g", .command),                   // Find Next
            Key("g", [.command, .shift]),         // Find Previous
            Key("e", .command),                   // Use Selection for Find
            // View
            Key("s", [.command, .control]),       // Show Sidebar
            // Help
            Key("?", .command),                   // Kernir Help
        ]
        if #available(iOS 26.0, *) {
            keys.append(Key("w", .command))       // Close (performClose:)
            // New Window (requestNewScene:), where `mainMenuConfiguration` includes it: logged
            // on the iPadOS 26.5 simulator.
            if UIApplication.shared.supportsMultipleScenes {
                keys.append(Key("n", .command))
            }
        }
        return keys
    }

    /// The keys of the system's Format menu, logged with `recordedStockKeys`. `ArchiveCommands.build`
    /// removes that menu, so they are free.
    static let recordedFormatKeys: [Key] = [
        Key("b", .command),                   // Bold
        Key("i", .command),                   // Italic
        Key("u", .command),                   // Underline
        Key("+", .command),                   // Bigger
        Key("-", .command),                   // Smaller
        Key("{", .command),                   // Align Left
        Key("|", .command),                   // Center
        Key("}", .command),                   // Align Right
    ]

    @Test func commandsHaveTitles() {
        #expect(!ArchiveCommands.all.isEmpty)
        for command in ArchiveCommands.all {
            #expect(!command.title.isEmpty, "\(Key(command))")
        }
        #expect(ArchiveCommands.save.title == "Save")
        #expect(ArchiveCommands.delete.title == "Delete")
        #expect(ArchiveCommands.getInfo.title == "Get Info")
    }

    /// Get Info is ⌘I, as in Finder and the Mac app. That is Format > Italic's key, so the Format
    /// menu goes: nothing in an archive window has formatted text.
    @Test func getInfoIsCommandIWithoutFormatMenu() {
        #expect(Key(ArchiveCommands.getInfo) == Key("i", .command))
        #expect(ArchiveCommands.getInfo.action == #selector(ArchiveNavigationController.getInfo(_:)))
        #expect(ArchiveCommands.all.contains { $0.action == ArchiveCommands.getInfo.action })
        #expect(Self.recordedFormatKeys.contains(Key(ArchiveCommands.getInfo)))
        #expect(ArchiveCommands.removedMenus == [.format])
    }

    /// Save is ⌘S and Delete is ⌘⌫ (never a plain ⌫, which the search field needs).
    @Test func saveAndDeleteKeys() {
        #expect(Key(ArchiveCommands.save) == Key("s", .command))
        #expect(ArchiveCommands.save.action == #selector(ArchiveNavigationController.saveArchive(_:)))
        #expect(Key(ArchiveCommands.delete) == Key("\u{8}", .command))
        #expect(ArchiveCommands.delete.action == #selector(UIResponderStandardEditActions.delete(_:)))
    }

    /// Extract Here is ⌥⌘E, as on the Mac, and goes to the navigation controller.
    @Test func extractHereKey() {
        #expect(Key(ArchiveCommands.extractHere) == Key("e", [.command, .alternate]))
        #expect(ArchiveCommands.extractHere.action == #selector(ArchiveNavigationController.extractHere(_:)))
        #expect(ArchiveCommands.extractHere.title == "Extract Here")
        #expect(ArchiveCommands.all.contains { $0.action == ArchiveCommands.extractHere.action })
    }

    @Test func noDuplicateKeys() {
        let ours = ArchiveCommands.all.map(Key.init)
        #expect(Set(ours).count == ours.count, "\(ours)")
        let stock = Set(Self.recordedStockKeys)
        for key in ours {
            #expect(!stock.contains(key), "\(key) is already a system key")
        }
    }

    /// iPadOS 26 has File > Close (⌘W, `performClose(_:)`); before it, ⌘W is ours.
    @Test func closeCommandOnlyBefore26() {
        if #available(iOS 26.0, *) {
            #expect(ArchiveCommands.close == nil)
            #expect(!ArchiveCommands.all.contains { $0.input == "w" })
        } else {
            let close = ArchiveCommands.close
            #expect(close.map(Key.init) == Key("w", .command))
            #expect(close?.title == "Close")
            #expect(close?.action == #selector(ArchiveNavigationController.closeArchive(_:)))
        }
    }

    /// iPadOS 26's menu bar gets File > New Window (⌘N), which the system's default menu leaves
    /// out for this app. Document, Print and Inspector, which a configuration would otherwise
    /// bring in, stay out as in the default menu, and so does text formatting (Format, whose ⌘I
    /// is Get Info here); the other groups stay automatic.
    @Test func mainMenuConfigurationAddsNewWindowOnly() throws {
        guard #available(iOS 26.0, *) else { return }
        let config = try #require(ArchiveCommands.mainMenuConfiguration(supportsMultipleScenes: true))
        #expect(config.newScenePreference == .included)
        #expect(config.documentPreference == .removed)
        #expect(config.printingPreference == .removed)
        #expect(config.inspectorPreference == .removed)
        #expect(config.findingPreference == .automatic)
        #expect(config.toolbarPreference == .automatic)
        #expect(config.sidebarPreference == .automatic)
        #expect(config.textFormattingPreference == .removed)
    }

    /// iPhone has one window: no New Window there, and the menu keeps the system's default.
    @Test func mainMenuUnchangedWithOneWindow() {
        guard #available(iOS 26.0, *) else { return }
        #expect(ArchiveCommands.mainMenuConfiguration(supportsMultipleScenes: false) == nil)
    }
}
