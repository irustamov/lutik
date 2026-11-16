import AppKit
import Testing
@testable import Kernir

/// Collects what the `ArchiveActions.presentError` seam receives, for one test at a time across all suites
///: a swap crossed with another suite's could send an error to the real app-modal alert,
/// which hangs a hosted run, or into the other suite's collector.
@MainActor
final class PresentedErrors {
    private(set) var errors: [any Error] = []

    private static let seam = TestSeamLock()

    /// Runs `body` with `ArchiveActions.presentError` collecting into a fresh `PresentedErrors`, then puts
    /// the seam back as it was. Waits while another test holds the seam.
    static func collecting<T>(_ body: (PresentedErrors) async throws -> T) async rethrows -> T {
        try await seam.withLock {
            let presented = PresentedErrors()
            let original = ArchiveActions.presentError
            ArchiveActions.presentError = { presented.errors.append($0) }
            defer { ArchiveActions.presentError = original }
            return try await body(presented)
        }
    }

    /// Runs `body` as `collecting` does, for a test that expects nothing presented: an error that reaches
    /// the seam fails the test instead of raising the real app-modal alert, which would hang a hosted run
    ///. Waits while another test holds the seam.
    static func expectingNone<T>(sourceLocation: SourceLocation = #_sourceLocation,
                                 _ body: () async throws -> T) async rethrows -> T {
        try await collecting { presented in
            let result = try await body()
            #expect(presented.errors.isEmpty, "Presented: \(presented.errors)", sourceLocation: sourceLocation)
            return result
        }
    }
}
