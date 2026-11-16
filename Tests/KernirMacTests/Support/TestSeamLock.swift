import Foundation

/// Lets one test at a time hold a process-wide seam (a static the tests swap). Swift Testing runs suites in
/// parallel, and @MainActor tests interleave at every `await`, so `.serialized` on one suite doesn't stop
/// another suite from swapping the same static meanwhile, or restoring it under a test still using it.
@MainActor
final class TestSeamLock {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Runs `body` once no other `withLock` body of this lock is running; the waiters go in arrival order.
    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        if isHeld {
            // Handed over by the body before, which leaves `isHeld` set.
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isHeld = true
        }
        defer {
            if waiters.isEmpty { isHeld = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}
