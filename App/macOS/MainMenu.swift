import AppKit
import KernirCore

/// The standard main menu, built in code. Actions go to the responder chain (nil target).
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = MainMenuBar()
        for menu in [appMenu(), fileMenu(), editMenu(), viewMenu(), windowMenu(), helpMenu()] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    // MARK: - Menus

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: appName)
        menu.addItem(item(String(localized: "About \(appName)"),
                          #selector(AppDelegate.showAbout(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Services"))
        let servicesItem = item(String(localized: "Services"), nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Hide \(appName)"), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(String(localized: "Hide Others"),
                          #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit \(appName)"), #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        menu.addItem(item(String(localized: "New"), #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item(String(localized: "Open…"), #selector(NSDocumentController.openDocument(_:)), "o"))
        let recent = NSMenu(title: String(localized: "Open Recent"))
        recent.delegate = RecentDocumentsMenu.shared
        let recentItem = item(String(localized: "Open Recent"), nil)
        recentItem.submenu = recent
        menu.addItem(recentItem)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item(String(localized: "Save",
                    comment: "Save (a verb), in two places: the File menu command (⌘S) that saves the archive, and the default button of the folder panel opened by “Save to Another Folder…” after Finder's “Compress with Lutik” couldn't save the new archive in its folder."), #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item(String(localized: "Save As…"), #selector(NSDocument.saveAs(_:)), "s", [.command, .shift]))
        menu.addItem(item(String(localized: "Revert to Saved"), #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Add Files…"),
                          #selector(ArchiveWindowController.addFiles(_:)), "a", [.command, .shift]))
        menu.addItem(item(String(localized: "New Folder"),
                          #selector(ArchiveWindowController.newFolder(_:)), "n", [.command, .shift]))
        // No key equivalent: Return renames through the table, and would be taken from the name field.
        menu.addItem(item(String(localized: "Rename"), #selector(ArchiveWindowController.rename(_:))))
        menu.addItem(item(String(localized: "Extract…"), #selector(ArchiveWindowController.extract(_:)), "e"))
        menu.addItem(item(String(localized: "Quick Look"),
                          #selector(ArchiveWindowController.toggleQuickLook(_:)), "y"))
        menu.addItem(item(String(localized: "Get Info"), #selector(ArchiveWindowController.showInfo(_:)), "i"))
        // ⌘↓ opens the selected rows, as in Finder. Hidden: a visible "Open" next to "Open…"
        // would confuse; double-click and the context menu are the visible ways.
        let openSelection = item(String(localized: "Open",
                    comment: "Open (a verb), in three places: the default button of the password sheet (opens the encrypted archive), the context-menu item that opens the selected items, and the hidden ⌘↓ command doing the same."), #selector(ArchiveWindowController.openSelection(_:)),
                                 String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)))
        openSelection.isHidden = true
        openSelection.allowsKeyEquivalentWhenHidden = true
        menu.addItem(openSelection)
        return menu
    }

    /// Internal for tests: `make()` also sets `NSApp.servicesMenu`, which tests leave to the host.
    static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        // undo: and redo: are the standard action messages (NSDocument and text views answer
        // them); AppKit's headers just don't declare them.
        menu.addItem(item(String(localized: "Undo"), Selector(("undo:")), "z"))
        menu.addItem(item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        // Cut and Copy go to the archive window, which takes its rows only when they are the target, and to the
        // app delegate when no archive window is key or main; anywhere else they are the standard cut: / copy:
        // (`StandardEditCommand`): SwiftUI's `onCopyCommand` empties the general pasteboard before a
        // Copy's export ends, and a failed Copy would leave it empty.
        menu.addItem(item(String(localized: "Cut"), #selector(ArchiveWindowController.cutSelection(_:)), "x"))
        menu.addItem(item(String(localized: "Copy"), #selector(ArchiveWindowController.copySelection(_:)), "c"))
        menu.addItem(item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"))
        menu.addItem(item(String(localized: "Delete",
                    comment: "Delete (a verb), in three places: the Edit menu command and context-menu item that remove the selected items from the archive, the label of the toolbar's － button doing the same, and a button of the alert about a file saved next to a file opened from the archive, which deletes that saved file."), #selector(ArchiveWindowController.delete(_:)), MainMenuBar.deleteKey))
        menu.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Find"), #selector(ArchiveWindowController.performFind(_:)), "f"))
        return menu
    }

    static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        menu.addItem(item(String(localized: "Show Toolbar"), #selector(NSWindow.toggleToolbarShown(_:)),
                          "t", [.command, .option]))
        menu.addItem(.separator())
        let encodings = textEncodingMenu()
        let encodingsItem = item(encodings.title, nil)
        encodingsItem.submenu = encodings
        menu.addItem(encodingsItem)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)),
                          "f", [.command, .control]))
        return menu
    }

    /// View > Text Encoding: how the archive's undeclared names are read. Automatic,
    /// then each of `ArchiveNameEncoding.choices` under `ArchiveNameEncoding.title(of:)`, the system name in
    /// the Mac's English; each item's `representedObject` is the encoding's `rawValue` as an NSNumber, nil for
    /// Automatic. `ArchiveDocument` validates and handles them.
    static func textEncodingMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Text Encoding", table: "Shared",
                                        comment: "View menu: the submenu choosing how archive file names are decoded"))
        let action = #selector(ArchiveDocument.selectNameEncoding(_:))
        menu.addItem(item(String(localized: "Automatic", table: "Shared",
                                 comment: "View > Text Encoding: decode names automatically"), action))
        menu.addItem(.separator())
        for encoding in ArchiveNameEncoding.choices {
            let encodingItem = item(ArchiveNameEncoding.title(of: encoding), action)
            encodingItem.representedObject = NSNumber(value: encoding.rawValue)
            menu.addItem(encodingItem)
        }
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        // As in Xcode: ⇧⌘1.
        menu.addItem(item(WelcomeFeature.welcomeTitle(appName: AppDisplayName.current),
                          #selector(AppDelegate.showWelcome(_:)), "1", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = menu
        return menu
    }

    private static func helpMenu() -> NSMenu {
        // AppKit adds the Help search field.
        let menu = NSMenu(title: String(localized: "Help"))
        NSApp.helpMenu = menu
        return menu
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }
}

/// Fills File > Open Recent from `NSDocumentController.recentDocumentURLs` each time it opens.
@MainActor
final class RecentDocumentsMenu: NSObject, NSMenuDelegate {
    static let shared = RecentDocumentsMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: url.path),
                                  action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem(title: String(localized: "Clear Menu"),
                                action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                                keyEquivalent: ""))
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error, (error as? CocoaError)?.code != .userCancelled {
                NSApp.presentError(error)
            }
        }
    }
}

/// The main menu bar. It leaves ⌘⌫ to editable text (a name, the search, the comment), where the key deletes
/// to the line start: Edit > Delete has the key for the selected items, and a menu item takes its key even
/// when its target (the field editor, which answers `delete:` itself) disables it at a caret.
@MainActor
final class MainMenuBar: NSMenu {
    /// Edit > Delete's key with Command, as Finder's Move to Trash: the Delete key. A menu item names it
    /// `NSBackspaceCharacter`; `NSDeleteCharacter`, what the key types, would be Forward Delete (⌦) there,
    /// and the keyboard's ⌘⌫ would never reach the item.
    static let deleteKey = String(Character(UnicodeScalar(UInt8(NSBackspaceCharacter))))
    /// What the Delete key types (`NSEvent.charactersIgnoringModifiers`).
    static let deleteCharacter = String(Character(UnicodeScalar(UInt8(NSDeleteCharacter))))

    /// The key window's first responder; tests set their own.
    var keyResponder: @MainActor () -> NSResponder? = { NSApp.keyWindow?.firstResponder }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.charactersIgnoringModifiers == Self.deleteCharacter,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           (keyResponder() as? NSTextView)?.isEditable == true {
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}
