import KernirCore
import SwiftUI

/// More > Text Encoding…: how the archive's undeclared names are read. A plain item that
/// opens `TextEncodingSheet`, not a submenu: a submenu can't show itself off. Off
/// when no name is stored in a code page, with unsaved changes, and while something else runs
/// (`ScreenState.canChooseNameEncoding`).
struct TextEncodingButton: View {
    let state: ScreenState
    @Binding var isPresented: Bool

    var body: some View {
        Button("Text Encoding…", systemImage: "textformat") {
            isPresented = true
        }
        .disabled(!state.canChooseNameEncoding)
    }
}

/// Text Encoding's choices: Automatic, then the `ArchiveNameEncoding.choices` titled by
/// `ArchiveNameEncoding.title(of:)`, as in the Mac's View > Text Encoding. Not the system's
/// `String.localizedName(of:)`: on iOS it is "" for every non-Unicode encoding, which left rows
/// 3-12 blank. The checked row is the encoding requested. A tap chooses and closes
/// the sheet; the archive is read again once it has gone (the progress sheet can't come up over it).
struct TextEncodingSheet: View {
    /// The encoding requested now: its row is checked.
    let current: ArchiveNameEncoding
    /// `ScreenState.canChooseNameEncoding`: the rows are off otherwise.
    let isEnabled: Bool
    let onChoose: (ArchiveNameEncoding) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(.automatic, title: String(localized: "Automatic", table: "Shared",
                                                  comment: "View > Text Encoding: decode names automatically"))
                }
                Section {
                    ForEach(ArchiveNameEncoding.choices, id: \.rawValue) { encoding in
                        row(.specific(encoding), title: ArchiveNameEncoding.title(of: encoding))
                    }
                }
            }
            .disabled(!isEnabled)
            .navigationTitle(String(localized: "Text Encoding", table: "Shared",
                                    comment: "View menu: the submenu choosing how archive file names are decoded"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    /// One choice: its title, and a checkmark when it is the current one (read as selected). No
    /// colours of its own: the List's button style draws the row in the tint, here the label colour
    /// (a choice, not an action), and `.disabled` dims the title and the checkmark the system way.
    private func row(_ encoding: ArchiveNameEncoding, title: String) -> some View {
        let isCurrent = encoding == current
        return Button {
            onChoose(encoding)
        } label: {
            HStack {
                Text(verbatim: title)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .tint(Color.primary)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Presents `TextEncodingSheet` while `isPresented`. A tap on a row closes the sheet; once it has
/// gone, the archive is read again with that encoding under the progress sheet, which can't come up
/// while this sheet is still going away (`chooseNameEncoding` checks it may still start).
struct TextEncodingSheetPresenter: ViewModifier {
    let state: ScreenState
    @Binding var isPresented: Bool
    /// The encoding a tap chose, read again with once the sheet has gone.
    @State private var chosen: ArchiveNameEncoding?

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: chooseOnDismiss) {
            TextEncodingSheet(current: state.nameEncoding, isEnabled: state.canChooseNameEncoding,
                              onChoose: { encoding in
                                  chosen = encoding
                                  isPresented = false
                              },
                              onCancel: {
                                  chosen = nil
                                  isPresented = false
                              })
        }
    }

    private func chooseOnDismiss() {
        guard let encoding = chosen else { return }
        chosen = nil
        state.chooseNameEncoding(encoding)
    }
}
