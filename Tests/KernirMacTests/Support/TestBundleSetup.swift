import Foundation
@testable import Kernir

/// The test bundle's principal class (`NSPrincipalClass`, set in project.yml): XCTest creates it
/// when it loads the bundle into the host app, before any test runs.
@objc(KernirMacTestsSetup)
final class TestBundleSetup: NSObject {
    override init() {
        super.init()
        // Hosted tests make archive and preview windows: never autosave their frames into the
        // app's real defaults.
        MainActor.assumeIsolated {
            ArchiveWindowController.frameAutosaveName = nil
            PreviewWindowController.frameAutosaveName = nil
        }
    }
}
