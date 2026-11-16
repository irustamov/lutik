import AppKit
import Testing
@testable import Kernir

/// The read-only volume error: it offers another folder rather than only failing.
/// Builds the alert without showing it; the flow itself runs in ExtractHereUITests.
@MainActor @Test func aReadOnlyVolumeErrorOffersAnotherFolder() {
    let destination = URL(fileURLWithPath: "/Volumes/Untitled", isDirectory: true)
    let alert = FolderAccessPanel.readOnlyAlert(for: destination)
    let name = FileManager.default.displayName(atPath: destination.path)
    #expect(alert.messageText == String(localized: "“\(name)” is on a read-only volume."))
    #expect(alert.buttons.map(\.title) == [String(localized: "Choose Another Folder…"), String(localized: "Cancel")])
}

// MARK: - Panel settings and responses, without showing anything (fix6)

/// Records what the panels set, in place of an NSOpenPanel (which tests never make).
@MainActor private final class FakeFolderPanel: FolderPanelSettings {
    var canChooseFiles = true
    var canChooseDirectories = false
    var canCreateDirectories = true
    var allowsMultipleSelection = true
    var directoryURL: URL?
    var message: String! = nil
    var prompt: String! = nil
}

/// The Allow panel opens on the destination, the archive's folder.
@MainActor @Test func theAllowPanelOpensOnTheDestination() {
    let destination = URL(fileURLWithPath: "/Users/someone/Downloads", isDirectory: true)
    let panel = FakeFolderPanel()
    FolderAccessPanel.configureAllowPanel(panel, for: destination)
    #expect(panel.directoryURL == destination)
    #expect(!panel.canChooseFiles)
    #expect(panel.canChooseDirectories)
    #expect(!panel.canCreateDirectories)
    #expect(!panel.allowsMultipleSelection)
    #expect(panel.message == FolderAccessPanel.message(for: destination))
    #expect(panel.prompt == String(localized: "Allow"))
}

/// The read-only volume's "Choose Another Folder…" panel starts in the user's Downloads folder
/// (the real one, not the sandbox container's) and may make a new folder.
@MainActor @Test func theOtherFolderPanelStartsInDownloads() throws {
    let panel = FakeFolderPanel()
    FolderAccessPanel.configureOtherFolderPanel(panel)
    let start = try #require(panel.directoryURL)
    #expect(start == FolderAccessPanel.otherFolderStart)
    #expect(start.lastPathComponent == "Downloads")
    let home = String(cString: try #require(getpwuid(getuid())).pointee.pw_dir)
    #expect(start.deletingLastPathComponent().standardizedFileURL.path == URL(fileURLWithPath: home).standardizedFileURL.path)
    #expect(!start.path.contains("/Library/Containers/"))
    #expect(!panel.canChooseFiles)
    #expect(panel.canChooseDirectories)
    #expect(panel.canCreateDirectories)
    #expect(!panel.allowsMultipleSelection)
    #expect(panel.prompt == String(localized: "Extract"))
}

/// Only the alert's first button, "Choose Another Folder…", goes on to the panel; Cancel doesn't.
@MainActor @Test func onlyTheFirstButtonChoosesAnotherFolder() {
    #expect(FolderAccessPanel.choosesAnotherFolder(.alertFirstButtonReturn))
    #expect(!FolderAccessPanel.choosesAnotherFolder(.alertSecondButtonReturn))
    #expect(!FolderAccessPanel.choosesAnotherFolder(.cancel))
    #expect(!FolderAccessPanel.choosesAnotherFolder(.abort))
}

/// A panel's pick counts only after OK: Cancel gives nil even though the panel still has a URL.
@MainActor @Test func aPanelPickCountsOnlyAfterOK() {
    let url = URL(fileURLWithPath: "/Users/someone/Downloads", isDirectory: true)
    #expect(FolderAccessPanel.pick(.OK, url) == url)
    #expect(FolderAccessPanel.pick(.cancel, url) == nil)
    #expect(FolderAccessPanel.pick(.abort, url) == nil)
    #expect(FolderAccessPanel.pick(.OK, nil) == nil)
}
