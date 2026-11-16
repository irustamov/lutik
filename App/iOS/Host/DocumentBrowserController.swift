import os
import UIKit
import UniformTypeIdentifiers

/// Every window's root on every iOS version: the full-screen document browser, Files-like with
/// Recents, Shared and Browse (and the sidebar on iPad). An archive opens full screen over it in
/// the archive window's navigation controller; closing it comes back here.
final class DocumentBrowserController: UIDocumentBrowserViewController {
    /// The types the app declares as documents in Info.plist (`InfoPlistTests`).
    static let contentTypes: [UTType] = KernirDocumentTypes.readable + KernirDocumentTypes.packageTypes

    init() {
        super.init(forOpening: Self.contentTypes)
        allowsDocumentCreation = true
        localizedCreateDocumentActionTitle = String(localized: "New Archive")
        delegate = self
        additionalTrailingNavigationBarButtonItems = [Acknowledgements.barButtonItem(presentingFrom: self)]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// DEBUG `-KernirCompactWidth` (`SceneDelegate`): the archive presented over the browser is
    /// compact width too. The window's override doesn't reach it: a full-screen present takes the
    /// browser's traits, and the browser keeps its own.
    var forcesCompactWidth = false

    /// The window's scene session, set by `SceneDelegate`; handed to each document view controller.
    weak var sceneSession: UISceneSession?

    /// The files picked in the browser, for `SceneDelegate` to open: the first in this window,
    /// further ones in new windows.
    var openDocuments: (([URL]) -> Void)?

    private static let logger = Logger(subsystem: "com.kernir.app", category: "scenes")

    /// Idle, showing an archive or closing it, and the file waiting to come up: a launch with a
    /// file asks before the browser is on screen, Open In may come while the archive closes.
    private(set) var flow = BrowserPresentationFlow()

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // First appearance only: after a close the pending file comes from the dismissal's end,
        // once the closed document has let go of the window's entry.
        if let url = flow.appeared() { present(documentAt: url, animated: false) }
        runAfterFirstAppearanceOnceActive()
    }

    /// Runs once, after the browser's first appearance and the launch file's present, if any, with
    /// the window's scene in the foreground and active: `SceneDelegate`'s one-time Welcome sheet.
    /// An appearance while the scene isn't active yet (iOS 17 at launch) waits for its activation.
    var afterFirstAppearance: ((DocumentBrowserController) -> Void)?

    /// Whether `scene` is in the foreground and active; tests stand in for UIKit's state.
    var sceneIsActive: (UIScene) -> Bool = { $0.activationState == .foregroundActive }
    /// Where the scene's activation is observed (`UIScene.didActivateNotification`); tests post to their own.
    var activationNotifications = NotificationCenter.default
    /// Waits for the scene's activation to run `afterFirstAppearance`; released (so removed) on
    /// the activation, or with the browser.
    private var activationObserver: NotificationObservation?

