import Foundation
import Testing
@testable import Kernir

// The line a window's file-promise writes wait in (`QueuedOperations`): one at a time, each only
// when the window can take an operation, none ever dropped; a cancel takes a waiting one out (its
// own cancel answers its promise) or stops the running one. Slot-free.

/// What the operations did, in order.
@MainActor
private final class Log {
    var events: [String] = []
}

/// An operation that logs its start and end, and ends only when `release(name)` is called.
@MainActor
private final class Gates {
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<String> = []

    func wait(_ name: String) async {
        if released.contains(name) { return }
        await withCheckedContinuation { waiting[name] = $0 }
    }

    func release(_ name: String) {
        released.insert(name)
        waiting.removeValue(forKey: name)?.resume()
    }
}

/// Lets the queue's drain task run until `condition` holds (at most 5 s).
@MainActor
private func settle(until condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func add(_ name: String, to queue: QueuedOperations, log: Log, gates: Gates) -> UUID {
    queue.add(run: {
        log.events.append("start \(name)")
        await gates.wait(name)
        log.events.append("end \(name)")
    }, cancel: {
        log.events.append("cancel \(name)")
        gates.release(name)
    })
}

@MainActor @Test func operationsRunOneAtATimeInOrder() async {
    let log = Log(), gates = Gates()
    let queue = QueuedOperations(pollInterval: .milliseconds(5)) { true }
    _ = add("a", to: queue, log: log, gates: gates)
    _ = add("b", to: queue, log: log, gates: gates)
    _ = add("c", to: queue, log: log, gates: gates)
    await settle { log.events == ["start a"] }
    #expect(log.events == ["start a"])
    #expect(queue.count == 3)
    #expect(!queue.isIdle)

    gates.release("a")
    await settle { log.events.count == 3 }
    #expect(log.events == ["start a", "end a", "start b"])
    gates.release("b")
    gates.release("c")
    await settle { queue.isIdle }
    #expect(log.events == ["start a", "end a", "start b", "end b", "start c", "end c"])
    #expect(queue.count == 0)
}

/// A drop while another operation (a save, an extraction) holds the window waits for it, then runs.
@MainActor @Test func anOperationWaitsWhileTheWindowIsBusy() async {
    let log = Log(), gates = Gates()
    var busy = true
    let queue = QueuedOperations(pollInterval: .milliseconds(5)) { !busy }
    _ = add("a", to: queue, log: log, gates: gates)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(log.events.isEmpty)
    #expect(queue.count == 1)

    busy = false
    await settle { log.events == ["start a"] }
    #expect(log.events == ["start a"])
    gates.release("a")
    await settle { queue.isIdle }
    #expect(log.events == ["start a", "end a"])
}

/// The window is asked again before every operation: one that becomes busy between two waits.
@MainActor @Test func theWindowIsAskedBeforeEachOperation() async {
    let log = Log(), gates = Gates()
    var busy = false
    let queue = QueuedOperations(pollInterval: .milliseconds(5)) { !busy }
    _ = add("a", to: queue, log: log, gates: gates)
    _ = add("b", to: queue, log: log, gates: gates)
    await settle { log.events == ["start a"] }
    busy = true
    gates.release("a")
    gates.release("b")
    try? await Task.sleep(for: .milliseconds(100))
    #expect(log.events == ["start a", "end a"])
    busy = false
    await settle { queue.isIdle }
    #expect(log.events == ["start a", "end a", "start b", "end b"])
}

/// Cancelling a waiting operation takes it out of the line: its cancel runs once (that answers its
/// promise), its run never does; the others are untouched.
@MainActor @Test func cancellingAWaitingOperationTakesItOut() async {
    let log = Log(), gates = Gates()
    let queue = QueuedOperations(pollInterval: .milliseconds(5)) { true }
    _ = add("a", to: queue, log: log, gates: gates)
    let b = add("b", to: queue, log: log, gates: gates)
    _ = add("c", to: queue, log: log, gates: gates)
    await settle { log.events == ["start a"] }

    queue.cancel(b)
    queue.cancel(b)
    #expect(log.events == ["start a", "cancel b"])
    #expect(queue.count == 2)
    gates.release("a")
    gates.release("c")
    await settle { queue.isIdle }
    #expect(log.events == ["start a", "cancel b", "end a", "start c", "end c"])
}

/// Cancelling the running operation calls its cancel; the line moves on once it has ended.
@MainActor @Test func cancellingTheRunningOperationStopsIt() async {
    let log = Log(), gates = Gates()
    let queue = QueuedOperations(pollInterval: .milliseconds(5)) { true }
    let a = add("a", to: queue, log: log, gates: gates)
    _ = add("b", to: queue, log: log, gates: gates)
    await settle { log.events == ["start a"] }

    queue.cancel(a)
    await settle { log.events.count == 4 }
    #expect(log.events == ["start a", "cancel a", "end a", "start b"])
    gates.release("b")
    await settle { queue.isIdle }
}

/// The document closes: the running operation and every waiting one are cancelled, each once;
/// none of the waiting ones runs.
@MainActor @Test func cancelAllCancelsEveryOperationOnce() async {
    let log = Log(), gates = Gates()
    let queue = QueuedOperations(pollInterval: .milliseconds(5)) { true }
    _ = add("a", to: queue, log: log, gates: gates)
    _ = add("b", to: queue, log: log, gates: gates)
    _ = add("c", to: queue, log: log, gates: gates)
    await settle { log.events == ["start a"] }

    queue.cancelAll()
    queue.cancelAll()
    await settle { queue.isIdle }
    #expect(log.events == ["start a", "cancel a", "cancel b", "cancel c", "end a"])
    #expect(queue.count == 0)
}

/// Cancelled while the window was busy: nothing ever runs, and a later operation still does.
@MainActor @Test func cancelAllWhileWaitingForTheWindow() async {
    let log = Log(), gates = Gates()
    var busy = true
    let queue = QueuedOperations(pollInterval: .milliseconds(5)) { !busy }
    _ = add("a", to: queue, log: log, gates: gates)
    queue.cancelAll()
    busy = false
    try? await Task.sleep(for: .milliseconds(50))
    #expect(log.events == ["cancel a"])
    #expect(queue.isIdle)

    _ = add("b", to: queue, log: log, gates: gates)
    gates.release("b")
    await settle { queue.isIdle && log.events.count == 3 }
    #expect(log.events == ["cancel a", "start b", "end b"])
}

/// An operation added while another runs, or after the line went idle, is never lost.
@MainActor @Test func anOperationAddedLaterStillRuns() async {
    let log = Log(), gates = Gates()
    let queue = QueuedOperations(pollInterval: .milliseconds(5)) { true }
    _ = add("a", to: queue, log: log, gates: gates)
    gates.release("a")
    await settle { queue.isIdle }
    _ = add("b", to: queue, log: log, gates: gates)
    await settle { log.events.count == 3 }
    _ = add("c", to: queue, log: log, gates: gates)
    gates.release("b")
    gates.release("c")
    await settle { queue.isIdle && log.events.count == 6 }
    #expect(log.events == ["start a", "end a", "start b", "end b", "start c", "end c"])
}
