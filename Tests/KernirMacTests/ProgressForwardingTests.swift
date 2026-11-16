import Testing
import Foundation
@testable import Kernir
import os

/// One operation's progress sheet: late and bursty updates from engine threads.
@Suite struct ProgressForwardingTests {
    @MainActor @Test func staleUpdateLeavesTheNextOperationAlone() {
        let state = ArchiveWindowState()
        let first = OperationProgress(title: "Extracting", fraction: nil, cancel: nil)
        state.progress = first
        state.applyProgress(0.4, for: first.id)
        #expect(state.progress?.fraction == 0.4)

        // The extraction ended and a save took the sheet; the old operation's update lands late.
        let second = OperationProgress(title: "Saving", fraction: 0.1, cancel: nil)
        state.progress = second
        state.applyProgress(0.9, for: first.id)
        #expect(state.progress?.fraction == 0.1)
        #expect(state.progress?.id == second.id)

        state.progress = nil
        state.applyProgress(1, for: second.id)
        #expect(state.progress == nil)
    }

    @MainActor @Test func progressNeverMovesBackwards() {
        let state = ArchiveWindowState()
        let operation = OperationProgress(title: "Extracting", fraction: nil, cancel: nil)
        state.progress = operation
        state.applyProgress(0.8, for: operation.id)
        state.applyProgress(0.5, for: operation.id)
        #expect(state.progress?.fraction == 0.8)
    }

    @Test func burstOfUpdatesIsThrottledAndEndsAtOne() {
        let delivered = OSAllocatedUnfairLock<[Double]>(initialState: [])
        // A clock that advances 1 ms per call: 1 000 updates span one second.
        let start = ContinuousClock.now
        let ticks = OSAllocatedUnfairLock(initialState: 0)
        let handler = ProgressForwarding.handler(
            clock: { start + .milliseconds(ticks.withLock { value in value += 1; return value }) },
            deliver: { fraction in delivered.withLock { $0.append(fraction) } })

        for index in 1...1_000 { handler(Double(index) / 1_000, nil) }

        let values = delivered.withLock { $0 }
        #expect(!values.isEmpty)
        #expect(values.count < 100)
        #expect(values.last == 1)
        #expect(values == values.sorted())
    }

    @Test func firstUpdateIsDelivered() {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let handler = ProgressForwarding.handler(deliver: { _ in count.withLock { $0 += 1 } })
        handler(0.01, nil)
        #expect(count.withLock { $0 } == 1)
    }
}