    private func runAfterFirstAppearanceOnceActive() {
        guard afterFirstAppearance != nil, activationObserver == nil else { return }
        guard let scene = view.window?.windowScene, !sceneIsActive(scene) else { return runAfterFirstAppearance() }
        Self.logger.notice("The browser appeared with its scene not active: waiting for the scene's activation")
        activationObserver = NotificationObservation(
            activationNotifications, name: UIScene.didActivateNotification, object: scene) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activationObserver != nil else { return }
                self.activationObserver = nil
                self.runAfterFirstAppearance()
            }
        }
    }

    private func runAfterFirstAppearance() {
        guard let firstAppearance = afterFirstAppearance else { return }
        afterFirstAppearance = nil
        firstAppearance(self)
    }

    /// The Welcome sheet over the browser, set by `SceneDelegate` when it presents it: a file
    /// asked for while it is up takes it away first (`dismissWelcomeSheet`).
    weak var welcomeSheet: UIViewController?

    /// A file is to come up: the Welcome sheet, if up, goes away with the stock animation, so the
    /// archive comes up over the browser rather than over the sheet (and no sheet is left once it
    /// closes). The file isn't lost: the flow holds it for the dismissal's transition and
    /// presents it once that is over (`holdUntilTransitionEnds`). A sheet still on its way up is
    /// left alone (UIKit would drop the dismissal): the file waits for that transition, then
    /// comes back here.
    private func dismissWelcomeSheet() {
        guard let sheet = welcomeSheet, let presenter = sheet.presentingViewController,
              !sheet.isBeingPresented, !sheet.isBeingDismissed else { return }
        Self.logger.notice("A file comes up: dismissing the Welcome sheet first")
        presenter.dismiss(animated: true)
    }

    /// A one-shot mark shared by a UIKit callback and a later check.
    @MainActor private final class Flag { var isSet = false }

    /// The archive window's navigation controller, from its present until its close has ended or
    /// UIKit is found to have dropped it (`presentWasDropped`).
    private var documentNavigation: ArchiveNavigationController?

    /// A controller in the presented chain that is being presented or dismissed: a present now
    /// would be dropped.
    private var transitioningController: UIViewController? {
        var presented = presentedViewController
        while let current = presented {
            if current.isBeingPresented || current.isBeingDismissed { return current }
            presented = current.presentedViewController
        }
        return nil
    }

    private var documentController: ArchiveDocumentViewController? {
        documentNavigation?.viewControllers.first as? ArchiveDocumentViewController
    }

    /// The document of the archive presented over the browser, if any.
    var presentedDocument: ArchiveDocument? { documentController?.document as? ArchiveDocument }

    /// The window (`sessionID`'s) is going away: the presented archive's document closes
    /// (`OpenDocuments.close`). The archive's controller leaves UIKit's user-activity registry on
    /// the main thread first, like its document: the close takes the document out of it on a
    /// background queue (`ArchiveDocumentViewController.document`).
    func closeForDisconnect(sessionID: String) {
        guard let document = presentedDocument else { return }
        documentController?.userActivity = nil
        OpenDocuments.close(document, sessionID: sessionID)
    }

    /// A file another window already shows brings that window forward instead. An archive
    /// already presented here gives way to the new one in place (Files' Open In while one is
    /// open). Otherwise the archive comes up full screen over whatever the browser shows, or
    /// once it can (`BrowserPresentationFlow`).
    func present(documentAt url: URL, animated: Bool = true) {
        // The archive closing in this window, asked for again: it comes back once the close is
        // done, rather than counting as shown here.
        let closingHere = flow.phase == .closing && sceneSession != nil
            && OpenDocuments.sessionID(for: url) == sceneSession?.persistentIdentifier
        if !closingHere, OpenDocuments.activateWindow(showing: url, from: sceneSession) { return }
        dismissWelcomeSheet()
        let step = flow.open(url, chainIsTransitioning: transitioningController != nil && !ignoresTransition,
                             fileIsClosing: OpenDocuments.isClosing(url))
        switch step {
        case .present(let url):
            transitionRetries = 0
            presentNavigation(for: url, animated: animated)
        case .replace(let url):
            guard let nav = documentNavigation, let shown = documentController else {
                // Gone some other way: start over from the browser alone.
                documentNavigation = nil
                flow.presentDropped()
                return present(documentAt: url, animated: animated)
            }
            nav.popToRootViewController(animated: false)
            shown.document = ArchiveDocument(fileURL: url)
        case .hold(let dropped):
            logDropped(dropped)
        case .holdUntilTransitionEnds(let dropped):
            logDropped(dropped)
            resumeAfterTransition()
        case .holdUntilFileCloses(let dropped):
            logDropped(dropped)
            OpenDocuments.whenClosed(url) { [weak self] in
                guard let self, let url = flow.fileClosed() else { return }
                present(documentAt: url, animated: true)
            }
        }
    }

    private func presentNavigation(for url: URL, animated: Bool) {
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        let nav = Self.makeDocumentNavigation(for: url, session: sceneSession, compactWidth: forcesCompactWidth)
        guard let docVC = nav.viewControllers.first as? ArchiveDocumentViewController, docVC.document != nil else {
            flow.presentDropped()
            return
        }
        documentNavigation = nav
        docVC.dismissHandler = { [weak self, weak nav, weak docVC] done in
            guard let self else { return done() }
            flow.closeStarted()
            dismissForClose(nav, of: docVC?.document?.fileURL, done: done)
        }
        // A window that never shows the archive must not keep it registered: a present over a
        // controller off screen never comes up. One UIKit drops because a transition is under
        // way doesn't get here (`holdUntilTransitionEnds`) unless forced (checked below).
        if top.viewIfLoaded?.window == nil {
            Self.logger.error("The browser's presented chain is off screen; the archive can't come up")
            return presentWasDropped(nav)
        }
        top.present(nav, animated: animated) { [weak self, weak nav] in
            // Came up after its close had already ended (`closeEnded` let it go): take it away.
            guard let self, let nav, documentNavigation !== nav, nav.presentedViewController == nil else { return }
            nav.presentingViewController?.dismiss(animated: false)
        }
        // Forced over a transition (`presentIgnoringTransition`), UIKit may drop the present
        // without a word: once that transition is over, a `nav` neither presented nor on its way
        // up was dropped.
        guard ignoresTransition else { return }
        afterTransition { [weak self, nav] in
            guard let self, documentNavigation === nav, nav.presentingViewController == nil,
                  !nav.isBeingPresented else { return }
            Self.logger.error("UIKit dropped the archive's present forced over a transition")
            presentWasDropped(nav)
        }
    }

    /// UIKit didn't present `nav`: its document goes, and the browser is alone again.
    private func presentWasDropped(_ nav: ArchiveNavigationController) {
        if documentNavigation === nav { documentNavigation = nil }
        flow.presentDropped()
        let docVC = nav.viewControllers.first as? ArchiveDocumentViewController
        docVC?.dismissHandler = nil
        docVC?.document = nil
    }

    /// Takes the closing archive's navigation controller off screen, then lets its document go
    /// (`done`). A dismissal UIKit drops (a sheet over the archive on its way up) never calls
    /// back: it is tried again after the transition, a few times. Then, still presented, the
    /// archive stays (the close is aborted); gone some other way, the close ends.
    private func dismissForClose(_ nav: ArchiveNavigationController?, of url: URL?, done: @escaping @MainActor () -> Void,
                                 ended: Flag = Flag(), attempt: Int = 0) {
        let end: @MainActor () -> Void = { [weak self] in
            guard !ended.isSet else { return }
            ended.isSet = true
            done()
            self?.closeEnded(waitingFor: url)
        }
        guard let nav, let presenter = nav.presentingViewController else { return end() }
        presenter.dismiss(animated: true) { end() }
        guard !ended.isSet, !nav.isBeingDismissed else { return }
        // Dropped: no dismissal under way, so its completion will never come.
        afterTransition { [weak self, weak nav] in
            guard let self, !ended.isSet else { return }
            if attempt + 1 < Self.retryLimit, nav?.presentingViewController != nil {
                dismissForClose(nav, of: url, done: done, ended: ended, attempt: attempt + 1)
            } else if nav?.presentingViewController == nil {
                Self.logger.error("The archive's dismissal never called back; ending its close")
                end()
            } else {
                Self.logger.error("The archive couldn't be dismissed; it stays open")
                ended.isSet = true
                (nav?.viewControllers.first as? ArchiveDocumentViewController)?.closeAborted()
                if let url = flow.closeAborted() { present(documentAt: url, animated: true) }
            }
        }
    }

    /// The closed archive is off screen and its document gone. Once that document has closed
    /// (its save landed), the file waiting, if any, comes up: the closed one's included.
    private func closeEnded(waitingFor url: URL?) {
        documentNavigation = nil
        let end: @MainActor () -> Void = { [weak self] in
            guard let self, let url = flow.closeEnded() else { return }
            present(documentAt: url, animated: true)
        }
        if let url { OpenDocuments.whenClosed(url, end) } else { end() }
    }

    /// A present held for a transition: tries again this many times, then goes ahead anyway.
    private static let retryLimit = 40
    private var transitionRetries = 0
    /// Set for the one present that goes ahead after `retryLimit` tries.
    private var ignoresTransition = false

    /// The one present that goes ahead after `retryLimit` tries, the chain still in transition.
    func presentIgnoringTransition(documentAt url: URL, animated: Bool) {
        ignoresTransition = true
        present(documentAt: url, animated: animated)
        ignoresTransition = false
    }

    /// Tries the waiting file again once the presented chain's transition is over.
    private func resumeAfterTransition() {
        transitionRetries += 1
        afterTransition { [weak self] in
            guard let self, let url = flow.transitionEnded() else { return }
            if transitionRetries >= Self.retryLimit {
                Self.logger.error("The browser's presented chain stays in transition; presenting the archive anyway")
                transitionRetries = 0
                return presentIgnoringTransition(documentAt: url, animated: true)
            }
            present(documentAt: url, animated: true)
        }
    }

    /// Runs `body` after the presented chain's transition (`afterTransition(animate:_:)`).
    private func afterTransition(_ body: @escaping @MainActor () -> Void) {
        let coordinator = transitioningController?.transitionCoordinator
        Self.afterTransition(animate: coordinator.map { coordinator in
            { completion in coordinator.animate(alongsideTransition: nil) { _ in completion() } }
        }, body)
    }

    /// Runs `body` once after a transition: a hop after the completion `animate` (a transition
    /// coordinator's `animate(alongsideTransition:completion:)`) queues, so UIKit has finished
    /// it. Without a coordinator, or one that doesn't queue it (false: that completion may never
    /// come), 50 ms later.
    static func afterTransition(animate: ((@escaping @Sendable () -> Void) -> Bool)?,
                                _ body: @escaping @MainActor () -> Void) {
        let ran = Flag()
        let run: @MainActor () -> Void = {
            guard !ran.isSet else { return }
            ran.isSet = true
            body()
        }
        if let animate, animate({ Task { @MainActor in run() } }) { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { MainActor.assumeIsolated(run) }
    }

    private func logDropped(_ url: URL?) {
        guard let url else { return }
        Self.logger.notice("A newer file takes the place of \(url.lastPathComponent, privacy: .private) waiting to open")
    }

    /// The archive window for `url`: its navigation controller, full screen, with the document set
    /// after init (the document setter registers it in `OpenDocuments` under `session`).
    /// `compactWidth`: the archive window and what it presents are compact width (`forcesCompactWidth`).
    static func makeDocumentNavigation(for url: URL, session: UISceneSession?,
                                       compactWidth: Bool = false) -> ArchiveNavigationController {
        let docVC = ArchiveDocumentViewController(document: nil)
        docVC.sceneSession = session
        docVC.document = ArchiveDocument(fileURL: url)
        let nav = ArchiveNavigationController(rootViewController: docVC)
        nav.navigationBar.prefersLargeTitles = true
        nav.modalPresentationStyle = .fullScreen
        if compactWidth {
            nav.traitOverrides.horizontalSizeClass = .compact
            nav.presentationController?.traitOverrides.horizontalSizeClass = .compact
        }
        return nav
    }
}

