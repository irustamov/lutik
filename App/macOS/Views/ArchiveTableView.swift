import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The archive's items as a sortable outline table: Name, Size, Kind, Date Modified.
struct ArchiveTableView: View {
    /// Filtered and sorted by the window.
    let items: [ArchiveItem]
    @Bindable var state: ArchiveWindowState
    let actions: ArchiveActions

    var body: some View {
        Table(of: ArchiveItem.self, selection: $state.selection, sortOrder: $state.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    FileIcon(item: item)
                    if state.renamingPath == item.path {
                        RenameField(name: item.name, isDirectory: item.isDirectory, window: actions.window,
                                    state: state, commit: { actions.commitRename($0, of: item.path) },
                                    cancel: { actions.cancelRename(item.path) })
                    } else {
                        Text(item.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .width(min: 160, ideal: 300)

            TableColumn("Size", value: \.sizeSortKey) { item in
                Text(verbatim: Self.sizeText(item.size))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel(Self.spokenSize(item.size))
            }
            .width(min: 60, ideal: 80)

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Date Modified", value: \.dateSortKey) { item in
                Text(KernirFormat.date(item.modificationDate))
                    .lineLimit(1)
            }
            .width(min: 100, ideal: 170)
        } rows: {
            ArchiveTableRows(items: items, state: state, actions: actions)
        }
        // Rows drag out as file promises, through the Table's own AppKit table view. The rows are the
        // `items` handed to the Table above, not the live model: a change the table hasn't shown yet
        // (a rename landing mid-drag) must not move a row onto another file. The open folders are
        // taken here too, with the items, not read when the drag starts: a reopen's job may
        // set them before the table redraws. A new `items` or `expanded` comes with new rows,
        // through the representable's update.
        // Assumed: SwiftUI updates the Table's outline and this background in the same
        // pass, so the rows never lag or lead the outline. The row count and level check
        // (`ArchiveTableDragSelection`) can't see an order-only change (a sort flip, a search swap
        // with as many rows); the hosted `aSortOrSearchChangeInTheDragsTurnBringsTheShownFile`
        // pins the premise.
        .background(ArchiveTableDragSource(
            rows: ArchiveTableDragSelection.rowsTaken(of: items, expanded: state.expanded),
            writer: { [actions] path, drop in actions.dragWriter(for: path, drop: drop) },
            canDrop: { [actions] in actions.canAdd },
            drop: { [actions] urls, directory in actions.addDropped(urls, to: directory) },
            moveToken: actions.moveToken,
            isFolder: { [actions] path in actions.isFolder(path) },
            canMove: { [actions] paths, folder in actions.canMove(paths, into: folder) },
            move: { [actions] paths, folder in actions.move(paths, into: folder) },
            canCopyIn: { [actions] paths, token, folder in actions.canCopyIn(paths, fromMoveToken: token, into: folder) },
            copyIn: { [actions] paths, token, folder in actions.copyIn(paths, fromMoveToken: token, into: folder) }))
        // nil disables Edit > Delete, which SwiftUI validates before the window controller can. A name
        // field's Delete key deletes text, never rows. Under a sheet `removeSelection` deletes nothing
        // (`ArchiveActions.hasNoSheet`).
        .onDeleteCommand(perform: actions.canRemoveSelection && state.renamingPath == nil
                         ? { actions.removeSelection() } : nil)
        // ⌘V: SwiftUI claims paste:, as Delete's; the validator's nil disables the menu item.
        // ⌘C / ⌘X are the window controller's (`ArchiveWindowController.copySelection(_:)`), not
        // `onCopyCommand` / `onCutCommand`: SwiftUI empties the pasteboard for their result before the Copy's
        // export ends.
        .onPasteCommand(of: [.fileURL, UTType(exportedAs: ArchiveClipboard.typeIdentifier)],
                        validator: { _ in actions.canPaste && state.renamingPath == nil ? () : nil },
                        perform: { (_: Void) in actions.paste() })
        .contextMenu(forSelectionType: String.self) { paths in
            // Rename on one row, New Folder in a folder row or on empty space; neither where Add isn't.
            if paths.isEmpty, actions.canAdd {
                Button("New Folder") { actions.newFolder(in: "") }
                    .disabled(!actions.canNewFolder)
            }
            if !paths.isEmpty {
                // Open With and Share, also in a read-only archive: neither changes it.
                let rowMenu = actions.rowMenu(for: paths)
                Button("Quick Look") { actions.quickLook(paths) }
                    .disabled(!actions.canOpen(paths))
                Button("Open") { actions.open(paths) }
                    .disabled(!actions.canOpen(paths))
                if rowMenu.showsOpenWith {
                    OpenWithMenu(menu: rowMenu, actions: actions)
                }
                Button("Extract…") {
                    actions.extract(paths, nextToArchive: NSEvent.modifierFlags.contains(.option))
                }
                .disabled(!actions.canExtract)
                // The picker shows at the menu's first row, found among the rows the table shows now.
                Button("Share…") {
                    actions.share(rowMenu.sharePaths,
                                  rows: ArchiveTableDragSelection.rowsTaken(of: items, expanded: state.expanded))
                }
                .disabled(!rowMenu.canShare)
                // Copy (and Paste into a folder row) next to Share, as Finder groups them.
                ArchiveClipboardMenuItems(paths: paths, actions: actions, leadingDivider: false)
                Divider()
                if actions.canAdd, paths.count == 1, let path = paths.first {
                    Button("Rename") { actions.beginRename(path) }
                        .disabled(!actions.canRename(paths))
                    if actions.isFolder(path) {
                        Button("New Folder") { actions.newFolder(in: path) }
                            .disabled(!actions.canNewFolder)
                    }
                }
                // Shown, like Delete, where it can't run (read-only, a job or a sheet up, nowhere to go): disabled.
                Button("Move To…") { actions.beginMoveTo(paths) }
                    .disabled(!actions.canMoveTo(paths))
                Button("Delete") { actions.remove(paths) }
                    .disabled(!actions.canRemove(paths))
            }
            // Paste on empty space; on rows Copy/Paste sit next to Share… above.
            if paths.isEmpty {
                ArchiveClipboardMenuItems(paths: paths, actions: actions)
            }
        } primaryAction: { paths in
            actions.open(paths)
        }
        // Return renames the one selected row, as in Finder; double-click and ⌘↓ open. While a
        // name field is showing, Return and Space are its own.
        .onKeyPress(.return) {
            guard state.renamingPath == nil, actions.canRename, state.selection.count == 1,
                  let path = state.selection.first else { return .ignored }
            // After this key event: the field shown during it never got focus, the table kept it (RenameUITests
            // run 2), while File > Rename and the context menu, outside a key event, focus it. The row selected
            // at the Return, and only while it still is: a key queued behind it may move the selection first.
            DispatchQueue.main.async {
                if state.selection == [path] { actions.beginRename(path) }
            }
            return .handled
        }
        .onKeyPress(.space) {
            guard state.renamingPath == nil, actions.canToggleQuickLook else { return .ignored }
            actions.toggleQuickLook()
            return .handled
        }
        // An open preview follows the selection, and ↑/↓ in the preview window move it, as in Finder.
        .onChange(of: state.selection) {
            actions.selectionDidChange()
        }
        // Files dropped on the table, between rows or on a file row go to the top level: here while no
        // row has a drop destination (no folders), else through the drag-out hook, as the table is
        // then the drag's destination (`ArchiveTableDragSource`).
        .dropDestination(for: URL.self) { urls, _ in
            actions.addDropped(urls, to: "")
        }
    }

    /// The Size column's text: "--" when the size is unknown, as in Finder.
    static func sizeText(_ size: Int64?) -> String {
        size.map(KernirFormat.size) ?? "--"
    }

    /// What VoiceOver reads for the Size column: words, not "--".
    static func spokenSize(_ size: Int64?) -> String {
        size.map(KernirFormat.size) ?? String(localized: "Unknown size")
    }
}

/// The row menu's Open With submenu, as Finder's: the default app, a separator, the other apps that open the
/// files (each with its icon), then Other…. Disabled while an operation runs (`ArchiveRowMenu`).
private struct OpenWithMenu: View {
    let menu: ArchiveRowMenu
    let actions: ArchiveActions

