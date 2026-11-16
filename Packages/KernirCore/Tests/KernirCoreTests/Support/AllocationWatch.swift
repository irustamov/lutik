import Darwin
import Foundation

/// Sees every block malloc hands out, through macOS's `malloc_logger` hook (the one malloc stack logging uses), so a
/// block that lives for microseconds still counts. `MemoryQuiet.PeakSampler` polls once a millisecond and misses a
/// calloc that is freed at once, and the untouched pages of a large calloc never reach the footprint either.
enum AllocationWatch {
    /// `malloc_logger_t` from libmalloc: type, then arg1-arg3, the result and the frames to skip. For an allocation
    /// (type bit 2) the size is arg2; a realloc (bits 2 and 4) has its new size in arg3.
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    struct HookMissing: Error {}

    /// The count being watched (`state[0]`), the largest block seen whose size is a multiple of it (`state[1]`), and
    /// the bits of a logger that was installed before ours (`state[2]`, malloc stack logging, say), which ours passes
    /// every event on to. Raw memory, not a Swift `var`: the logger runs on threads that never ran Swift, and the
    /// dynamic exclusivity check of a global `var` would make the runtime malloc that thread's context inside the
    /// logger, which logs that malloc and recurses until the stack overflows (SIGBUS).
    nonisolated(unsafe) static let state: UnsafeMutablePointer<Int> = {
        let p = UnsafeMutablePointer<Int>.allocate(capacity: 3)
        p.initialize(repeating: 0, count: 3)
        return p
    }()

    /// The largest block anything in the process allocated while `body` ran whose size is a whole multiple of `count`
    /// bytes (an array of `count` elements of any size), or 0 if there was none. malloc is process-wide, so it runs
    /// inside `MemoryQuiet.measure`: one watch at a time, with no heavy section beside it. Don't call it inside
    /// `measure` or `heavy`. The largest size is best-effort under concurrent qualifying allocations (a non-atomic max).
    static func largestMultiple<T>(of count: Int, during body: () async throws -> T) async throws
        -> (result: T, largest: Int) {
        precondition(count > 0)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { throw HookMissing() }
        let hook = symbol.assumingMemoryBound(to: Logger?.self)
        return try await MemoryQuiet.measure {
            // Installed twice, `previous` would be watchLogger itself and every malloc event would recurse.
            precondition(hook.pointee.map { unsafeBitCast($0, to: UnsafeRawPointer.self) }
                         != unsafeBitCast(watchLogger, to: UnsafeRawPointer.self), "AllocationWatch is already installed")
            let previous = hook.pointee
            state[0] = count
            state[1] = 0
            state[2] = unsafeBitCast(previous, to: Int.self)
            // The stores to `state` must be visible to other threads before the logger that reads them is.
            OSMemoryBarrier()
            hook.pointee = watchLogger
            defer {
                hook.pointee = previous
                state[0] = 0
            }
            let result = try await body()
            return (result, state[1])
        }
    }

    /// `largestMultiple(of:during:)` run up to `attempts` times, until the largest block is under `bound`: the first
    /// attempt under it, else the last one. `measure` keeps other measurements and heavy sections out, not ordinary
    /// tests, and the watch sees their blocks too: one of 64 MiB + 8 bytes failed a 16 MiB bound once in a full run
    /// under load. A block `body` allocates itself comes back on every attempt and still fails; `body` must be safe
    /// to run again.
    static func largestMultiple<T>(of count: Int, under bound: Int, attempts: Int = 5,
                                   during body: () async throws -> T) async throws -> (result: T, largest: Int) {
        precondition(attempts > 0)
        var watched = try await largestMultiple(of: count, during: body)
        for _ in 1..<attempts where watched.largest >= bound {
            watched = try await largestMultiple(of: count, during: body)
        }
        return watched
    }
}

/// Runs on every malloc event in the process, on the allocating thread: it must not allocate, nor touch a Swift
/// global `var` (see `state`).
private let watchLogger: AllocationWatch.Logger = { type, arg1, arg2, arg3, result, skip in
    let s = AllocationWatch.state
    if type & 2 != 0 {
        let bytes = Int(bitPattern: type & 4 != 0 ? arg3 : arg2)
        let count = s[0]
        if count > 0, bytes >= count, bytes % count == 0, bytes > s[1] { s[1] = bytes }
    }
    unsafeBitCast(s[2], to: AllocationWatch.Logger?.self)?(type, arg1, arg2, arg3, result, skip)
}
