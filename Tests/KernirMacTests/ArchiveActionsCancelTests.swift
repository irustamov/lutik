import Testing
import AppKit
import os
@testable import Kernir
import KernirCore

/// Closing a document stops what its window started.
@Suite(.serialized) @MainActor
struct ArchiveActionsCancelTests {
    /// Polls until `condition` holds, for at most about five seconds; the caller asserts the outcome.
    private func wait(for condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func cancelAllStopsQuickLookWithoutPresentingAnything() async throws {
        try await PresentedErrors.collecting { presented in
            let probe = SuspendingReaderProbe()
            let document = try ArchiveDocument(type: "public.zip-archive")
            let reader = SuspendingReader(entries: SampleArchive().entries, probe: probe)
            document.state.model = ArchiveModel(reader: reader, undoManager: nil)
            let actions = ArchiveActions(document: document)

            actions.quickLook(["README.md"])
            await wait { probe.started == 1 }
            #expect(probe.started == 1)
            #expect(actions.hasRunningTasks)

            actions.cancelAll()
            await wait { probe.cancelled == 1 }

            #expect(probe.cancelled == 1)
            #expect(!actions.hasRunningTasks)
            #expect(document.state.previewURL == nil)
            #expect(document.state.previewURLs.isEmpty)
            #expect(presented.errors.isEmpty)
        }
    }

    /// A preview already showing (its stand-in maybe still rendering) ends too, so no preview
    /// window opens for a window that is closing.
    @Test func cancelAllEndsAShowingPreview() throws {
        let document = try ArchiveDocument(type: "public.zip-archive")
        let actions = ArchiveActions(document: document)
        document.state.previewEntries = [PreviewEntry(path: "Report.docx", url: URL(fileURLWithPath: "/tmp/Report.docx"))]
        document.state.previewURL = URL(fileURLWithPath: "/tmp/Report.docx")
        #expect(actions.canToggleQuickLook)

        actions.cancelAll()

        #expect(document.state.previewURL == nil)
        // Its entries name the old listing's paths and extracted files, so they go too.
        #expect(document.state.previewEntries.isEmpty)
        #expect(!actions.hasRunningTasks)
    }

    /// Moving the selection while the preview resolves cancels the stale extraction.
    @Test func movingTheSelectionCancelsTheStalePreview() async throws {
        try await PresentedErrors.expectingNone {
            let probe = SuspendingReaderProbe()
            let document = try ArchiveDocument(type: "public.zip-archive")
            document.state.model = ArchiveModel(reader: SuspendingReader(entries: SampleArchive().entries, probe: probe),
                                                undoManager: nil)
            let actions = ArchiveActions(document: document)
            defer { actions.cancelAll() }

            document.state.selection = ["README.md"]
            actions.toggleQuickLook()
            await wait { probe.started == 1 }
            #expect(probe.started == 1)

            document.state.selection = ["brief.pdf"]
            actions.selectionDidChange()
            await wait { probe.cancelled == 1 && probe.started == 2 }

            #expect(probe.cancelled == 1)
            #expect(probe.started == 2)
            #expect(actions.hasRunningTasks)
            #expect(document.state.previewURL == nil)
        }
    }

    /// Closing the document cancels through the window controller's actions.
    @Test func closingTheDocumentCancelsAndCleansUp() async throws {
        let probe = SuspendingReaderProbe()
        let document = try ArchiveDocument(type: "public.zip-archive")
        document.state.model = ArchiveModel(reader: SuspendingReader(entries: SampleArchive().entries, probe: probe),
                                            undoManager: nil)
        document.makeWindowControllers()
        #expect(document.windowControllers.first is ArchiveWindowController)
        let actions = try #require(document.actions)

        actions.quickLook(["README.md"])
        await wait { probe.started == 1 }
        #expect(probe.started == 1)

        document.close()
        await wait { probe.cancelled == 1 }

        #expect(probe.cancelled == 1)
        #expect(!actions.hasRunningTasks)
    }

    /// A cancel that comes once the copy for another app is made, before the app gets it, opens nothing and
    /// leaves no copy behind: the copy and its folder are deleted and no longer tracked, so
    /// the close never asks about it. The task is cancelled before it runs, so the copy is already tracked
    /// when `launchCopy` sees the cancel, with no timing involved. It drives `ArchiveActions.launchCopy`
    /// directly because `openFile` has no suspension between the clone's last cancel check and the launch,
    /// so the guard is a defensive second check and the helper is the only deterministic seam.
    @Test func cancelOnceTheCopyIsMadeLaunchesNothingAndLeavesNoCopy() async throws {
        let copies = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveActionsCancelTests-\(UUID().uuidString)", isDirectory: true)
        let openedFiles = OpenedFiles(in: copies)
        let model = ArchiveModel(reader: FakeReader(entries: SampleArchive().entries), undoManager: nil,
                                 openedFiles: openedFiles)
        defer {
            model.removeTemporaryFiles()
            openedFiles.close()
            try? FileManager.default.removeItem(at: copies)
        }
        // The launch lock comes before the PresentedErrors one (see LaunchRecorder).
        try await LaunchRecorder.recording { launched in
            try await PresentedErrors.expectingNone {
                let url = try await model.copyForOpening("README.md")
                #expect(openedFiles.files.map(\.url) == [url])
                #expect(FileManager.default.fileExists(atPath: url.path))

                let launching = Task { @MainActor in try ArchiveActions.launchCopy(url, in: nil, of: openedFiles) }
                launching.cancel()
                await #expect(throws: CancellationError.self) { try await launching.value }

                #expect(launched.files.isEmpty)
                #expect(openedFiles.files.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
                #expect(openedFiles.changed().isEmpty)
            }
        }
    }

    /// Closing the document cancels the drag-out writes too, the running one and the waiting ones: each
    /// promise's completion handler hears Cocoa's user-cancelled error, none is alerted.
    @Test func cancelAllCancelsDragOutWrites() async throws {
        try await PresentedErrors.expectingNone {
            let probe = SuspendingReaderProbe()
            let document = try ArchiveDocument(type: "public.zip-archive")
            document.state.model = ArchiveModel(reader: SuspendingReader(entries: SampleArchive().entries, probe: probe),
                                                undoManager: nil)
            let actions = ArchiveActions(document: document)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveActionsCancelTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: destination) }
            let results = OSAllocatedUnfairLock(initialState: [Int]())
            for name in ["README.md", "brief.pdf"] {
                let provider = try #require(actions.filePromise(for: name))
                let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
                delegate.filePromiseProvider(provider, writePromiseTo: destination.appendingPathComponent(name)) { error in
                    results.withLock { $0.append((error as NSError?)?.code ?? 0) }
                }
            }
            await wait { probe.started == 1 }
            #expect(actions.hasRunningTasks)
            // A preview showing while the promises run goes with them.
            document.state.previewEntries = [PreviewEntry(path: "README.md", url: URL(fileURLWithPath: "/tmp/README.md"))]
            document.state.previewURL = URL(fileURLWithPath: "/tmp/README.md")

            actions.cancelAll()
            await wait { results.withLock { $0.count } == 2 }

            #expect(results.withLock { $0 } == [CocoaError.userCancelled.rawValue, CocoaError.userCancelled.rawValue])
            #expect(probe.started == 1)
            #expect(!actions.hasRunningTasks)
            #expect(document.state.progress == nil)
            #expect(document.state.previewURL == nil)
            #expect(document.state.previewEntries.isEmpty)
        }
    }
}
