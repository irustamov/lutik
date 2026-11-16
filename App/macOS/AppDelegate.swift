import AppKit

/// AppKit lifecycle without a nib: install the delegate and the programmatic main menu, then run.
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication holds its delegate weakly.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    /// The running Dock tile: the Lutik art on a transparent background, no system plate.
    /// Finder, Launchpad and the App Store keep AppIcon.icon. `DockIcon.png` is a 512 px resource in the
    /// app bundle; a missing one leaves the default icon. Dock badges are untouched (`applicationIconImage`
    /// replaces the image only, not the tile's content view). The art's box is 406 x 472 of 512 px (about
    /// 79 % x 92 %): taller than the 824/1024 squircle so the narrower shape looks as big as its neighbours.
    static let dockIconName = "DockIcon"

    @MainActor static func installDockIcon(into app: NSApplication = .shared, named name: String = dockIconName) {
        guard let image = NSImage(named: name) else { return }
        app.applicationIconImage = image
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.installDockIcon()
        // Create the document controller before AppKit opens files passed at launch. The first
        // one created becomes `NSDocumentController.shared`.
        let documents = KernirDocumentController()
        // Before any document opens (so no root is live yet): delete the Quick Look stand-in
        // folders a crashed run left behind. Never throws; failures are logged.
        PreviewLeftoverSweeper.runAtLaunch()
        // Copy's export folders a previous run left (a crash skips the quit sweep); not another
        // instance's live ones, and none while tests host the app.
        ArchiveActions.sweepClipboardExports()
        // Drag-out folders (`ArchiveDragOutFiles`) a crashed run left, once old; none while tests host the app.
        ArchiveDragOutFolders.removeLeftovers()
        // An open request (from Finder too) counts as soon as it arrives, while its document
        // still loads with no window, so a queue draining then doesn't quit under it.
        documents.willOpenDocument = { [weak self] in
            self?.launchFlag.noteOpened()
            self?.openRequested = true
        }
        // A launch decision that skipped the Welcome window for restored documents still reading
        // decides again once they are done, if none opened (`welcomeReopensFinished`).
        documents.reopensDidFinish = { [weak self] in self?.welcomeReopensFinished() }
        #if DEBUG
        if LaunchOverrides.welcomeReset {
            UserDefaults.standard.removeObject(forKey: WelcomeSettings.seenKey)
            UserDefaults.standard.removeObject(forKey: WelcomeSettings.showAtLaunchKey)
        }
        #endif
        // Before launch finishes: a launch only to run a Service delivers it right after.
        let runner = ServicesJobRunner.live()
        let jobs = ServicesJobQueue(run: { await runner.run($0, progress: $1, prompting: $2) },
                                    effects: .live(launchFlag: { [weak self] in self?.launchFlag ?? ServicesLaunchFlag() }))
        servicesJobs = jobs
        let provider = ServicesProvider(submit: { [weak self] job in
            self?.servicesRequestArrived()
            jobs.submit(job)
        })
        servicesProvider = provider
        NSApp.servicesProvider = provider
        // A document's or a window's opening makes the launch a usual one for good. A
        // document counts through its window; panels (alerts, the Allow panel, the progress
        // panel) never do.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidOpen(_:)), name: name, object: nil)
        }
        // So does an action from the menu bar: About or File > Open opens a panel that hides
        // when Finder comes in front. Not one under the queue's own prompts (the Allow panel's
        // ⌘V): they are the Services job's, not the user using the app.
        menuActivity = ServicesMenuActivity(queue: jobs, noteOpened: { [weak self] in self?.launchFlag.noteOpened() })
   }

    /// Notes the menu bar's actions in `launchFlag`.
    private var menuActivity: ServicesMenuActivity?

    /// A window became key or main (AppKit posts it on the main thread). The Welcome window too:
    /// the user working in it (its checkbox, Make Default, Open Archive) makes it key, and it
    /// opens by itself only at a launch that counts already (`WelcomeLaunch`). A new document's
    /// first window closes the Welcome window (`WelcomeDocumentWindows`, which sees every
    /// document window, Welcome open or not).
    @MainActor @objc private func windowDidOpen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !(window is NSPanel) else { return }
        launchFlag.noteOpened()
        guard let document = window.windowController?.document as? NSDocument else { return }
        if welcomeDocumentWindows.documentWindowActivated(document, fileURL: document.fileURL,
                                                          welcomeShowing: welcome?.isShowing == true) {
            welcome?.close()
        }
    }

    /// The Welcome window, made the first time it shows.
    @MainActor private var welcome: WelcomeWindowController?

    /// The document windows seen so far, for when the Welcome window closes.
    @MainActor private lazy var welcomeDocumentWindows = WelcomeDocumentWindows()

    /// An open request or a document opening arrived (`WelcomeLaunch`).
    private var openRequested = false

    /// A Finder Service sent a job: a Services launch, when it comes at launch (`WelcomeLaunch`).
    private var servicesRequested = false

    /// The files the launch's open requests named, until the launch decision
    /// (`showWelcomeAtLaunchIfNeeded`): their windows don't close the Welcome window.
    @MainActor private var launchOpenURLs: [URL] = []

    /// The Welcome window's launch decision has run.
    @MainActor private var welcomeLaunchDecided = false

    /// The launch decision skipped the Welcome window while state restoration still read
    /// documents (`KernirDocumentController.isReopeningDocuments`): it decides again once they
    /// are done (`welcomeReopensFinished`).
    @MainActor private var welcomeLaunchAwaitsReopens = false

    /// The launch was a default one (`showWelcomeAtLaunchIfNeeded`), for deciding again.
    @MainActor private var welcomeLaunchIsDefault = true

    /// A non-default launch's deferred Welcome decision, pending (`WelcomeLaunch.servicesGracePeriod`).
    @MainActor private var welcomeLaunchDeferral: Task<Void, Never>?

    /// A Service's job came (`WelcomeLaunch`).
    @MainActor private func servicesRequestArrived() {
        servicesRequested = true
    }

    /// Window > Welcome to <app> (⇧⌘1), a Dock click, or launch (`WelcomeLaunch`).
    @MainActor @objc func showWelcome(_ sender: Any?) {
        showWelcomeWindow()
    }

    @MainActor private func showWelcomeWindow(withDocument: Bool = false, awaiting urls: [URL] = []) {
        // Shown now (⇧⌘1, a Dock click): the launch's deferred decision doesn't show it again,
        // nor do failed state restores once it is closed (`WelcomeLaunch.decideAfterReopens`).
        welcomeLaunchDeferral?.cancel()
        welcomeLaunchDeferral = nil
        welcomeLaunchAwaitsReopens = false
        let controller = welcome ?? WelcomeWindowController(documentWindows: welcomeDocumentWindows)
        welcome = controller
        controller.show(withDocument: withDocument, awaiting: urls)
    }

    /// Launch has settled: the launch's open requests and restored windows are in. A launch
    /// AppKit doesn't call default with nothing to open may be for a Service whose request is
    /// still to come: the decision waits `WelcomeLaunch.servicesGracePeriod` for it, and with a
    /// request (or an open) the window stays closed and the first-run one unseen.
    @MainActor private func showWelcomeAtLaunchIfNeeded(isDefaultLaunch: Bool) {
        welcomeLaunchDecided = true
        let urls = launchOpenURLs
        launchOpenURLs = []
        // Never in the KernirMacTests host: its tests count windows, and it would mark it seen.
        guard !PreviewLeftoverSweeper.isHostedByTests else { return }
        welcomeLaunchIsDefault = isDefaultLaunch
        let hasDocuments = hasDocumentsForWelcome
        switch WelcomeLaunch.decideAtLaunch(WelcomeSettings(), isDefaultLaunch: isDefaultLaunch,
                                            servicesRequested: servicesRequested,
                                            openRequested: openRequested, hasDocuments: hasDocuments) {
        case .show:
            showWelcomeWindow(withDocument: openRequested || hasDocuments, awaiting: urls)
        case .skip:
            welcomeLaunchAwaitsReopens = isReopeningDocuments
        case .deferForServices:
            welcomeLaunchDeferral = Task { @MainActor [weak self] in
                try? await Task.sleep(for: WelcomeLaunch.servicesGracePeriod)
                guard !Task.isCancelled else { return }
                self?.resolveDeferredWelcomeLaunch()
            }
        }
    }

    /// The grace period is over with the deferral still pending: show the window unless a Service
    /// request or an open came meanwhile (`WelcomeLaunch.resolveDeferred`).
    @MainActor private func resolveDeferredWelcomeLaunch() {
        welcomeLaunchDeferral = nil
        guard WelcomeLaunch.resolveDeferred(WelcomeSettings(), servicesRequested: servicesRequested,
                                            openRequested: openRequested,
                                            hasDocuments: hasDocumentsForWelcome) == .show else {
            welcomeLaunchAwaitsReopens = isReopeningDocuments
            return
        }
        guard welcome?.isShowing != true else { return }
        showWelcomeWindow()
    }

    /// State restoration's last pending reopen is done: the launch decides again with the usual
    /// rules when `WelcomeLaunch.decideAfterReopens` says so.
    @MainActor private func welcomeReopensFinished() {
        let awaits = welcomeLaunchAwaitsReopens
        welcomeLaunchAwaitsReopens = false
        guard WelcomeLaunch.decideAfterReopens(awaits: awaits, hasDocuments: hasDocumentsForWelcome,
                                               isShowing: welcome?.isShowing == true) else { return }
        showWelcomeAtLaunchIfNeeded(isDefaultLaunch: welcomeLaunchIsDefault)
    }

    /// State restoration is still reading documents (`KernirDocumentController.isReopeningDocuments`).
    @MainActor private var isReopeningDocuments: Bool {
        (NSDocumentController.shared as? KernirDocumentController)?.isReopeningDocuments ?? false
    }

    /// Documents open, or ones state restoration still reads (`KernirDocumentController.hasDocumentsForWelcome`).
    @MainActor private var hasDocumentsForWelcome: Bool {
        (NSDocumentController.shared as? KernirDocumentController)?.hasDocumentsForWelcome
            ?? !NSDocumentController.shared.documents.isEmpty
    }

    /// Finder's Services (Info.plist `NSServices`), kept here as well as in `NSApp`.
    private(set) var servicesProvider: ServicesProvider?

    /// Runs the Services' jobs, with no window.
    private var servicesJobs: ServicesJobQueue?

    /// Whether this launch was only to run a Service, open a file or restore windows, and whether
    /// the user has used the app since (a document or a window opened, an open request, a menu
    /// bar action, a Dock click): the quit rule after the Services' jobs
    /// (`ServicesJobQueue.shouldQuit`) reads it. Readable for `OpenRequestQuitRuleTests`.
    private(set) var launchFlag = ServicesLaunchFlag()

    /// The menu goes in after launch: while launching, NSDocumentController inserts its own
    /// Open Recent item into a menu that lacks AppKit's (private) recent-documents marker,
    /// which would duplicate ours.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        let isDefault = ServicesProvider.isDefaultLaunch(notification.userInfo)
        launchFlag.finishLaunching(isDefault: isDefault)
        // The next main-queue turn, once launch's open requests are in (`WelcomeLaunch`).
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.showWelcomeAtLaunchIfNeeded(isDefaultLaunch: isDefault) }
        }
    }

    @MainActor @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: AboutCredits.panelOptions())
    }

    @MainActor @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.showSettings(sender)
    }

    /// Edit > Cut and Copy where no archive window is key or main to take them (the About panel, Settings, a
    /// full-screen preview): the standard cut: / copy: (`StandardEditCommand`). Tests stand in their own target.
    @MainActor var standardEdit = StandardEditCommand()

    @MainActor @objc func copySelection(_ sender: Any?) {
        standardEdit.send(#selector(NSText.copy(_:)), from: sender)
    }

    @MainActor @objc func cutSelection(_ sender: Any?) {
        standardEdit.send(#selector(NSText.cut(_:)), from: sender)
    }

    /// A click on the Dock icon (or another launch of the app while it runs): the user means to
    /// use it, so the queue doesn't quit it after a Services-only launch. Not
    /// `didBecomeActiveNotification`: the jobs' own Allow panel and alerts activate the app.
    /// With no window to bring forward and no document open, it shows the Welcome window while
    /// "Show this window when <app> opens" is on.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launchFlag.noteOpened()
        if WelcomeLaunch.showsOnReopen(WelcomeSettings(), hasVisibleWindows: flag,
                                       hasDocuments: !NSDocumentController.shared.documents.isEmpty) {
            showWelcomeWindow()
            return false
        }
        return true
    }

    /// Every open request from outside: files dropped on the Dock icon, Open With, `open`, a
    /// double click in Finder. AppKit
    /// may split one request into several calls (archives in one, other files in another), so
    /// `openBatch` gathers the calls that come close together into one request for
    /// `OpenRequest.handle`: archives open as before, each through `KernirDocumentController`, with
    /// its error presented as AppKit did; anything else (a plain file or folder, alone or among
    /// archives) goes into one new untitled archive window with the Save sheet on it, or into the
    /// one an earlier drop opened while it is still unsaved. The request counts as use at once,
    /// so a queue draining while it gathers never quits under it. Non-file URLs are ignored
    /// (Lutik declares no URL scheme).
    func application(_ sender: NSApplication, open urls: [URL]) {
        // OpenRequestQuitRuleTests checks this counts for the quit rule.
        launchFlag.noteOpened()
        openRequested = true
        if !welcomeLaunchDecided { launchOpenURLs += urls }
        openBatch.add(urls)
    }

    /// The open requests' calls, gathered (`application(_:open:)`).
    @MainActor private lazy var openBatch = OpenBatch(deliver: { [weak self] in self?.deliverOpenRequest($0) })

    /// A gathered open request: when its items go into a new untitled archive, that window is the
    /// one the Welcome window waits for instead of theirs (`WelcomeDocumentWindows`).
    @MainActor private func deliverOpenRequest(_ urls: [URL]) {
        if case .newArchive(let items)? = OpenRoute.route(urls, opensInKernir: ServicesRequest.opensInKernir) {
            welcomeDocumentWindows.newArchiveWillOpen(for: items)
        }
        openRequest.handle(urls)
    }

    /// What a gathered open request does (`application(_:open:)`); keeps the Dock session's window.
    /// An open that brings no new window (it failed, or the document was open already) ends the
    /// Welcome window's wait for it (`WelcomeDocumentWindows`).
    @MainActor private lazy var openRequest = OpenRequest(open: { [weak self] url in
        let controller = NSDocumentController.shared
        controller.openDocument(withContentsOf: url, display: true) { [weak self] _, alreadyOpen, error in
            if error != nil || alreadyOpen { self?.welcomeDocumentWindows.stopAwaiting(url) }
            guard let error, (error as? CocoaError)?.code != .userCancelled else { return }
            controller.presentError(error)
        }
    }, newSession: { ArchiveDocument.makeNewArchiveSession() })

    /// This process's Copy export folders go at quit (a pending addition reads its copy at save, so they stay
    /// until then), for a bounded time (the next launch takes the rest), and the general pasteboard is cleared
    /// while it still holds Lutik's last copy or cut: no URLs of removed copies left for Finder. The drags out's
    /// plain files go too (`ArchiveDragOutFolders`).
    func applicationWillTerminate(_ notification: Notification) {
        ArchiveActions.clearIfStillOurs(.general)
        ArchiveActions.removeOwnClipboardExports()
        ArchiveDragOutFolders.shared.removeAll()
    }

    /// Launch with no window: File > New or Open, or a double-clicked archive, opens one.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

extension AppDelegate: NSMenuItemValidation {
    /// Edit > Cut and Copy as their standard target validates them; the delegate's other actions are always on.
    @MainActor func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copySelection(_:)):
            return standardEdit.validate(#selector(NSText.copy(_:)), for: menuItem)
        case #selector(cutSelection(_:)):
            return standardEdit.validate(#selector(NSText.cut(_:)), for: menuItem)
        default:
            return true
        }
    }
}
