import Foundation
import Testing
@testable import Kernir

/// The Welcome screen's settings and when it shows (WelcomeSettings).
struct WelcomeSettingsTests {
    private func withSettings(_ body: (WelcomeSettings, UserDefaults) -> Void) {
        let (defaults, suite) = makeTestDefaults("WelcomeSettingsTests")
        defer { removeTestDefaults(defaults, suite: suite) }
        body(WelcomeSettings(defaults: defaults), defaults)
    }

    @Test func keys() {
        #expect(WelcomeSettings.showAtLaunchKey == "KernirWelcomeShowAtLaunch")
        #expect(WelcomeSettings.seenKey == "KernirWelcomeSeen")
    }

    @Test func defaults() {
        withSettings { settings, _ in
            #expect(settings.showsAtLaunch)
            #expect(!settings.hasBeenSeen)
        }
    }

    @Test func storesBothValues() {
        withSettings { settings, defaults in
            settings.showsAtLaunch = false
            settings.markSeen()
            #expect(defaults.object(forKey: WelcomeSettings.showAtLaunchKey) as? Bool == false)
            #expect(defaults.bool(forKey: WelcomeSettings.seenKey))
            let again = WelcomeSettings(defaults: defaults)
            #expect(!again.showsAtLaunch)
            #expect(again.hasBeenSeen)
        }
    }

    /// Mac, first launch: shown even with a document (non-modal), never for a Services launch.
    @Test func macFirstLaunch() {
        withSettings { settings, _ in
            #expect(settings.shouldShowOnLaunch(hasDocument: false, launchedForServices: false))
            #expect(settings.shouldShowOnLaunch(hasDocument: true, launchedForServices: false))
            #expect(!settings.shouldShowOnLaunch(hasDocument: false, launchedForServices: true))
            // Off at first launch still shows once: the box only governs later launches.
            settings.showsAtLaunch = false
            #expect(settings.shouldShowOnLaunch(hasDocument: false, launchedForServices: false))
        }
    }

    /// Mac, later launches: only with no document and "Show at launch" on.
    @Test func macLaterLaunches() {
        withSettings { settings, _ in
            settings.markSeen()
            #expect(settings.shouldShowOnLaunch(hasDocument: false, launchedForServices: false))
            #expect(!settings.shouldShowOnLaunch(hasDocument: true, launchedForServices: false))
            #expect(!settings.shouldShowOnLaunch(hasDocument: false, launchedForServices: true))
            settings.showsAtLaunch = false
            #expect(!settings.shouldShowOnLaunch(hasDocument: false, launchedForServices: false))
        }
    }

    /// iOS: once, then never again.
    @Test func iOSOnce() {
        withSettings { settings, _ in
            #expect(settings.shouldPresentOnce)
            settings.markSeen()
            #expect(!settings.shouldPresentOnce)
            #expect(!WelcomeSettings(defaults: settings.defaults).shouldPresentOnce)
        }
    }
}
