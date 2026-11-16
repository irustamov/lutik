import AppKit
import SwiftUI

/// The archive Info popover's content: Format, Size, Items, Encryption and, for a ZIP, the
/// archive comment. The comment is monospaced (comments are often ASCII art), selectable and
/// scrolls past about 12 lines. The window hosts it (`ArchiveInfoPopover`) from File > Get Info
/// (⌘I), the toolbar's Info button and the footer's Comment button.
struct ArchiveInfoView: View {
    let summary: ArchiveInfoSummary
    @Binding var comment: String
    /// False hides the comment (formats without one, ZIP only).
    let showsComment: Bool
    /// False shows the comment read-only: selectable text, no editing.
    let canEditComment: Bool
    /// One line under a read-only comment saying why it can't be changed.
    let readOnlyNote: String?
    /// Why the edited comment can't be saved (`ArchiveModel.commentProblem`), shown under the field.
    let commentProblem: String?

    private static let commentFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let lineHeight = NSLayoutManager().defaultLineHeight(for: commentFont)

    var body: some View {
        Form {
            Section {
                ForEach(summary.rows, id: \.label) { row in
                    LabeledContent(row.label, value: row.value)
                }
            }
            .textSelection(.enabled)
            if showsComment {
                Section("Comment") {
                    commentField
                    if canEditComment, let commentProblem {
                        Text(commentProblem)
                            .foregroundStyle(.red)
                    }
                    if !canEditComment, let readOnlyNote {
                        Text(readOnlyNote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Why `model`'s comment shows read-only, or nil when it can be edited (or isn't shown). A split set
    /// can't hold a comment at all; any other comment Lutik can't write back gets the general note.
    static func readOnlyNote(for model: ArchiveModel) -> String? {
        guard model.showsComment, !model.canEditComment else { return nil }
        if (model.reader?.volumeURLs.count ?? 1) > 1 {
            return String(localized: "The comment of a split archive can’t be changed.",
                          comment: "Info popover, under the read-only comment of a split (multi-part) ZIP archive.")
        }
        return String(localized: "This comment can’t be changed in Lutik.",
                      comment: "Info popover, under a read-only archive comment that Lutik can't write back.")
    }

    /// An editor for a writable comment; otherwise selectable text, since a disabled editor
    /// can't be selected or copied from.
    @ViewBuilder private var commentField: some View {
        let font = Font(Self.commentFont)
        if canEditComment {
            // Labelled on its text view (`CommentEditor`), where VoiceOver and UI tests find it.
            CommentEditor(text: $comment, font: Self.commentFont, lines: 4...12)
        } else {
            ScrollView {
                Text(verbatim: comment)
                    .font(font)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.lineHeight * 12)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Comment")
        }
    }
}

/// The editable comment: an AppKit text view, as in `TextEditor`, with its own undo off (`allowsUndo`). The model's
/// "Edit Comment" step on the document's undo manager covers the typing; the text view's "Typing" steps would mix
/// with it. `TextEditor` can't turn that off, and which undo manager it registers on depends on the OS: SwiftUI's
/// coordinator answers the text view's `undoManager(for:)`, on macOS 26.2 with the window's (the undo gate's, while
/// the popover is on screen), on macOS 26.7.3 with the document's.
/// It grows with its text within `lines` (as `TextEditor` did in the grouped form), then scrolls. Insets, line
/// padding and font as `TextEditor`'s text view had them: no inset, the default 5 pt padding, `font`.
private struct CommentEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    /// How many lines the field shows at least, and at most before it scrolls.
    let lines: ClosedRange<Int>

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.allowsUndo = false
            textView.isRichText = false
            textView.drawsBackground = false
            textView.font = font
            textView.string = text
            textView.delegate = context.coordinator
            // On the text view too, where VoiceOver and UI tests (`textViews`) find it, not only the scroll view.
            textView.setAccessibilityLabel(String(localized: "Comment"))
            // Writing Tools only suggests: a rewrite in place would have no undo of the field's own to take it back.
            if #available(macOS 15.0, *) {
                textView.writingToolsBehavior = .limited
            }
        }
        return scrollView
    }

    /// The text's height at the proposed width in whole lines, clamped to `lines`; none without a width. Measured
    /// on a layout of its own (asking the text view for its `layoutManager` would switch it from TextKit 2 to
    /// TextKit 1), and only as far as the most lines shown: a long comment needn't be laid out on each keystroke.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let textView = scrollView.documentView as? NSTextView,
              let padding = textView.textContainer?.lineFragmentPadding else { return nil }
        let inset = textView.textContainerInset
        let container = NSTextContainer(size: NSSize(width: max(width - 2 * inset.width, 1),
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = padding
        let layoutManager = NSTextLayoutManager()
        layoutManager.textContainer = container
        let storage = NSTextContentStorage()
        storage.addTextLayoutManager(layoutManager)
        storage.attributedString = NSAttributedString(string: textView.string, attributes: [.font: font])
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let maximum = lineHeight * CGFloat(lines.upperBound)
        var textHeight: CGFloat = 0
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                   options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            textHeight = fragment.layoutFragmentFrame.maxY
            return textHeight < maximum
        }
        // Whole lines: the empty line after a last newline measures at the default font's (smaller) height. The
        // hundredth of a line keeps a height a hair over whole lines (floating point) from rounding up a line.
        let lineCount = Int((textHeight / lineHeight - 0.01).rounded(.up))
        let height = lineHeight * CGFloat(min(max(lineCount, lines.lowerBound), lines.upperBound))
        return CGSize(width: width, height: height + 2 * inset.height)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        // Only a change from outside (an undo, a save's snapshot); never while the input method composes.
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text,
              !textView.hasMarkedText() else { return }
        textView.string = text
        scrollView.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        /// Not while the input method composes: the comment takes the text once it is committed (`unmarkText`
        /// and `insertText` end the marking and change the text again).
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !textView.hasMarkedText() else { return }
            text.wrappedValue = textView.string
            // The field's height follows its text (`sizeThatFits`).
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
    }
}

/// The Info popover for `model`: its rows, and its comment bound to `setComment`. Reads the file size off
/// the main actor when it opens and again after a save. Tells `state` its window (the undo gate); `state` ends
/// the comment's typing step when it closes (`infoAnchor`).
struct ArchiveInfoPopover: View {
    let model: ArchiveModel
    let state: ArchiveWindowState

    var body: some View {
        ArchiveInfoView(summary: model.infoSummary,
                        comment: Binding(get: { model.commentText }, set: { model.setComment($0) }),
                        showsComment: model.showsComment,
                        // Read-only while an operation runs: a save adopts its snapshot when it ends, dropping
                        // text typed meanwhile (the progress sheet doesn't stop the popover).
                        canEditComment: model.canEditComment && state.progress == nil,
                        readOnlyNote: ArchiveInfoView.readOnlyNote(for: model), commentProblem: model.commentProblem)
            // On open and after each save, also one that lands while the size loads (that result is dropped).
            .task(id: model.snapshotGeneration) {
                if model.infoFileSize == nil { await model.loadInfoFileSize() }
            }
            .background(InfoPopoverWindowReader(state: state))
    }
}

/// Tells `state` the window of the popover it sits in, for the undo gate.
private struct InfoPopoverWindowReader: NSViewRepresentable {
    let state: ArchiveWindowState

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(state: state)
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        private let state: ArchiveWindowState

        init(state: ArchiveWindowState) {
            self.state = state
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { state.infoPopoverWindow = window }
        }
    }
}
