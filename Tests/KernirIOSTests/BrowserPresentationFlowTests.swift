import Foundation
import Testing
@testable import Kernir

/// `BrowserPresentationFlow`: when the browser presents, replaces, or holds a file back.
@Suite struct BrowserPresentationFlowTests {
    private let a = URL(fileURLWithPath: "/flow/a.zip")
    private let b = URL(fileURLWithPath: "/flow/b.zip")
    private let c = URL(fileURLWithPath: "/flow/c.zip")

    private func appeared() -> BrowserPresentationFlow {
        var flow = BrowserPresentationFlow()
        #expect(flow.appeared() == nil)
        return flow
    }

    /// A launch with a file asks before the browser is on screen: it comes up on the first
    /// appearance.
    @Test func fileBeforeFirstAppearanceWaitsForIt() {
        var flow = BrowserPresentationFlow()
        #expect(flow.open(a, chainIsTransitioning: false) == .hold(dropped: nil))
        #expect(flow.phase == .idle)
        #expect(flow.appeared() == a)
        #expect(flow.pending == nil)
        #expect(flow.open(a, chainIsTransitioning: false) == .present(a))
        #expect(flow.phase == .showing)
    }

    @Test func idleBrowserPresents() {
        var flow = appeared()
        #expect(flow.open(a, chainIsTransitioning: false) == .present(a))
        #expect(flow.phase == .showing)
    }

    /// An archive shown (or on its way up) gives its place to the new file in place.
    @Test func shownArchiveIsReplaced() {
        var flow = appeared()
        _ = flow.open(a, chainIsTransitioning: false)
        #expect(flow.open(b, chainIsTransitioning: true) == .replace(b))
        #expect(flow.phase == .showing)
        #expect(flow.pending == nil)
    }

    /// A sheet going away (or coming up) would swallow the present.
    @Test func transitioningChainHoldsUntilItEnds() {
        var flow = appeared()
        #expect(flow.open(a, chainIsTransitioning: true) == .holdUntilTransitionEnds(dropped: nil))
        #expect(flow.phase == .idle)
        #expect(flow.transitionEnded() == a)
        #expect(flow.pending == nil)
        #expect(flow.open(a, chainIsTransitioning: false) == .present(a))
    }

    /// A file during a close comes up from the close's end, never from the
    /// browser's re-appearance (before the closed document has let go of the window's entry).
    @Test func fileDuringCloseWaitsForTheCloseToEnd() {
        var flow = appeared()
        _ = flow.open(a, chainIsTransitioning: false)
        flow.closeStarted()
        #expect(flow.phase == .closing)
        #expect(flow.open(b, chainIsTransitioning: true) == .hold(dropped: nil))
        #expect(flow.appeared() == nil, "a later appearance opened the pending file")
        #expect(flow.transitionEnded() == nil, "a transition's end opened the file mid-close")
        #expect(flow.pending == b)
        #expect(flow.closeEnded() == b)
        #expect(flow.phase == .idle)
        #expect(flow.open(b, chainIsTransitioning: false) == .present(b))
    }

    @Test func closeWithNothingPendingEndsIdle() {
        var flow = appeared()
        _ = flow.open(a, chainIsTransitioning: false)
        flow.closeStarted()
        #expect(flow.closeEnded() == nil)
        #expect(flow.phase == .idle)
    }

    /// Only the newest waiting file is kept; the one it replaces is reported (logged).
    @Test func newerPendingFileDropsTheOlder() {
        var flow = BrowserPresentationFlow()
        #expect(flow.open(a, chainIsTransitioning: false) == .hold(dropped: nil))
        #expect(flow.open(b, chainIsTransitioning: false) == .hold(dropped: a))
        #expect(flow.open(b, chainIsTransitioning: false) == .hold(dropped: nil))
        #expect(flow.appeared() == b)
    }

    /// A present UIKit dropped goes back to idle, so the next file presents again.
    @Test func droppedPresentGoesBackToIdle() {
        var flow = appeared()
        _ = flow.open(a, chainIsTransitioning: false)
        flow.presentDropped()
        #expect(flow.phase == .idle)
        #expect(flow.open(c, chainIsTransitioning: false) == .present(c))
    }

    @Test func closeStartedOnlyFromShowing() {
        var flow = appeared()
        flow.closeStarted()
        #expect(flow.phase == .idle)
    }
}

/// A file whose previous document is still closing, a close UIKit never finished.
extension BrowserPresentationFlowTests {
    /// (b) The file's previous document (any window) still saves: the file waits for its close.
    @Test func fileStillClosingWaitsForItsClose() {
        var flow = appeared()
        #expect(flow.open(a, chainIsTransitioning: false, fileIsClosing: true) == .holdUntilFileCloses(dropped: nil))
        #expect(flow.phase == .idle)
        #expect(flow.fileClosed() == a)
        #expect(flow.pending == nil)
        #expect(flow.open(a, chainIsTransitioning: false) == .present(a))
    }

    /// (b) Shown archive: the file still closing elsewhere doesn't replace it yet.
    @Test func fileStillClosingDoesNotReplaceTheShownArchiveYet() {
        var flow = appeared()
        _ = flow.open(a, chainIsTransitioning: false)
        #expect(flow.open(b, chainIsTransitioning: false, fileIsClosing: true) == .holdUntilFileCloses(dropped: nil))
        #expect(flow.phase == .showing)
        #expect(flow.fileClosed() == b)
        #expect(flow.open(b, chainIsTransitioning: false) == .replace(b))
    }

    /// (b) Mid-close the file's own close end brings it up, not another file's close.
    @Test func fileClosedMidCloseLeavesThePendingFileToTheCloseEnd() {
        var flow = appeared()
        _ = flow.open(a, chainIsTransitioning: false)
        flow.closeStarted()
        #expect(flow.open(a, chainIsTransitioning: false, fileIsClosing: true) == .hold(dropped: nil))
        #expect(flow.fileClosed() == nil)
        #expect(flow.closeEnded() == a)
    }

    /// (c) A dismissal UIKit never made: the archive stays shown, the waiting file replaces it.
    @Test func abortedCloseGoesBackToShowing() {
        var flow = appeared()
        _ = flow.open(a, chainIsTransitioning: false)
        flow.closeStarted()
        _ = flow.open(b, chainIsTransitioning: false)
        #expect(flow.closeAborted() == b)
        #expect(flow.phase == .showing)
        #expect(flow.open(b, chainIsTransitioning: false) == .replace(b))
        #expect(flow.closeAborted() == nil, "only a close under way is aborted")
    }

    /// A file presented directly drops the one that was still waiting (newest wins).
    @Test func presentDropsTheOlderPendingFile() {
        var flow = appeared()
        _ = flow.open(a, chainIsTransitioning: true)
        #expect(flow.open(b, chainIsTransitioning: false) == .present(b))
        #expect(flow.pending == nil)
        #expect(flow.transitionEnded() == nil)
    }

    /// Fix-forward #3: a file replacing the shown archive drops the one waiting for its file's
    /// close (newest wins): that close landing later doesn't put the older file over it.
    @Test func replaceDropsTheFileWaitingForItsClose() {
        var flow = appeared()
        _ = flow.open(c, chainIsTransitioning: false)
        #expect(flow.open(a, chainIsTransitioning: false, fileIsClosing: true) == .holdUntilFileCloses(dropped: nil))
        #expect(flow.open(b, chainIsTransitioning: false) == .replace(b))
        #expect(flow.pending == nil)
        #expect(flow.fileClosed() == nil, "the older file came up over the newer one")
        #expect(flow.phase == .showing)
    }
}
