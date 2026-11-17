import Foundation
import Testing
import UIKit
@testable import Kernir

/// `OpenDocuments`: which window (scene session) shows which archive, so a second open of the
/// same file brings that window forward instead of opening the file twice. The registry is
/// process-wide, so every test uses files and session IDs of its own.
@MainActor @Suite(.serialized) struct OpenDocumentsTests {
    private let folder = URL(fileURLWithPath: "/OpenDocumentsTests-\(UUID().uuidString)", isDirectory: true)

    @Test func registersAndFindsByStandardizedURL() {
        let url = folder.appendingPathComponent("a/./b.zip")
        OpenDocuments.register(url, sessionID: "window-1")
        defer { OpenDocuments.forget(url) }

        #expect(OpenDocuments.sessionID(for: folder.appendingPathComponent("a/b.zip")) == "window-1")
        #expect(OpenDocuments.sessionID(for: folder.appendingPathComponent("a/x/../b.zip")) == "window-1")
        #expect(OpenDocuments.sessionID(for: url) == "window-1")
        #expect(OpenDocuments.sessionID(for: folder.appendingPathComponent("a/c.zip")) == nil)
    }

    @Test func forgetsOnClose() {
        let url = folder.appendingPathComponent("archive.zip")
        OpenDocuments.register(url, sessionID: "window-1")
        OpenDocuments.forget(folder.appendingPathComponent("./archive.zip"))

        #expect(OpenDocuments.sessionID(for: url) == nil)
    }

    /// By window: exact even when the file's path no longer gives the key it was registered
    /// under (moved, or deleted so /private can't be resolved away). Other windows keep theirs.
    @Test func forgetsBySession() {
        let gone = folder.appendingPathComponent("moved-away.zip")
        let other = folder.appendingPathComponent("other.zip")
        OpenDocuments.register(gone, sessionID: "window-1")
        OpenDocuments.register(other, sessionID: "window-2")
        defer { OpenDocuments.forget(other) }

        OpenDocuments.forget(sessionID: "window-1")

        #expect(OpenDocuments.sessionID(for: gone) == nil)
        #expect(OpenDocuments.sessionID(for: other) == "window-2")
    }

    /// A window shows one archive at a time: its next archive replaces its entry, and another
    /// window's entry stays. The second open of a file finds the first window, whatever the spelling.
    @Test func secondOpenOfSameFileFindsFirstScene() {
        let first = folder.appendingPathComponent("first.zip")
        let second = folder.appendingPathComponent("second.zip")
        let third = folder.appendingPathComponent("third.zip")
        OpenDocuments.register(first, sessionID: "window-1")
        OpenDocuments.register(second, sessionID: "window-2")
        defer { [first, second, third].forEach(OpenDocuments.forget) }

        #expect(OpenDocuments.sessionID(for: folder.appendingPathComponent("sub/../first.zip")) == "window-1")
        #expect(OpenDocuments.sessionID(for: second) == "window-2")

        OpenDocuments.register(third, sessionID: "window-2")
        #expect(OpenDocuments.sessionID(for: second) == nil)
        #expect(OpenDocuments.sessionID(for: third) == "window-2")
        #expect(OpenDocuments.sessionID(for: first) == "window-1")
    }

    /// A document's forget removes the window's entry only while it is still that document's.
    @Test func forgetByDocumentLeavesTheNextDocumentsEntry() {
        let old = NSObject(), next = NSObject()
        let first = folder.appendingPathComponent("old.zip"), second = folder.appendingPathComponent("next.zip")
        OpenDocuments.register(first, sessionID: "window-owned", document: old)
        defer { OpenDocuments.forget(sessionID: "window-owned") }
        OpenDocuments.register(second, sessionID: "window-owned", document: next)

        OpenDocuments.forget(sessionID: "window-owned", document: old)
        #expect(OpenDocuments.sessionID(for: second) == "window-owned")

        OpenDocuments.forget(sessionID: "window-owned", document: next)
        #expect(OpenDocuments.sessionID(for: second) == nil)
    }

