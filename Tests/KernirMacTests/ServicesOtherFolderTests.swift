import AppKit
import Testing
@testable import Kernir

/// Finder Services: a job whose folder refuses writes offers another
/// folder, app-modal, in words that fit the job. Builds the alert and checks the panel settings and
/// the flow with stand-ins; nothing is shown. The live alert and panel run in a hosted run.
@MainActor
struct ServicesOtherFolderTests {
    nonisolated private static let folder = URL(fileURLWithPath: "/Users/u/Downloads", isDirectory: true)
    nonisolated private static let archive = folder.appendingPathComponent("project.zip")
    nonisolated private static let extract = ServicesJob.extractHere(archive)
    nonisolated private static let compressOne = ServicesJob.compress([folder.appendingPathComponent("a.txt")], format: .zip)
    private static let compressThree = ServicesJob.compress(
        ["a.txt", "b.txt", "c.txt"].map { folder.appendingPathComponent($0) }, format: .zip)
    private static let failure = ServicesJobFailure(title: "Couldn't do it.", reason: "Because.")

    private static func name(_ url: URL) -> String { ServicesJobRunner.displayName(of: url) }

    /// Records what the panel is given, in place of an NSOpenPanel.
    @MainActor private final class FakePanel: FolderPanelSettings {
        var canChooseFiles = true
        var canChooseDirectories = false
        var canCreateDirectories = false
        var allowsMultipleSelection = true
        var directoryURL: URL?
        var message: String! = nil
        var prompt: String! = nil
    }

    // MARK: Words

    /// The alert says what failed and why (the failure, not Extract Here's read-only text); its button and
    /// the panel say "extract".
    @Test func extractHereOffersToExtractElsewhere() {
        let text = ServicesOtherFolderText(failure: Self.failure, job: Self.extract)
        #expect(text.message == Self.failure.title)
        #expect(text.information == Self.failure.reason)
        #expect(text.choose == String(localized: "Extract to Another Folder…"))
        #expect(text.cancel == String(localized: "Cancel"))
        #expect(text.panelMessage == String(localized: "Choose where to extract “\(Self.name(Self.archive))”."))
        #expect(text.panelPrompt == String(localized: "Extract"))
    }

    /// Compress's button and panel say "save the archive", naming what it was made of.
    @Test func compressOffersToSaveTheArchiveElsewhere() {
        let one = ServicesOtherFolderText(failure: Self.failure, job: Self.compressOne)
        #expect(one.message == Self.failure.title)
        #expect(one.information == Self.failure.reason)
        #expect(one.choose == String(localized: "Save to Another Folder…"))
        #expect(one.cancel == String(localized: "Cancel"))
        let name = Self.name(Self.folder.appendingPathComponent("a.txt"))
        #expect(one.panelMessage == String(localized: "Choose where to save the archive of “\(name)”."))
        #expect(one.panelMessage == "Choose where to save the archive of “a.txt”.")
        #expect(one.panelPrompt == String(localized: "Save"))
        let three = ServicesOtherFolderText(failure: Self.failure, job: Self.compressThree)
        #expect(three.panelMessage == String(localized: "Choose where to save the archive of \(3) items."))
        #expect(three.panelMessage == "Choose where to save the archive of 3 items.")
    }

    /// Not Extract Here's read-only alert: that one always says "read-only volume" and "Choose Another Folder…",
    /// and the Services offer comes for a folder's permissions too.
    @Test func theWordsAreNotTheReadOnlyAlerts() {
        let readOnly = FolderAccessPanel.readOnlyAlert(for: Self.folder)
        for job in [Self.extract, Self.compressOne] {
            let text = ServicesOtherFolderText(failure: Self.failure, job: job)
            #expect(text.message != readOnly.messageText)
            #expect(text.information != readOnly.informativeText)
            #expect(text.choose != readOnly.buttons[0].title)
        }
    }

    /// The alert: the failure's title and reason; the job's button first (the default), Cancel second.
    @Test(arguments: [extract, compressOne])
    func theAlertShowsTheFailureAndTheJobsButton(job: ServicesJob) {
        let text = ServicesOtherFolderText(failure: Self.failure, job: job)
        let alert = ServicesOtherFolderPanel.alert(for: text)
        #expect(alert.messageText == Self.failure.title)
        #expect(alert.informativeText == Self.failure.reason)
        #expect(alert.buttons.map(\.title) == [text.choose, text.cancel])
    }

    // MARK: The panel

    /// The folder panel opens in the user's real Downloads (`otherFolderStart`, through
    /// getpwuid, never the sandbox container's), takes one folder, may make one, and says what the
    /// folder is for.
    @Test(arguments: [extract, compressOne])
    func thePanelStartsInTheRealDownloads(job: ServicesJob) throws {
        let text = ServicesOtherFolderText(failure: Self.failure, job: job)
        let panel = FakePanel()
        ServicesOtherFolderPanel.configure(panel, text: text)
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
        #expect(panel.message == text.panelMessage)
        #expect(panel.prompt == text.panelPrompt)
    }

    // MARK: The flow

    /// Cancel in the alert ends the offer: no panel, no folder.
    @Test(arguments: [NSApplication.ModalResponse.alertSecondButtonReturn, .alertThirdButtonReturn, .cancel, .abort])
    func cancelInTheAlertShowsNoPanel(response: NSApplication.ModalResponse) {
        var panels = 0
        let picked = ServicesOtherFolderPanel.offer(
            ServicesOtherFolderText(failure: Self.failure, job: Self.extract),
            alert: { _ in response },
            panel: { _ in panels += 1; return (.OK, Self.folder) })
        #expect(picked == nil)
        #expect(panels == 0)
    }

    /// The job's button opens the panel, given the same words as the alert; its pick counts only
    /// after OK.
    @Test(arguments: [(NSApplication.ModalResponse.OK, Optional(URL(fileURLWithPath: "/Volumes/Other", isDirectory: true)), true),
                      (.cancel, Optional(URL(fileURLWithPath: "/Volumes/Other", isDirectory: true)), false),
                      (.OK, nil, false)])
    func theButtonOpensThePanel(response: NSApplication.ModalResponse, url: URL?, counts: Bool) {
        let text = ServicesOtherFolderText(failure: Self.failure, job: Self.compressOne)
        var alerts: [ServicesOtherFolderText] = []
        var panels: [ServicesOtherFolderText] = []
        let picked = ServicesOtherFolderPanel.offer(
            text,
            alert: { alerts.append($0); return .alertFirstButtonReturn },
            panel: { panels.append($0); return (response, url) })
        #expect(picked == (counts ? url : nil))
        #expect(alerts == [text])
        #expect(panels == [text])
    }

    /// The app's runner makes the offer.
    @Test func theAppsRunnerOffersAnotherFolder() {
        let (defaults, suite) = makeTestDefaults("ServicesOtherFolderTests")
        defer { removeTestDefaults(defaults, suite: suite) }
        let runner = ServicesJobRunner.live(store: FolderAccessStore(defaults: defaults))
        #expect(runner.offerAnotherFolder != nil)
    }
}
