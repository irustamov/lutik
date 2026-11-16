import Testing
import AppKit
@testable import Kernir

@MainActor
@Test func creditsContainLibarchiveNotice() {
    #expect(AboutCredits.make().string.contains("libarchive"))
}

/// The license sits in a code fence; inline-only markdown would turn it into one
/// code span and collapse its line breaks into a single paragraph.
@MainActor
@Test func creditsKeepLicenseLineBreaks() {
    let credits = AboutCredits.make().string
    #expect(credits.contains("libarchive contributors\nAll rights reserved."))
    #expect(credits.contains("``AS IS''"))
    #expect(!credits.contains("```"))
}

/// Inline-only markdown leaves "# Third-party notices" as literal text; headings show as bold
/// lines without their marks.
@MainActor
@Test func creditsShowHeadingsAsBoldLines() throws {
    let credits = AboutCredits.make()
    let text = credits.string as NSString
    #expect(!credits.string.contains("#"))
    for heading in ["Third-party notices\n", "libarchive\n", "System libraries\n"] {
        let range = text.range(of: "\n" + heading)
        try #require(range.location != NSNotFound, "\(heading)")
        let font = try #require(credits.attribute(.font, at: range.location + 1, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold), "\(heading)")
    }
    // Prose stays regular.
    let prose = text.range(of: "Vendored as C source")
    let font = try #require(credits.attribute(.font, at: prose.location, effectiveRange: nil) as? NSFont)
    #expect(!font.fontDescriptor.symbolicTraits.contains(.bold))
}

/// The credits open with a link to the website.
@MainActor
@Test func creditsStartWithWebsiteLink() throws {
    let credits = AboutCredits.make()
    #expect(credits.string.hasPrefix("lutik.io\n"))
    let link = try #require(credits.attribute(.link, at: 0, effectiveRange: nil) as? URL)
    #expect(link == URL(string: "https://lutik.io"))
    // Only the domain is a link: the Acknowledgements heading after it isn't.
    let heading = (credits.string as NSString).range(of: "Acknowledgements")
    #expect(credits.attribute(.link, at: heading.location, effectiveRange: nil) == nil)
}

/// The panel shows "Version 0.1.0 (1234, 9cc7108)": the version, then build and commit.
@MainActor
@Test func panelOptionsCarryBuildAndCommit() throws {
    let version = AppVersion(infoDictionary: [
        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1234", "KernirGitCommit": "9cc7108",
    ])
    let options = AboutCredits.panelOptions(version: version)
    #expect(options[.applicationVersion] as? String == "0.1.0")
    #expect(options[.version] as? String == "1234, 9cc7108")
    #expect(options[.credits] is NSAttributedString)
    // The bundle icon, not the Dock tile art (AppDelegate.installDockIcon).
    let icon = try #require(options[.applicationIcon] as? NSImage)
    let dockIcon = try #require(NSImage(named: AppDelegate.dockIconName))
    #expect(icon !== NSApp.applicationIconImage)
    #expect(icon.tiffRepresentation != dockIcon.tiffRepresentation)
    let bare = AboutCredits.panelOptions(version: AppVersion(infoDictionary: [:]))
    #expect(bare[.applicationVersion] == nil && bare[.version] == nil)
}

/// The running app is stamped: a digits-only build number (App Store) and a commit.
@Test func runningAppIsStamped() throws {
    let version = AppVersion.current
    let build = try #require(version.build)
    #expect(!build.isEmpty && build.allSatisfy(\.isASCII) && build.allSatisfy(\.isNumber))
    #expect(version.commit != nil)
}