    /// The scene's disconnect path (`OpenDocuments.close`): the pending edit is saved once, the
    /// staging folder goes, and the file is no longer open in any window.
    @Test func sceneDisconnectClosesDocument() async throws {
        let fixture = try Fixture.copy("zip/deflate.zip")
        let fake = FakeEngine()
        ArchiveDocument.engine = fake.engine
        let doc = ArchiveDocument(fileURL: fixture)
        ArchiveDocument.engine = .live
        #expect(await doc.openOnMain())
        let model = try #require(doc.session.model)
        model.remove(["README.md"])
        for _ in 0..<100 where !doc.hasUnsavedChanges {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(doc.hasUnsavedChanges)
        _ = try doc.staging.stage(data: Data("added".utf8), suggestedName: "added.txt")
        #expect(FileManager.default.fileExists(atPath: doc.staging.root.path))
        OpenDocuments.register(doc.fileURL, sessionID: "window-disconnect")

        await withCheckedContinuation { continuation in
            OpenDocuments.close(doc, sessionID: "window-disconnect") { continuation.resume() }
        }

        #expect(fake.writeCalls.count == 1)
        #expect(fake.writeCalls.first?.changes.removedPaths == ["README.md"])
        #expect(doc.documentState.contains(.closed))
        #expect(!FileManager.default.fileExists(atPath: doc.staging.root.path))
        #expect(OpenDocuments.sessionID(for: doc.fileURL) == nil)
    }

    /// The document view controller's setter, with the test host's own window as the session:
    /// a document registers under it, a second document on the same file is refused (that window
    /// shows it already), and nil (an in-window close) forgets it.
    @Test func documentSetterRegistersRefusesAndForgets() async throws {
        let session = try #require(UIApplication.shared.openSessions.first)
        let fixture = try Fixture.copy("zip/deflate.zip")
        ArchiveDocument.engine = FakeEngine().engine
        let doc = ArchiveDocument(fileURL: fixture)
        let duplicate = ArchiveDocument(fileURL: fixture)
        ArchiveDocument.engine = .live
        let docVC = ArchiveDocumentViewController(document: nil)
        docVC.sceneSession = session
        defer { OpenDocuments.forget(sessionID: session.persistentIdentifier) }

        docVC.document = doc
        #expect(OpenDocuments.sessionID(for: fixture) == session.persistentIdentifier)
        #expect(OpenDocuments.activateWindow(showing: fixture, from: session))

        docVC.document = duplicate
        #expect(docVC.document === doc)

        docVC.document = nil
        #expect(OpenDocuments.sessionID(for: fixture) == nil)
        #expect(OpenDocuments.activateWindow(showing: fixture, from: session) == false)
        if !doc.documentState.contains(.closed) { await doc.closeOnMain() }
    }

    /// The window's next archive registered before the closing one's
    /// document goes (close, then the pending file presented): the late nil keeps the new entry.
    @Test func closingDocumentDoesNotForgetTheWindowsNextArchive() async throws {
        let session = try #require(UIApplication.shared.openSessions.first)
        let closing = try Fixture.copy("zip/deflate.zip"), next = try Fixture.copy("zip/deflate.zip")
        ArchiveDocument.engine = FakeEngine().engine
        let closingDoc = ArchiveDocument(fileURL: closing)
        let nextDoc = ArchiveDocument(fileURL: next)
        ArchiveDocument.engine = .live
        let closingVC = ArchiveDocumentViewController(document: nil)
        let nextVC = ArchiveDocumentViewController(document: nil)
        closingVC.sceneSession = session
        nextVC.sceneSession = session
        defer { OpenDocuments.forget(sessionID: session.persistentIdentifier) }

        closingVC.document = closingDoc
        nextVC.document = nextDoc
        closingVC.document = nil
        #expect(OpenDocuments.sessionID(for: next) == session.persistentIdentifier)
        #expect(OpenDocuments.sessionID(for: closing) == nil)

        nextVC.document = nil
        #expect(OpenDocuments.sessionID(for: next) == nil)
        for doc in [closingDoc, nextDoc] where !doc.documentState.contains(.closed) { await doc.closeOnMain() }
    }

    /// A document let go of stays "closing" until it reports closed; what waits
    /// for its file runs after, its own forget first.
    @Test(.timeLimit(.minutes(1))) func closingDocumentHoldsItsFileUntilClosed() async throws {
        let fixture = try Fixture.copy("zip/deflate.zip")
        ArchiveDocument.engine = FakeEngine().engine
        let doc = ArchiveDocument(fileURL: fixture)
        ArchiveDocument.engine = .live
        #expect(await doc.openOnMain())
        OpenDocuments.register(fixture, sessionID: "window-closing", document: doc)
        defer { OpenDocuments.forget(sessionID: "window-closing") }

        let log = MainCallLog()
        OpenDocuments.trackClosing(doc) { doc in
            OpenDocuments.forget(sessionID: "window-closing", document: doc)
            log.calls.append("forget")
        }
        OpenDocuments.whenClosed(fixture) {
            log.calls.append(OpenDocuments.sessionID(for: fixture) == nil ? "waiter" : "waiter before forget")
        }
        #expect(OpenDocuments.isClosing(fixture))
        #expect(log.calls.isEmpty)

        await doc.closeOnMain()
        for _ in 0..<200 where log.calls.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.calls == ["forget", "waiter"])
        #expect(!OpenDocuments.isClosing(fixture))
        OpenDocuments.whenClosed(fixture) { log.calls.append("now") }
        #expect(log.calls.last == "now")
    }

