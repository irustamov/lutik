import os
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    /// iOS 18+: the window's root document controller, which shows the system launch view while
    /// it has no document. Internal for tests.
    var documentVC: ArchiveDocumentViewController?
    /// iOS 17: the window's root, the full-screen browser. Internal for tests.
    var browser: DocumentBrowserController?

    private static let logger = Logger(subsystem: "com.kernir.app", category: "scenes")
    /// The user activity that asks a new window to open a file: `userInfo["handoff"]` is the key of
    /// the file's URL in `handoffURLs`.
    private static let openArchiveActivityType = "com.kernir.app.open-archive"
    /// Files on their way to a new window. The URL object stays in this process: a security-scoped
    /// URL from Files could lose its sandbox extension if it travelled in the activity itself.
    private static var handoffURLs: [UUID: URL] = [:]

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)

        let given = options.urlContexts.map(\.url)
            + options.userActivities.compactMap { Self.fileURL(in: $0) }
        let launchURLs = WindowOpenRoute.launchURLs(given: given) { Self.fixtureURL() }

        let root: UIViewController
        if #available(iOS 18.0, *) {
            // The stock launch view: the document controller shows it
            // while it has no document, and archives open in place. The Welcome sheet comes up
            // over it once it is shown.
            Self.applyDebugTraits(to: window, browser: nil)
            let nav = ArchiveDocumentViewController.makeLaunchNavigation(session: session)
            let documentVC = nav.viewControllers.first as? ArchiveDocumentViewController
            documentVC?.onLaunchContentShown = { [weak documentVC] in
                guard let documentVC else { return }
                Self.presentWelcomeIfNeeded(overLaunchViewOf: documentVC, launchedWithFile: !launchURLs.isEmpty)
            }
            self.documentVC = documentVC
            root = nav
        } else {
            // iOS 17 has no launch view: the full-screen browser, with archives over it.
            let browser = DocumentBrowserController()
            Self.applyDebugTraits(to: window, browser: browser)
            browser.sceneSession = session
            browser.openDocuments = { [weak self] urls in self?.open(urls) }
            browser.afterFirstAppearance = { browser in
                Self.presentWelcomeIfNeeded(over: browser, launchedWithFile: !launchURLs.isEmpty)
            }
            self.browser = browser
            root = browser
        }
        window.rootViewController = root
        Self.logger.notice("""
            Window \(session.persistentIdentifier, privacy: .public): root \
            \(String(describing: type(of: root)), privacy: .public)
            """)
        self.window = window
        window.makeKeyAndVisible()
        Self.closeOtherWindows(keeping: session)

        Self.applyDebugEngine()

        open(launchURLs)
    }

    /// The one-time Welcome sheet, over the first window that comes up without a file
    /// (`WelcomeSheetGate`). A window launched to open a file leaves it for a later launch. The
    /// sheet is marked seen once it has appeared, not here: a present that never comes up doesn't
    /// use it up.
    private static func presentWelcomeIfNeeded(over browser: DocumentBrowserController, launchedWithFile: Bool) {
        let settings = WelcomeSettings()
        guard !WelcomeSheet.isUnitTestHost,
              WelcomeSheetGate.shared.claim(settings: settings, launchedWithFile: launchedWithFile,
                                            browserIsCovered: browser.presentedViewController != nil) else { return }
        logger.notice("Presenting the Welcome sheet")
        let sheet = WelcomeSheet.makeController(settings: settings)
        browser.welcomeSheet = sheet
        browser.present(sheet, animated: true)
    }

    /// iOS 18+: the one-time Welcome sheet over the launch view, the first time it is shown with
    /// no document (`LaunchHeaderView.onContentShown`); same rules as over the iOS 17 browser.
    private static func presentWelcomeIfNeeded(overLaunchViewOf documentVC: ArchiveDocumentViewController,
                                               launchedWithFile: Bool) {
        let settings = WelcomeSettings()
        guard !WelcomeSheet.isUnitTestHost, documentVC.document == nil,
              WelcomeSheetGate.shared.claim(settings: settings, launchedWithFile: launchedWithFile,
                                            browserIsCovered: false) else { return }
        logger.notice("Presenting the Welcome sheet over the launch view")
        presentWelcome(WelcomeSheet.makeController(settings: settings), overLaunchViewOf: documentVC)
    }

    /// Presents `sheet` from the top of the window's presented chain; a document arriving takes it
    /// away (`ArchiveDocumentViewController.welcomeSheet`). Internal for tests.
    static func presentWelcome(_ sheet: UIViewController, overLaunchViewOf documentVC: ArchiveDocumentViewController) {
        guard let root = documentVC.viewIfLoaded?.window?.rootViewController ?? documentVC.navigationController else {
            return
        }
        var top = root
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        documentVC.welcomeSheet = sheet
        top.present(sheet, animated: true)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        open(URLContexts.map(\.url))
    }

    /// Each window saves its own document when it leaves the screen, even while the app stays
    /// active in another window.
    func sceneDidEnterBackground(_ scene: UIScene) {
        currentDocument?.saveForBackground()
    }

    /// The window is gone (closed, or its scene released): save and close its document.
    func sceneDidDisconnect(_ scene: UIScene) {
        let sessionID = scene.session.persistentIdentifier
        if let documentVC {
            guard let document = documentVC.document as? ArchiveDocument else { return }
            // The close takes the document out of UIKit's user-activity registry on a background
            // queue: the controller leaves it on the main thread first (`ArchiveDocumentViewController.document`).
            documentVC.userActivity = nil
            OpenDocuments.close(document, sessionID: sessionID)
        } else {
            browser?.closeForDisconnect(sessionID: sessionID)
        }
    }

    /// The document this window shows, on either root.
    private var currentDocument: ArchiveDocument? {
        if let documentVC { return documentVC.document as? ArchiveDocument }
        return browser?.presentedDocument
    }

    /// The first file opens in this window, each further one in a new window. One already open
    /// in a window brings that window forward instead (`OpenDocuments.activateWindow`).
    private func open(_ urls: [URL]) {
        guard let route = WindowOpenRoute(urls: urls) else { return }
        if let documentVC {
            open(route.here, in: documentVC)
        } else {
            browser?.present(documentAt: route.here)
        }
        let session = window?.windowScene?.session
        for url in route.newWindows where !OpenDocuments.activateWindow(showing: url, from: session) {
            openInNewWindow(url)
        }
    }

    /// iOS 18+: the file replaces whatever the window shows, in place (Open In while an archive
    /// is open). Its own earlier document still closing (Back, then Open In) is let finish first:
    /// its save must land before the file opens again.
    private func open(_ url: URL, in documentVC: ArchiveDocumentViewController) {
        let session = window?.windowScene?.session
        guard !OpenDocuments.activateWindow(showing: url, from: session) else { return }
        OpenDocuments.whenClosed(url) { [weak documentVC] in
            guard let documentVC else { return }
            // Another window may have opened the file meanwhile: the setter would decline (and
            // bring that window forward), so this window keeps its archive and its folders.
            guard !OpenDocuments.activateWindow(showing: url, from: documentVC.sceneSession) else { return }
            documentVC.navigationController?.popToRootViewController(animated: false)
            documentVC.document = ArchiveDocument(fileURL: url)
        }
    }

    /// Where the device has one window (iPhone) the file isn't opened: a new scene there would
    /// take this window's place.
    private func openInNewWindow(_ url: URL) {
        guard UIApplication.shared.supportsMultipleScenes else {
            Self.logger.error("One window only: not opening another archive")
            return
        }
        let id = UUID()
        Self.handoffURLs[id] = url
        let activity = NSUserActivity(activityType: Self.openArchiveActivityType)
        activity.userInfo = ["handoff": id.uuidString]
        var request = UISceneSessionActivationRequest(role: .windowApplication)
        request.userActivity = activity
        UIApplication.shared.activateSceneSession(for: request) { error in
            Self.logger.error("Cannot open a new window: \(error.localizedDescription, privacy: .public)")
            Task { @MainActor in Self.handoffURLs[id] = nil }
        }
    }

    /// Takes the file a new window was asked to open out of `handoffURLs`. Without it (a stale
    /// activity) the window shows the launch view (iOS 17: the browser).
    private static func fileURL(in activity: NSUserActivity) -> URL? {
        guard activity.activityType == openArchiveActivityType else { return nil }
        guard let id = (activity.userInfo?["handoff"] as? String).flatMap(UUID.init(uuidString:)),
              let url = handoffURLs.removeValue(forKey: id) else {
            logger.error("A new window was asked to open a file that is no longer handed off")
            return nil
        }
        return url
    }

    /// DEBUG only, for UI tests:
    /// - `-KernirFailSave` makes every save fail after three seconds, long enough for a UI test
    ///   to see the progress sheet before the failed-save alert.
    /// - `-KernirSlowExtract [seconds]` makes every extraction (preview, share, extract) wait that
    ///   long first, 1.5 s by default, so the progress sheet comes up before the preview or share sheet.
    private static func applyDebugEngine() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        var engine = DocumentEngine.live
        if args.contains("-KernirFailSave") {
            engine.write = { _, _, _, _, _, _ in
                try await Task.sleep(for: .seconds(3))
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        if let i = args.firstIndex(of: "-KernirSlowExtract") {
            let seconds = args.indices.contains(i + 1) ? Double(args[i + 1]) : nil
            engine = engine.slowingExtraction(by: .seconds(seconds ?? 1.5))
        }
        ArchiveDocument.engine = engine
        #endif
    }

    /// DEBUG only, for UI tests: `-KernirCompactWidth` makes every window compact width, as in
    /// Split View or Slide Over, so an iPad runs its compact layout at full size. The override is
    /// on the window, before it has a root: on the scene (iOS 26.5 sim) it changes nothing, and on
    /// the root view controller the bar folds but sheets stay form sheets. iOS 17: the archive
    /// presented over the browser gets its own (`DocumentBrowserController.forcesCompactWidth`).
    private static func applyDebugTraits(to window: UIWindow, browser: DocumentBrowserController?) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-KernirCompactWidth") {
            window.traitOverrides.horizontalSizeClass = .compact
            browser?.forcesCompactWidth = true
        }
        #endif
    }

    #if DEBUG
    /// The close-other-windows hook has run.
    private static var didCloseOtherWindows = false
    #endif

    /// DEBUG only, for UI tests: `-KernirCloseOtherWindows` closes every other window (scene
    /// session) when the app launches, for the first window only. A two-window test uses it to
    /// leave one window behind whatever its outcome: sessions outlive the app, and leftovers
    /// change which one the next launch restores.
    private static func closeOtherWindows(keeping session: UISceneSession) {
        #if DEBUG
        guard !didCloseOtherWindows, ProcessInfo.processInfo.arguments.contains("-KernirCloseOtherWindows") else {
            return
        }
        didCloseOtherWindows = true
        for other in UIApplication.shared.openSessions where other != session {
            UIApplication.shared.requestSceneSessionDestruction(other, options: nil) { error in
                logger.error("Closing a window failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        #endif
    }

    #if DEBUG
    /// DEBUG only, for UI tests: `-KernirExtractDestination <absolute path>` is the folder Extract
    /// uses instead of asking in the Files picker. The path is used as given (no copy, no container).
    static let extractDestination: URL? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-KernirExtractDestination"), args.indices.contains(i + 1) else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }()
    #endif

    #if DEBUG
    /// The fixture hook has run: a second window would delete and re-copy the file the first has open.
    private static var didOpenFixture = false
    #endif

    /// DEBUG only: `-KernirOpenFixture <absolute path>` copies the file into Documents and returns
    /// the copy, with no remembered Mac metadata answer. For the first window only.
    private static func fixtureURL() -> URL? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard !didOpenFixture, let i = args.firstIndex(of: "-KernirOpenFixture"), args.indices.contains(i + 1) else {
            return nil
        }
        didOpenFixture = true
        let source = URL(fileURLWithPath: args[i + 1])
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let copy = documents.appendingPathComponent(source.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: source, to: copy)
            // A fresh copy asks Save's Mac metadata question again: a previous run's answer for
            // this path could match it (a Keep matches the creation date, which the copy keeps).
            MacMetadataChoiceStore.shared.forget(copy)
            return copy
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
