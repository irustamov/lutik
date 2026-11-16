import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Kernir

/// When the Mac Welcome window opens by itself (WelcomeLaunch) and the default-app rows behind it
/// and Settings > General (DefaultAppModel).
@MainActor
struct WelcomeLaunchTests {
    private func withSettings(_ body: (WelcomeSettings, UserDefaults) -> Void) {
        let (defaults, suite) = makeTestDefaults("WelcomeLaunchTests")
        defer { removeTestDefaults(defaults, suite: suite) }
        body(WelcomeSettings(defaults: defaults), defaults)
    }

    private func decision(_ settings: WelcomeSettings, isDefaultLaunch: Bool = true, servicesRequested: Bool = false,
                          openRequested: Bool = false, hasDocuments: Bool = false) -> WelcomeLaunch.Decision {
        WelcomeLaunch.decideAtLaunch(settings, isDefaultLaunch: isDefaultLaunch, servicesRequested: servicesRequested,
                                     openRequested: openRequested, hasDocuments: hasDocuments)
    }

    private func shows(_ settings: WelcomeSettings, isDefaultLaunch: Bool = true, servicesRequested: Bool = false,
                       openRequested: Bool = false, hasDocuments: Bool = false) -> Bool {
        decision(settings, isDefaultLaunch: isDefaultLaunch, servicesRequested: servicesRequested,
                 openRequested: openRequested, hasDocuments: hasDocuments) == .show
    }

    private func resolved(_ settings: WelcomeSettings, servicesRequested: Bool = false, openRequested: Bool = false,
                          hasDocuments: Bool = false) -> WelcomeLaunch.Decision {
        WelcomeLaunch.resolveDeferred(settings, servicesRequested: servicesRequested,
                                      openRequested: openRequested, hasDocuments: hasDocuments)
    }

    @Test func firstLaunchShowsWithOrWithoutDocument() {
        withSettings { settings, _ in
            #expect(shows(settings))
            #expect(shows(settings, servicesRequested: true, openRequested: true))
            #expect(shows(settings, servicesRequested: true, hasDocuments: true))
            // A launch AppKit doesn't call default that opens or restores a document.
            #expect(shows(settings, isDefaultLaunch: false, openRequested: true))
            #expect(shows(settings, isDefaultLaunch: false, hasDocuments: true))
        }
    }

    /// A Finder Service request and nothing to open: a Services launch, never shown, not even first.
    @Test func servicesLaunchNeverShows() {
        withSettings { settings, _ in
            #expect(!shows(settings, servicesRequested: true))
            #expect(!shows(settings, isDefaultLaunch: false, servicesRequested: true))
            settings.markSeen()
            #expect(!shows(settings, servicesRequested: true))
            #expect(!shows(settings, isDefaultLaunch: false, servicesRequested: true))
        }
    }

    /// A launch AppKit doesn't call default with nothing to open (a relaunch that restored no
    /// window, or a Services launch whose request is still to come): the decision waits for the
    /// grace period, first launch or not.
    @Test func nonDefaultLaunchWithNothingOpenDefers() {
        withSettings { settings, _ in
            #expect(decision(settings, isDefaultLaunch: false) == .deferForServices)
            settings.markSeen()
            #expect(decision(settings, isDefaultLaunch: false) == .deferForServices)
            settings.showsAtLaunch = false
            #expect(decision(settings, isDefaultLaunch: false) == .deferForServices)
        }
        #expect(WelcomeLaunch.servicesGracePeriod == .seconds(1))
    }

    /// Default launches decide at once, never deferred.
    @Test func defaultLaunchNeverDefers() {
        withSettings { settings, _ in
            #expect(decision(settings) == .show)
            #expect(decision(settings, servicesRequested: true) == .skip)
            settings.markSeen()
            settings.showsAtLaunch = false
            #expect(decision(settings) == .skip)
        }
    }

    /// No Service request and nothing opened in the grace period: the usual rules (first launch,
    /// then the checkbox); the window marks itself seen only when it shows.
    @Test func deferredLaunchWithNothingArrivingFollowsTheUsualRules() {
        withSettings { settings, _ in
            #expect(resolved(settings) == .show)
            settings.markSeen()
            #expect(resolved(settings) == .show)
            settings.showsAtLaunch = false
            #expect(resolved(settings) == .skip)
        }
    }