    /// A file still closing in its window doesn't bring that window forward for
    /// another (it would show only its browser); the asker opens it once the close is done.
    /// The closing window itself still counts as showing it.
    @Test(.timeLimit(.minutes(1))) func fileClosingInItsWindowDoesNotBringThatWindowForward() async throws {
        let session = try #require(UIApplication.shared.openSessions.first)
        let fixture = try Fixture.copy("zip/deflate.zip")
        ArchiveDocument.engine = FakeEngine().engine
        let doc = ArchiveDocument(fileURL: fixture)
        ArchiveDocument.engine = .live
        #expect(await doc.openOnMain())
        OpenDocuments.register(fixture, sessionID: session.persistentIdentifier, document: doc)
        defer { OpenDocuments.forget(sessionID: session.persistentIdentifier) }

        OpenDocuments.trackClosing(doc)
        #expect(OpenDocuments.activateWindow(showing: fixture, from: nil) == false)
        #expect(OpenDocuments.activateWindow(showing: fixture, from: session))
        await doc.closeOnMain()
    }

    /// Only the asked-for window's own closing document holds it back. Another
    /// document on the same file still closing elsewhere (a close stuck past the wait limit's
    /// start) doesn't stop the window showing the file live from being brought forward.
    @Test(.timeLimit(.minutes(1))) func fileClosingElsewhereStillBringsItsLiveWindowForward() async throws {
        let session = try #require(UIApplication.shared.openSessions.first)
        let fixture = try Fixture.copy("zip/deflate.zip")
        ArchiveDocument.engine = FakeEngine().engine
        let live = ArchiveDocument(fileURL: fixture)
        ArchiveDocument.engine = .live
        #expect(await live.openOnMain())
        let stuck = BlankDocument(fileURL: fixture)
        #expect(await withCheckedContinuation { done in stuck.open { done.resume(returning: $0) } })
        OpenDocuments.register(fixture, sessionID: session.persistentIdentifier, document: live)
        defer { OpenDocuments.forget(sessionID: session.persistentIdentifier) }

        OpenDocuments.trackClosing(stuck)
        try #require(OpenDocuments.isClosing(fixture))
        #expect(OpenDocuments.activateWindow(showing: fixture, from: nil))
        #expect(OpenDocuments.activateWindow(showing: fixture, from: session))
        _ = await withCheckedContinuation { done in stuck.close { done.resume(returning: $0) } }
        await live.closeOnMain()
    }

    /// A document that has closed isn't kept alive by the close wait limit's
    /// timer (60 s): it goes as soon as nothing else holds it.
    @Test(.timeLimit(.minutes(1))) func closedDocumentIsNotKeptUntilTheCloseWaitLimit() async throws {
        let fixture = try Fixture.copy("zip/deflate.zip")
        weak var released: BlankDocument?
        do {
            let doc = BlankDocument(fileURL: fixture)
            released = doc
            #expect(await withCheckedContinuation { done in doc.open { done.resume(returning: $0) } })
            OpenDocuments.trackClosing(doc)
            #expect(OpenDocuments.isClosing(fixture))
            _ = await withCheckedContinuation { done in doc.close { done.resume(returning: $0) } }
            for _ in 0..<200 where OpenDocuments.isClosing(fixture) { try await Task.sleep(for: .milliseconds(10)) }
            try #require(!OpenDocuments.isClosing(fixture), "the document never finished closing")
        }
        for _ in 0..<200 where released != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(released == nil, "the closed document is kept until the close wait limit")
    }
}

/// A UIDocument with nothing in it, for what `OpenDocuments` keeps of a closing document.
private final class BlankDocument: UIDocument {
    override func contents(forType typeName: String) throws -> Any { Data() }
    override func load(fromContents contents: Any, ofType typeName: String?) throws {}
}

/// Calls recorded by main-actor callbacks.
@MainActor final class MainCallLog {
    var calls: [String] = []
}
