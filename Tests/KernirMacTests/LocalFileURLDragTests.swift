import Testing
import Foundation
@testable import Kernir
import KernirCore

// What a drag out of an archive window delivers: `ArchiveModel.localFileURL(for:)` on a real zip
// (no FakeReader), for a file row and for folder rows with nested files. A file comes from
// `reader.extractToTemporaryFile`; a folder from plan/run into a fresh `Kernir-<UUID>` folder.
// Both zip shapes: with directory entries (`zip -r`) and with folders only implied by paths (`zip -rD`).
// No defaults, no UI: runs next to ArchiveModelTests.

// MARK: - Helpers

/// <tmp>/LocalFileURLDragTests-<UUID>/{src/…, fixture.zip} holding readme.txt, docs/notes.txt and
/// docs/sub/deep.txt. Remove the returned folder when done.
private func makeDragFixture(directoryEntries: Bool) throws -> (folder: URL, zip: URL) {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalFileURLDragTests-\(UUID().uuidString)", isDirectory: true)
    let src = folder.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: src.appendingPathComponent("docs/sub"), withIntermediateDirectories: true)
    try Data("readme body".utf8).write(to: src.appendingPathComponent("readme.txt"))
    try Data("notes body".utf8).write(to: src.appendingPathComponent("docs/notes.txt"))
    try Data("deep body".utf8).write(to: src.appendingPathComponent("docs/sub/deep.txt"))
    let zip = folder.appendingPathComponent("fixture.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = src
    process.arguments = [directoryEntries ? "-qr" : "-qrD", zip.path, "readme.txt", "docs"]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return (folder, zip)
}

private func contents(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

/// The paths below `url`, relative and sorted; nil when `url` isn't an existing folder.
private func listing(_ url: URL) -> [String]? {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
    else { return nil }
    return (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String])?.sorted()
}

@MainActor
private func checkDragDelivery(directoryEntries: Bool) async throws {
    let fixture = try makeDragFixture(directoryEntries: directoryEntries)
    defer { try? FileManager.default.removeItem(at: fixture.folder) }
    let model = ArchiveModel(reader: try await Archive.open(at: fixture.zip), undoManager: nil)
    defer { model.removeTemporaryFiles() }

    // File rows: top level and nested.
    let readme = try await model.localFileURL(for: "readme.txt")
    #expect(readme.lastPathComponent == "readme.txt")
    #expect(contents(readme) == "readme body")
    let deep = try await model.localFileURL(for: "docs/sub/deep.txt")
    #expect(deep.lastPathComponent == "deep.txt")
    #expect(contents(deep) == "deep body")

    // Folder rows: named for the folder, holding everything below it.
    let docs = try await model.localFileURL(for: "docs")
    #expect(docs.lastPathComponent == "docs")
    #expect(listing(docs) == ["notes.txt", "sub", "sub/deep.txt"])
    #expect(contents(docs.appendingPathComponent("notes.txt")) == "notes body")
    #expect(contents(docs.appendingPathComponent("sub/deep.txt")) == "deep body")
    let sub = try await model.localFileURL(for: "docs/sub")
    #expect(sub.lastPathComponent == "sub")
    #expect(listing(sub) == ["deep.txt"])

    // Dragging the same folder again: a fresh copy, no collision with the first.
    let again = try await model.localFileURL(for: "docs")
    #expect(again != docs)
    #expect(contents(again.appendingPathComponent("sub/deep.txt")) == "deep body")
}

// MARK: - Tests

@MainActor @Test func dragDeliveryFromZipWithDirectoryEntries() async throws {
    try await checkDragDelivery(directoryEntries: true)
}

@MainActor @Test func dragDeliveryFromZipWithImpliedFolders() async throws {
    try await checkDragDelivery(directoryEntries: false)
}
