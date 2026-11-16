import AppKit
import SwiftUI

/// The Name cell's field while its item is renamed, as in Finder: it takes focus with the name selected up to
/// its extension (`EntryNameValidation.editableLength`); Return commits, Esc cancels, and leaving it (a click
/// elsewhere, another window) commits.
struct RenameField: View {
    let name: String
    let isDirectory: Bool
    /// False when the name can't be taken yet (a save runs): the field stays, focused again once the save
    /// ends, and Return commits again.
    let commit: (String) -> Bool
    let cancel: () -> Void
    /// The archive window: the preselection only touches its own field editor.
    private weak var window: NSWindow?
    /// Its state: a commit refused while a save runs takes the focus back once the save ends.
    private let state: ArchiveWindowState

    @State private var text: String
    @FocusState private var isFocused: Bool
    /// Committed or cancelled: the focus loss that follows ends nothing again.
    @State private var isDone = false
    /// A commit was refused (a save runs; its sheet took the focus): the field asks for the focus again when
    /// the save ends, or it would stay unfocused with the rename still on.
    @State private var isWaitingForSave = false

    init(name: String, isDirectory: Bool, window: NSWindow?, state: ArchiveWindowState,
         commit: @escaping (String) -> Bool, cancel: @escaping () -> Void) {
        self.name = name
        self.isDirectory = isDirectory
        self.window = window
        self.state = state
        self.commit = commit
        self.cancel = cancel
        _text = State(initialValue: name)
    }

    var body: some View {
        TextField("Name", text: $text)
            .labelsHidden()
            .accessibilityLabel(Text("Name"))
            .focused($isFocused)
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onKeyPress(.escape) {
                finish(commit: false)
                return .handled
            }
            .onAppear {
                isFocused = true
                // Shown from File > Rename, the request can be lost while the menu closes, and the typing then
                // goes to the table (RenameUITests): ask once more on the next turn.
                Task { @MainActor in
                    if !isDone, !isFocused { isFocused = true }
                }
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    selectBaseName()
                } else {
                    finish(commit: true)
                }
            }
            .onChange(of: state.progress == nil) { _, isIdle in
                guard isIdle, isWaitingForSave, !isDone else { return }
                isWaitingForSave = false
                isFocused = true
                // The sheet may still be closing: ask once more on the next turn, as on appear.
                Task { @MainActor in
                    if !isDone, !isFocused { isFocused = true }
                }
            }
            .onDisappear { finish(commit: true) }
    }

    private func finish(commit shouldCommit: Bool) {
        guard !isDone else { return }
        isDone = true
        // The name as it was commits nothing: a field torn down after its item moved (a folder above it
        // renamed meanwhile) must not commit for the old path.
        if shouldCommit, text != name {
            if !commit(text) {
                isDone = false
                isWaitingForSave = true
            }
        } else {
            cancel()
        }
    }

    /// SwiftUI selects the whole name on focus; once it has, select the part before the extension. The field
    /// editor is the archive window's first responder (no text-selection API for `TextField` on macOS 14); never
    /// another text view, such as the search field's, that happens to hold the same text.
    private func selectBaseName() {
        let length = EntryNameValidation.editableLength(of: name, isDirectory: isDirectory)
        Task { @MainActor [window] in
            guard let window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  editor.window === window, editor.string == name else { return }
            editor.setSelectedRange(NSRange(location: 0, length: length))
        }
    }
}
