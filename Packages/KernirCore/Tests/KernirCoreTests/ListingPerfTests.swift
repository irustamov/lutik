import Testing
import Foundation
import KernirCore

/// Opt-in timing tests: KERNIR_PERF=1 swift test --filter ListingPerfTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KERNIR_PERF"] == "1"))
struct ListingPerfTests {
    private static let tree200kURL: URL = {
        let stamp = SyntheticZip.dosTime(year: 2024, month: 3, day: 9, hour: 10, minute: 20, second: 30)
        var entries = [(path: String, dosTime: UInt32, data: [UInt8])]()
        entries.reserveCapacity(200 * 1_001)
        for i in 0..<200 {
            entries.append((path: "d\(i)/", dosTime: stamp, data: []))
            for j in 0..<1_000 { entries.append((path: "d\(i)/f\(j).txt", dosTime: stamp, data: [])) }
        }
        return SyntheticZip.write(SyntheticZip.stored(entries))
    }()

    /// 200 directories x 1 000 empty files, written once per run.
    static func tree200k() -> URL { tree200kURL }

    static func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

    @Test func openTree200k() async throws {
        let url = Self.tree200k()
        var times = [Double]()
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let reader = try await Archive.open(at: url)
            let d = ContinuousClock.now - start
            #expect(reader.entries.count == 200 * 1_001)
            times.append(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        print("PERF openTree200k median \(String(format: "%.3f", Self.median(times))) s (runs: \(times))")
    }

    @Test func previewTree200k() async throws {
        let url = Self.tree200k()
        var times = [Double]()
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let p = try await Archive.previewListing(at: url, limit: 5_000)
            let d = ContinuousClock.now - start
            #expect(p.visibleEntryCount == 200 * 1_001)
            #expect(p.entries.count == 5_000)
            times.append(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        print("PERF previewTree200k median \(String(format: "%.3f", Self.median(times))) s (runs: \(times))")
    }
}
