import Testing
import Foundation
@testable import Kernir
import KernirCore

/// Renames through the real engine (`ArchiveEngine.live`), no UI: a model's renames and New Folder are
/// saved with the options a save panel leaves in `model.saveOptions`, and the saved archive, reopened,
/// holds the new names with the old bytes and the empty folder, with "Exclude Mac metadata" on and off.
/// The source is built by hand (`LiveMetadataSaveTests.storedZip`), so no repo fixture is read.
@MainActor struct LiveRenameSaveTests {
    /// A Finder-made ZIP: a file with its `._` and `__MACOSX` companions, a subfolder, a top-level file.
    private static let sourceEntries: [(path: String, contents: String?)] = [
        ("Project/", nil),
        ("Project/hello.txt", "hello"),
        ("Project/._hello.txt", "apple double"),
        ("Project/docs/", nil),
        ("Project/docs/readme.md", "readme"),
        ("notes.txt", "notes"),
        ("__MACOSX/", nil),
        ("__MACOSX/Project/", nil),
        ("__MACOSX/Project/._hello.txt", "apple double"),
    ]

    /// What the save holds without metadata: the renamed file and folder, the untouched file, the new folder.
    private static let savedWithoutMetadata: Set<String> = [
        "Project", "Project/greeting.txt", "Project/papers", "Project/papers/readme.md",
        "Project/untitled folder", "notes.txt",
    ]

    /// The companions, moved with the renamed file.
    private static let savedMetadata: Set<String> = [
        "Project/._greeting.txt", "__MACOSX", "__MACOSX/Project", "__MACOSX/Project/._greeting.txt",
    ]

    @Test(arguments: [true, false])
    func renameAndNewFolderSurviveARealSave(excludesMacMetadata: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveRenameSaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.zip")
        try LiveMetadataSaveTests.storedZip(Self.sourceEntries).write(to: sourceURL)
        let reader = try await ArchiveEngine.live.open(sourceURL, nil)

        let model = ArchiveModel(reader: reader, undoManager: nil)
        defer { model.removeTemporaryFiles() }
        #expect(model.rename("Project/hello.txt", to: "greeting.txt") == .success("Project/greeting.txt"))
        #expect(model.rename("Project/docs", to: "papers") == .success("Project/papers"))
        #expect(try model.newFolder(in: "Project") == "Project/untitled folder")
        var settings = ArchiveSaveSettings(model: model)
        settings.options.excludesMacMetadata = excludesMacMetadata
        model.apply(settings)
        #expect(model.changes.renamedPaths["Project/hello.txt"] == "Project/greeting.txt")
        #expect(model.changes.renamedPaths["Project/docs"] == "Project/papers")

        let savedURL = directory.appendingPathComponent("saved.zip")
        try await ArchiveEngine.live.write(reader, model.changes, .zip, savedURL, model.saveOptions, nil)

        let saved = try await ArchiveEngine.live.open(savedURL, nil)
        let paths = Set(saved.entries.map(\.path))
        let expected = excludesMacMetadata ? Self.savedWithoutMetadata
                                           : Self.savedWithoutMetadata.union(Self.savedMetadata)
        #expect(paths == expected)
        #expect(saved.entries.first { $0.path == "Project/untitled folder" }?.isDirectory == true)

        let out = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await saved.extract(nil, to: out, progress: nil)
        func contents(_ path: String) -> String? {
            (try? Data(contentsOf: out.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(contents("Project/greeting.txt") == "hello")
        #expect(contents("Project/papers/readme.md") == "readme")
        #expect(contents("notes.txt") == "notes")
        let newFolder = out.appendingPathComponent("Project/untitled folder").path
        #expect((try? FileManager.default.contentsOfDirectory(atPath: newFolder)) == [])
        if !excludesMacMetadata {
            #expect(saved.entries.first { $0.path == "__MACOSX/Project/._greeting.txt" }?.size == 12)
        }

        // The model takes the saved archive as its source: the same tree, nothing pending.
        model.didSave(reader: saved)
        #expect(model.changes.isEmpty)
        #expect(model.item(at: "Project/greeting.txt")?.isPendingAddition == false)
        #expect(model.item(at: "Project/papers/readme.md") != nil)
        let folder = try #require(model.item(at: "Project/untitled folder"))
        #expect(folder.isDirectory && !folder.isPendingAddition)
        #expect(model.item(at: "Project/hello.txt") == nil)
        #expect(model.item(at: "Project/docs") == nil)
    }
}
