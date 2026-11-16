import Foundation
import KernirCore
import os

/// What a `SuspendingReader` saw, for assertions after the task it served has ended.
final class SuspendingReaderProbe: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (started: 0, cancelled: 0))

    var started: Int { counts.withLock { $0.started } }
    var cancelled: Int { counts.withLock { $0.cancelled } }

    fileprivate func start() { counts.withLock { $0.started += 1 } }
    fileprivate func cancel() { counts.withLock { $0.cancelled += 1 } }
}

/// An `ArchiveReading` whose extractions suspend until their task is cancelled, then throw
/// `CancellationError`, like a real reader stopped midway. Entries come from a `FakeReader`.
struct SuspendingReader: ArchiveReading {
    let base: FakeReader
    let probe: SuspendingReaderProbe

    init(entries: [ArchiveEntry], probe: SuspendingReaderProbe) {
        base = FakeReader(entries: entries)
        self.probe = probe
    }

    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        try await suspend()
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        try await suspend()
        throw ArchiveError.io("unreachable")
    }

    private func suspend() async throws {
        probe.start()
        do {
            try await Task.sleep(for: .seconds(120))
        } catch {
            probe.cancel()
            throw error
        }
    }
}
