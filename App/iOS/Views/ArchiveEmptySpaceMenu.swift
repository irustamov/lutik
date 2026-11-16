import SwiftUI
import UIKit

// A long press on the list's empty space shows ＋'s Paste in the edit menu, at the finger, as Files does.
// On the two drop layers over that space: an empty level's and the one below the rows
// (`ArchiveDropLayerBelowRows`).
//
// The edit menu, not `.contextMenu`: a context menu lifts its view, here a clear layer up to the list's
// full size, as a blank platter over a blurred screen. The layers stay what they were for drops and touches:
// the long press is a gesture on the layer (a pan or a tap fails it, so the back swipe and taps behave as
// before), and the menu shows from a view behind it that takes no touch (`ArchiveEditMenuAnchorView`).

extension View {
    /// The empty-space menu on a drop layer of the folder on screen (`folder`).
    func archiveEmptySpaceMenu(_ state: ScreenState, folder: String) -> some View {
        modifier(ArchiveEmptySpaceMenuModifier(state: state, folder: folder))
    }
}

/// The menu a long press on empty space shows, gated as ＋ > Paste: none while ＋ is off (`canAdd`:
/// read-only, locked, busy), else Paste, off unless `canPaste`. ＋ stays on in Select mode, so does this.
@MainActor enum ArchiveEmptySpaceMenu {
    static func menu(for state: ScreenState, into folder: String) -> UIMenu? {
        guard state.canAdd else { return nil }
        let paste = UIAction(title: String(localized: "Paste"), image: UIImage(systemName: "doc.on.clipboard"),
                             attributes: state.canPaste ? [] : .disabled) { [weak state] _ in
            state?.startPaste(into: folder)
        }
        return UIMenu(children: [paste])
    }
}

private struct ArchiveEmptySpaceMenuModifier: ViewModifier {
    let state: ScreenState
    let folder: String
    @State private var anchor = ArchiveEditMenuAnchor()

    func body(content: Content) -> some View {
        let layer = content
            .background {
                ArchiveEditMenuAnchorView(anchor: anchor)
                    .accessibilityHidden(true)
            }
        // The menu is built at the long press: the gates as they are then.
        if #available(iOS 18.0, *) {
            layer.gesture(ArchiveLongPress { point in
                anchor.present(ArchiveEmptySpaceMenu.menu(for: state, into: folder), at: point)
            })
        } else {
            // No touch location before iOS 18: the menu points at the layer's middle.
            layer.onLongPressGesture {
                anchor.present(ArchiveEmptySpaceMenu.menu(for: state, into: folder), at: nil)
            }
        }
    }
}

/// UIKit's long press (0.5 s, under 10 pt of movement), for where the finger is.
@available(iOS 18.0, *)
private struct ArchiveLongPress: UIGestureRecognizerRepresentable {
    let action: @MainActor (CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        UILongPressGestureRecognizer()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        guard recognizer.state == .began else { return }
        action(context.converter.localLocation)
    }
}

/// Shows an edit menu from the anchor view, which has the layer's frame: a point in the layer is one in it.
@MainActor final class ArchiveEditMenuAnchor: NSObject, @preconcurrency UIEditMenuInteractionDelegate {
    private weak var view: UIView?
    private var interaction: UIEditMenuInteraction?
    private var menu: UIMenu?

    func attach(to view: UIView) {
        guard self.view !== view else { return }
        if let interaction { self.view?.removeInteraction(interaction) }
        let interaction = UIEditMenuInteraction(delegate: self)
        view.addInteraction(interaction)
        self.view = view
        self.interaction = interaction
    }

    /// `point` nil: the middle. No menu (＋ off), or the layer off screen: nothing.
    func present(_ menu: UIMenu?, at point: CGPoint?) {
        guard let menu, let view, view.window != nil, let interaction else { return }
        self.menu = menu
        let source = point ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        interaction.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: source))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        menu
    }
}

/// The edit menu's view, behind the layer: clear, and never the view a touch or a drop lands on.
private struct ArchiveEditMenuAnchorView: UIViewRepresentable {
    let anchor: ArchiveEditMenuAnchor

    func makeUIView(context: Context) -> PassThroughView {
        let view = PassThroughView()
        view.backgroundColor = .clear
        anchor.attach(to: view)
        return view
    }

    func updateUIView(_ view: PassThroughView, context: Context) {
        anchor.attach(to: view)
    }

    final class PassThroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
    }
}
