import Testing
import Foundation
@testable import Kernir
import KernirCore

/// Open With keeps the item clicked while its file is extracted: a rename, a swap of
/// names or a delete meanwhile never opens another item, nor alerts that the item is gone.
@Suite(.serialized) @MainActor
struct ArchiveActionsOpenFileTests {
    private static func file(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
    }

    private static let entries = [file("a.txt"), file("A.txt"), file("notes.txt")]

    /// Polls until `condition` holds, for at most about five seconds; the caller asserts the outcome.
    private func wait(for condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Opens "a.txt" in its default app, runs `meanwhile` while its file is extracted, then lets the
    /// extraction go on. Returns the contents of the file launched (FakeReader writes an entry's source
    /// path) and the archive paths the opened copies are tracked at, with nothing presented.
    private func open(during meanwhile: (ArchiveModel) -> Void) async throws
        -> (launched: [String], tracked: [String]) {
        let held = GatedCopy()
        defer { held.release() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveActionsOpenFileTests-\(UUID().uuidString)", isDirectory: true)
        let openedFiles = OpenedFiles(in: folder)
        let model = ArchiveModel(reader: HeldReader(base: FakeReader(entries: Self.entries), gate: held),
                                 undoManager: nil, openedFiles: openedFiles)
        let document = try ArchiveDocument(type: "public.zip-archive")
        document.state.model = model
        let actions = ArchiveActions(document: document)
        defer {
            actions.cancelAll()
            openedFiles.close()
            model.removeTemporaryFiles()
            try? FileManager.default.removeItem(at: folder)
        }
        // The launch lock comes before the PresentedErrors one (see LaunchRecorder).
        return try await LaunchRecorder.recording { launched in
            try await PresentedErrors.expectingNone {
                actions.openFile("a.txt")
                try await held.started()
                meanwhile(model)
                held.release()
                await wait { !actions.hasRunningTasks }
                #expect(!actions.hasRunningTasks)
                #expect(launched.calls.allSatisfy { $0.app == nil })
                let contents = try launched.files.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
                return (contents, openedFiles.files.map(\.path))
            }
        }
    }

    /// Renamed meanwhile: the renamed item opens, and its copy goes back in at the new name.
    @Test func renameDuringTheExtractionOpensTheRenamedItem() async throws {
        let (launched, tracked) = try await open { model in
            #expect(model.rename("a.txt", to: "b.txt") == .success("b.txt"))
        }
        #expect(launched == ["a.txt"])
        #expect(tracked == ["b.txt"])
    }

    /// Swapped with its case twin meanwhile: the item clicked opens, not the one that took its name.
    @Test func twinSwapDuringTheExtractionOpensTheClickedItem() async throws {
        let (launched, tracked) = try await open { model in
            #expect(model.rename("a.txt", to: "t.txt") == .success("t.txt"))
            #expect(model.rename("A.txt", to: "a.txt") == .success("a.txt"))
            #expect(model.rename("t.txt", to: "A.txt") == .success("A.txt"))
        }
        #expect(launched == ["a.txt"])
        #expect(tracked == ["A.txt"])
    }

    /// Deleted meanwhile: the item clicked still opens, as a copy of a gone item does (it goes back in
    /// unasked), and no other item does.
    @Test func deleteDuringTheExtractionOpensNoOtherItem() async throws {
        let (launched, tracked) = try await open { model in
            model.remove(["a.txt"])
        }
        #expect(launched == ["a.txt"])
        #expect(tracked == ["a.txt"])
    }

    /// An inner archive (`check` throws, as `openFile` does for a file Kernir opens) renamed while its file is
    /// extracted: the throw comes out with the item's extracted file, nothing is tracked and
    /// no copy folder is left, and a later copy of the renamed item is tracked as usual.
    @Test func checkThrowingDuringARenameLeavesNoCopy() async throws {
        struct Inner: Error { let local: URL }
        let held = GatedCopy()
        defer { held.release() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveActionsOpenFileTests-\(UUID().uuidString)", isDirectory: true)
        let openedFiles = OpenedFiles(in: folder)
        let model = ArchiveModel(reader: HeldReader(base: FakeReader(entries: Self.entries), gate: held),
                                 undoManager: nil, openedFiles: openedFiles)
        defer {
            openedFiles.close()
            model.removeTemporaryFiles()
            try? FileManager.default.removeItem(at: folder)
        }
        let copyFolders = {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("Kernir-") }
        }

        let opening = Task { try await model.copyForOpening("a.txt") { local in throw Inner(local: local) } }
        try await held.started()
        #expect(model.rename("a.txt", to: "b.txt") == .success("b.txt"))
        held.release()
        let thrown = await #expect(throws: Inner.self) { try await opening.value }
        let local = try #require(thrown?.local)
        #expect(String(decoding: try Data(contentsOf: local), as: UTF8.self) == "a.txt")
        #expect(openedFiles.files.isEmpty)
        #expect(copyFolders().isEmpty)

        let url = try await model.copyForOpening("b.txt")
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "a.txt")
        #expect(openedFiles.files.map(\.path) == ["b.txt"])
        #expect(openedFiles.files.map(\.url) == [url])
        #expect(copyFolders().count == 1)
    }
}

/// A `FakeReader` whose single-file extraction waits at `gate.pass()`: a test acts while the file opened is
/// extracted.
private struct HeldReader: ArchiveReading {
    let base: FakeReader
    let gate: GatedCopy
    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        try await base.extract(paths, to: directory, progress: progress)
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        await gate.pass()
        return try await base.extractToTemporaryFile(path)
    }
}
