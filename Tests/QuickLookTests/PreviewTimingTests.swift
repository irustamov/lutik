import Foundation
import Testing
import KernirCore

/// Times the 200 000-entry zip through the real `PreviewLoader.load`, with no Quick Look and
/// no UI (nothing touches the user's desktop). Opt-in because building the zip takes a while:
///
///     TEST_RUNNER_KERNIR_PERF=1 xcodebuild test -project Kernir.xcodeproj \
///       -scheme KernirQuickLookTests -destination 'platform=macOS' [-configuration Release] \
///       -only-testing:KernirQuickLookTests/PreviewTimingTests
///
/// The zip matches the one measured through Quick Look: Python
/// zipfile, stored, 200 000 empty files. This times the listing only, not the extension's cold
/// start, so it is a lower bound for what Space in Finder takes.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KERNIR_PERF"] == "1"))
struct PreviewTimingTests {
    @Test func zip200kListing() async throws {
        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernir-ql-200k-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        // /usr/bin/python3 needs the Command Line Tools (installed with Xcode).
        let python = Process()
        python.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        python.arguments = ["-I", "-c", """
            import sys, zipfile
            with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_STORED) as z:
                for i in range(200000): z.writestr(f"f{i}.txt", "")
            """, zip.path]
        try python.run()
        python.waitUntilExit()
        try #require(python.terminationStatus == 0, "python3 could not build the zip")

        var times: [Duration] = []
        for _ in 0..<3 {
            var content: PreviewContent?
            times.append(try await ContinuousClock().measure { content = try await PreviewLoader.load(zip) })
            guard case .listing(let l) = content else { Issue.record("expected a listing"); return }
            #expect(l.totalCount == 200_000)
        }
        let ms = times.map { Int($0 / .milliseconds(1)) }
        print("PreviewTimingTests: 200k zip listing ms = \(ms)")
        #if !DEBUG
        #expect(times.allSatisfy { $0 < .seconds(2) }, "Release listing over 2 s: \(ms) ms")
        #endif
    }
}
