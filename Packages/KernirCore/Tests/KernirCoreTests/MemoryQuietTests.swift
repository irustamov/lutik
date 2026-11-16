import Foundation
import Testing

/// The gate behind `MemoryQuiet`, on gates of its own so the suite never holds up the real measurements.
@Suite("MemoryQuiet gate")
struct MemoryQuietTests {
    actor Log {
        var events: [String] = []
        func add(_ e: String) { events.append(e) }
    }

    static func pause() async throws { try await Task.sleep(for: .milliseconds(50)) }

    @Test("A measurement waits for a running heavy section")
    func measureWaitsForHeavy() async throws {
        let gate = MemoryQuiet.Gate(), log = Log()
        await gate.begin(measuring: false)
        let m = Task {
            await gate.begin(measuring: true)
            await log.add("measure")
            await gate.end(measuring: true)
        }
        try await Self.pause()
        await log.add("heavy ends")
        await gate.end(measuring: false)
        await m.value
        #expect(await log.events == ["heavy ends", "measure"])
    }

    @Test("A heavy section waits for a running measurement")
    func heavyWaitsForMeasure() async throws {
        let gate = MemoryQuiet.Gate(), log = Log()
        await gate.begin(measuring: true)
        let h = Task {
            await gate.begin(measuring: false)
            await log.add("heavy")
            await gate.end(measuring: false)
        }
        try await Self.pause()
        await log.add("measure ends")
        await gate.end(measuring: true)
        await h.value
        #expect(await log.events == ["measure ends", "heavy"])
    }

    @Test("Measurements run one at a time")
    func measurementsTakeTurns() async throws {
        let gate = MemoryQuiet.Gate(), log = Log()
        await gate.begin(measuring: true)
        let m = Task {
            await gate.begin(measuring: true)
            await log.add("second")
            await gate.end(measuring: true)
        }
        try await Self.pause()
        await log.add("first ends")
        await gate.end(measuring: true)
        await m.value
        #expect(await log.events == ["first ends", "second"])
    }

    @Test("Heavy sections share, and a waiting measurement goes before a new one")
    func waitingMeasureGoesFirst() async throws {
        let gate = MemoryQuiet.Gate(), log = Log()
        await gate.begin(measuring: false)
        await gate.begin(measuring: false)  // A second one does not wait.
        let m = Task {
            await gate.begin(measuring: true)
            await log.add("measure")
            try? await Self.pause()
            await log.add("measure ends")
            await gate.end(measuring: true)
        }
        try await Self.pause()
        let h = Task {
            await gate.begin(measuring: false)
            await log.add("new heavy")
            await gate.end(measuring: false)
        }
        try await Self.pause()
        await log.add("heavy ends")
        await gate.end(measuring: false)
        try await Self.pause()
        #expect(await log.events == ["heavy ends"])
        await log.add("heavy ends")
        await gate.end(measuring: false)
        await m.value
        await h.value
        #expect(await log.events == ["heavy ends", "heavy ends", "measure", "measure ends", "new heavy"])
    }

    @Test("At most two heavy sections run at once; a third waits for one to end")
    func heavySectionsAreCapped() async throws {
        let gate = MemoryQuiet.Gate(), log = Log()
        await gate.begin(measuring: false)
        await gate.begin(measuring: false)
        let h = Task {
            await gate.begin(measuring: false)
            await log.add("third")
            await gate.end(measuring: false)
        }
        try await Self.pause()
        await log.add("first ends")
        await gate.end(measuring: false)
        await h.value
        await gate.end(measuring: false)
        #expect(await log.events == ["first ends", "third"])
    }

    /// Heavy sections that waited for a measurement do not all start together when it ends: they would compete for
    /// the CPU, and the wall-clock bounds of some (100,000 entries listed under 10 s) fail.
    @Test("A measurement's end lets at most two waiting heavy sections in")
    func releaseAfterMeasureIsCapped() async throws {
        let gate = MemoryQuiet.Gate(), log = Log()
        await gate.begin(measuring: true)
        let waiting = (0..<3).map { _ in
            Task {
                await gate.begin(measuring: false)
                await log.add("in")
            }
        }
        try await Self.pause()
        await gate.end(measuring: true)
        try await Self.pause()
        #expect(await log.events == ["in", "in"])
        await gate.end(measuring: false)
        try await Self.pause()
        #expect(await log.events == ["in", "in", "in"])
        for t in waiting { await t.value }
        await gate.end(measuring: false)
        await gate.end(measuring: false)
    }

    @Test("A section that throws still lets the next one in")
    func throwingSectionReleases() async throws {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { try await MemoryQuiet.measure { throw Boom() } }
        await #expect(throws: Boom.self) { try await MemoryQuiet.heavy { throw Boom() } }
        #expect(await MemoryQuiet.measure { 1 } == 1)
        #expect(await MemoryQuiet.heavy { 2 } == 2)
    }
}
