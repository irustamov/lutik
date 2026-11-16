import SwiftUI

/// A small sheet for a long operation: title, progress bar and, when it can stop, Cancel.
struct ProgressSheet: View {
    let progress: OperationProgress
    /// The content's height at the sheet's width, so the detent grows with the title.
    @State private var contentHeight: CGFloat = 0
    /// The title's widest line in a fitted iPad sheet: 488 pt with the padding, a readable card.
    private static let fittedTitleWidth: CGFloat = 440

    /// Where `FittedPresentation` sizes an iPad sheet (regular width) to the content, nil everywhere else.
    private var titleMaxWidth: CGFloat? {
        guard #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad else {
            return nil
        }
        return Self.fittedTitleWidth
    }

    var body: some View {
        // The title wraps over more lines with a long name, a longer language or a large
        // Dynamic Type size: the sheet takes the measured height, never less than the usual
        // one, and scrolls only when even the tallest sheet can't show everything.
        ScrollView {
            VStack(spacing: 16) {
                TitleWidthCap(maxWidth: titleMaxWidth) {
                    Text(progress.title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                if let cancel = progress.cancel {
                    Button("Cancel", role: .cancel, action: cancel)
                }
            }
            .padding(24)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0.rounded(.up) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(max(contentHeight, progress.cancel == nil ? 140 : 190))])
        .modifier(FittedPresentation())
        .interactiveDismissDisabled()
    }
}

/// At regular width (iPad) a sheet ignores height detents and would show this small content in
/// a full form sheet; `.fitted` sizes it to the content. Compact width keeps the detent.
private struct FittedPresentation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.fitted)
        } else {
            content
        }
    }
}

/// `.fitted` sizes the sheet to the content's ideal width, and a title's ideal width is the
/// whole title on one line: a long one made the iPad sheet as wide as the window, at its bottom
/// edge. Here the title gets at most a readable card width and wraps; a short one still takes
/// only its own width. On only with `.fitted` (iPad, iOS 18): other sheets set their own width.
private struct TitleWidthCap: Layout {
    /// nil leaves the proposal as it is.
    let maxWidth: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                              proposal: capped(proposal))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        guard let maxWidth else { return proposal }
        return ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
    }
}
