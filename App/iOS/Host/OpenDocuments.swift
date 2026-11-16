import os
import UIKit

/// Which window (scene session) shows which archive. One file is open in one window at most:
/// two `ArchiveDocument`s on one file would each save over the other's snapshot. A window shows
/// one archive at a time, so registering its next archive replaces its entry.
///
/// Keyed by `UISceneSession.persistentIdentifier`; the `UISceneSession` calls resolve it through
/// `UIApplication.shared.openSessions`.
@MainActor enum OpenDocuments {
    private nonisolated static let logger = Logger(subsystem: "com.kernir.app", category: "scenes")

    /// The file each session's window shows, as `key(_:)`, and the document showing it.
    private struct Entry {
        let url: URL
        weak var document: AnyObject?
    }

    private static var entries: [String: Entry] = [:]

    static func register(_ url: URL, sessionID: String, document: AnyObject? = nil) {
        entries[sessionID] = Entry(url: key(url), document: document)
    }

    static func forget(_ url: URL) {
        let url = key(url)
        entries = entries.filter { $0.value.url != url }
    }

    /// Exact even when the file has moved or gone since it was registered, which `forget(_:)`,
    /// keyed by the file's current path, can miss.
    static func forget(sessionID: String) {
        entries[sessionID] = nil
    }

    /// Only while the window's entry is still `document`'s: a closing document's late forget
    /// leaves alone the entry of the next document the window already shows.
    static func forget(sessionID: String, document: AnyObject) {
        guard entries[sessionID]?.document === document else { return }
        entries[sessionID] = nil
    }

    static func sessionID(for url: URL) -> String? {
        let url = key(url)
        return entries.first { $0.value.url == url }?.key
    }

    /// The standardized file URL, with symbolic links resolved: a URL from Files and the
    /// document's `fileURL` may spell one temporary file as /private/var/... and /var/....
    private static func key(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Also makes the window the one the system prefers for this file's URL (Files' "open").
    static func register(_ url: URL, session: UISceneSession, document: AnyObject? = nil) {
        register(url, sessionID: session.persistentIdentifier, document: document)
        session.scene?.activationConditions.prefersToActivateForTargetContentIdentifierPredicate =
            NSPredicate(format: "self == %@", key(url).absoluteString)
    }

    /// A discarded session's entry is dropped on the way.
    static func session(for url: URL) -> UISceneSession? {
        let url = key(url)
        let sessions = UIApplication.shared.openSessions
        for (id, shown) in entries where shown.url == url {
            if let session = sessions.first(where: { $0.persistentIdentifier == id }) { return session }
            entries[id] = nil
        }
        return nil
    }

