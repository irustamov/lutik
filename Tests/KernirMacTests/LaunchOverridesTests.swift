import Testing
import AppKit
@testable import Kernir

@Test func parsesWindowFrame() {
    #expect(LaunchOverrides.parseFrame("1152x720") == CGSize(width: 1152, height: 720))
    #expect(LaunchOverrides.parseFrame("600x360") == CGSize(width: 600, height: 360))
}

@Test func rejectsMalformedWindowFrame() {
    for bad in ["", "1152", "1152x", "x720", "1152x720x1", "1152 x 720", " 1152x720", "1152X720",
                "-1152x720", "0x720", "1152x0", "abc x def", "1152.5x720", "+1152x720", "1152×720",
                "99999999999999999999x720", "100000x720"] {
        #expect(LaunchOverrides.parseFrame(bad) == nil, "\(bad)")
    }
    #expect(LaunchOverrides.parseFrame(nil) == nil)
}

@Test func parsesPreviewStandInDelay() {
    #expect(LaunchOverrides.parseDelay("3") == .seconds(3))
    #expect(LaunchOverrides.parseDelay("0.5") == .milliseconds(500))
    #expect(LaunchOverrides.parseDelay("60") == .seconds(60))
    for bad in ["", "0", "0.0", "-1", "61", "abc", " 3", "3s", "inf", "nan", "1e3", "3,5"] {
        #expect(LaunchOverrides.parseDelay(bad) == nil, "\(bad)")
    }
    #expect(LaunchOverrides.parseDelay(nil) == nil)
}

@Test func parsesAppearance() {
    #expect(LaunchOverrides.parseAppearance("light") == NSAppearance(named: .aqua))
    #expect(LaunchOverrides.parseAppearance("dark") == NSAppearance(named: .darkAqua))
    #expect(LaunchOverrides.parseAppearance("Dark") == nil)
    #expect(LaunchOverrides.parseAppearance("") == nil)
    #expect(LaunchOverrides.parseAppearance(nil) == nil)
}

/// The forced frame is centered on the menu-bar display (the one `XCUIScreen.main` captures),
/// whichever display holds the key window.
@Test func forcedWindowFrameIsCenteredOnTheMenuBarDisplay() {
    let size = CGSize(width: 1152, height: 720)
    #expect(LaunchOverrides.centered(size, on: NSRect(x: 0, y: 0, width: 1920, height: 1050))
            == NSRect(x: 384, y: 165, width: 1152, height: 720))
    #expect(LaunchOverrides.centered(size, on: NSRect(x: 1920, y: 30, width: 1920, height: 1050))
            == NSRect(x: 2304, y: 195, width: 1152, height: 720))
    #expect(LaunchOverrides.centered(size, on: nil) == NSRect(origin: .zero, size: size))
}

@MainActor @Test func forcedWindowFrameLandsOnTheMenuBarDisplay() throws {
    let document = try ArchiveDocument(type: "public.zip-archive")
    let forced = ArchiveWindowController(document: document, windowFrame: CGSize(width: 640, height: 400))
    let display = try #require(NSScreen.screens.first)
    #expect(display.frame.contains(try #require(forced.window?.frame)))
}

/// The screenshot UI test's forced frame must not be autosaved, or later launches open at it.
@MainActor @Test func forcedWindowFrameIsNotAutosaved() throws {
    #expect(ArchiveWindowController.autosaveName("ArchiveWindow", frameForced: true) == nil)
    #expect(ArchiveWindowController.autosaveName("ArchiveWindow", frameForced: false) == "ArchiveWindow")
    #expect(ArchiveWindowController.autosaveName(nil, frameForced: false) == nil)

    let document = try ArchiveDocument(type: "public.zip-archive")
    let forced = ArchiveWindowController(document: document, windowFrame: CGSize(width: 640, height: 400))
    #expect(forced.windowFrameAutosaveName == "")
    #expect(forced.window?.frame.size == CGSize(width: 640, height: 400))
}

/// The test bundle turns frame autosaving off before any test runs, so windows made by hosted
/// tests never write "NSWindow Frame ArchiveWindow" into the app's real defaults.
@MainActor @Test func hostedTestsNeverAutosaveWindowFrames() throws {
    #expect(ArchiveWindowController.frameAutosaveName == nil)

    let document = try ArchiveDocument(type: "public.zip-archive")
    let normal = ArchiveWindowController(document: document, windowFrame: nil)
    #expect(normal.windowFrameAutosaveName == "")
}

/// The Quick Look UI tests pass `-KernirPreviewFrameAutosave NO`: the preview window then neither
/// reads nor writes an autosaved frame, so a frame saved by an earlier run never moves where it
/// opens. Without the argument (and always in release builds) it autosaves as before.
@MainActor @Test func previewFrameAutosaveCanBeTurnedOff() {
    #expect(PreviewWindowController.autosaveName("PreviewWindow", disabled: true) == nil)
    #expect(PreviewWindowController.autosaveName("PreviewWindow", disabled: false) == "PreviewWindow")
    #expect(PreviewWindowController.autosaveName(nil, disabled: false) == nil)
    #expect(!LaunchOverrides.previewFrameAutosaveDisabled)
}

/// Only "NO" turns preview frame autosaving off; "YES", other text and no argument leave it on.
@Test func parsesPreviewFrameAutosave() {
    #expect(LaunchOverrides.parsePreviewFrameAutosaveDisabled("NO"))
    #expect(!LaunchOverrides.parsePreviewFrameAutosaveDisabled("YES"))
    #expect(!LaunchOverrides.parsePreviewFrameAutosaveDisabled(nil))
    for other in ["", "no", "No", "0", "false", " NO"] {
        #expect(!LaunchOverrides.parsePreviewFrameAutosaveDisabled(other), "\(other)")
    }
}

#if DEBUG
/// `-WelcomeSnapshot <name>` (Debug): a plain file name (letters, digits, `-`,
/// `_`, `.`; not starting with a dot; up to 100 characters); anything else is nil.
@Test func parsesWelcomeSnapshotName() {
    #expect(LaunchOverrides.parseSnapshotName("A-light") == "A-light")
    #expect(LaunchOverrides.parseSnapshotName("before_dark.2") == "before_dark.2")
    #expect(LaunchOverrides.parseSnapshotName(String(repeating: "a", count: 100)) != nil)
    for bad in [nil, "", ".hidden", "../x", "a/b", "a b", "ä", "x\n", String(repeating: "a", count: 101)] {
        #expect(LaunchOverrides.parseSnapshotName(bad) == nil, "\(String(describing: bad))")
    }
}
#endif
