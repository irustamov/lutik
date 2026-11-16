import SwiftUI
import UIKit

/// The Welcome sheet's controller (`WelcomeSheet.makeController`). It marks the sheet seen once it
/// has appeared: a present UIKit drops, or one the app leaves before it is up, doesn't use up the
/// one-time sheet (it comes at a later launch). Any dismissal after that counts, and is posted
/// (`WelcomeSheet.didDismissNotification`).
final class WelcomeSheetController: UIHostingController<WelcomeSheetView> {
    private let settings: WelcomeSettings
    /// The scene of the window the sheet came up in, kept for the dismissal's notification: by
    /// `viewDidDisappear` the view may have left its window.
    private weak var scene: UIWindowScene?
    private var didPostDismissal = false

    init(rootView: WelcomeSheetView, settings: WelcomeSettings) {
        self.settings = settings
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        captureScene()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        captureScene()
        settings.markSeen()
    }

    override func viewWillDisappear(_ animated: Bool) {
        captureScene()
        super.viewWillDisappear(animated)
    }

    /// Dismissed (Continue, a swipe down, a file taking it away): posted once.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed, !didPostDismissal else { return }
        didPostDismissal = true
        NotificationCenter.default.post(name: WelcomeSheet.didDismissNotification, object: scene)
    }

    private func captureScene() {
        if let windowScene = view.window?.windowScene ?? presentingViewController?.viewIfLoaded?.window?.windowScene {
            scene = windowScene
        }
    }
}

extension WelcomeSheet {
    /// Posted once when the Welcome sheet has been dismissed (Continue, a swipe down, a file taking
    /// it away); the object is the `UIWindowScene` of the window it was presented in. It is not
    /// posted when the scene disconnects with the sheet still up (the sheet is never dismissed):
    /// observers waiting for it also end their wait on `UIScene.didDisconnectNotification`.
    static let didDismissNotification = Notification.Name("KernirWelcomeSheetDidDismiss")
}
