import AppKit
import Foundation
import os
import Testing
@testable import Kernir
import KernirCore

// `ArchiveActions.filePromise(for:)`, the entry point of a row dragged out of the window: the write
// waits for the window to be free, shows the progress sheet with Cancel and clears only its own,
// and a failure is alerted exactly once (or goes to `presentError` when the window is gone); a
// Cancel is never alerted. Hosted (ArchiveDocument, AppKit): needs a hosted UI test run. Most tests have
// no window (`presentError` is what a missing window gets); one test sets an offscreen one on `actions.window`.

private let testDeviceToken = "f12ef12ef12ef12e"

private let entries: [ArchiveEntry] = [
    ArchiveEntry(path: "README.md", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
    ArchiveEntry(path: "src", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil),
    ArchiveEntry(path: "src/main.swift", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
]

/// A fresh empty folder standing for the drop's destination; the caller removes it.
private func makeDestination() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveActionsFilePromiseTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A document whose archive is `reader`, renames being renamex_np(2) with a test device token.
@MainActor
private func makeDocument(reader: any ArchiveReading) throws -> ArchiveDocument {
    let document = try ArchiveDocument(type: "public.zip-archive")
    let model = ArchiveModel(reader: reader, undoManager: nil)
    model.extractionFileSystem = ExtractionFileSystem(deviceToken: testDeviceToken) { from, to, flags in
        renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    document.state.model = model
    return document
}

/// Every call of a promise's completion handler.
private final class Completions: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(any Error)?] = []
    func record(_ error: (any Error)?) { lock.withLock { calls.append(error) } }
    var all: [(any Error)?] { lock.withLock { calls } }
}

/// Polls until `condition` holds, for at most about five seconds; the caller asserts the outcome.
@MainActor
private func wait(for condition: () -> Bool) async {
    for _ in 0..<1_000 where !condition() {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// Settles: waits for `condition`, then 0.3 s more so a second call would show.
@MainActor
private func settle(until condition: () -> Bool) async {
    await wait(for: condition)
    try? await Task.sleep(for: .milliseconds(300))
}

/// How many extractions a `HeldReader` has begun.
private final class HeldProbe: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var started: Int { count.withLock { $0 } }
    func noteStart() { count.withLock { $0 += 1 } }
}

/// An `ArchiveReading` whose extractions write like a `FakeReader`, but only after `release` (and
/// stop at a cancel, like a real reader stopped midway). `started` counts the extractions begun.
private struct HeldReader: ArchiveReading {
    let base: FakeReader
    let probe: HeldProbe
    let release: AsyncStream<Void>

    init(entries: [ArchiveEntry], probe: HeldProbe, release: AsyncStream<Void>) {
        base = FakeReader(entries: entries)
        self.probe = probe
        self.release = release
    }

    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        probe.noteStart()
        for await _ in release { break }
        try Task.checkCancellation()
        try await base.extract(paths, to: directory, progress: progress)
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        try await base.extractToTemporaryFile(path)
    }
}

/// Which extractions of a `TurnReader` have begun, and which may go on.
private final class Turns: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (started: 0, opened: Set<Int>()))
    /// How many extractions have begun; the n-th is turn n.
    var started: Int { state.withLock { $0.started } }
    func begin() -> Int { state.withLock { $0.started += 1; return $0.started } }
    func open(_ turn: Int) { state.withLock { _ = $0.opened.insert(turn) } }
    func isOpen(_ turn: Int) -> Bool { state.withLock { $0.opened.contains(turn) } }
}

/// A `TurnReader` turn nobody opened in time: the test is stuck, not slow.
private struct TurnNeverOpened: Error {
    let turn: Int
}