extension DocumentBrowserController: @preconcurrency UIDocumentBrowserViewControllerDelegate {
    func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
        if let openDocuments {
            openDocuments(documentURLs)
        } else if let url = documentURLs.first {
            present(documentAt: url)
        }
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController,
                         didRequestDocumentCreationWithHandler importHandler: @escaping
                         (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
        NewArchiveFlow.present(from: controller, importHandler: importHandler)
    }

    /// The new archive is in place: its settings follow it, and it opens like a picked one.
    func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL,
                         toDestinationURL destinationURL: URL) {
        NewArchiveFlow.didImport(from: sourceURL, to: destinationURL)
        present(documentAt: destinationURL)
    }

    func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL,
                         error: (any Error)?) {
        NewArchiveFlow.didFailToImport(documentURL, error: error, presenter: controller)
    }
}

/// Where a window opens the files it is asked to open: the first in this window, each further
/// one in a new window (or, with one window, not at all). Duplicates count once.
struct WindowOpenRoute: Equatable {
    let here: URL
    let newWindows: [URL]

    init?(urls: [URL]) {
        var seen = Set<URL>()
        let urls = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        guard let first = urls.first else { return nil }
        here = first
        newWindows = Array(urls.dropFirst())
    }

    /// A new window's files: those it was connected with (Open In, a new-window hand-off), else
    /// the DEBUG fixture's, which is only asked for then (it runs once per process).
    static func launchURLs(given: [URL], fixture: () -> URL?) -> [URL] {
        if !given.isEmpty { return given }
        return fixture().map { [$0] } ?? []
    }
}

/// A block observer of `center`, removed when this is released: `DocumentBrowserController` drops
/// its wait for the scene's activation with it, also when the browser goes away first (its
/// `deinit` can't reach its main-actor state).
final class NotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: any NSObjectProtocol

    init(_ center: NotificationCenter, name: Notification.Name, object: Any?, queue: OperationQueue? = .main,
         using block: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: queue, using: block)
    }

    deinit { center.removeObserver(token) }
}
