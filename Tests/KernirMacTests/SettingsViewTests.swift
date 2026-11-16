import AppKit
import Testing
@testable import Kernir

/// "Open Login Items & Extensions…" opens System Settings at the Quick Look extensions list.
/// This checks the URL and that System Settings handles it, without opening it; which page
/// System Settings actually shows stays a manual check.
@MainActor
@Test func quickLookSettingsURLOpensSystemSettings() throws {
    let url = SettingsView.quickLookSettingsURL
    #expect(url.scheme == "x-apple.systempreferences")
    #expect(url.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.ExtensionsPreferences?"))
    #expect(url.query == "extensionPointIdentifier=com.apple.quicklook.preview")
    let handler = try #require(NSWorkspace.shared.urlForApplication(toOpen: url))
    #expect(Bundle(url: handler)?.bundleIdentifier == "com.apple.systempreferences")
}
