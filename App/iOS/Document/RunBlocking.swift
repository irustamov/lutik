import Dispatch
import Foundation
import os

/// Runs `operation` and blocks the calling thread until it finishes. Bridges UIDocument's
/// synchronous read and write overrides, which UIKit calls on its own background queue, to
/// the async engine. Never call it on the main thread: `operation` may need the main actor.
func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    precondition(!Thread.isMainThread, "runBlocking would block the main thread")
    let result = OSAllocatedUnfairLock<Result<T, any Error>?>(initialState: nil)
    let done = DispatchSemaphore(value: 0)
    // Outside a task, `currentPriority` is the calling thread's QoS: no priority inversion.
    Task.detached(priority: Task.currentPriority) {
        let outcome: Result<T, any Error>
        do {
            outcome = .success(try await operation())
        } catch {
            outcome = .failure(error)
        }
        result.withLock { $0 = outcome }
        done.signal()
    }
    done.wait()
    return try result.withLock { $0 }!.get()
}
