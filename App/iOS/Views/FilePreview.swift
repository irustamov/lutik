import QuickLook
import SwiftUI
import UIKit

/// The Quick Look preview of `ScreenState.previewURL`, which swipes left and right through the folder
/// level's other files like Files (`PreviewQueue`). SwiftUI's `quickLookPreview(_:in:)` takes every URL
/// up front, which would mean extracting the whole folder first; a `QLPreviewController` asks for each
/// item as it is shown, so each file is extracted only then.
///
/// Presented from a hidden host view in the level's background, from the topmost controller presented
/// over it (the search field's while searching). A nil `url` sends it away (a save started, the model
/// was replaced); the user's Done sets `previewURL` nil through `dismiss`.
struct FilePreview: UIViewControllerRepresentable {
    /// The previewed file while this level presents the preview, else nil.
    let url: URL?
    /// The level's rows as shown, read once the preview comes up, and the queue over them.
    let makeQueue: () -> PreviewQueue?
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.isHidden = true
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.dismiss = dismiss
        context.coordinator.update(url: url, host: host, makeQueue: makeQueue)
    }

    static func dismantleUIViewController(_ host: UIViewController, coordinator: Coordinator) {
        coordinator.close()
    }

    /// Where the preview is presented from over `host`: the topmost controller presented over it (a
    /// child's `presentedViewController` is its presentation context's), or nil while one of them is
    /// still coming up or going away, which a presentation now would fail on: try again shortly.
    static func presenter(over host: UIViewController) -> UIViewController? {
        var top = host
        while let presented = top.presentedViewController {
            guard !presented.isBeingPresented, !presented.isBeingDismissed else { return nil }
            top = presented
        }
        return top
    }

    @MainActor final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        /// How often, and how far apart, a preview that can't be presented yet is tried again before
        /// it is given up: about two seconds, longer than a sheet or the search field takes to move.
        static let presentAttempts = 40
        static let presentRetryDelay: TimeInterval = 0.05

        var dismiss: () -> Void = {}
        private var controller: QLPreviewController?
        private var queue: PreviewQueue?
        /// The URL the open preview started from.
        private var shownURL: URL?
        /// The failures already told, so swiping back doesn't tell them again.
        private var told: Set<Int> = []
        /// Not relied on (KVO of it isn't documented): it only tells a swipe sooner than the data
        /// source and delegate calls do.
        private var indexObservation: NSKeyValueObservation?

        func update(url: URL?, host: UIViewController, makeQueue: () -> PreviewQueue?) {
            guard let url else {
                close()
                return
            }
            guard url != shownURL else { return }
            close()
            guard let queue = makeQueue() else { return }
            let controller = QLPreviewController()
            controller.dataSource = self
            controller.delegate = self
            controller.currentPreviewItemIndex = queue.startIndex
            queue.onUpdate = { [weak self] index in self?.itemDidLoad(index) }
            self.queue = queue
            self.controller = controller
            shownURL = url
            indexObservation = controller.observe(\.currentPreviewItemIndex) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.syncCurrentItem() }
            }
            // Not in the middle of SwiftUI's update.
            DispatchQueue.main.async { [weak host] in
                self.present(controller, from: host, attemptsLeft: Self.presentAttempts)
            }
        }

        /// Presents `controller` once `host` is on screen and nothing over it is moving; given up (and
        /// `previewURL` cleared) only if that doesn't happen within `presentAttempts`.
        private func present(_ controller: QLPreviewController, from host: UIViewController?, attemptsLeft: Int) {
            guard self.controller === controller, let host else { return }
            if host.viewIfLoaded?.window != nil, let presenter = FilePreview.presenter(over: host) {
                presenter.present(controller, animated: true)
                return
            }
            guard attemptsLeft > 1 else {
                close()
                dismiss()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.presentRetryDelay) { [weak self, weak host] in
                self?.present(controller, from: host, attemptsLeft: attemptsLeft - 1)
            }
        }

        /// The preview goes (if up) and its queue stops.
        func close() {
            queue?.cancel()
            queue = nil
            indexObservation = nil
            told = []
            shownURL = nil
            guard let controller else { return }
            self.controller = nil
            // From its presenter: on the preview itself, dismiss would only take a failure's alert away.
            guard let presenter = controller.presentingViewController, !controller.isBeingDismissed else { return }
            if controller.isBeingPresented {
                // UIKit ignores a dismissal while the presentation runs: do it once that is over.
                guard let coordinator = controller.transitionCoordinator else {
                    DispatchQueue.main.async { [weak presenter, weak controller] in
                        guard let presenter, controller?.presentingViewController === presenter else { return }
                        presenter.dismiss(animated: true)
                    }
                    return
                }
                coordinator.animate(alongsideTransition: nil) { [weak presenter] _ in
                    presenter?.dismiss(animated: true)
                }
            } else {
                presenter.dismiss(animated: true)
            }
        }

        private func itemDidLoad(_ index: Int) {
            guard let controller, controller.currentPreviewItemIndex == index else { return }
            syncCurrentItem()
        }

        /// The item on screen: the queue is told (it stops what was swiped past), a blank page
        /// whose file is ready now is shown again, and a failure is told once. Called from the data
        /// source and delegate calls Quick Look makes as items are shown, and when a file is ready.
        private func syncCurrentItem() {
            guard let controller, let queue else { return }
            let index = controller.currentPreviewItemIndex
            queue.show(index)
            if queue.takeRefresh(at: index) { controller.refreshCurrentPreviewItem() }
            tellFailure(at: index)
        }

        /// A file swiped to that couldn't be extracted says why, as a tapped row's alert does.
        private func tellFailure(at index: Int) {
            guard let controller, let alert = queue?.failureAlert(at: index), !told.contains(index),
                  controller.presentedViewController == nil else { return }
            told.insert(index)
            let alertController = UIAlertController(title: alert.title, message: alert.message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            controller.present(alertController, animated: true)
        }

        /// After the Quick Look call that tells it, not within it.
        private func syncCurrentItemSoon() {
            DispatchQueue.main.async { [weak self] in self?.syncCurrentItem() }
        }

        // MARK: QLPreviewControllerDataSource

        nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            MainActor.assumeIsolated { queue?.files.count ?? 0 }
        }

        nonisolated func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            MainActor.assumeIsolated { () -> Item in
                guard let queue, queue.files.indices.contains(index) else { return Item(url: nil, title: nil) }
                // Asked for a neighbor: the swipe that led here has moved the current index.
                if controller === self.controller { queue.show(controller.currentPreviewItemIndex) }
                let item = Item(url: queue.item(at: index), title: queue.files[index].name)
                syncCurrentItemSoon()
                return item
            }
        }

        // MARK: QLPreviewControllerDelegate

        /// Quick Look asks this as each item comes on screen in practice, though the documentation
        /// doesn't promise a call per item; it is one more chance (with the index observation and
        /// the data source calls) to show a page that was blank when Quick Look got it, a neighbor
        /// whose file got ready while it was off screen (`PreviewQueue.takeRefresh` keeps it marked
        /// until then). No documented callback tells a swipe, so at the list's ends a blank page may
        /// wait for these. Archive copies are read-only, as without this method.
        nonisolated func previewController(_ controller: QLPreviewController,
                                           editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode {
            MainActor.assumeIsolated {
                if controller === self.controller { syncCurrentItemSoon() }
                return .disabled
            }
        }

        nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
            MainActor.assumeIsolated {
                // Only the user's Done: `close` already let go of a preview it sent away.
                guard controller === self.controller else { return }
                close()
                dismiss()
            }
        }
    }

    /// One file for Quick Look: nil `url` while it is being extracted, or when it couldn't be.
    final class Item: NSObject, QLPreviewItem, Sendable {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(url: URL?, title: String?) {
            previewItemURL = url
            previewItemTitle = title
        }
    }
}
