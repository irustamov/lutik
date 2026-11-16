import SwiftUI

/// The row menu's Copy and Paste, next to Share… on rows as in Finder, alone on empty space:
/// Copy on rows (the rows under the menu, as its other items), Paste on empty space (the top level) and on a folder row (into it). No Cut item:
/// ⌘X only. What shows and what is enabled: `ArchiveActions.clipboardMenu(for:)`.
struct ArchiveClipboardMenuItems: View {
    let paths: Set<String>
    let actions: ArchiveActions
    /// A divider before the items: on empty space; not on rows, where they follow Share….
    var leadingDivider = true

    var body: some View {
        let menu = actions.clipboardMenu(for: paths)
        if leadingDivider, menu.showsCopy || menu.pasteFolder != nil {
            Divider()
        }
        if menu.showsCopy {
            Button("Copy") { actions.copyItems(paths) }
                .disabled(!menu.canCopy)
        }
        if let folder = menu.pasteFolder {
            Button("Paste") { actions.paste(into: folder) }
                .disabled(!menu.canPaste)
        }
    }
}
