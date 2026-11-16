import Foundation

/// The Welcome screen's state, in the app's defaults. Mac: a non-modal window at first launch and
/// at launches with no document while "Show at launch" is on. iOS: a sheet shown once, never again.
struct WelcomeSettings {
    /// Mac: the window's "Show at launch" checkbox. On by default.
    static let showAtLaunchKey = "KernirWelcomeShowAtLaunch"
    /// Whether the Welcome screen was ever shown (Mac first launch, iOS one-time sheet).
    static let seenKey = "KernirWelcomeSeen"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Mac: show the window at launches with no document. On until the user turns it off. Read
    /// with `bool(forKey:)`, so a launch argument's "NO" (a string) counts too.
    var showsAtLaunch: Bool {
        get { defaults.object(forKey: Self.showAtLaunchKey) == nil ? true : defaults.bool(forKey: Self.showAtLaunchKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.showAtLaunchKey) }
    }

    /// The Welcome screen was shown at least once.
    var hasBeenSeen: Bool { defaults.bool(forKey: Self.seenKey) }

    /// Records that the Welcome screen was shown; call it when it appears.
    func markSeen() {
        defaults.set(true, forKey: Self.seenKey)
    }

    /// Mac: whether to open the Welcome window when launching. Never for a launch that only runs a
    /// Finder Service (Extract Here, Compress): that launch shows no UI. The first launch shows it
    /// even with a document (the window is non-modal) and whatever the checkbox says; later
    /// launches only with no document and "Show at launch" on.
    func shouldShowOnLaunch(hasDocument: Bool, launchedForServices: Bool) -> Bool {
        if launchedForServices { return false }
        if !hasBeenSeen { return true }
        return showsAtLaunch && !hasDocument
    }

    /// iOS: present the one-time sheet. Call `markSeen()` once it has appeared.
    var shouldPresentOnce: Bool { !hasBeenSeen }
}