/// An `ArchiveReading` whose n-th extraction writes like a `FakeReader` only once turn n is open, and
/// stops at a cancel while it waits (like a real reader stopped midway). Unlike `HeldReader`, one
/// extraction's cancel leaves the next one held. A turn not opened within 10 s records an issue and
/// throws, so a stuck test fails rather than spinning for good.
private struct TurnReader: ArchiveReading {
    let base: FakeReader
    let turns: Turns

    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        let turn = turns.begin()
        let deadline = ContinuousClock.now + .seconds(10)
        while !turns.isOpen(turn) {
            guard ContinuousClock.now < deadline else {
                Issue.record("TurnReader: turn \(turn) was not opened within 10 s")
                throw TurnNeverOpened(turn: turn)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await base.extract(paths, to: directory, progress: progress)
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        try await base.extractToTemporaryFile(path)
    }
}

@MainActor
private func writePromise(_ provider: NSFilePromiseProvider, named name: String, to destination: URL,
                          completions: Completions) throws {
    let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
    delegate.filePromiseProvider(provider, writePromiseTo: destination.appendingPathComponent(name)) {
        completions.record($0)
    }
}

/// A window held offscreen (AppKit keeps a titled window on a screen unless told not to), ordered front so
/// a sheet attaches to it; `end()` takes its sheets down and closes it.
@MainActor
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    static func make() -> OffscreenWindow {
        let window = OffscreenWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    func end() {
        for sheet in sheets { endSheet(sheet) }
        orderOut(nil)
    }
}

/// A sheet that is not a failure alert: another operation's, or a panel.
@MainActor
private func beginPlainSheet(on window: NSWindow) -> NSWindow {
    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                         backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    window.beginSheet(sheet)
    return sheet
}

// MARK: - The progress sheet

@Suite(.serialized) @MainActor
struct ArchiveActionsFilePromiseTests {
    /// While the write runs the window shows "Extracting “…”…" with Cancel; when it ends, the sheet is
    /// gone and the completion handler was called once, without an error.
    @Test func theProgressSheetShowsWhileTheWriteRunsAndGoesWhenItEnds() async throws {
        try await PresentedErrors.expectingNone {
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let probe = HeldProbe()
            let (released, release) = AsyncStream.makeStream(of: Void.self)
            let document = try makeDocument(reader: HeldReader(entries: entries, probe: probe, release: released))
            let actions = ArchiveActions(document: document)
            let provider = try #require(actions.filePromise(for: "src"))
            let completions = Completions()
            #expect(document.state.progress == nil)

            try writePromise(provider, named: "src", to: destination, completions: completions)
            await wait { document.state.progress != nil && probe.started == 1 }

            let sheet = try #require(document.state.progress)
            #expect(sheet.title.contains(document.displayName))
            #expect(sheet.cancel != nil)
            #expect(actions.hasFilePromiseWork)
            #expect(completions.all.isEmpty)

            release.yield()
            await settle { !completions.all.isEmpty }

            #expect(completions.all.count == 1)
            #expect(completions.all.first.map { $0 == nil } == true)
            #expect(document.state.progress == nil)
            #expect(!actions.hasFilePromiseWork)
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["src"])
        }
    }

