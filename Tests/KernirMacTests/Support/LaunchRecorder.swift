import Foundation
import Testing
@testable import Kernir

/// Collects what the `ArchiveActions.launch` seam is asked to open, in place of another app, for one test at
/// a time across all suites: a swap crossed with another suite's could send one test's launch to the other's
/// recorder, or put the real launcher back under a test still running, which opens TextEdit for real.
///
/// Lock order: a test that also takes the `PresentedErrors` lock takes this one first (`recording` outside
/// `PresentedErrors.collecting` / `expectingNone`), so two tests can never wait on each other.
@MainActor
final class LaunchRecorder {
    /// Each file asked for, with its app, in order.
    private(set) var calls: [(file: URL, app: URL?)] = []
    /// Each `launch`: the files it handed over together, and the app.
    private(set) var batches: [(files: [URL], app: URL?)] = []

    /// The files asked for, in order.
    var files: [URL] { calls.map(\.file) }

    private static let seam = TestSeamLock()

    /// Runs `body` with `ArchiveActions.launch` recording into a fresh `LaunchRecorder`, then puts the seam
    /// back as it was. Waits while another test holds the seam.
    static func recording<T>(_ body: (LaunchRecorder) async throws -> T) async rethrows -> T {
        try await seam.withLock {
            let recorder = LaunchRecorder()
            let original = ArchiveActions.launch
            ArchiveActions.launch = { files, app in
                recorder.batches.append((files, app))
                recorder.calls += files.map { ($0, app) }
            }
            defer { ArchiveActions.launch = original }
            return try await body(recorder)
        }
    }
}
