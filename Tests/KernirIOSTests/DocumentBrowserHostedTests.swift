import Foundation
import Testing
import UIKit
@testable import Kernir

/// UIKit's private user-activity registry (`_userActivity`), read by the activity tests: expected
/// from iOS 26 on, where a UIKit without it fails those tests rather than skipping them. Below
/// iOS 26 (iOS 17.4 has no such method) only their registry checks are left out; their
/// controller checks run everywhere.
private let documentActivityRegistryExpected = ProcessInfo.processInfo.isOperatingSystemAtLeast(
    .init(majorVersion: 26, minorVersion: 0, patchVersion: 0))

/// `DocumentBrowserController` in a real window of the test host: what `OpenDocuments` says the
/// window shows across present, close, pending files and in-place replacement.
/// Part of the serialized `OpenDocumentsTests` because both register under the host's session.
extension OpenDocumentsTests {
    /// A browser as the root of a second window on the host's scene, on screen.
    private func hostedBrowser(presentingFirst url: URL? = nil,
                               configure: (DocumentBrowserController) -> Void = { _ in })
        async throws -> (DocumentBrowserController, UIWindow) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let browser = DocumentBrowserController()
        browser.sceneSession = scene.session
        configure(browser)
        if let url { browser.present(documentAt: url, animated: false) }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = browser
        window.isHidden = false
        try await waitUntil { browser.flow.hasAppeared }
        try #require(browser.flow.hasAppeared, "the browser never appeared")
        return (browser, window)
    }

    private func documentController(of browser: DocumentBrowserController) -> ArchiveDocumentViewController? {
        (browser.presentedViewController as? UINavigationController)?.viewControllers.first as? ArchiveDocumentViewController
    }

    /// The archive is up and no transition is under way.
    private func settled(_ browser: DocumentBrowserController) -> Bool {
        guard let presented = browser.presentedViewController else { return false }
        return !presented.isBeingPresented && !presented.isBeingDismissed && browser.presentedDocument != nil
    }

    /// Closes what the browser shows, takes the window away and closes every document.
    private func tearDown(_ browser: DocumentBrowserController, _ window: UIWindow, documents: [ArchiveDocument?]) async throws {
        documentController(of: browser)?.closeDocument()
        try await waitUntil { browser.presentedViewController == nil && browser.flow.phase == .idle }
        window.isHidden = true
        window.rootViewController = nil
        OpenDocuments.forget(sessionID: browser.sceneSession?.persistentIdentifier ?? "")
        // The closed controller's document closes on its own; a second close of one already
        // closing never calls back, so only wait for it (and nudge one still open after that).
        let documents = documents.compactMap { $0 }
        try await waitUntil { documents.allSatisfy { $0.documentState.contains(.closed) } }
        for doc in documents where !doc.documentState.contains(.closed) { doc.close(completionHandler: nil) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Major 2: a file asked for while the archive closes comes up once the close is done and
    /// keeps its entry; the closed archive's entry is gone.
    @Test(.timeLimit(.minutes(1))) func fileDuringCloseComesUpAfterAndKeepsItsEntry() async throws {
        let a = try Fixture.copy("zip/deflate.zip"), b = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        let id = try #require(browser.sceneSession?.persistentIdentifier)
        browser.present(documentAt: a, animated: false)
        try await waitUntil { settled(browser) }
        let first = browser.presentedDocument
        #expect(OpenDocuments.sessionID(for: a) == id)

        try #require(documentController(of: browser)).closeDocument()
        #expect(browser.flow.phase == .closing)
        browser.present(documentAt: b)
        #expect(browser.flow.pending == b)
        try await waitUntil { settled(browser) && browser.presentedDocument !== first }

        #expect(browser.presentedDocument !== first)
        #expect(browser.flow.phase == .showing)
        #expect(OpenDocuments.sessionID(for: b) == id)
        #expect(OpenDocuments.sessionID(for: a) == nil)
        let second = browser.presentedDocument
        try await tearDown(browser, window, documents: [first, second])
        #expect(OpenDocuments.sessionID(for: b) == nil)
    }

    /// Minor 3: the closing archive asked for again (Files' Open In mid-close) comes back.
    @Test(.timeLimit(.minutes(1))) func closingArchiveAskedForAgainComesBack() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        let id = try #require(browser.sceneSession?.persistentIdentifier)
        browser.present(documentAt: a, animated: false)
        try await waitUntil { settled(browser) }
        let first = browser.presentedDocument

        try #require(documentController(of: browser)).closeDocument()
        browser.present(documentAt: a)
        #expect(browser.flow.pending == a)
        try await waitUntil { settled(browser) && browser.presentedDocument !== first }

        #expect(browser.presentedDocument !== first)
        #expect(OpenDocuments.sessionID(for: a) == id)
        try await tearDown(browser, window, documents: [first, browser.presentedDocument])
    }

    /// A launch with a file asks before the browser is on screen: it comes up on first appearance.
    @Test(.timeLimit(.minutes(1))) func fileBeforeFirstAppearanceComesUp() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser(presentingFirst: a)
        let id = try #require(browser.sceneSession?.persistentIdentifier)
        try await waitUntil { settled(browser) }

        #expect(browser.presentedDocument != nil)
        #expect(browser.flow.pending == nil)
        #expect(OpenDocuments.sessionID(for: a) == id)
        try await tearDown(browser, window, documents: [browser.presentedDocument])
        #expect(OpenDocuments.sessionID(for: a) == nil)
    }

    /// Open In while an archive is shown: the new one takes its place in the same archive window.
    @Test(.timeLimit(.minutes(1))) func shownArchiveIsReplacedInPlace() async throws {
        let a = try Fixture.copy("zip/deflate.zip"), b = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        let id = try #require(browser.sceneSession?.persistentIdentifier)
        browser.present(documentAt: a, animated: false)
        try await waitUntil { settled(browser) }
        let first = browser.presentedDocument
        let nav = browser.presentedViewController

        browser.present(documentAt: b)
        #expect(browser.presentedViewController === nav)
        #expect(browser.presentedDocument !== first)
        #expect(OpenDocuments.sessionID(for: b) == id)
        #expect(OpenDocuments.sessionID(for: a) == nil)
        try await tearDown(browser, window, documents: [first, browser.presentedDocument])
    }

    /// Whether the document has a user activity as UIDocument's close sees it (private
    /// `_userActivity`; the public getter would make a default one). Nil where UIKit's registry isn't
    /// expected (`documentActivityRegistryExpected`, below iOS 26): callers skip the
    /// registry check there. From iOS 26 on, a document that can't be read this way fails.
    private func hasRegisteredActivity(_ document: UIDocument) throws -> Bool? {
        guard documentActivityRegistryExpected else { return nil }
        try #require(document.responds(to: NSSelectorFromString("_userActivity")), "UIKit's activity registry isn't readable")
        return document.value(forKey: "_userActivity") is NSUserActivity
    }

    /// A document that goes (replaced, closed) has left UIKit's user-activity registry on the main
    /// thread before UIDocumentViewController closes it on its background queue: that close would
    /// take it out there while the main thread takes the controller out of the same entry
    /// ("NSConcreteHashTable was mutated while being enumerated", once on close).
    @Test(.timeLimit(.minutes(1))) func goneDocumentsLeaveTheirUserActivityOnTheMainThread() async throws {
        let a = try Fixture.copy("zip/deflate.zip"), b = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        browser.present(documentAt: a, animated: false)
        try await waitUntil { settled(browser) && opened(browser.presentedDocument) }
        let first = try #require(browser.presentedDocument)
        if let registered = try hasRegisteredActivity(first) { try #require(registered, "no user activity: nothing to race") }

        browser.present(documentAt: b)
        if let registered = try hasRegisteredActivity(first) { #expect(registered == false) }
        try await waitUntil { opened(browser.presentedDocument) }
        let second = try #require(browser.presentedDocument)
        try #require(second !== first)
        if let registered = try hasRegisteredActivity(second) { try #require(registered, "no user activity: nothing to race") }

        let controller = try #require(documentController(of: browser))
        controller.closeDocument()
        try await waitUntil { browser.presentedViewController == nil && browser.flow.phase == .idle }
        #expect(controller.document == nil)
        if let registered = try hasRegisteredActivity(second) { #expect(registered == false) }
        #expect(controller.userActivity == nil)
        try await tearDown(browser, window, documents: [first, second])
    }

    /// A window going away (its scene's disconnect) closes its document only
    /// once the document and the archive's controller have left UIKit's user-activity registry
    /// on the main thread (the same race as above, on an iPad window's close).
    @Test(.timeLimit(.minutes(1))) func disconnectedWindowsDocumentLeavesItsUserActivityOnTheMainThread() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        let id = try #require(browser.sceneSession?.persistentIdentifier)
        browser.present(documentAt: a, animated: false)
        try await waitUntil { settled(browser) && opened(browser.presentedDocument) }
        let document = try #require(browser.presentedDocument)
        let controller = try #require(documentController(of: browser))
        if let registered = try hasRegisteredActivity(document) { try #require(registered, "no user activity: nothing to race") }

        browser.closeForDisconnect(sessionID: id)
        if let registered = try hasRegisteredActivity(document) { #expect(registered == false) }
        #expect(controller.userActivity == nil)
        try await waitUntil { document.documentState.contains(.closed) }
        #expect(document.documentState.contains(.closed))
        #expect(OpenDocuments.sessionID(for: a) == nil)
        try await tearDown(browser, window, documents: [document])
    }

    /// A transition coordinator that doesn't queue the completion (`animate`
    /// returns false) may never call it: the step after the transition (a close's dismissal
    /// retry, a held file) runs anyway, and once whichever way it comes.
    @Test(.timeLimit(.minutes(1))) func stepAfterATransitionRunsWhenTheCoordinatorDoesNotQueueIt() async throws {
        let log = MainCallLog()
        DocumentBrowserController.afterTransition(animate: { _ in false }) { log.calls.append("not queued") }
        DocumentBrowserController.afterTransition(animate: { completion in
            completion()
            return false
        }) { log.calls.append("called anyway") }
        DocumentBrowserController.afterTransition(animate: { completion in
            completion()
            return true
        }) { log.calls.append("queued") }
        DocumentBrowserController.afterTransition(animate: nil) { log.calls.append("no coordinator") }
        try await waitUntil { log.calls.count >= 4 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.calls.sorted() == ["called anyway", "no coordinator", "not queued", "queued"])
    }

    /// Major 1: a file asked for while a sheet goes away waits for it instead of being dropped
    /// with its window's entry left behind.
    @Test(.timeLimit(.minutes(1))) func fileWhileASheetIsDismissedComesUpAfter() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        let id = try #require(browser.sceneSession?.persistentIdentifier)
        let sheet = UIViewController()
        browser.present(sheet, animated: false)
        try await waitUntil { browser.presentedViewController === sheet && !sheet.isBeingPresented }

        browser.dismiss(animated: true)
        try #require(sheet.isBeingDismissed, "the sheet's dismissal didn't start")
        browser.present(documentAt: a)
        #expect(browser.flow.pending == a)
        #expect(OpenDocuments.sessionID(for: a) == nil, "registered before it could come up")
        try await waitUntil { settled(browser) }

        #expect(browser.presentedDocument != nil)
        #expect(OpenDocuments.sessionID(for: a) == id)
        try await tearDown(browser, window, documents: [browser.presentedDocument])
    }

    /// Welcome sheet: a file asked for while the Welcome sheet is up (Open In, a URL) takes it
    /// away first and comes up over the browser, not over the sheet; nothing is left behind once
    /// the archive closes.
    @Test(.timeLimit(.minutes(1))) func fileWhileTheWelcomeSheetIsUpDismissesItFirst() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        let id = try #require(browser.sceneSession?.persistentIdentifier)
        let (defaults, suite) = makeTestDefaults("WelcomeHosted")
        defer { removeTestDefaults(defaults, suite: suite) }
        let welcome = WelcomeSheet.makeController(appName: "Kernir", settings: WelcomeSettings(defaults: defaults))
        browser.welcomeSheet = welcome
        browser.present(welcome, animated: false)
        try await waitUntil { browser.presentedViewController === welcome && !welcome.isBeingPresented }

        browser.present(documentAt: a)
        #expect(welcome.isBeingDismissed, "the Welcome sheet didn't start going away")
        try await waitUntil { settled(browser) }

        #expect(welcome.presentingViewController == nil, "the Welcome sheet is still up")
        #expect(browser.presentedViewController !== welcome)
        #expect(browser.presentedDocument != nil, "the archive never came up")
        #expect(OpenDocuments.sessionID(for: a) == id)
        try await tearDown(browser, window, documents: [browser.presentedDocument])
        #expect(browser.presentedViewController == nil, "something is left over the browser after the close")
    }

    /// Welcome: a file asked for (open-URL) while the Welcome sheet is still on its
    /// way up waits for that present, then takes the sheet away and comes up over the browser: the
    /// archive opens, and no sheet is left stuck or presented twice, before or after its close.
    @Test(.timeLimit(.minutes(1))) func fileDuringTheWelcomeSheetsAnimatedPresentOpensOverTheBrowser() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        let id = try #require(browser.sceneSession?.persistentIdentifier)
        let (defaults, suite) = makeTestDefaults("WelcomeHosted")
        defer { removeTestDefaults(defaults, suite: suite) }
        let welcome = WelcomeSheet.makeController(appName: "Kernir", settings: WelcomeSettings(defaults: defaults))
        browser.welcomeSheet = welcome
        browser.present(welcome, animated: true)
        // UIKit starts the sheet's transition a moment after the present.
        try await waitUntil { welcome.isBeingPresented }
        try #require(welcome.isBeingPresented, "the Welcome sheet isn't on its way up")

        browser.present(documentAt: a)
        try await waitUntil { settled(browser) }

        #expect(browser.presentedDocument != nil, "the archive never came up")
        #expect(OpenDocuments.sessionID(for: a) == id)
        #expect(welcome.presentingViewController == nil, "the Welcome sheet is stuck under or over the archive")
        let nav = try #require(browser.presentedViewController as? UINavigationController)
        #expect(nav.presentedViewController == nil, "something is presented over the archive")
        #expect(browser.flow.phase == .showing)
        try await tearDown(browser, window, documents: [browser.presentedDocument])
        #expect(browser.presentedViewController == nil, "something is left over the browser after the close")
        #expect(welcome.presentingViewController == nil, "the Welcome sheet came back after the close")
    }

    /// Welcome: the first appearance's hook (the Welcome sheet) runs with the scene
    /// active. An appearance before the scene is active (iOS 17 at launch) waits for that scene's
    /// activation, and runs the hook once.
    @Test(.timeLimit(.minutes(1))) func afterFirstAppearanceWaitsForTheScenesActivation() async throws {
        let center = NotificationCenter()
        var runs = 0
        var active = false
        let (browser, window) = try await hostedBrowser { browser in
            browser.sceneIsActive = { _ in active }
            browser.activationNotifications = center
            browser.afterFirstAppearance = { _ in runs += 1 }
        }
        let scene = try #require(window.windowScene)
        #expect(runs == 0, "the hook ran with the scene not active")

        // Another scene's activation isn't this one's.
        center.post(name: UIScene.didActivateNotification, object: NSObject())
        try await Task.sleep(for: .milliseconds(200))
        #expect(runs == 0)

        active = true
        center.post(name: UIScene.didActivateNotification, object: scene)
        try await waitUntil { runs > 0 }
        #expect(runs == 1, "the hook didn't run on the scene's activation")
        center.post(name: UIScene.didActivateNotification, object: scene)
        try await Task.sleep(for: .milliseconds(200))
        #expect(runs == 1, "the hook ran again")
        try await tearDown(browser, window, documents: [])
    }

    /// The browser's wait for its scene's activation (`NotificationObservation`) ends
    /// when the observation is released, as it is with the browser, not only on the activation.
    @Test func activationObservationIsRemovedWhenReleased() {
        final class Runs: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            var count: Int { lock.withLock { value } }
            func add() { lock.withLock { value += 1 } }
        }
        let center = NotificationCenter()
        let name = Notification.Name("KernirActivationObservationTest")
        let runs = Runs()
        var observation: NotificationObservation? = NotificationObservation(
            center, name: name, object: nil, queue: nil) { _ in runs.add() }
        center.post(name: name, object: nil)
        #expect(runs.count == 1)
        #expect(observation != nil)
        observation = nil
        center.post(name: name, object: nil)
        #expect(runs.count == 1, "the observer is still registered after its release")
    }

    /// Welcome: with the scene active at the first appearance, the hook runs then, once.
    @Test(.timeLimit(.minutes(1))) func afterFirstAppearanceRunsAtOnceWhenTheSceneIsActive() async throws {
        let center = NotificationCenter()
        var runs = 0
        let (browser, window) = try await hostedBrowser { browser in
            browser.sceneIsActive = { _ in true }
            browser.activationNotifications = center
            browser.afterFirstAppearance = { _ in runs += 1 }
        }
        #expect(runs == 1)
        center.post(name: UIScene.didActivateNotification, object: window.windowScene)
        try await Task.sleep(for: .milliseconds(200))
        #expect(runs == 1, "the hook ran again")
        try await tearDown(browser, window, documents: [])
    }

    /// Welcome: the sheet is marked seen once it has appeared, not before: a present
    /// that never comes up (over a browser off screen) leaves it for a later launch.
    @Test(.timeLimit(.minutes(1))) func welcomeSheetIsMarkedSeenOnlyOnceItAppeared() async throws {
        let (defaults, suite) = makeTestDefaults("WelcomeHosted")
        defer { removeTestDefaults(defaults, suite: suite) }
        let settings = WelcomeSettings(defaults: defaults)

        let offScreen = DocumentBrowserController()
        offScreen.present(WelcomeSheet.makeController(appName: "Kernir", settings: settings), animated: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!settings.hasBeenSeen, "a present that never came up marked the sheet seen")

        let (browser, window) = try await hostedBrowser()
        let welcome = WelcomeSheet.makeController(appName: "Kernir", settings: settings)
        browser.present(welcome, animated: true)
        #expect(!settings.hasBeenSeen, "marked seen before the sheet appeared")
        try await waitUntil { settings.hasBeenSeen }
        #expect(settings.hasBeenSeen, "the sheet appeared but isn't marked seen")
        #expect(browser.presentedViewController === welcome)
        browser.dismiss(animated: false)
        try await tearDown(browser, window, documents: [])
    }

    /// The Welcome sheet's dismissal (here Continue) is posted once, with the scene of the window
    /// it was presented in (`WelcomeSheet.didDismissNotification`).
    @Test(.timeLimit(.minutes(1))) func welcomeSheetDismissalIsPostedOnceWithItsScene() async throws {
        let (defaults, suite) = makeTestDefaults("WelcomeHosted")
        defer { removeTestDefaults(defaults, suite: suite) }
        let (browser, window) = try await hostedBrowser()
        let scene = try #require(window.windowScene)
        let welcome = try #require(WelcomeSheet.makeController(appName: "Kernir",
                                                               settings: WelcomeSettings(defaults: defaults))
                                   as? WelcomeSheetController)
        browser.present(welcome, animated: false)
        try await waitUntil { browser.presentedViewController === welcome && !welcome.isBeingPresented }

        let posted = PostedObjects()
        let observer = NotificationCenter.default.addObserver(forName: WelcomeSheet.didDismissNotification,
                                                              object: nil, queue: .main) { note in
            let object = note.object.map { ObjectIdentifier($0 as AnyObject) }
            MainActor.assumeIsolated { posted.objects.append(object) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        welcome.rootView.onContinue()
        try await waitUntil { welcome.presentingViewController == nil && !posted.objects.isEmpty }
        try await Task.sleep(for: .milliseconds(200))

        #expect(welcome.presentingViewController == nil, "Continue didn't close the sheet")
        #expect(posted.objects.count == 1, "posted \(posted.objects.count) times")
        #expect(posted.objects.first == ObjectIdentifier(scene), "not posted with the window's scene")
        try await tearDown(browser, window, documents: [])
    }

    // MARK: - Closing and reopening

    /// The archive's model is ready: the document has opened and read its file.
    private func opened(_ document: ArchiveDocument?) -> Bool { document?.session.model != nil }

    /// (b) Close, then the same file again: the new document opens only once the old one has
    /// closed, and reads what the old one saved on its way out.
    @Test(.timeLimit(.minutes(1))) func reopenedFileWaitsForTheClosingDocumentsSave() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        let id = try #require(browser.sceneSession?.persistentIdentifier)
        let live = DocumentEngine.live
        var slow = live
        slow.write = { source, changes, format, url, options, progress in
            try await Task.sleep(for: .seconds(1))
            try await live.write(source, changes, format, url, options, progress)
        }
        ArchiveDocument.engine = slow
        browser.present(documentAt: a, animated: false)
        ArchiveDocument.engine = .live
        try await waitUntil { settled(browser) && opened(browser.presentedDocument) }
        let first = try #require(browser.presentedDocument)
        try #require(first.session.model).remove(["hello.txt"])
        try await waitUntil { first.hasUnsavedChanges }
        try #require(first.hasUnsavedChanges)

        try #require(documentController(of: browser)).closeDocument()
        browser.present(documentAt: a)
        var openedEarly = false
        try await waitUntil {
            let shown = browser.presentedDocument
            if let shown, shown !== first, !first.documentState.contains(.closed) { openedEarly = true }
            return settled(browser) && shown !== first && opened(shown)
        }

        #expect(!openedEarly, "the new document came before the old one had closed")
        #expect(first.documentState.contains(.closed))
        let second = try #require(browser.presentedDocument)
        #expect(second !== first)
        let items = try #require(second.session.model).items
        #expect(!items.contains { $0.name == "hello.txt" }, "the old document's save isn't visible")
        #expect(!items.isEmpty)
        #expect(OpenDocuments.sessionID(for: a) == id)
        try await tearDown(browser, window, documents: [first, second])
    }

    /// (a) A present over a controller that is off screen never comes up: no entry, idle again.
    @Test(.timeLimit(.minutes(1))) func presentOverAnOffWindowControllerClearsItsEntry() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        window.isHidden = true
        window.rootViewController = nil
        try #require(browser.viewIfLoaded?.window == nil)

        browser.present(documentAt: a, animated: false)
        try await waitUntil { browser.flow.phase == .idle && OpenDocuments.sessionID(for: a) == nil }

        #expect(browser.flow.phase == .idle)
        #expect(browser.presentedDocument == nil)
        #expect(OpenDocuments.sessionID(for: a) == nil)
        OpenDocuments.forget(sessionID: browser.sceneSession?.persistentIdentifier ?? "")
    }

    /// (a) An animated present over a browser on screen always comes up: once its transition is
    /// over, the archive shows and the window keeps its entry (no timed give-up).
    @Test(.timeLimit(.minutes(1))) func animatedPresentOverAnOnWindowBrowserSettlesShowing() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        let id = try #require(browser.sceneSession?.persistentIdentifier)

        browser.present(documentAt: a, animated: true)
        #expect(OpenDocuments.sessionID(for: a) == id)
        try await waitUntil { settled(browser) }

        #expect(settled(browser))
        #expect(browser.flow.phase == .showing)
        #expect(browser.presentedViewController?.view.window === window)
        #expect(OpenDocuments.sessionID(for: a) == id)
        try await tearDown(browser, window, documents: [browser.presentedDocument])
    }

    /// DEBUG `-KernirCompactWidth`: the archive presented over the browser, and a popover from it
    /// (Share), are compact width like the window, so the popover comes up as a sheet.
    @Test(.timeLimit(.minutes(1))) func compactWidthOverrideReachesThePresentedArchive() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let browser = DocumentBrowserController()
        browser.sceneSession = scene.session
        browser.forcesCompactWidth = true
        let window = UIWindow(windowScene: scene)
        window.traitOverrides.horizontalSizeClass = .compact
        window.rootViewController = browser
        window.isHidden = false
        try await waitUntil { browser.flow.hasAppeared }
        browser.present(documentAt: a, animated: false)
        try await waitUntil { settled(browser) }
        let docVC = try #require(documentController(of: browser))
        #expect(docVC.traitCollection.horizontalSizeClass == .compact)

        let popover = UIViewController()
        popover.modalPresentationStyle = .popover
        popover.popoverPresentationController?.sourceView = docVC.view
        docVC.present(popover, animated: false)
        try await waitUntil { popover.presentingViewController != nil && !popover.isBeingPresented }
        #expect(popover.presentationController?.traitCollection.horizontalSizeClass == .compact)
        #expect(popover.traitCollection.horizontalSizeClass == .compact)
        docVC.dismiss(animated: false)
        try await waitUntil { docVC.presentedViewController == nil }

        // SwiftUI's popover, adapted, comes up as a sheet with detents: compact, it spans the
        // width instead of a centred form-sheet card.
        let sheet = UIViewController()
        sheet.modalPresentationStyle = .pageSheet
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        docVC.present(sheet, animated: false)
        try await waitUntil { sheet.presentingViewController != nil && !sheet.isBeingPresented }
        #expect(sheet.presentationController?.traitCollection.horizontalSizeClass == .compact)
        #expect(sheet.view.frame.width == window.bounds.width, "the sheet is a card, not full width")
        docVC.dismiss(animated: false)
        try await waitUntil { docVC.presentedViewController == nil }
        try await tearDown(browser, window, documents: [browser.presentedDocument])
    }

    /// (c) Close while a sheet comes up over the archive: UIKit drops that dismissal, which never
    /// calls back. The close still ends instead of staying in `.closing`.
    @Test(.timeLimit(.minutes(1))) func closeWhileASheetComesUpOverTheArchiveStillEnds() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        browser.present(documentAt: a, animated: false)
        try await waitUntil { settled(browser) }
        let first = browser.presentedDocument
        let nav = try #require(browser.presentedViewController)
        let docVC = try #require(documentController(of: browser))

        nav.present(UIViewController(), animated: true)
        try #require(nav.presentedViewController?.isBeingPresented == true, "the sheet isn't on its way up")
        docVC.closeDocument()
        #expect(browser.flow.phase == .closing)
        try await waitUntil { browser.flow.phase != .closing && browser.presentedViewController == nil }

        #expect(browser.flow.phase == .idle)
        #expect(browser.presentedViewController == nil)
        #expect(OpenDocuments.sessionID(for: a) == nil)
        try await tearDown(browser, window, documents: [first])
    }

    /// The window goes away mid-close: its document closes once (saving), its entry goes, and
    /// the browser's close still ends.
    @Test(.timeLimit(.minutes(1))) func sceneDisconnectWhileClosingClosesTheDocument() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        browser.present(documentAt: a, animated: false)
        try await waitUntil { settled(browser) && opened(browser.presentedDocument) }
        let first = try #require(browser.presentedDocument)
        let scene = try #require(window.windowScene)
        let delegate = SceneDelegate()
        delegate.browser = browser

        let controller = try #require(documentController(of: browser))
        if let registered = try hasRegisteredActivity(first) { try #require(registered, "no user activity: nothing to leave") }
        controller.closeDocument()
        try #require(browser.flow.phase == .closing)
        delegate.sceneDidDisconnect(scene)
        #expect(controller.userActivity == nil)
        if let registered = try hasRegisteredActivity(first) { #expect(registered == false) }
        try await waitUntil { browser.flow.phase == .idle && first.documentState.contains(.closed) }

        #expect(browser.flow.phase == .idle)
        #expect(first.documentState.contains(.closed))
        #expect(browser.presentedViewController == nil)
        #expect(OpenDocuments.sessionID(for: a) == nil)
        try await tearDown(browser, window, documents: [first])
    }

    /// The present forced after `retryLimit` holds goes ahead while the chain is still in
    /// transition, and UIKit drops it without a word: once that transition is over, the browser is
    /// alone again, idle, and the window has no entry for the file.
    @Test(.timeLimit(.minutes(1))) func forcedPresentDroppedByUIKitClearsItsEntry() async throws {
        let a = try Fixture.copy("zip/deflate.zip")
        let (browser, window) = try await hostedBrowser()
        let sheet = UIViewController()
        browser.present(sheet, animated: false)
        try await waitUntil { browser.presentedViewController === sheet && !sheet.isBeingPresented }
        browser.dismiss(animated: true)
        try #require(sheet.isBeingDismissed, "the sheet's dismissal didn't start")

        browser.presentIgnoringTransition(documentAt: a, animated: true)
        let dropped = try #require(browser.presentedDocument, "the forced present didn't go ahead")
        try await waitUntil { browser.presentedViewController == nil }
        try #require(browser.presentedViewController == nil, "the archive came up: UIKit didn't drop it")
        try await waitUntil { browser.flow.phase == .idle && OpenDocuments.sessionID(for: a) == nil }

        #expect(browser.flow.phase == .idle)
        #expect(browser.presentedDocument == nil)
        #expect(OpenDocuments.sessionID(for: a) == nil)
        try await tearDown(browser, window, documents: [dropped])
    }
}

/// The objects of the notifications a test saw.
@MainActor private final class PostedObjects {
    var objects: [ObjectIdentifier?] = []
}