    var body: some View {
        Menu("Open With") {
            if let app = menu.defaultApp {
                appButton(app, title: String(localized: "\(PreviewNavigation.appName(app)) (default)"))
                if menu.showsSeparatorAfterDefault { Divider() }
            }
            ForEach(menu.otherApps, id: \.self) { app in
                appButton(app, title: PreviewNavigation.appName(app))
            }
            if !menu.apps.isEmpty { Divider() }
            Button("Other…") { actions.chooseAppToOpen(menu.openWithPaths) }
        }
        .disabled(!menu.canOpen)
    }

    private func appButton(_ app: URL, title: String) -> some View {
        Button {
            actions.open(menu.openWithPaths, withApplicationAt: app)
        } label: {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(nsImage: ArchiveRowMenu.icon(for: app))
            }
            .labelStyle(.titleAndIcon)
        }
    }
}

/// Rows for one level of the tree; folders recurse into their children.
private struct ArchiveTableRows: TableRowContent {
    typealias TableRowValue = ArchiveItem

    let items: [ArchiveItem]
    let state: ArchiveWindowState
    let actions: ArchiveActions

    // Each row carries an empty item provider only to pass SwiftUI's drag gate: its table lets a row
    // drag only when the row has a drag modifier of SwiftUI's own (`canDragRowsWithIndexes:atPoint:`).
    // The drag's real writers, file promises, come from `ArchiveTableDragSource`'s hook; while the
    // table's data source is hooked it answers the writer message itself, so this provider's contents
    // never reach the pasteboard.
    var tableRowBody: some TableRowContent<ArchiveItem> {
        ForEach(items) { item in
            if let children = item.children {
                DisclosureTableRow(item, isExpanded: isExpanded(item)) {
                    ArchiveTableRows(items: children, state: state, actions: actions)
                }
                .dropDestination(for: URL.self) { urls in
                    actions.addDropped(urls, to: item.path)
                }
                // A gate only: keep this provider empty; filling it would open a second write path.
                .itemProvider { NSItemProvider() }
            } else {
                TableRow(item)
                    // A gate only: keep this provider empty; filling it would open a second write path.
                    .itemProvider { NSItemProvider() }
            }
        }
    }

    private func isExpanded(_ item: ArchiveItem) -> Binding<Bool> {
        Binding(
            get: { state.expanded.contains(item.id) },
            set: { isExpanded in
                if isExpanded {
                    state.expanded.insert(item.id)
                } else {
                    state.expanded.remove(item.id)
                }
            }
        )
    }
}
