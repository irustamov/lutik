import AppKit

/// The app's document controller: created first, in `applicationWillFinishLaunching`, so it is
/// `NSDocumentController.shared`.
final class KernirDocumentController: NSDocumentController {
    /// Called as each request to open a document arrives, before the document is read, and as
    /// File > Open shows its panel (`AppDelegate`: `ServicesLaunchFlag.noteOpened`).
    var willOpenDocument: (@MainActor () -> Void)?

    /// Every open request passes here: a double click or Open With in Finder, an archive dropped on
    /// the Dock icon (`AppDelegate.application(_:open:)` hands each archive of the open-documents
    /// event here; plain files go into a new untitled archive instead), File > Open and Open Recent. A
    /// document read in the background is in `documents` and has a window only later, so
    /// `willOpenDocument` comes first. The
    /// Services' queue opening an archive for its password (`ServicesJobEffects.live`'s
    /// `openDocument`) comes here too and counts as use, as it did through `windowDidOpen` before.
    /// State restoration (`reopenDocument(for:withContentsOf:display:completionHandler:)`) doesn't
    /// pass here, so it isn't counted as use: a restored window still counts once it opens
    /// (`windowDidOpen`, `ServicesQuitState.hasDocumentWindows`).
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        willOpenDocument?()
        super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
    }

    /// State restoration's reopens still reading: the Welcome window's launch decision only
    /// (`hasDocumentsForWelcome`), never `willOpenDocument`.
    private(set) var pendingReopens = 0

    /// State restoration is still reading a document it reopens.
    var isReopeningDocuments: Bool { pendingReopens > 0 }

    /// Called once each time the last pending reopen is done, whether it opened its document or
    /// failed (the archive was deleted, its volume is gone): a launch decision that skipped the
    /// Welcome window for them decides again (`AppDelegate`).
    var reopensDidFinish: (@MainActor () -> Void)?

    /// Documents are open, or state restoration is reading one in the background that isn't in
    /// `documents` yet (`ArchiveDocument` reads concurrently): the Welcome window's launch
    /// decision (`WelcomeLaunch`), so a launch that restores archive windows doesn't flash it.
    var hasDocumentsForWelcome: Bool { isReopeningDocuments || !documents.isEmpty }

    /// State restoration reopening a window's document (a Dock or Spotlight launch, a relaunch).
    /// AppKit calls the completion handler on the main thread, with the document added if it
    /// opened.
    override func reopenDocument(for urlOrNil: URL?, withContentsOf contentsURL: URL, display displayDocument: Bool,
                                 completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        pendingReopens += 1
        super.reopenDocument(for: urlOrNil, withContentsOf: contentsURL,
                             display: displayDocument) { [weak self] document, wasOpen, error in
            // First AppKit's own handler (it restores the window), then the count.
            completionHandler(document, wasOpen, error)
            MainActor.assumeIsolated { self?.reopenFinished() }
        }
    }

    private func reopenFinished() {
        pendingReopens = max(0, pendingReopens - 1)
        if pendingReopens == 0 { reopensDidFinish?() }
    }

    /// File > Open: its Open panel hides when Finder comes in front, so it counts as soon as it
    /// opens, by ⌘O too, whatever the menu bar's notifications do for a key equivalent
    /// (`ServicesMenuActivity`).
    override func openDocument(_ sender: Any?) {
        willOpenDocument?()
        super.openDocument(sender)
    }

    /// Lutik's own temporary files (copies opened from an archive window, inner archives) are
    /// deleted on close, so they never go into File > Open Recent.
    override func noteNewRecentDocumentURL(_ url: URL) {
        guard !Self.isTemporary(url) else { return }
        super.noteNewRecentDocumentURL(url)
    }

    /// Quit asks about files changed in other apps first, even in archives without other edits:
    /// AppKit itself only reviews edited documents. Then AppKit's own review runs as before.
    override func reviewUnsavedDocuments(withAlertTitle title: String?, cancellable: Bool, delegate: Any?,
                                         didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        let pending = documents.compactMap { $0 as? ArchiveDocument }.filter(\.hasChangedOpenedFiles)
        Self.review(pending[...]) { [weak self] proceed in
            guard let self else { return }
            guard proceed else {
                Self.report(false, to: delegate, selector: didReviewAllSelector, from: self, contextInfo: contextInfo)
                return
            }
            self.reviewUnsavedDocumentsAsAppKitDoes(withAlertTitle: title, cancellable: cancellable, delegate: delegate,
                                                    didReviewAllSelector: didReviewAllSelector, contextInfo: contextInfo)
        }
    }

    /// AppKit's own review. Swift doesn't allow `super` in a closure that captures `self` explicitly.
    private func reviewUnsavedDocumentsAsAppKitDoes(withAlertTitle title: String?, cancellable: Bool, delegate: Any?,
                                                    didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        super.reviewUnsavedDocuments(withAlertTitle: title, cancellable: cancellable, delegate: delegate,
                                     didReviewAllSelector: didReviewAllSelector, contextInfo: contextInfo)
    }

    /// Asks each document in turn; stops at the first that cancels.
    private static func review(_ documents: ArraySlice<ArchiveDocument>, then done: @escaping @MainActor (Bool) -> Void) {
        guard let document = documents.first else {
            done(true)
            return
        }
        document.reviewOpenedFiles { proceed in
            guard proceed else { return done(false) }
            review(documents.dropFirst(), then: done)
        }
    }

    /// Calls `documentController:didReviewAll:contextInfo:` on `delegate`, as AppKit would.
    private static func report(_ didReviewAll: Bool, to delegate: Any?, selector: Selector?,
                               from controller: NSDocumentController, contextInfo: UnsafeMutableRawPointer?) {
        guard let delegate = delegate as? NSObject, let selector, delegate.responds(to: selector) else { return }
        typealias Callback = @convention(c) (NSObject, Selector, NSDocumentController, Bool, UnsafeMutableRawPointer?) -> Void
        let callback = unsafeBitCast(delegate.method(for: selector), to: Callback.self)
        callback(delegate, selector, controller, didReviewAll, contextInfo)
    }

    /// Whether `url` lies inside the temporary folder. Compares both the folder as given and with
    /// symlinks resolved, since a deleted file's path can't be resolved; /var, /tmp and /etc are
    /// spelled /private/… on both sides, as resolving does for a path that exists.
    nonisolated static func isTemporary(_ url: URL,
                                        temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> Bool {
        let path = privateSpelling(url.standardizedFileURL.pathComponents)
        let resolvedPath = privateSpelling(url.standardizedFileURL.resolvingSymlinksInPath().pathComponents)
        let bases = [temporaryDirectory.standardizedFileURL.pathComponents,
                     temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().pathComponents]
            .map(privateSpelling)
        return bases.contains { base in
            [path, resolvedPath].contains { $0.count > base.count && Array($0.prefix(base.count)) == base }
        }
    }

    /// `components` with a leading /var, /tmp or /etc (symlinks to /private/…) spelled /private/….
    private nonisolated static func privateSpelling(_ components: [String]) -> [String] {
        guard components.count > 1, components[0] == "/", ["var", "tmp", "etc"].contains(components[1]) else {
            return components
        }
        return ["/", "private"] + components.dropFirst()
    }
}
