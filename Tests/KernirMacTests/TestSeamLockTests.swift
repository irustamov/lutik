import Testing
import Foundation
@testable import Kernir

/// The lock behind `PresentedErrors.collecting`.
@MainActor
struct TestSeamLockTests {
    @MainActor private final class Log {
        var entries: [String] = []
    }

    /// Bodies that wait inside never overlap: each one's start and end are next to each other.
    @Test func bodiesRunOneAtATime() async {
        let lock = TestSeamLock()
        let log = Log()
        let tasks = (0..<3).map { index in
            Task { @MainActor in
                await lock.withLock {
                    log.entries.append("\(index) in")
                    try? await Task.sleep(for: .milliseconds(10))
                    log.entries.append("\(index) out")
                }
            }
        }
        for task in tasks { await task.value }

        #expect(log.entries.count == 6)
        for start in stride(from: 0, to: log.entries.count - 1, by: 2) {
            let index = log.entries[start].split(separator: " ")[0]
            #expect(log.entries[start] == "\(index) in" && log.entries[start + 1] == "\(index) out")
        }
        // Free again: a later body runs straight away.
        #expect(await lock.withLock { 42 } == 42)
    }

    /// A body that throws hands the lock on too.
    @Test func throwingBodyReleasesTheLock() async {
        let lock = TestSeamLock()
        await #expect(throws: CancellationError.self) {
            try await lock.withLock { throw CancellationError() }
        }
        #expect(await lock.withLock { "free" } == "free")
    }
}
