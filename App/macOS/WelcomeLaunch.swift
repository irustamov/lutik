import Foundation

/// When the Mac Welcome window opens by itself.
///
/// At launch the decision waits one main-queue turn after `applicationDidFinishLaunching`: AppKit
/// delivers the files a launch opens (`application(_:open:)`) and restores windows before it
/// finishes launching, so by then every launch-time open request has arrived (`openRequested`) and
/// restored documents exist or are still reading (`hasDocuments`:
/// `KernirDocumentController.hasDocumentsForWelcome`), with no fixed delay. A Services launch never shows
/// it, and never marks it seen. Its Finder Service request (`servicesRequested`, from
/// `ServicesProvider`) may come only after that turn, and a launch AppKit doesn't call default
/// (`NSApplication.launchIsDefaultUserInfoKey`) with nothing to open may be one, or a relaunch
/// that restored no window: that decision waits `servicesGracePeriod` more
/// (`resolveDeferred`). ⇧⌘1 or a Dock click shows it meanwhile, and the wait ends.
/// A decision skipped only for restored documents still reading decides again once the reads are
/// done with none open (a restore that failed: `decideAfterReopens`).
enum WelcomeLaunch {
    /// What the launch does with the window.
    enum Decision: Equatable {
        case show
        case skip
        /// Wait `servicesGracePeriod` for a Service request or an open, then `resolveDeferred`.
        case deferForServices
    }

    /// How long a non-default launch with nothing to open waits for a Service request.
    static let servicesGracePeriod: Duration = .seconds(1)

    /// The decision once launch has settled. Default launches decide at once.
    static func decideAtLaunch(_ settings: WelcomeSettings, isDefaultLaunch: Bool, servicesRequested: Bool,
                               openRequested: Bool, hasDocuments: Bool) -> Decision {
        let hasDocument = openRequested || hasDocuments
        if !isDefaultLaunch && !servicesRequested && !hasDocument { return .deferForServices }
        return settings.shouldShowOnLaunch(hasDocument: hasDocument,
                                           launchedForServices: servicesRequested && !hasDocument) ? .show : .skip
    }

    /// The deferred decision after `servicesGracePeriod`: a Service request or an open in the
    /// meantime skips it (a Services launch, or the user is already at work); otherwise the usual
    /// rules for a launch with no document.
    static func resolveDeferred(_ settings: WelcomeSettings, servicesRequested: Bool, openRequested: Bool,
                                hasDocuments: Bool) -> Decision {
        if servicesRequested || openRequested || hasDocuments { return .skip }
        return settings.shouldShowOnLaunch(hasDocument: false, launchedForServices: false) ? .show : .skip
    }

    /// State restoration's last pending reopen is done: decide again (true) only when the launch
    /// decision skipped the window for the reopens (`awaits`; a manual show clears it), none of them
    /// opened a document (the archives were deleted, their volume is gone) and the window isn't
    /// showing, so the launch doesn't end with no window.
    static func decideAfterReopens(awaits: Bool, hasDocuments: Bool, isShowing: Bool) -> Bool {
        awaits && !hasDocuments && !isShowing
    }

    /// A Dock click with no visible window and no document open shows it, while "Show this window
    /// when <app> opens" is on.
    static func showsOnReopen(_ settings: WelcomeSettings, hasVisibleWindows: Bool, hasDocuments: Bool) -> Bool {
        !hasVisibleWindows && !hasDocuments && settings.showsAtLaunch
    }
}
