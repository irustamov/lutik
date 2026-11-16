import Darwin
import Testing

/// `AllocationWatch`'s malloc logger runs on every thread of the process, including threads that never ran Swift.
/// Where `allocateAndFree` publishes each block before freeing it, so the optimizer cannot elide the malloc.
private nonisolated(unsafe) var allocationSink: UnsafeMutableRawPointer?

/// Mallocs `count` bytes, keeps the pointer observable through a global, and frees it.
@inline(never)
private func allocateAndFree(_ count: Int) {
    let block = malloc(count)
    allocationSink = block
    block?.storeBytes(of: 1, as: UInt8.self)
    free(block)
}

@Suite("AllocationWatch")
struct AllocationWatchTests {
    /// A thread that has not run Swift code yet has no Swift runtime thread context. If the logger touched one (the
    /// dynamic exclusivity check of a global `var` does), the runtime would malloc it inside the logger, which logs
    /// that malloc and recurses until the stack overflows: SIGBUS, seen in full `swift test` runs while a crafted-size
    /// 7z test had the watch installed and the pool started a new thread. Here a bare pthread allocates as its first
    /// act under the watch; the child process must exit cleanly, and the watch must have seen that thread's block.
    @Test func aThreadThatNeverRanSwiftAllocatesUnderTheWatch() async {
        await #expect(processExitsWith: .success) {
            let count = 100_003
            let watched = try await AllocationWatch.largestMultiple(of: count) { Self.allocateOnABareThread() }
            if watched.largest != 3 * count { exit(3) }
        }
    }

    /// Starts a pthread whose first act is a malloc of 3 × 100,003 bytes, and waits for it.
    private static func allocateOnABareThread() {
        var thread: pthread_t?
        let rc = pthread_create(&thread, nil, { _ in
            allocateAndFree(3 * 100_003)
            return nil
        }, nil)
        guard rc == 0, let thread else { exit(2) }
        pthread_join(thread, nil)
    }

    /// A 64 MiB block another test allocates on another thread while the watch is on (seen once in a full run under
    /// load, against the 16 MiB bound of an ISO 9660 test) fails that attempt only: the next one, without it, is kept.
    @Test func aBlockFromBesideTheBodyFailsOneAttemptOnly() async throws {
        var attempt = 0
        let watched = try await AllocationWatch.largestMultiple(of: 1, under: 16 << 20) {
            attempt += 1
            if attempt == 1 { await Task.detached { allocateAndFree((64 << 20) + 8) }.value }
            return attempt
        }
        #expect(watched.largest < 16 << 20, "largest block \(watched.largest)")
        // A parallel allocation landing in attempt 2 too would make the kept attempt a later one.
        #expect(watched.result >= 2)
    }

    /// A block the body allocates itself comes back on every attempt, so the bound still fails.
    @Test func aBlockOfTheBodysOwnFailsEveryAttempt() async throws {
        var attempts = 0
        let watched = try await AllocationWatch.largestMultiple(of: 1, under: 16 << 20, attempts: 3) {
            attempts += 1
            allocateAndFree(32 << 20)
        }
        #expect(watched.largest >= 32 << 20, "largest block \(watched.largest)")
        #expect(attempts == 3)
    }
}
