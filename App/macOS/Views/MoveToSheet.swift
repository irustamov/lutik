import SwiftUI

/// Move To…: the archive's folders as an outline under the archive's own row (its top level); Move moves the
/// items into the selected one. Rows the items can't move into are disabled (`MoveToFolders`).
struct MoveToSheet: View {
    let folders: MoveToFolders
    let move: (_ folder: String) -> Void
    let cancel: () -> Void

    @State private var selected: String?
    /// The open folders; the archive's row and every folder above a moved item start open
    /// (`MoveToFolders.initiallyExpanded`), so a sibling folder of the items is in reach at once.
    @State private var expanded: Set<String>

    init(folders: MoveToFolders, move: @escaping (_ folder: String) -> Void, cancel: @escaping () -> Void) {
        self.folders = folders
        self.move = move
        self.cancel = cancel
        _expanded = State(initialValue: folders.initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
            ScrollViewReader { proxy in
                List(selection: $selected) {
                    MoveToFolderRow(folder: folders.root, expanded: $expanded)
                }
                .listStyle(.bordered)
                .frame(minHeight: 240)
                .onAppear {
                    // The open folders above the items can reach below the fold on a big archive: bring the
                    // items' own folder into view (`MoveToFolders.initialScrollTarget`). On the next turn of the
                    // run loop, once the outline has its rows.
                    guard let target = folders.initialScrollTarget else { return }
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Move") {
                    if let selected { move(selected) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.map { !folders.isEnabled($0) } ?? true)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    @ViewBuilder private var heading: some View {
        // The items that move: "docs" with "docs/a.txt" selected too is one item, "docs".
        if let name = folders.singleMovedName {
            Text("Move “\(name)” to:")
        } else {
            Text("Move \(folders.movedCount) items to:")
        }
    }
}

/// One folder's row, and its subfolders' under a disclosure triangle.
private struct MoveToFolderRow: View {
    let folder: MoveToFolders.Folder
    @Binding var expanded: Set<String>

    var body: some View {
        if let children = folder.children {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(children) { child in
                    MoveToFolderRow(folder: child, expanded: $expanded)
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    // In a List, a DisclosureGroup's label is the outline row itself and each of its content views is a child
    // row, so the row's selection value (`tag`) and `selectionDisabled` go on the label: on the group they
    // would not reach the row the List sees. A disabled row is only unselectable and dimmed: `.disabled` would
    // also take the disclosure triangle (and, on the group, the children), and a disabled row, say the folder
    // the items are in now, must still open onto the folders the items can move into.
    private var label: some View {
        Label(folder.name, systemImage: folder.id.isEmpty ? "archivebox" : "folder")
            .foregroundStyle(folder.isEnabled ? HierarchicalShapeStyle.primary : .secondary)
            .tag(folder.id)
            // The scroll id (`initialScrollTarget`): the ForEach's ids name the nested groups, not the outline
            // row, and the root row is in no ForEach.
            .id(folder.id)
            .selectionDisabled(!folder.isEnabled)
            .accessibilityHint(hint)
    }

    /// Why the row can't take the items, for VoiceOver; empty (no hint) when it can, or the reason is not one
    /// to name.
    private var hint: Text {
        switch folder.disabledReason {
        case .alreadyThere: Text("Already in this folder.")
        case .intoItself: Text("Can’t move a folder into itself.")
        case nil: Text(verbatim: "")
        }
    }

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { expanded.contains(folder.id) },
            set: { isExpanded in
                if isExpanded {
                    expanded.insert(folder.id)
                } else {
                    expanded.remove(folder.id)
                }
            }
        )
    }
}
