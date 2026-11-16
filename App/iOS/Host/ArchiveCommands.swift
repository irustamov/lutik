import UIKit

/// The archive's keyboard commands, which are also menu bar items on iPadOS 26 and in the ⌘-hold
/// overlay before. Only commands the system lacks are added: Undo ⌘Z, Redo ⇧⌘Z, Select All ⌘A
/// and Find ⌘F are stock, and so is Close ⌘W on iPadOS 26 (`performClose(_:)`).
/// `ArchiveNavigationController` performs and validates them all.
@MainActor enum ArchiveCommands {
    /// Save ⌘S: there is no stock Save on iOS.
    static var save: UIKeyCommand {
        UIKeyCommand(title: String(localized: "Save",
                                              comment: "Save the changes made to the archive: the Save menu command (⌘S), the trailing toolbar button and the confirm button of the save options sheet in Save a Copy. Verb."),
                     action: #selector(ArchiveNavigationController.saveArchive(_:)),
                     input: "s", modifierFlags: .command)
    }

    /// Delete ⌘⌫, as in Files. Never a plain ⌫, which belongs to the search field.
    static var delete: UIKeyCommand {
        UIKeyCommand(title: String(localized: "Delete",
                                              comment: "Remove the selected items from the archive: the Delete menu command (⌘⌫) and the Delete buttons of the item's menu and the toolbar. Verb. Not a permanent delete: it can be undone."),
                     action: #selector(UIResponderStandardEditActions.delete(_:)),
                     input: "\u{8}", modifierFlags: .command)
    }

    /// Get Info ⌘I, as in Finder and the Mac app: the Info sheet. ⌘I is the stock Format > Italic,
    /// so the Format menu goes (`build`): nothing in an archive window has formatted text, and the
    /// Mac app has no Format menu either.
    static var getInfo: UIKeyCommand {
        UIKeyCommand(title: String(localized: "Get Info"),
                     action: #selector(ArchiveNavigationController.getInfo(_:)),
                     input: "i", modifierFlags: .command)
    }

    /// New Folder ⇧⌘N, as in Files and Finder: in the folder on screen.
    static var newFolder: UIKeyCommand {
        UIKeyCommand(title: String(localized: "New Folder"),
                     action: #selector(ArchiveNavigationController.newFolder(_:)),
                     input: "n", modifierFlags: [.command, .shift])
    }

    /// Rename, with no key: the one item selected in Select mode, validated as Delete is. Its own action,
    /// not the stock `rename(_:)`, which renames the document from its title menu.
    static var rename: UICommand {
        UICommand(title: String(localized: "Rename"),
                  action: #selector(ArchiveNavigationController.renameItem(_:)))
    }

    /// The system menus `build` takes out.
    static let removedMenus: [UIMenu.Identifier] = [.format]

    /// Extract Here ⌥⌘E, the Mac's key: next to the archive, with the same gate as the menus
    /// (`ScreenState.canExtractHere`).
    static var extractHere: UIKeyCommand {
        UIKeyCommand(title: String(localized: "Extract Here"),
                     action: #selector(ArchiveNavigationController.extractHere(_:)),
                     input: "e", modifierFlags: [.command, .alternate])
    }

    /// Close ⌘W before iPadOS 26, which has the stock File > Close instead.
    static var close: UIKeyCommand? {
        if #unavailable(iOS 26.0) {
            return UIKeyCommand(title: String(localized: "Close"),
                                action: #selector(ArchiveNavigationController.closeArchive(_:)),
                                input: "w", modifierFlags: .command)
        }
        return nil
    }

    static var all: [UIKeyCommand] {
        [save, delete, newFolder, getInfo, extractHere] + [close].compactMap { $0 }
    }

    /// iPadOS 26's menu bar with File > New Window (⌘N, the system's `requestNewScene:`), which
    /// the default menu leaves out for this app (iPadOS 26.5 simulator): ⌘N opened no window.
    /// Any configuration also brings in the Document (Duplicate, Move, Rename, Export), Print and
    /// Inspector groups, which the default leaves out: they stay out for parity. The document's
    /// title menu already offers Rename, Move, Duplicate and Export, so the menu bar doesn't
    /// repeat them.
    /// Nil with one window (iPhone): the system's default menu stays.
    @available(iOS 26.0, *)
    static func mainMenuConfiguration(supportsMultipleScenes: Bool) -> UIMainMenuSystem.Configuration? {
        guard supportsMultipleScenes else { return nil }
        let configuration = UIMainMenuSystem.Configuration()
        configuration.newScenePreference = .included
        configuration.documentPreference = .removed
        configuration.printingPreference = .removed
        configuration.inspectorPreference = .removed
        // Format's ⌘I is Get Info here (`getInfo`).
        configuration.textFormattingPreference = .removed
        return configuration
    }

    /// Sets `mainMenuConfiguration` at launch. `buildMenu(with:)` still adds our commands.
    static func configureMainMenu() {
        guard #available(iOS 26.0, *),
              let configuration = mainMenuConfiguration(
                supportsMultipleScenes: UIApplication.shared.supportsMultipleScenes) else { return }
        UIMainMenuSystem.shared.setBuildConfiguration(configuration)
    }

    /// File: Close (before iPadOS 26), Save, Get Info and Extract Here, after the stock Close where
    /// there is one. Edit: Delete with its key, in place of the stock Delete, which has none. No
    /// Format menu (`removedMenus`), which would take ⌘I.
    static func build(_ builder: any UIMenuBuilder) {
        for menu in removedMenus { builder.remove(menu: menu) }
        let file = UIMenu(options: .displayInline,
                          children: [close, save, newFolder, getInfo, rename, extractHere].compactMap { $0 })
        if builder.menu(for: .close) != nil {
            builder.insertSibling(file, afterMenu: .close)
        } else {
            builder.insertChild(file, atEndOfMenu: .file)
        }

        let delete = delete
        builder.replaceChildren(ofMenu: .standardEdit) { children in
            let stockDelete = children.firstIndex { ($0 as? UICommand)?.action == delete.action }
            var children = children
            if let stockDelete {
                children[stockDelete] = delete
            } else {
                children.append(delete)
            }
            return children
        }
    }
}
