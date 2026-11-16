import Foundation

/// What `DocumentBrowserController` does with the files it is asked to show, as pure transitions:
/// idle (the browser alone), showing (an archive presented or on its way up) and closing (the
/// archive on its way off screen; its document goes when it is off). A file that cannot come up
/// yet waits as the one pending file (a newer one replaces it) until the browser has first
/// appeared, the close has finished, or the transition under way in the presented chain has ended.
struct BrowserPresentationFlow: Equatable {
    enum Phase: Equatable { case idle, showing, closing }

    enum Step: Equatable {
        /// Present a new archive window for the file (phase is now `showing`).
        case present(URL)
        /// Give the shown archive's place to the file, in the same archive window.
        case replace(URL)
        /// Wait (pending now); `dropped` is the pending file this one replaced.
        case hold(dropped: URL?)
        /// Wait until the presented chain's transition ends, then call `transitionEnded()`.
        case holdUntilTransitionEnds(dropped: URL?)
        /// Wait until the file's previous document (in any window) has closed, then call `fileClosed()`.
        case holdUntilFileCloses(dropped: URL?)
    }

    private(set) var phase = Phase.idle
    private(set) var hasAppeared = false
    private(set) var pending: URL?

    /// The browser is asked to show `url`; `chainIsTransitioning`: a controller presented over
    /// it is being presented or dismissed, so a present now would be dropped. `fileIsClosing`: a
    /// document on the file is still closing (saving), so a new one now could read it before
    /// that save lands and later write over it.
    mutating func open(_ url: URL, chainIsTransitioning: Bool, fileIsClosing: Bool = false) -> Step {
        switch phase {
        case .showing:
            if fileIsClosing { return .holdUntilFileCloses(dropped: hold(url)) }
            // The newest file wins: one still waiting for its file's close won't replace it later.
            pending = nil
            return .replace(url)
        case .closing:
            return .hold(dropped: hold(url))
        case .idle:
            guard hasAppeared else { return .hold(dropped: hold(url)) }
            if fileIsClosing { return .holdUntilFileCloses(dropped: hold(url)) }
            if chainIsTransitioning { return .holdUntilTransitionEnds(dropped: hold(url)) }
            // The newest file wins: one still waiting won't come up over it later.
            pending = nil
            phase = .showing
            return .present(url)
        }
    }

    /// The browser's appearance: the pending file to open on the first one only. Later ones
    /// (the archive gone off screen) leave the pending file to `closeEnded()`.
    mutating func appeared() -> URL? {
        guard !hasAppeared else { return nil }
        hasAppeared = true
        return takePending()
    }

    /// The presentation didn't take (UIKit dropped it): back to the browser alone.
    mutating func presentDropped() {
        if phase == .showing { phase = .idle }
    }

    /// The shown archive starts going off screen.
    mutating func closeStarted() {
        if phase == .showing { phase = .closing }
    }

    /// The archive is off screen and its document closed: the pending file to open, if any.
    mutating func closeEnded() -> URL? {
        phase = .idle
        return takePending()
    }

    /// The close couldn't take the archive off screen (UIKit never dismissed it): it stays shown.
    /// The pending file to open in its place, if any.
    mutating func closeAborted() -> URL? {
        guard phase == .closing else { return nil }
        phase = .showing
        return takePending()
    }

    /// A file's previous document has closed: the pending file to open, if any. Mid-close it
    /// stays for `closeEnded()`.
    mutating func fileClosed() -> URL? { takePending() }

    /// The presented chain's transition has ended: the pending file to open, if any.
    mutating func transitionEnded() -> URL? { takePending() }

    private mutating func hold(_ url: URL) -> URL? {
        let dropped = pending
        pending = url
        return dropped == url ? nil : dropped
    }

    private mutating func takePending() -> URL? {
        guard phase != .closing, hasAppeared, let url = pending else { return nil }
        pending = nil
        return url
    }
}
