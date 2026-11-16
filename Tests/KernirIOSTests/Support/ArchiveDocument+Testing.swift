import Foundation
@testable import Kernir

/// Main-actor versions of UIDocument's completion-handler calls. The generated
/// `open() async` / `close() async` are nonisolated, and Swift 6.3's region checker
/// rejects sending a UIDocument subclass to them despite `@unchecked Sendable`.
extension ArchiveDocument {
    @MainActor func openOnMain() async -> Bool {
        await withCheckedContinuation { continuation in
            open { continuation.resume(returning: $0) }
        }
    }

    @discardableResult @MainActor func closeOnMain() async -> Bool {
        await withCheckedContinuation { continuation in
            close { continuation.resume(returning: $0) }
        }
    }

    /// Waits for the close a controller started when it let this document go
    /// (`ArchiveDocumentViewController.document`). Never `closeOnMain()` such a document: a
    /// second close of one under way never calls back, and the continuation leaks (hang).
    @MainActor func closedByController() async {
        await withCheckedContinuation { continuation in
            OpenDocuments.trackClosing(self) { _ in continuation.resume() }
        }
    }

    @MainActor func autosaveOnMain() async -> Bool {
        await withCheckedContinuation { continuation in
            autosave { continuation.resume(returning: $0) }
        }
    }

    @MainActor func revertOnMain(toContentsOf url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            revert(toContentsOf: url) { continuation.resume(returning: $0) }
        }
    }
}

/// Carries a document into a non-main task (see the note above on region checking).
struct SendableDocument: @unchecked Sendable {
    let document: ArchiveDocument
}
