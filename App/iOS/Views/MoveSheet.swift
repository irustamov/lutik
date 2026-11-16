import SwiftUI

/// Move…'s sheet: the archive's folders, nested, under the archive's own row (the top
/// level). A folder that can't take the items (one of them, beneath one, or where they all already are)
/// can't be picked; Move Here moves into the picked one.
struct MoveSheet: View {
    let state: ScreenState
    let request: MoveRequest
    @State private var target: String?

    var body: some View {
        NavigationStack {
            List(selection: $target) {
                row(name: state.name, path: "", systemImage: "doc.zipper")
                OutlineGroup(state.moveFolders(), children: \.children) { folder in
                    row(name: folder.name, path: folder.path, systemImage: "folder")
                }
            }
            .navigationTitle("Move To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { state.cancelMove() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move Here") {
                        if let target { state.confirmMove(into: target) }
                    }
                    .disabled(!canMove(into: target))
                }
            }
        }
    }

    private func canMove(into folder: String?) -> Bool {
        guard let folder else { return false }
        return state.canMove(request.paths, into: folder)
    }

    private func row(name: String, path: String, systemImage: String) -> some View {
        let takes = canMove(into: path)
        return Label(name, systemImage: systemImage)
            .foregroundStyle(takes ? .primary : .secondary)
            .tag(Optional(path))
            .selectionDisabled(!takes)
            .accessibilityIdentifier("move-target:" + path)
    }
}
