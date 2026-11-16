import Foundation
import Testing
@testable import Kernir

/// The app's user-visible name (AppDisplayName): CFBundleDisplayName, then CFBundleName.
struct AppDisplayNameTests {
    @Test func prefersTheDisplayName() {
        let name = AppDisplayName.resolve(infoDictionary: ["CFBundleDisplayName": "Lutik", "CFBundleName": "Kernir"],
                                          fallback: "fallback")
        #expect(name == "Lutik")
    }

    @Test func fallsBackToTheBundleName() {
        #expect(AppDisplayName.resolve(infoDictionary: ["CFBundleName": "Kernir"], fallback: "fallback") == "Kernir")
    }

    /// Blank, non-string and unexpanded build-setting values ("$(PRODUCT_NAME)") count as missing.
    @Test func ignoresJunkValues() {
        #expect(AppDisplayName.resolve(infoDictionary: ["CFBundleDisplayName": "  ", "CFBundleName": " Kernir "],
                                       fallback: "fallback") == "Kernir")
        #expect(AppDisplayName.resolve(infoDictionary: ["CFBundleDisplayName": "$(PRODUCT_NAME)", "CFBundleName": 7],
                                       fallback: "fallback") == "fallback")
    }

    @Test func nothingKnownUsesTheFallback() {
        #expect(AppDisplayName.resolve(infoDictionary: [:], fallback: "fallback") == "fallback")
    }
}
