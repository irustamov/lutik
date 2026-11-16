import Foundation

/// The line a window's file-promise writes wait in: one at a time, in the order they came, each
/// started only when the window can take an operation (`canStart`: no progress sheet and no other
/// sheet, so a drop never takes over a save's or an extraction's Cancel). `canStart` is asked
/// again before every operation. An operation is never dropped: it waits until the window is free
/// or it is cancelled. Cancelling one that waits takes it out of the line and calls its `cancel`
/// (which answers its promise), never its `run`; cancelling the running one calls its `cancel`
/// once, and the line moves on when its `run` has returned.
///
/// A promise receiver inside a Lutik window (a drop onto a Lutik window, its own included) must
/// never receive through this line. A self-drop could deadlock: the receiver holds the window (its
/// progress sheet) while it waits for the promised file, and the write that would deliver it waits in
/// this line for the window to be free. So the table refuses drops inside Lutik
/// (`ArchiveTableDragAnchor`: no local drag operation), and Lutik's drop destinations take file URLs only.
@MainActor
final class QueuedOperations {
    private struct Operation {
        let id: UUID
        let run: @MainActor () async -> Void
        let cancel: @MainActor () -> Void
    }

    private let pollInterval: Duration
    private let canStart: @MainActor () -> Bool
    private var waiting: [Operation] = []
    private var running: Operation?
    /// The running operation's `cancel` was called already.
    private var runningWasCancelled = false
    /// The task that works through `waiting`; nil when the line is idle.
    private var drain: Task<Void, Never>?

    /// - Parameters:
    ///   - pollInterval: how often a waiting operation asks `canStart` again.
    ///   - canStart: whether the window can take an operation now.
    init(pollInterval: Duration = .milliseconds(100), canStart: @escaping @MainActor () -> Bool) {
        self.pollInterval = pollInterval
        self.canStart = canStart
    }

    /// Operations waiting plus the one running.
    var count: Int { waiting.count + (running == nil ? 0 : 1) }
    /// Nothing waits or runs.
    var isIdle: Bool { count == 0 }

    /// Puts an operation at the end of the line. `run` is called once the window can take it and
    /// every earlier one has ended; `cancel` is called, at most once, if it is cancelled first or
    /// while it runs. Returns the operation's id, for `cancel(_:)`.
    @discardableResult
    func add(run: @escaping @MainActor () async -> Void, cancel: @escaping @MainActor () -> Void) -> UUID {
        let operation = Operation(id: UUID(), run: run, cancel: cancel)
        waiting.append(operation)
        if drain == nil {
            drain = Task { [weak self] in await self?.work() }
        }
        return operation.id
    }

    /// Cancels the operation `id`: one that waits leaves the line, the running one is told to stop;
    /// an unknown or finished one is ignored.
    func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).cancel()
        } else if running?.id == id {
            cancelRunning()
        }
    }

    /// Cancels every operation, e.g. when the document closes: the running one first, then the
    /// waiting ones in order. None of the waiting ones runs.
    func cancelAll() {
        cancelRunning()
        let cancelled = waiting
        waiting = []
        for operation in cancelled { operation.cancel() }
    }

    private func cancelRunning() {
        guard let running, !runningWasCancelled else { return }
        runningWasCancelled = true
        running.cancel()
    }

    /// Runs the line until it is empty. Between two operations nothing suspends, so an `add` always
    /// either finds this task or starts the next one.
    ///
    /// While `canStart` says no (a progress sheet, an attached sheet such as an alert) this asks again
    /// every `pollInterval` (100 ms by default) on the main actor, with no time limit: a queued write
    /// is never dropped, and Finder, which waits for the promise's completion handler, waits with it
    /// until the window is free or the write is cancelled.
    private func work() async {
        while !waiting.isEmpty {
            guard canStart() else {
                try? await Task.sleep(for: pollInterval)
                continue
            }
            let operation = waiting.removeFirst()
            running = operation
            runningWasCancelled = false
            await operation.run()
            running = nil
        }
        drain = nil
    }
}
