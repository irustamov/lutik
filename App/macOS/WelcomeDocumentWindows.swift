import Foundation

/// Which document window closes the Welcome window, as in Xcode: only a new document's first
/// window. Windows of documents already open becoming key or main again (a click on an archive
/// window while Welcome shows after ⇧⌘1) never do. Shown with files the launch asked to open (the
/// first launch), their windows don't close it either, nor does the new untitled archive their
/// plain files go into; the next new one does.
@MainActor
final class WelcomeDocumentWindows {
    /// Every document whose window has become key or main, or that was open when Welcome showed;
    /// weak, so a closed document goes.
    private let seen = NSHashTable<AnyObject>.weakObjects()
    /// The files the launch asked to open whose windows haven't opened yet (standardized).
    private var awaitedURLs: Set<URL> = []
    /// Some of those went into a new untitled archive (`newArchiveWillOpen`) whose window hasn't opened yet.
    private var awaitsNewArchive = false

    /// The Welcome window showed. `openDocuments` are open now (restored, or opened before it),
    /// so their windows never close it; `awaiting` are the files the launch asked to open.
    func welcomeShown(openDocuments: [AnyObject], awaiting urls: [URL]) {
        for document in openDocuments { seen.add(document) }
        awaitedURLs = Set(urls.map(Self.key))
        awaitsNewArchive = false
    }

    func welcomeClosed() {
        awaitedURLs = []
        awaitsNewArchive = false
    }

    /// A requested file's open ended without a new window (it failed, or the document was already
    /// open): nothing to wait for.
    func stopAwaiting(_ url: URL) {
        awaitedURLs.remove(Self.key(url))
    }

    /// An open request's `items` go into a new untitled archive (`OpenRequest`): when the launch
    /// asked for them, that archive's window is the one awaited instead.
    func newArchiveWillOpen(for items: [URL]) {
        let keys = Set(items.map(Self.key))
        guard !awaitedURLs.isDisjoint(with: keys) else { return }
        awaitedURLs.subtract(keys)
        awaitsNewArchive = true
    }

    /// A window of `document` (at `fileURL`, nil while untitled) became key or main. True when
    /// the Welcome window (`welcomeShowing`) should close: the document's first window, and not
    /// an awaited one.
    func documentWindowActivated(_ document: AnyObject, fileURL: URL?, welcomeShowing: Bool) -> Bool {
        guard !seen.contains(document) else { return false }
        seen.add(document)
        guard welcomeShowing else { return false }
        if let fileURL {
            if awaitedURLs.remove(Self.key(fileURL)) != nil { return false }
        } else if awaitsNewArchive {
            awaitsNewArchive = false
            return false
        }
        return true
    }

    private static func key(_ url: URL) -> URL {
        url.standardizedFileURL
    }
}
