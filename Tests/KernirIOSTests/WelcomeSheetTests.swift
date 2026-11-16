import Foundation
import Testing
import UIKit
@testable import Kernir

/// The one-time Welcome sheet: which window presents it (`WelcomeSheetGate`), and the sheet itself.
/// Each test has its own gate and its own defaults (`makeTestDefaults`).
@MainActor struct WelcomeSheetTests {
    private func withSettings(_ body: (WelcomeSettings) -> Void) {
        let (defaults, suite) = makeTestDefaults("WelcomeSheetTests")
        defer { removeTestDefaults(defaults, suite: suite) }
        body(WelcomeSettings(defaults: defaults))
    }

    /// A plain first launch presents it; it is marked seen only once it has appeared
    /// (`WelcomeSheetController`), not at the claim.
    @Test func plainFirstLaunchPresentsWithoutMarkingSeenYet() {
        withSettings { settings in
            let gate = WelcomeSheetGate()
            #expect(gate.claim(settings: settings, launchedWithFile: false, browserIsCovered: false))
            #expect(!settings.hasBeenSeen)
            #expect(gate.hasPresented)
        }
    }

    /// Several iPad windows at launch: only the first presents it.
    @Test func onlyOneWindowPerProcess() {
        withSettings { settings in
            let gate = WelcomeSheetGate()
            #expect(gate.claim(settings: settings, launchedWithFile: false, browserIsCovered: false))
            // A second window of the same process, even with the seen mark gone.
            settings.defaults.removeObject(forKey: WelcomeSettings.seenKey)
            #expect(!gate.claim(settings: settings, launchedWithFile: false, browserIsCovered: false))
        }
    }

    /// A launch to open a file shows the file; the sheet waits for a later plain launch.
    @Test func fileLaunchDefersToLaterPlainLaunch() {
        withSettings { settings in
            let gate = WelcomeSheetGate()
            #expect(!gate.claim(settings: settings, launchedWithFile: true, browserIsCovered: false))
            #expect(!settings.hasBeenSeen)
            #expect(!gate.hasPresented)

            let laterLaunch = WelcomeSheetGate()
            #expect(laterLaunch.claim(settings: settings, launchedWithFile: false, browserIsCovered: false))
        }
    }

    @Test func browserCoveredDoesNotPresent() {
        withSettings { settings in
            let gate = WelcomeSheetGate()
            #expect(!gate.claim(settings: settings, launchedWithFile: false, browserIsCovered: true))
            #expect(!settings.hasBeenSeen)
        }
    }

    @Test func alreadySeenNeverPresents() {
        withSettings { settings in
            settings.markSeen()
            let gate = WelcomeSheetGate()
            #expect(!gate.claim(settings: settings, launchedWithFile: false, browserIsCovered: false))
            #expect(!gate.hasPresented)
        }
    }

    /// A sheet at its large detent (a form sheet on iPad), dismissable with a swipe.
    @Test func controllerIsALargeSwipeableSheet() throws {
        let controller = WelcomeSheet.makeController(appName: "Kernir")
        #expect(controller is WelcomeSheetController)
        #expect(controller.modalPresentationStyle == .formSheet)
        #expect(!controller.isModalInPresentation)
        let sheet = try #require(controller.sheetPresentationController)
        #expect(sheet.detents.map { $0.identifier } == [.large])
    }

    @Test func hintNamesTheApp() {
        let hint = WelcomeSheetView.openHint(appName: "Lutik")
        #expect(hint.contains("Lutik"))
        #expect(hint.contains("Files"))
    }
}
