import Testing
import Foundation
@testable import Kernir
import KernirCore
import os

// Extract Here sweeps a crashed run's staging beside the archive before making its own:
// this device's, its process gone, 10 minutes old. A live run's and a young one stay.

@MainActor @Test func extractHereSweepsStaleStagingBesideTheArchive() async throws {
    let token = "5eed5eed5eed5eed"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExtractHereSweepTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("report.zip")
    try Data("archive".utf8).write(to: archive)
    let old = Date(timeIntervalSinceNow: -3600)
    let stale = try makeTestStaging(in: directory, token: token, pid: try reapedPid(), modified: old)
    let live = try makeTestStaging(in: directory, token: token, pid: getppid(), modified: old)
    let young = try makeTestStaging(in: directory, token: token, pid: try reapedPid(), modified: Date())
    let model = ArchiveModel(reader: FakeReader(entries: [
        ArchiveEntry(path: "report.pdf", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
    ]), undoManager: nil)
    model.extractionFileSystem = ExtractionFileSystem(deviceToken: token) { from, to, flags in
        renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    let plan = try #require(ExtractHerePlan.make(nil, in: model, archiveURL: archive))

    let placed = try await ExtractHereService.extract(plan, from: model, nextTo: archive, progress: nil)

    #expect(placed.lastPathComponent == "report.pdf")
    let left = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    #expect(left == ["report.zip", "report.pdf", live.lastPathComponent, young.lastPathComponent])
    #expect(!left.contains(stale.lastPathComponent))
}

/// A Cancel that lands while the sweep runs (awaiting the sweep never throws) stops Extract Here
/// before it makes any staging: no hidden folder, no output, nothing removed (`removeItem` is never
/// called, which is what a made staging folder would have gone through), and the error is the cancel.
/// The sweep itself is not undone: the stale staging it was started on is gone.
@MainActor @Test func aCancelDuringTheSweepStopsBeforeAnyStagingIsMade() async throws {
    let token = "5eed5eed5eed5eed"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExtractHereSweepTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stale = try makeTestStaging(in: directory, token: token, pid: try reapedPid(),
                                    modified: Date(timeIntervalSinceNow: -3600))
    let model = ArchiveModel(reader: FakeReader(entries: [
        ArchiveEntry(path: "report.pdf", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
    ]), undoManager: nil)
    model.extractionFileSystem = ExtractionFileSystem(deviceToken: token) { from, to, flags in
        renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    let removed = OSAllocatedUnfairLock(initialState: [URL]())

    // The task has not started when it is cancelled (this test holds the main actor), so the
    // cancel is there before and during the sweep it awaits.
    let task = Task { @MainActor in
        try await ExtractHereService.extract(.single(path: "report.pdf", name: "report.pdf", isDirectory: false),
                                             from: model, in: directory, progress: nil,
                                             removeItem: { url in removed.withLock { $0.append(url) } })
    }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("a cancelled Extract Here must throw")
    } catch {
        #expect(error is CancellationError, "\(error)")
    }

    #expect(removed.withLock { $0 }.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
}

/// The sweep before a write runs at most once per folder per `StagingSweep.interval`: a
/// second Extract Here into the same folder soon after goes straight to its write, and stale staging
/// that showed up in between stays for a later sweep.
@MainActor @Test func aSecondExtractHereSoonAfterDoesNotSweepAgain() async throws {
    let token = "5eed5eed5eed5eed"
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExtractHereSweepTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = Date(timeIntervalSinceNow: -3600)
    let first = try makeTestStaging(in: directory, token: token, pid: try reapedPid(), modified: old)
    let model = ArchiveModel(reader: FakeReader(entries: [
        ArchiveEntry(path: "report.pdf", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
    ]), undoManager: nil)
    model.extractionFileSystem = ExtractionFileSystem(deviceToken: token) { from, to, flags in
        renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    let plan = ExtractHerePlan.single(path: "report.pdf", name: "report.pdf", isDirectory: false)

    _ = try await ExtractHereService.extract(plan, from: model, in: directory, progress: nil)
    #expect(!FileManager.default.fileExists(atPath: first.path))

    let second = try makeTestStaging(in: directory, token: token, pid: try reapedPid(), modified: old)
    let placed = try await ExtractHereService.extract(plan, from: model, in: directory, progress: nil)

    #expect(placed.lastPathComponent == "report 2.pdf")
    #expect(FileManager.default.fileExists(atPath: second.path))
}
