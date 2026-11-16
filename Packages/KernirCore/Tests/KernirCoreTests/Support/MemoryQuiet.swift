import Foundation
import Testing

/// Process-wide memory measurements and the tests that disturb them take turns.
///
/// malloc's in-use total and the footprint are process-wide, and suites run in parallel, so a test that holds
/// hundreds of MiB (an LZMA encoder fed 512 MiB, a 256 MiB xar TOC) while another test measures its own growth makes
/// that measurement fail. Every measurement runs inside `measure`, alone: no other measurement and no `heavy` section
/// runs then. `heavy` sections run beside ordinary tests and up to two beside each other, never beside a measurement.
/// A waiting measurement goes first: no new `heavy` section starts while one waits.
///
/// Mark as `heavy` (or the whole test `.memoryHeavy`) anything that holds more than 16 MiB for more than a second.
/// Shorter bursts (a 7z save's ~94 MiB LZMA encoder, under 1.5 s) are left to the measurements' retries: each one
/// keeps the smallest growth of a few attempts. Never nest `measure` and `heavy`: a `measure` inside `heavy` (or the
/// other way round) waits for itself.
enum MemoryQuiet {
    /// Runs `body` with no other `measure` or `heavy` section running.
    static func measure<T>(_ body: () async throws -> T) async rethrows -> T {
        await Gate.shared.begin(measuring: true)
        do {
            let result = try await body()
            await Gate.shared.end(measuring: true)
            return result
        } catch {
            await Gate.shared.end(measuring: true)
            throw error
        }
    }

    /// Runs `body`, which allocates a lot, with no `measure` section running.
    static func heavy<T>(_ body: () async throws -> T) async rethrows -> T {
        await Gate.shared.begin(measuring: false)
        do {
            let result = try await body()
            await Gate.shared.end(measuring: false)
            return result
        } catch {
            await Gate.shared.end(measuring: false)
            throw error
        }
    }

    /// Bytes malloc has handed out and not taken back, over all zones. Unlike the footprint, this does not hide an
    /// allocation that reuses pages a previous attempt freed.
    static func mallocInUse() -> Int64 {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int64(stats.size_in_use)
    }

    /// Samples `mallocInUse` every millisecond on its own thread and keeps the highest value.
    final class PeakSampler: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var highest: Int64 = 0
        private let done = DispatchSemaphore(value: 0)

        init() {
            Thread.detachNewThread { [self] in
                while lock.withLock({ running }) {
                    let f = MemoryQuiet.mallocInUse()
                    lock.withLock { highest = max(highest, f) }
                    usleep(1000)
                }
                done.signal()
            }
        }

        func stop() -> Int64 {
            lock.withLock { running = false }
            done.wait()
            return lock.withLock { highest }
        }
    }

    /// One measurement at a time, and only while no heavy section runs; up to `heavyLimit` heavy sections share.
    actor Gate {
        static let shared = Gate()
        /// Heavy sections that waited (for a measurement, say) would otherwise all start together and compete for
        /// the CPU, and the wall-clock bounds of some fail (100,000 entries listed under 10 s).
        static let heavyLimit = 2
        private var measuring = false
        private var heavy = 0
        private var waitingMeasures: [CheckedContinuation<Void, Never>] = []
        private var waitingHeavy: [CheckedContinuation<Void, Never>] = []

        func begin(measuring m: Bool) async {
            if m {
                if !measuring, heavy == 0, waitingMeasures.isEmpty {
                    measuring = true
                    return
                }
                // `wake` hands over: it sets `measuring` before it resumes this one.
                await withCheckedContinuation { waitingMeasures.append($0) }
            } else {
                if !measuring, waitingMeasures.isEmpty, waitingHeavy.isEmpty, heavy < Self.heavyLimit {
                    heavy += 1
                    return
                }
                // `wake` counts this one in `heavy` before it resumes it.
                await withCheckedContinuation { waitingHeavy.append($0) }
            }
        }

        func end(measuring m: Bool) {
            if m { measuring = false } else { heavy -= 1 }
            wake()
        }

        private func wake() {
            guard !measuring else { return }
            if !waitingMeasures.isEmpty {
                guard heavy == 0 else { return }
                measuring = true
                waitingMeasures.removeFirst().resume()
                return
            }
            while heavy < Self.heavyLimit, !waitingHeavy.isEmpty {
                heavy += 1
                waitingHeavy.removeFirst().resume()
            }
        }
    }
}

/// Runs a whole test (each of its cases) as a `MemoryQuiet.heavy` section: for tests that hold more than 16 MiB for
/// more than a second, which is enough to fail a measurement running beside them.
struct MemoryHeavy: TestTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await MemoryQuiet.heavy { try await function() }
    }
}

extension Trait where Self == MemoryHeavy {
    /// The test holds a lot of memory for a while: no `MemoryQuiet.measure` runs beside it.
    static var memoryHeavy: Self { Self() }
}
