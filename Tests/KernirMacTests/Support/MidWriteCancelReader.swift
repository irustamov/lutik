import Foundation
import KernirCore

/// An `ArchiveReading` that has written part of the item (a folder "src" holding "main.swift") when it
/// calls `wrote`, then waits for its task's cancel and stops the way the engine does: by throwing
/// `error` (KernirCore's `ArchiveError.cancelled`, or a `CancellationError`). Entries come from a
/// `FakeReader`.
struct MidWriteCancelReader: ArchiveReading {
    let base: FakeReader
    let wrote: @Sendable () -> Void
    let error: any Error & Sendable

    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        let partial = directory.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: partial.appendingPathComponent("main.swift"))
        wrote()
        // try?: Task.sleep throws CancellationError on the cancel, which must not stand in for `error`.
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        throw error
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        try await base.extractToTemporaryFile(path)
    }
}
