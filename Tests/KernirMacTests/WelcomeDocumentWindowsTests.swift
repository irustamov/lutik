import Foundation
import Testing
@testable import Kernir

/// Which document window closes the Mac Welcome window (WelcomeDocumentWindows): only a new
/// document's first window, and not the window of a file the launch asked to open.
@MainActor
struct WelcomeDocumentWindowsTests {
    private final class Document {}

    private static let launchURL = URL(fileURLWithPath: "/tmp/kernir-welcome-test/launch.zip")
    private static let otherURL = URL(fileURLWithPath: "/tmp/kernir-welcome-test/other.zip")

    /// Archives already open, Welcome from ⇧⌘1: clicking their windows keeps it; a new one closes it.
    @Test func onlyANewDocumentCloses() {
        let windows = WelcomeDocumentWindows()
        let open = Document(), other = Document()
        #expect(!windows.documentWindowActivated(open, fileURL: nil, welcomeShowing: false))
        windows.welcomeShown(openDocuments: [], awaiting: [])
        #expect(!windows.documentWindowActivated(open, fileURL: nil, welcomeShowing: true))
        #expect(!windows.documentWindowActivated(open, fileURL: nil, welcomeShowing: true))
        #expect(windows.documentWindowActivated(other, fileURL: nil, welcomeShowing: true))
        #expect(!windows.documentWindowActivated(other, fileURL: nil, welcomeShowing: true))
    }

    /// Documents open when Welcome shows, whose windows haven't become key yet (restored at
    /// launch), never close it.
    @Test func documentsOpenWhenShownKeepIt() {
        let windows = WelcomeDocumentWindows()
        let restored = Document()
        windows.welcomeShown(openDocuments: [restored], awaiting: [])
        #expect(!windows.documentWindowActivated(restored, fileURL: Self.otherURL, welcomeShowing: true))
        #expect(windows.documentWindowActivated(Document(), fileURL: nil, welcomeShowing: true))
    }

    /// First launch with a document: its window keeps Welcome, the next new document closes it.
    @Test func launchDocumentStaysOnlyForItsOwnWindow() {
        let windows = WelcomeDocumentWindows()
        windows.welcomeShown(openDocuments: [], awaiting: [Self.launchURL])
        #expect(!windows.documentWindowActivated(Document(), fileURL: Self.launchURL, welcomeShowing: true))
        #expect(windows.documentWindowActivated(Document(), fileURL: Self.launchURL, welcomeShowing: true))
    }

    /// The wait is for the requested file only: another document (restored, or opened from the
    /// menu) closes Welcome and leaves the wait for the requested one.
    @Test func anotherDocumentDoesNotTakeTheWait() {
        let windows = WelcomeDocumentWindows()
        windows.welcomeShown(openDocuments: [], awaiting: [Self.launchURL])
        #expect(windows.documentWindowActivated(Document(), fileURL: Self.otherURL, welcomeShowing: true))
        #expect(!windows.documentWindowActivated(Document(), fileURL: Self.launchURL, welcomeShowing: true))
    }

    /// The same file named another way (`.` and `..` in the path) is the one awaited.
    @Test func awaitedURLIsStandardized() {
        let windows = WelcomeDocumentWindows()
        let roundabout = URL(fileURLWithPath: "/tmp/kernir-welcome-test/sub/../launch.zip")
        windows.welcomeShown(openDocuments: [], awaiting: [roundabout])
        #expect(!windows.documentWindowActivated(Document(), fileURL: Self.launchURL, welcomeShowing: true))
    }

    /// The requested file failed to open: nothing to wait for, so the next new document closes it.
    @Test func failedOpenDropsTheWait() {
        let windows = WelcomeDocumentWindows()
        windows.welcomeShown(openDocuments: [], awaiting: [Self.launchURL])
        windows.stopAwaiting(Self.launchURL)
        #expect(windows.documentWindowActivated(Document(), fileURL: Self.launchURL, welcomeShowing: true))
    }

    /// Requested plain files go into a new untitled archive: its window is the awaited one.
    @Test func newArchiveTakesTheWaitForItsItems() {
        let windows = WelcomeDocumentWindows()
        let note = URL(fileURLWithPath: "/tmp/kernir-welcome-test/note.txt")
        windows.welcomeShown(openDocuments: [], awaiting: [note, Self.launchURL])
        windows.newArchiveWillOpen(for: [note, Self.launchURL])
        #expect(!windows.documentWindowActivated(Document(), fileURL: nil, welcomeShowing: true))
        #expect(windows.documentWindowActivated(Document(), fileURL: Self.launchURL, welcomeShowing: true))
    }

    /// A new archive from items the launch didn't ask for (a later Dock drop) closes it.
    @Test func newArchiveFromOtherItemsCloses() {
        let windows = WelcomeDocumentWindows()
        windows.welcomeShown(openDocuments: [], awaiting: [Self.launchURL])
        windows.newArchiveWillOpen(for: [URL(fileURLWithPath: "/tmp/kernir-welcome-test/note.txt")])
        #expect(windows.documentWindowActivated(Document(), fileURL: nil, welcomeShowing: true))
    }

    /// Closing Welcome drops the wait: shown again from the menu, a new document closes it.
    @Test func closingDropsTheWait() {
        let windows = WelcomeDocumentWindows()
        windows.welcomeShown(openDocuments: [], awaiting: [Self.launchURL])
        windows.newArchiveWillOpen(for: [Self.launchURL])
        windows.welcomeClosed()
        windows.welcomeShown(openDocuments: [], awaiting: [])
        #expect(windows.documentWindowActivated(Document(), fileURL: Self.launchURL, welcomeShowing: true))
        #expect(windows.documentWindowActivated(Document(), fileURL: nil, welcomeShowing: true))
    }

    /// A document opening while Welcome is closed is seen, and doesn't close it later.
    @Test func seenWhileClosed() {
        let windows = WelcomeDocumentWindows()
        let document = Document()
        #expect(!windows.documentWindowActivated(document, fileURL: nil, welcomeShowing: false))
        windows.welcomeShown(openDocuments: [], awaiting: [])
        #expect(!windows.documentWindowActivated(document, fileURL: nil, welcomeShowing: true))
    }
}
