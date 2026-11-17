import Foundation
import Testing
@testable import KernirCore

/// The "Test archive" API (ws19): report value types and the `ArchiveReading.test(progress:)` default.
struct ArchiveTestReportAPITests {
    private static func failure(_ path: String = "a.txt", same: [String] = []) -> ArchiveTestFailure {
        ArchiveTestFailure(path: path, error: .corrupted(path), sameBlockPaths: same)
    }

    @Test func isCleanWithNoFailuresAndNothingUnchecked() {
        let report = ArchiveTestReport(checkedCount: 3, failures: [], notChecked: [], coverage: .dataChecksums)
        #expect(report.isClean)
    }

    @Test func isNotCleanWithAFailure() {
        let report = ArchiveTestReport(checkedCount: 3, failures: [Self.failure()], notChecked: [],
                                       coverage: .dataChecksums)
        #expect(!report.isClean)
    }

    @Test func isNotCleanWithUncheckedEntries() {
        let report = ArchiveTestReport(checkedCount: 1, failures: [], notChecked: ["b.txt"], coverage: .headersOnly)
        #expect(!report.isClean)
    }

    @Test func valuesAreEquatable() {
        let a = ArchiveTestReport(checkedCount: 2, failures: [Self.failure(same: ["s1"])], notChecked: ["x"],
                                  coverage: .none)
        let b = ArchiveTestReport(checkedCount: 2, failures: [Self.failure(same: ["s1"])], notChecked: ["x"],
                                  coverage: .none)
        #expect(a == b)
        #expect(a != ArchiveTestReport(checkedCount: 2, failures: [Self.failure(same: ["s1", "s2"])], notChecked: ["x"],
                                       coverage: .none))
        #expect(a != ArchiveTestReport(checkedCount: 2, failures: [Self.failure(same: ["s1"])], notChecked: ["x"],
                                       coverage: .headersOnly))
        #expect(ArchiveIntegrityCoverage.dataChecksums != .headersOnly)
    }

    @Test func affectedPathsIsTheDedupedUnion() {
        let report = ArchiveTestReport(
            checkedCount: 4,
            failures: [Self.failure("a", same: ["b", "c"]), Self.failure("c", same: ["a", "d"])],
            notChecked: ["d", "e"],
            coverage: .dataChecksums)
        #expect(report.affectedPaths == ["a", "b", "c", "d", "e"])
        #expect(ArchiveTestReport(checkedCount: 1, failures: [], notChecked: [], coverage: .none)
            .affectedPaths.isEmpty)
    }

    @Test func defaultTestThrowsNotImplemented() async {
        let reader: any ArchiveReading = MinimalReader()
        await #expect(throws: ArchiveError.notImplemented) {
            _ = try await reader.test(progress: nil)
        }
    }

    /// TEST-PENDING: ws19 implements `LibArchiveReader.test`; until then a real reader falls back to the protocol
    /// default. Once it lands the known issue is not recorded and this fails: remove the marker and assert the report.
    @Test func openedZipTestIsNotImplementedUntilWs19() async throws {
        let reader = try await Archive.open(at: Corpus.root.appending(path: "zip/deflate.zip"))
        try await withKnownIssue("TEST-PENDING: ws19 implements LibArchiveReader.test") {
            _ = try await reader.test(progress: nil)
            Issue.record("test(progress:) returned; expected .notImplemented")
        } matching: { issue in
            guard let error = issue.error as? ArchiveError, case .notImplemented = error else { return false }
            return true
        }
    }

    private struct MinimalReader: ArchiveReading {
        var url: URL { URL(fileURLWithPath: "/dev/null") }
        var format: ArchiveFormat { .zip }
        var entries: [ArchiveEntry] { [] }
        var isEncrypted: Bool { false }
        func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {}
        func extractToTemporaryFile(_ path: String) async throws -> URL { url }
    }
}
