import SwiftUI
import UIKit

/// The archive's Info sheet (the bar's Info, File > Get Info ⌘I): Format, Size, Items and Encryption, and for a
/// ZIP the archive comment, as the Mac's Info popover shows them. A writable comment is edited in place: the
/// typing is one undo step ("Edit Comment") that marks the document changed and goes with its Save; Done or a
/// swipe down ends it (`ScreenState.closeInfo`). The comment is read-only while a save writes the archive.
struct ArchiveInfoSheet: View {
    let state: ScreenState

    var body: some View {
        NavigationStack {
            Form {
                if let model = state.model {
                    Section {
                        ForEach(model.infoSummary.rows, id: \.label) { row in
                            LabeledContent(row.label, value: row.value)
                        }
                    }
                    if state.showsComment {
                        Section("Comment") {
                            CommentTextView(text: model.commentText, isEditable: state.canEditCommentNow,
                                            onChange: { state.setComment($0) },
                                            onEndEditing: { model.endCommentTyping() })
                            if state.canEditCommentNow, let problem = model.commentProblem {
                                Text(problem)
                                    .foregroundStyle(.red)
                            }
                            if let note = state.commentReadOnlyNote {
                                Text(note)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { state.closeInfo() }
                }
            }
            // On open and after each save, also one that lands while the size loads (that result is dropped).
            .task(id: state.model?.snapshotGeneration) {
                if let model = state.model, model.infoFileSize == nil { await model.loadInfoFileSize() }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The comment field: a stock text view, monospaced (comments are often ASCII art), scrolling past about 12
/// lines. Editable, or selectable only. A text view rather than `TextEditor` for its undo manager: the field's
/// own "Typing" undo would otherwise go to the document's undo manager (the sheet's responder chain leads to
/// it) and mix with the model's "Edit Comment" step, which already covers the typing. So typing registers no
/// undo of its own, as on the Mac (`windowWillReturnUndoManager`): Undo in the open sheet does nothing, and the
/// bar's Undo after it closes takes the typing back.
private struct CommentTextView: UIViewRepresentable {
    let text: String
    let isEditable: Bool
    let onChange: (String) -> Void
    let onEndEditing: () -> Void

    private static let minimumLines: CGFloat = 4
    private static let maximumLines: CGFloat = 12

    func makeUIView(context: Context) -> NoUndoTextView {
        let view = NoUndoTextView()
        // Body's size at the default text size (17 pt), scaled for Dynamic Type.
        view.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: UIFont.monospacedSystemFont(ofSize: 17, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // Comments are often ASCII art: nothing rewrites what is typed.
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.dataDetectorTypes = []
        view.accessibilityLabel = String(localized: "Comment")
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: NoUndoTextView, context: Context) {
        context.coordinator.parent = self
        if view.isEditable != isEditable { view.isEditable = isEditable }
        // Not while a word is being composed (marked text): setting the text would end the composition.
        if view.text != text, view.markedTextRange == nil { view.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NoUndoTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let lineHeight = uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fitting, lineHeight * Self.minimumLines), lineHeight * Self.maximumLines)
        return CGSize(width: width, height: height.rounded(.up))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CommentTextView

        init(parent: CommentTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            // A composition in progress reports again once it is committed.
            guard textView.markedTextRange == nil else { return }
            parent.onChange(textView.text)
        }

        /// A word still being composed is committed as editing ends, which may not report a change: it is taken
        /// in here, into the typing's undo step, before that step ends.
        func textViewDidEndEditing(_ textView: UITextView) {
            if textView.text != parent.text { parent.onChange(textView.text) }
            parent.onEndEditing()
        }
    }
}

/// A text view whose edits register no undo (see `CommentTextView`).
private final class NoUndoTextView: UITextView {
    private let disabledUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override var undoManager: UndoManager? { disabledUndoManager }
}