    /// The sheet's Cancel stops the write: the completion handler hears Cocoa's user-cancelled error
    /// once, nothing is alerted, nothing stays in the drop folder, and the sheet goes.
    @Test func cancelOnTheSheetEndsTheWriteAsUserCancelledWithoutAnAlert() async throws {
        try await PresentedErrors.expectingNone {
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let probe = HeldProbe()
            let (released, _) = AsyncStream.makeStream(of: Void.self)
            let document = try makeDocument(reader: HeldReader(entries: entries, probe: probe, release: released))
            let actions = ArchiveActions(document: document)
            let provider = try #require(actions.filePromise(for: "src"))
            let completions = Completions()

            try writePromise(provider, named: "src", to: destination, completions: completions)
            await wait { document.state.progress != nil && probe.started == 1 }
            let cancel = try #require(document.state.progress?.cancel)
            cancel()
            await settle { !completions.all.isEmpty }

            #expect(completions.all.count == 1)
            let error = try #require(completions.all.first ?? nil) as NSError
            #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
            #expect(document.state.progress == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    /// The write clears only its own sheet: another operation's that replaced it stays.
    @Test func theWriteClearsOnlyItsOwnSheet() async throws {
        try await PresentedErrors.expectingNone {
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let probe = HeldProbe()
            let (released, release) = AsyncStream.makeStream(of: Void.self)
            let document = try makeDocument(reader: HeldReader(entries: entries, probe: probe, release: released))
            let actions = ArchiveActions(document: document)
            let provider = try #require(actions.filePromise(for: "src"))
            let completions = Completions()

            try writePromise(provider, named: "src", to: destination, completions: completions)
            await wait { document.state.progress != nil && probe.started == 1 }
            let other = OperationProgress(title: "Another operation", fraction: nil, cancel: nil)
            document.state.progress = other

            release.yield()
            await settle { !completions.all.isEmpty }

            #expect(completions.all.count == 1)
            #expect(document.state.progress?.id == other.id)
            document.state.progress = nil
        }
    }

    // MARK: - The line, and the alert

    /// A drop while another operation has the window (a save, an extraction) waits: nothing starts,
    /// no sheet is replaced, the completion handler isn't called; it runs once the window is free.
    @Test func aDropWaitsWhileTheWindowIsBusyThenRuns() async throws {
        try await PresentedErrors.expectingNone {
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let probe = HeldProbe()
            let (released, release) = AsyncStream.makeStream(of: Void.self)
            let document = try makeDocument(reader: HeldReader(entries: entries, probe: probe, release: released))
            let actions = ArchiveActions(document: document)
            let busy = OperationProgress(title: "A save", fraction: nil, cancel: nil)
            document.state.progress = busy
            let provider = try #require(actions.filePromise(for: "src"))
            let completions = Completions()

            try writePromise(provider, named: "src", to: destination, completions: completions)
            try await Task.sleep(for: .milliseconds(400))

            #expect(probe.started == 0)
            #expect(completions.all.isEmpty)
            #expect(document.state.progress?.id == busy.id)
            #expect(actions.hasFilePromiseWork)

            document.state.progress = nil
            release.yield()
            await settle { !completions.all.isEmpty }

            #expect(probe.started == 1)
            #expect(completions.all.count == 1)
            #expect(completions.all.first.map { $0 == nil } == true)
            #expect(document.state.progress == nil)
        }
    }

    /// Two drops queue: while the first extraction runs the second does not begin; once released both
    /// finish and neither is dropped. Queue order only: the sheet and alert gaps are the window tests below.
    @Test func twoDropsRunOneAfterTheOther() async throws {
        try await PresentedErrors.expectingNone {
            let first = try makeDestination(), second = try makeDestination()
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }
            let probe = HeldProbe()
            let (released, release) = AsyncStream.makeStream(of: Void.self)
            let document = try makeDocument(reader: HeldReader(entries: entries, probe: probe, release: released))
            let actions = ArchiveActions(document: document)
            let completions = Completions()

            try writePromise(try #require(actions.filePromise(for: "src")), named: "src", to: first, completions: completions)
            try writePromise(try #require(actions.filePromise(for: "README.md")), named: "README.md", to: second,
                             completions: completions)
            await wait { probe.started == 1 }
            try await Task.sleep(for: .milliseconds(300))
            #expect(probe.started == 1)
            #expect(completions.all.isEmpty)

            release.yield()
            release.yield()
            await settle { completions.all.count == 2 }

            #expect(probe.started == 2)
            #expect(completions.all.count == 2)
            #expect(completions.all.allSatisfy { $0 == nil })
            #expect(try FileManager.default.contentsOfDirectory(atPath: first.path) == ["src"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: second.path) == ["README.md"])
            #expect(document.state.progress == nil)
        }
    }

    /// A Cancel on a drop that still waits: it leaves the line, its completion handler hears the
    /// user-cancelled error, and the drop before it is untouched.
    @Test func cancellingAWaitingDropLeavesTheRunningOne() async throws {
        try await PresentedErrors.expectingNone {
            let first = try makeDestination(), second = try makeDestination()
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }
            let probe = HeldProbe()
            let (released, release) = AsyncStream.makeStream(of: Void.self)
            let document = try makeDocument(reader: HeldReader(entries: entries, probe: probe, release: released))
            let actions = ArchiveActions(document: document)
            let firstCompletions = Completions(), secondCompletions = Completions()
            let secondProvider = try #require(actions.filePromise(for: "README.md"))
            let secondDelegate = try #require(secondProvider.delegate as? ArchiveFilePromiseDelegate)

            try writePromise(try #require(actions.filePromise(for: "src")), named: "src", to: first,
                             completions: firstCompletions)
            await wait { probe.started == 1 }
            try writePromise(secondProvider, named: "README.md", to: second, completions: secondCompletions)
            try await Task.sleep(for: .milliseconds(200))
            secondDelegate.cancel()
            await settle { !secondCompletions.all.isEmpty }

            let error = try #require(secondCompletions.all.first ?? nil) as NSError
            #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
            #expect(secondCompletions.all.count == 1)
            #expect(firstCompletions.all.isEmpty)
            #expect(probe.started == 1)

            release.yield()
            await settle { !firstCompletions.all.isEmpty }
            #expect(firstCompletions.all.count == 1)
            #expect(firstCompletions.all.first.map { $0 == nil } == true)
            #expect(probe.started == 1)
        }
    }

    /// A drag of two rows is one drop. Cancel on the first row's sheet stops every row of
    /// that drop: the running row as a mid-write cancel, the waiting row before it starts (no sheet
    /// of its own); each completion hears user-cancelled exactly once, no alert, nothing lands.
    @Test func cancelOnARowsSheetStopsEveryRowOfItsDrop() async throws {
        try await PresentedErrors.expectingNone {
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let turns = Turns()
            let document = try makeDocument(reader: TurnReader(base: FakeReader(entries: entries), turns: turns))
            let actions = ArchiveActions(document: document)
            let firstCompletions = Completions(), secondCompletions = Completions()
            // One drop of two rows: the hook tags both with the drag's id; Finder asks for both at once.
            let drop = UUID()
            try writePromise(try #require(actions.filePromise(for: "src", drop: drop)), named: "src",
                             to: destination, completions: firstCompletions)
            try writePromise(try #require(actions.filePromise(for: "README.md", drop: drop)), named: "README.md",
                             to: destination, completions: secondCompletions)
            await wait { document.state.progress != nil && turns.started == 1 && actions.hasFilePromiseWork }
            let firstSheet = try #require(document.state.progress)
            let cancelFirst = try #require(firstSheet.cancel)
            cancelFirst()
            await settle { !firstCompletions.all.isEmpty && !secondCompletions.all.isEmpty }

            for completions in [firstCompletions, secondCompletions] {
                #expect(completions.all.count == 1)
                let error = try #require(completions.all.first ?? nil) as NSError
                #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
            }
            #expect(turns.started == 1)  // the second row never started
            #expect(document.state.progress == nil)
            #expect(!actions.hasFilePromiseWork)
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    /// Cancel stops its own drop only: a second, separate drop waiting behind it then runs under a
    /// sheet of its own, with a Cancel of its own, and lands.
    @Test func cancellingADropLeavesASeparateDropGoing() async throws {
        try await PresentedErrors.expectingNone {
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let turns = Turns()
            let document = try makeDocument(reader: TurnReader(base: FakeReader(entries: entries), turns: turns))
            let actions = ArchiveActions(document: document)
            let firstCompletions = Completions(), secondCompletions = Completions()
            try writePromise(try #require(actions.filePromise(for: "src", drop: UUID())), named: "src",
                             to: destination, completions: firstCompletions)
            try writePromise(try #require(actions.filePromise(for: "README.md", drop: UUID())), named: "README.md",
                             to: destination, completions: secondCompletions)
            await wait { document.state.progress != nil && turns.started == 1 }
            let firstSheet = try #require(document.state.progress)
            let cancelFirst = try #require(firstSheet.cancel)
            cancelFirst()
            await wait { turns.started == 2 && !firstCompletions.all.isEmpty }

            let error = try #require(firstCompletions.all.first ?? nil) as NSError
            #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
            #expect(secondCompletions.all.isEmpty)
            let secondSheet = try #require(document.state.progress)
            #expect(secondSheet.id != firstSheet.id)
            #expect(secondSheet.cancel != nil)

            turns.open(2)
            await settle { !secondCompletions.all.isEmpty }
            #expect(firstCompletions.all.count == 1)
            #expect(secondCompletions.all.count == 1)
            #expect(secondCompletions.all.first.map { $0 == nil } == true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["README.md"])
            #expect(document.state.progress == nil)
        }
    }

    /// Closing the window cancels every live drop. A row of a drop whose write Finder asks
    /// for only after the close, its archive gone by then, hears user-cancelled exactly once, with
    /// no alert and no `presentError`, rather than entry-not-found; nothing lands.
    @Test func aRowAskedForAfterTheWindowClosedIsCancelledSilently() async throws {
        try await PresentedErrors.expectingNone {
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let document = try makeDocument(reader: FakeReader(entries: entries))
            let actions = ArchiveActions(document: document)
            let provider = try #require(actions.filePromise(for: "README.md", drop: UUID()))
            let completions = Completions()

            actions.cancelFilePromises()  // the window closes
            document.state.model = nil  // and its archive goes
            try writePromise(provider, named: "README.md", to: destination, completions: completions)
            await settle { !completions.all.isEmpty }

            #expect(completions.all.count == 1)
            let error = try #require(completions.all.first ?? nil) as NSError
            #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
            #expect(document.state.progress == nil)
            #expect(!actions.hasFilePromiseWork)
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    /// A failure with no window (the document has none here): exactly one `presentError`, with the
    /// error as it is, and exactly one completion call with the same error.
    @Test func aFailureWithoutAWindowIsPresentedOnce() async throws {
        try await PresentedErrors.collecting { presented in
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let probe = HeldProbe()
            let (released, _) = AsyncStream.makeStream(of: Void.self)
            let document = try makeDocument(reader: HeldReader(entries: entries, probe: probe, release: released))
            let actions = ArchiveActions(document: document)
            let provider = try #require(actions.filePromise(for: "gone.txt"))
            let completions = Completions()

            try writePromise(provider, named: "gone.txt", to: destination, completions: completions)
            await settle { !completions.all.isEmpty }

            #expect(completions.all.count == 1)
            #expect((completions.all.first ?? nil) as? ArchiveError == .entryNotFound("gone.txt"))
            #expect(presented.errors.count == 1)
            #expect(presented.errors.first as? ArchiveError == .entryNotFound("gone.txt"))
            #expect(document.state.progress == nil)
        }
    }

    /// The engine's own cancel (Cancel stopped a zip bomb midway) alerts nothing and completes with the
    /// user-cancelled error.
    @Test func theEnginesCancelIsNeverPresented() async throws {
        try await PresentedErrors.expectingNone {
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let (written, wrote) = AsyncStream.makeStream(of: Void.self)
            let reader = MidWriteCancelReader(base: FakeReader(entries: entries), wrote: { wrote.yield() },
                                              error: ArchiveError.cancelled)
            let document = try makeDocument(reader: reader)
            let actions = ArchiveActions(document: document)
            let provider = try #require(actions.filePromise(for: "src"))
            let completions = Completions()

            try writePromise(provider, named: "src", to: destination, completions: completions)
            for await _ in written { break }
            let cancel = try #require(document.state.progress?.cancel)
            cancel()
            await settle { !completions.all.isEmpty }

            #expect(completions.all.count == 1)
            let error = try #require(completions.all.first ?? nil) as NSError
            #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
            #expect(document.state.progress == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        }
    }

    // MARK: - The failure alert on a window

    /// A failing write on a window: exactly one alert is begun, and it is the sheet attached to the window;
    /// `presentError` is not used, and the completion handler heard the error once. The alerts are counted
    /// at `filePromiseAlertWillBegin` (`NSAlert.beginSheetModal` does not go through `NSWindow.beginSheet`).
    /// Settles past `whenNoSheetAttached`'s 2 s wait, so a duplicate alert, which AppKit may queue instead
    /// of listing in `sheets`, would be counted.
    @Test func aFailureWithAWindowAttachesExactlyOneSheet() async throws {
        try await PresentedErrors.expectingNone {
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let (released, _) = AsyncStream.makeStream(of: Void.self)
            let document = try makeDocument(reader: HeldReader(entries: entries, probe: HeldProbe(), release: released))
            let actions = ArchiveActions(document: document)
            let window = OffscreenWindow.make()
            defer { window.end() }
            actions.window = window
            var alerts: [NSAlert] = []
            actions.filePromiseAlertWillBegin = { alerts.append($0) }
            let completions = Completions()

            try writePromise(try #require(actions.filePromise(for: "gone.txt")), named: "gone.txt", to: destination,
                             completions: completions)
            await settle { window.attachedSheet != nil && !completions.all.isEmpty }
            try await Task.sleep(for: .seconds(2.5))

            #expect(alerts.count == 1)
            let alert = try #require(alerts.first)
            #expect(window.attachedSheet === alert.window)
            #expect(window.sheets.count == 1)
            #expect(completions.all.count == 1)
            #expect((completions.all.first ?? nil) as? ArchiveError == .entryNotFound("gone.txt"))
            #expect(document.state.progress == nil)
        }
    }

    /// A second drop while a failure alert is up waits (`attachedSheet` is set, and the alert is counted
    /// until answered): nothing starts, no second sheet; once the alert ends (`endSheet`) it runs.
    @Test func aDropWaitsForAFailureAlertToEndThenRuns() async throws {
        try await PresentedErrors.expectingNone {
            let first = try makeDestination(), second = try makeDestination()
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }
            let probe = HeldProbe()
            let (released, release) = AsyncStream.makeStream(of: Void.self)
            let document = try makeDocument(reader: HeldReader(entries: entries, probe: probe, release: released))
            let actions = ArchiveActions(document: document)
            let window = OffscreenWindow.make()
            defer { window.end() }
            actions.window = window
            let failed = Completions(), dropped = Completions()

            try writePromise(try #require(actions.filePromise(for: "gone.txt")), named: "gone.txt", to: first,
                             completions: failed)
            await wait { window.attachedSheet != nil }
            let alert = try #require(window.attachedSheet)
            try writePromise(try #require(actions.filePromise(for: "src")), named: "src", to: second, completions: dropped)
            release.yield()
            try await Task.sleep(for: .milliseconds(500))

            #expect(window.sheets.count == 1)
            #expect(probe.started == 0)
            #expect(dropped.all.isEmpty)
            #expect(actions.hasFilePromiseWork)

            window.endSheet(alert)
            await settle { !dropped.all.isEmpty }

            #expect(probe.started == 1)
            #expect(dropped.all.count == 1)
            #expect(dropped.all.first.map { $0 == nil } == true)
            #expect(failed.all.count == 1)
            #expect(window.attachedSheet == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: second.path) == ["src"])
            #expect(!actions.hasFilePromiseWork)
        }
    }

    /// The `attachedSheet` condition on its own: a sheet that is no failure alert (nothing counted)
    /// holds a drop back, and the drop runs when that sheet ends.
    @Test func aDropWaitsForAnyAttachedSheet() async throws {
        try await PresentedErrors.expectingNone {
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let probe = HeldProbe()
            let (released, release) = AsyncStream.makeStream(of: Void.self)
            let document = try makeDocument(reader: HeldReader(entries: entries, probe: probe, release: released))
            let actions = ArchiveActions(document: document)
            let window = OffscreenWindow.make()
            defer { window.end() }
            actions.window = window
            let sheet = beginPlainSheet(on: window)
            #expect(window.attachedSheet === sheet)
            let completions = Completions()

            try writePromise(try #require(actions.filePromise(for: "src")), named: "src", to: destination,
                             completions: completions)
            release.yield()
            try await Task.sleep(for: .milliseconds(500))

            #expect(probe.started == 0)
            #expect(completions.all.isEmpty)
            #expect(document.state.progress == nil)

            window.endSheet(sheet)
            await settle { !completions.all.isEmpty }

            #expect(probe.started == 1)
            #expect(completions.all.count == 1)
            #expect(completions.all.first.map { $0 == nil } == true)
            #expect(window.attachedSheet == nil)
        }
    }

    /// A cancelled write alerts nothing on a window either: no sheet, completion heard as user-cancelled.
    @Test func aCancelWithAWindowAttachesNoSheet() async throws {
        try await PresentedErrors.expectingNone {
            let destination = try makeDestination()
            defer { try? FileManager.default.removeItem(at: destination) }
            let probe = HeldProbe()
            let (released, _) = AsyncStream.makeStream(of: Void.self)
            let document = try makeDocument(reader: HeldReader(entries: entries, probe: probe, release: released))
            let actions = ArchiveActions(document: document)
            let window = OffscreenWindow.make()
            defer { window.end() }
            actions.window = window
            let completions = Completions()

            try writePromise(try #require(actions.filePromise(for: "src")), named: "src", to: destination,
                             completions: completions)
            await wait { document.state.progress != nil && probe.started == 1 }
            let cancel = try #require(document.state.progress?.cancel)
            cancel()
            await settle { !completions.all.isEmpty }

            let error = try #require(completions.all.first ?? nil) as NSError
            #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
            #expect(window.attachedSheet == nil)
        }
    }

    /// The window's line of promise writes is released with its `ArchiveActions` (an associated object,
    /// not a weak-to-strong table that may keep it): a closed window leaks neither state nor queue.
    @Test func theWindowsLineIsReleasedWithItsActions() throws {
        let document = try makeDocument(reader: HeldReader(entries: entries, probe: HeldProbe(),
                                                           release: AsyncStream.makeStream(of: Void.self).stream))
        weak var line: QueuedOperations?
        autoreleasepool {
            let actions = ArchiveActions(document: document)
            let provider = actions.filePromise(for: "src")
            line = (provider?.delegate as? ArchiveFilePromiseDelegate)?.windowQueue
            #expect(line != nil)
        }
        #expect(line == nil)
    }

    /// No archive open in the window: no promise to give.
    @Test func noArchiveGivesNoPromise() throws {
        let document = try ArchiveDocument(type: "public.zip-archive")
        document.state.model = nil
        #expect(ArchiveActions(document: document).filePromise(for: "src") == nil)
    }
}