    /// If a window already shows `url`, brings it forward (unless it is `session`'s own) and
    /// returns true: the caller doesn't open the file again. Another window whose own document on
    /// `url` is closing doesn't count: brought forward, it would show only its browser; the
    /// caller opens the file once that close is done (`whenClosed`). A document on `url` closing
    /// in some other window (stuck past the wait limit) doesn't hold back the one showing it.
    static func activateWindow(showing url: URL, from session: UISceneSession?) -> Bool {
        guard let owner = self.session(for: url) else { return false }
        if owner.persistentIdentifier != session?.persistentIdentifier {
            if let document = entries[owner.persistentIdentifier]?.document,
               closing[ObjectIdentifier(document)] != nil { return false }
            UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: owner)) { error in
                logger.error("Cannot bring the archive's window forward: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    /// A window (`sessionID`'s) going away: closes its document, which saves pending edits and
    /// removes its staging, then forgets the window's file once nothing writes it any more.
    /// A failed save is logged: with the window gone, no one sees the document's save error.
    /// A document already closing (its controller let it go) isn't closed twice: a second close
    /// of one under way never calls back.
    static func close(_ document: ArchiveDocument, sessionID: String,
                      completion: (@MainActor @Sendable () -> Void)? = nil) {
        let alreadyClosing = closing[ObjectIdentifier(document)] != nil
        trackClosing(document) { _ in
            forget(sessionID: sessionID)
            completion?()
        }
        guard !alreadyClosing, !document.documentState.contains(.closed) else { return }
        let name = document.fileURL.lastPathComponent
        let id = ObjectIdentifier(document)
        // UIDocument's close takes the document out of UIKit's user-activity registry on its
        // background queue, racing the main thread's teardown of the same entry (see
        // `ArchiveDocumentViewController.document`): it leaves it here, on the main thread, first.
        document.userActivity = nil
        document.close { ok in
            if !ok {
                logger.error("Closing the window's archive failed; unsaved edits to \(name, privacy: .private) are lost")
            }
            Task { @MainActor in finishIfClosed(id) }
        }
    }

    // MARK: - Closing documents

    /// A document let go of (its controller's close or swap, a window's disconnect) until it
    /// reports `.closed`: its close may still save. A new document on the same file waits for it
    /// (`whenClosed`), else it could read the file before that save lands and later write over it.
    @MainActor private final class Closing {
        let url: URL
        let document: UIDocument
        var then: [@MainActor (UIDocument) -> Void] = []
        var observer: (any NSObjectProtocol)?
        /// The close wait limit's timer; it holds the entry weakly and goes with it.
        var timeout: Task<Void, Never>?

        init(url: URL, document: UIDocument) {
            self.url = url
            self.document = document
        }
    }

    private static var closing: [ObjectIdentifier: Closing] = [:]
    private static var waiters: [(url: URL, body: @MainActor () -> Void)] = []

    /// Last resort for a document that never reports `.closed`: the files waiting on it go ahead.
    /// Its save, if any, has started by then; the file coordination of that write holds off the
    /// next document's read.
    static var closeWaitLimit: Duration = .seconds(60)

    /// Calls `then` with `document` once it is closed: now if it is, else when it reports `.closed`.
    /// (Handed back rather than captured: Swift 6.3 region checking rejects a UIDocument captured
    /// in a main-actor closure.)
    static func trackClosing(_ document: UIDocument, then: (@MainActor (UIDocument) -> Void)? = nil) {
        let id = ObjectIdentifier(document)
        if let entry = closing[id] {
            if let then { entry.then.append(then) }
            return
        }
        guard !document.documentState.contains(.closed) else {
            then?(document)
            return
        }
        let entry = Closing(url: key(document.fileURL), document: document)
        if let then { entry.then.append(then) }
        entry.observer = NotificationCenter.default.addObserver(
            forName: UIDocument.stateChangedNotification, object: document, queue: .main) { _ in
            MainActor.assumeIsolated { finishIfClosed(id) }
        }
        closing[id] = entry
        let limit = closeWaitLimit
        entry.timeout = Task { @MainActor [weak entry] in
            try? await Task.sleep(for: limit)
            guard let entry, closing[id] === entry else { return }
            logger.error("A closing archive never reported closed; opening its file again anyway")
            finish(id)
        }
    }

    /// A document on `url` (any window) is still closing.
    static func isClosing(_ url: URL) -> Bool {
        let url = key(url)
        return closing.values.contains { $0.url == url }
    }

    /// Runs `body` once no document on `url` is closing: now, or after the last one's close.
    static func whenClosed(_ url: URL, _ body: @escaping @MainActor () -> Void) {
        guard isClosing(url) else { return body() }
        waiters.append((key(url), body))
    }

    /// A close's own callback, should the state change come without a notification.
    private static func finishIfClosed(_ id: ObjectIdentifier) {
        guard let document = closing[id]?.document, document.documentState.contains(.closed) else { return }
        finish(id)
    }

    private static func finish(_ id: ObjectIdentifier) {
        guard let entry = closing.removeValue(forKey: id) else { return }
        if let observer = entry.observer { NotificationCenter.default.removeObserver(observer) }
        entry.timeout?.cancel()
        entry.then.forEach { $0(entry.document) }
        let ready = waiters.filter { !isClosing($0.url) }
        waiters.removeAll { !isClosing($0.url) }
        ready.forEach { $0.body() }
    }
}