    /// A Service request or a document open in the grace period: never shown, not even first (so
    /// never marked seen).
    @Test func deferredLaunchWithServiceOrOpenSkips() {
        withSettings { settings, _ in
            #expect(resolved(settings, servicesRequested: true) == .skip)
            #expect(resolved(settings, openRequested: true) == .skip)
            #expect(resolved(settings, hasDocuments: true) == .skip)
            #expect(!settings.hasBeenSeen)
        }
    }

    @Test func laterLaunchesOnlyWithNoDocumentAndCheckboxOn() {
        withSettings { settings, _ in
            settings.markSeen()
            #expect(shows(settings))
            #expect(!shows(settings, servicesRequested: true, openRequested: true))
            #expect(!shows(settings, hasDocuments: true))
            #expect(!shows(settings, isDefaultLaunch: false, hasDocuments: true))
            settings.showsAtLaunch = false
            #expect(!shows(settings))
        }
    }

    @Test func reopenShowsOnlyWithNothingOpenAndCheckboxOn() {
        withSettings { settings, _ in
            #expect(WelcomeLaunch.showsOnReopen(settings, hasVisibleWindows: false, hasDocuments: false))
            #expect(!WelcomeLaunch.showsOnReopen(settings, hasVisibleWindows: true, hasDocuments: false))
            #expect(!WelcomeLaunch.showsOnReopen(settings, hasVisibleWindows: false, hasDocuments: true))
            settings.showsAtLaunch = false
            #expect(!WelcomeLaunch.showsOnReopen(settings, hasVisibleWindows: false, hasDocuments: false))
        }
    }

    /// After state restoration's reopens are done the launch decides again only when it skipped the
    /// window for them (`awaits`), none of them opened a document and the window isn't showing. A
    /// manual show (⇧⌘1, a Dock click) clears `awaits`: closing that window and every restore then
    /// failing doesn't bring it back by itself.
    @Test func reopensFinishedDecidesAgainOnlyWhenAwaitedWithNothingOpenOrShowing() {
        #expect(WelcomeLaunch.decideAfterReopens(awaits: true, hasDocuments: false, isShowing: false))
        #expect(!WelcomeLaunch.decideAfterReopens(awaits: true, hasDocuments: true, isShowing: false))
        #expect(!WelcomeLaunch.decideAfterReopens(awaits: true, hasDocuments: false, isShowing: true))
        #expect(!WelcomeLaunch.decideAfterReopens(awaits: true, hasDocuments: true, isShowing: true))
        // Never awaited, or a manual show settled the launch decision.
        #expect(!WelcomeLaunch.decideAfterReopens(awaits: false, hasDocuments: false, isShowing: false))
        #expect(!WelcomeLaunch.decideAfterReopens(awaits: false, hasDocuments: true, isShowing: false))
        #expect(!WelcomeLaunch.decideAfterReopens(awaits: false, hasDocuments: false, isShowing: true))
    }

    @MainActor final class OpenCount { var count = 0 }

    /// A Dock or Spotlight launch that restores archive windows: AppKit reopens each document
    /// (`reopenDocument`) and reads it concurrently, so it may not be in `documents` yet when the
    /// launch decides. It counts as a document for the Welcome window while it reads, and still not
    /// as an open request (`willOpenDocument`). A restore that fails (the archive was deleted,
    /// its volume is gone) counts no more once it is done, and `reopensDidFinish` lets the launch
    /// decide again, so the Welcome window shows instead of no window at all.
    @Test(.timeLimit(.minutes(1))) func failedReopenStopsCountingAndLetsTheLaunchDecideAgain() async {
        let controller = KernirDocumentController()
        let opened = OpenCount()
        let finished = OpenCount()
        controller.willOpenDocument = { opened.count += 1 }
        controller.reopensDidFinish = { finished.count += 1 }
        #expect(!controller.hasDocumentsForWelcome)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("WelcomeLaunchTests-\(UUID().uuidString).zip")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controller.reopenDocument(for: missing, withContentsOf: missing, display: false) { _, _, _ in
                continuation.resume()
            }
            #expect(controller.hasDocumentsForWelcome)
            #expect(controller.isReopeningDocuments)
        }
        #expect(controller.documents.isEmpty)
        #expect(!controller.isReopeningDocuments)
        #expect(!controller.hasDocumentsForWelcome)
        #expect(finished.count == 1)
        #expect(opened.count == 0)
        withSettings { settings, _ in
            settings.markSeen()
            #expect(shows(settings, hasDocuments: controller.hasDocumentsForWelcome))
            #expect(resolved(settings, hasDocuments: controller.hasDocumentsForWelcome) == .show)
        }
    }

    /// A restore that succeeds keeps counting: its document is in `documents` by the time the
    /// reopen is done.
    @Test(.timeLimit(.minutes(1)), .enabled(if: Fixture.isReadable))
    func successfulReopenCountsForTheLaunchDecision() async throws {
        let controller = KernirDocumentController()
        let opened = OpenCount()
        let finished = OpenCount()
        controller.willOpenDocument = { opened.count += 1 }
        controller.reopensDidFinish = { finished.count += 1 }
        let archive = try Fixture.copy("zip/deflate.zip")
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            controller.reopenDocument(for: archive, withContentsOf: archive, display: false) { _, _, _ in
                continuation.resume()
            }
            #expect(controller.hasDocumentsForWelcome)
        }
        let document = try #require(controller.documents.first)
        defer {
            controller.removeDocument(document)
            document.close()
        }
        #expect(!controller.isReopeningDocuments)
        #expect(controller.hasDocumentsForWelcome)
        #expect(finished.count == 1)
        #expect(opened.count == 0)
        withSettings { settings, _ in
            settings.markSeen()
            #expect(!shows(settings, hasDocuments: controller.hasDocumentsForWelcome))
            #expect(!shows(settings, isDefaultLaunch: false, hasDocuments: controller.hasDocumentsForWelcome))
        }
    }

    /// The UI tests' `-KernirWelcomeShowAtLaunch NO` lands in the argument domain as a string.
    @Test func showAtLaunchReadsStringValues() {
        withSettings { settings, defaults in
            defaults.set("NO", forKey: WelcomeSettings.showAtLaunchKey)
            #expect(!settings.showsAtLaunch)
            defaults.set("YES", forKey: WelcomeSettings.showAtLaunchKey)
            #expect(settings.showsAtLaunch)
        }
    }

    // MARK: - DefaultAppModel

    private static let appURL = URL(fileURLWithPath: "/Applications/Lutik.app", isDirectory: true)

    @MainActor
    final class RecordingWorkspace: DefaultAppWorkspace {
        var handlers: [String: URL] = [:]
        var errors: [String: Error] = [:]
        private(set) var asked: [String] = []
        /// Whether a fresh process (Finder) sees the app as a type's default; nil = it can't tell.
        var finder: ((String) -> Bool)?
        func urlForApplication(toOpen contentType: UTType) -> URL? { handlers[contentType.identifier] }
        func handlersSeenByFinder(bundleIdentifier: String, types: [String]) async -> [String: Bool]? {
            guard let finder else { return nil }
            return Dictionary(uniqueKeysWithValues: types.map { ($0, finder($0)) })
        }
        func setDefaultApplication(at applicationURL: URL, toOpen contentType: UTType) async throws {
            asked.append(contentType.identifier)
            if let error = errors[contentType.identifier] { throw error }
            handlers[contentType.identifier] = applicationURL
        }
    }

    private func model(_ workspace: RecordingWorkspace) -> DefaultAppModel {
        DefaultAppModel(defaultApp: DefaultArchiveApp(appURL: Self.appURL, bundleIdentifier: "io.lutik.test", workspace: workspace),
                        appName: "Lutik")
    }

    /// The UI tests click "Make … the Default App" only once the dry run's marker shows
    /// (`DefaultAppDryRunMarker`): it is there with the dry-run stand-in alone.
    @Test func dryRunOnlyWithTheDryRunWorkspace() {
        #expect(!model(RecordingWorkspace()).isDryRun)
        #expect(!DefaultAppModel(defaultApp: DefaultArchiveApp(appURL: Self.appURL), appName: "Lutik").isDryRun)
        let dryRun = DefaultArchiveApp(appURL: Self.appURL, workspace: DryRunDefaultAppWorkspace())
        #expect(DefaultAppModel(defaultApp: dryRun, appName: "Lutik").isDryRun)
        #expect(DefaultAppDryRunMarker.identifier == "DefaultAppDryRun")
    }

    @Test func rowsFollowTheGroups() {
        let workspace = RecordingWorkspace()
        workspace.handlers["public.zip-archive"] = Self.appURL
        let model = model(workspace)
        #expect(model.rows.map(\.id) == DefaultArchiveApp.groups.filter { !$0.types.isEmpty }.map(\.id))
        #expect(model.rows.first { $0.id == "zip" }?.isDefault == true)
        #expect(model.rows.first { $0.id == "7z" }?.isDefault == false)
        #expect(!model.isDefaultForAll)
    }

    @Test func makeDefaultForOneGroupThenAll() async {
        let workspace = RecordingWorkspace()
        let model = model(workspace)
        await model.makeDefault(groupID: "7z")
        #expect(workspace.asked == ["org.7-zip.7-zip-archive"])
        #expect(model.rows.first { $0.id == "7z" }?.isDefault == true)
        #expect(model.outcome == .madeDefault)
        await model.makeDefaultForAll()
        #expect(model.isDefaultForAll)
        #expect(!model.isWorking)
        #expect(model.outcome == .madeDefault)
    }

    /// "For all" leaves ISO to its own row: the app counts as the default for all without it.
    @Test func allLeavesISOToItsRow() async {
        let workspace = RecordingWorkspace()
        let model = model(workspace)
        await model.makeDefaultForAll()
        #expect(!workspace.asked.contains("public.iso-image"))
        #expect(model.isDefaultForAll)
        #expect(model.rows.first { $0.id == "iso" }?.isDefault == false)
        await model.makeDefault(groupID: "iso")
        #expect(workspace.asked.last == "public.iso-image")
        #expect(model.rows.first { $0.id == "iso" }?.isDefault == true)
    }

    /// macOS took the call but Finder still opens archives elsewhere: no "is the default", the
    /// Get Info way in its place, until a later check (the window coming back) sees the change.
    @Test func notAppliedIsNotTheDefaultUntilFinderSeesIt() async {
        let workspace = RecordingWorkspace()
        workspace.finder = { _ in false }
        let model = model(workspace)
        await model.makeDefaultForAll()
        #expect(!model.isDefaultForAll)
        #expect(model.rows.first { $0.id == "zip" }?.isDefault == false)
        #expect(model.problemMessage(pointsToSettings: true)?.hasPrefix("macOS didn’t make Lutik the default app for archives.") == true)
        model.refresh()
        #expect(!model.isDefaultForAll)
        await model.recheckUnconfirmed()
        #expect(!model.isDefaultForAll)
        // Asked again: the unconfirmed types aren't skipped as already set.
        let asked = workspace.asked.count
        await model.makeDefault(groupID: "zip")
        #expect(workspace.asked.count == asked + 1)
        #expect(model.rows.first { $0.id == "zip" }?.isDefault == false)
        // The user picked Lutik in Get Info: the next check sees it.
        workspace.finder = { _ in true }
        await model.recheckUnconfirmed()
        #expect(model.isDefaultForAll)
        #expect(model.rows.first { $0.id == "zip" }?.isDefault == true)
    }

    /// A fresh-process check that can't tell keeps the API's word.
    @Test func unknownFinderStateTrustsTheChange() async {
        let workspace = RecordingWorkspace()
        let model = model(workspace)
        await model.makeDefaultForAll()
        #expect(model.isDefaultForAll)
        #expect(model.outcome == .madeDefault)
    }

    @Test func failureShowsTheMessageAndDeclineShowsNothing() async {
        let workspace = RecordingWorkspace()
        workspace.errors["public.zip-archive"] = NSError(domain: "test", code: 1)
        let model = model(workspace)
        await model.makeDefault(groupID: "zip")
        #expect(model.problemMessage(pointsToSettings: true) == "Lutik couldn’t be made the default app for archives. Try again in Settings.")
        #expect(model.problemMessage(pointsToSettings: false) == "Lutik couldn’t be made the default app for archives.")
        workspace.errors["public.zip-archive"] = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        await model.makeDefault(groupID: "zip")
        #expect(model.outcome == nil)
        #expect(model.rows.first { $0.id == "zip" }?.isDefault == false)
    }
}
