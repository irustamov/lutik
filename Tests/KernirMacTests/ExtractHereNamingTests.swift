import Testing
import Foundation
@testable import Kernir
import KernirCore

// MARK: - Helpers

/// Fresh empty directory; the caller removes it.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExtractHereNamingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Puts a file or a folder named `name` in `directory`.
private func makeItem(_ name: String, isDirectory: Bool, in directory: URL) throws {
    let url = directory.appendingPathComponent(name, isDirectory: isDirectory)
    if isDirectory {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } else {
        try Data("mine".utf8).write(to: url)
    }
}

/// Finder's copy names: the name taken, whether it is a folder, the name Keep Both gives.
private let copyNameTable: [(name: String, isDirectory: Bool, expected: String)] = [
    ("project", true, "project 2"),
    ("report.pdf", false, "report 2.pdf"),
    ("name 2.ext", false, "name 3.ext"),
    ("name 2", true, "name 3"),
    ("Report 2024.pdf", false, "Report 2024 2.pdf"),
    ("Report 2024 2.pdf", false, "Report 2024 3.pdf"),
    ("take 999", true, "take 1000"),
    ("take 1000", true, "take 1000 2"),
    ("take 02", true, "take 02 2"),
    ("take 1", true, "take 1 2"),
    // A folder's name is never split at a dot.
    ("v1.2", true, "v1.2 2"),
    // A dotfile has no extension.
    (".env", false, ".env 2"),
    ("notes.txt", false, "notes 2.txt"),
    ("archive.tar.gz", false, "archive.tar 2.gz"),
]

// MARK: - FinderCopyName

@Test(arguments: copyNameTable.indices)
func copyNameFollowsFinder(_ index: Int) {
    let row = copyNameTable[index]
    #expect(FinderCopyName.next(after: row.name, isDirectory: row.isDirectory) { $0 == row.name } == row.expected)
}

@Test func copyNameSkipsTakenNumbers() {
    let taken: Set = ["report.pdf", "report 2.pdf", "report 3.pdf"]
    #expect(FinderCopyName.next(after: "report.pdf", isDirectory: false) { taken.contains($0) } == "report 4.pdf")
    #expect(FinderCopyName.next(after: "report 2.pdf", isDirectory: false) { taken.contains($0) } == "report 4.pdf")
}

@Test func freeNameIsTheNameItselfWhenNothingIsThere() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(FinderCopyName.free("project", isDirectory: true, in: directory) == "project")
    #expect(FinderCopyName.free("report.pdf", isDirectory: false, in: directory) == "report.pdf")
}

@Test func freeNameCountsOnPastItemsOnDisk() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeItem("project", isDirectory: true, in: directory)
    try makeItem("project 2", isDirectory: false, in: directory)
    try makeItem("report.pdf", isDirectory: false, in: directory)
    // A dangling symlink is in the way too.
    try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("notes.txt").path,
                                               withDestinationPath: "/nonexistent/kernir")

    #expect(FinderCopyName.free("project", isDirectory: true, in: directory) == "project 3")
    #expect(FinderCopyName.free("report.pdf", isDirectory: false, in: directory) == "report 2.pdf")
    #expect(FinderCopyName.free("notes.txt", isDirectory: false, in: directory) == "notes 2.txt")
}

@Test func freeNameSkipsReservedNamesAsTheVolumeComparesThem() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // Reserved names compare case- and normalization-insensitively, as the default volumes do.
    let reserved: Set = ["PROJECT", "project 2", "Cafe\u{301}"]
    #expect(FinderCopyName.free("project", isDirectory: true, in: directory, reserved: reserved) == "project 3")
    #expect(FinderCopyName.free("Caf\u{E9}", isDirectory: true, in: directory, reserved: reserved) == "Caf\u{E9} 2")
    #expect(FinderCopyName.free("other", isDirectory: true, in: directory, reserved: reserved) == "other")
}

/// The same table through `ArchiveModel`'s Keep Both: the two must never drift apart.
@MainActor @Test(arguments: copyNameTable.indices)
func copyNameMatchesTheModelsKeepBoth(_ index: Int) async throws {
    let row = copyNameTable[index]
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeItem(row.name, isDirectory: row.isDirectory, in: directory)
    let entry = ArchiveEntry(path: row.name, isDirectory: row.isDirectory, size: row.isDirectory ? nil : 1,
                             compressedSize: nil, modificationDate: nil)
    let model = ArchiveModel(reader: FakeReader(entries: [entry]), undoManager: nil)

    let written = try await model.extract([row.name], to: directory, resolutions: [row.name: .keepBoth],
                                          progress: nil)

    #expect(written.map(\.lastPathComponent) == [row.expected])
}

// MARK: - ExtractHereNaming

@Test(arguments: [
    ("project.zip", "project"),
    ("project.tar.gz", "project"),
    ("project.TAR.XZ", "project"),
    ("project.tgz", "project"),
    ("notes.txt.gz", "notes.txt"),
    ("v1.2.zip", "v1.2"),
    ("README", "README"),
    // Zip-based packages Extract Here takes.
    ("requests-2.31.0-py3-none-any.whl", "requests-2.31.0-py3-none-any"),
    ("app.jar", "app"),
])
func folderNameDropsTheArchiveExtensions(_ name: String, _ expected: String) {
    let url = URL(fileURLWithPath: "/tmp/Downloads").appendingPathComponent(name)
    #expect(ExtractHereNaming.folderName(for: url, isVolumeSet: false) == expected)
}

/// Extract Here and Option-Extract name their folder with one shared helper (`ArchiveBaseName`,
/// whose own tests hold the rules). Split-save still has its own proposal
/// (`ArchiveSaveSettings.splitFolderProposal`). As done in
/// practice: one recognized suffix goes, a compound one counting as one; any other extension stays.
@Test(arguments: [
    ("project.tar.gz", false, "project"),
    // Was "notes": "txt" is not an archive suffix ("as done in practice").
    ("notes.txt", false, "notes.txt"),
    // Was "s2-plain": only one suffix goes ("as done in practice").
    ("s2-plain.tar.tgz", false, "s2-plain.tar"),
    // Was "...tar": "tar.gz" is one suffix, and a dot name gives the file's own name.
    ("...tar.gz", false, "...tar.gz"),
    ("Photos.zip.001", true, "Photos"),
    ("Photos.part1.rar", true, "Photos"),
    // Was "..": a set named by dots alone gives the part's own name.
    ("...part1.rar", true, "...part1.rar"),
])
func extractFolderNamesAreTheArchivesBaseName(_ name: String, _ isVolumeSet: Bool, _ expected: String) {
    let url = URL(fileURLWithPath: "/tmp/Downloads").appendingPathComponent(name)
    #expect(ArchiveBaseName.of(name, isVolumeSet: isVolumeSet) == expected)
    #expect(ExtractHereNaming.folderName(for: url, isVolumeSet: isVolumeSet) == expected)
    #expect(ArchiveActions.extractionFolderName(for: url, isVolumeSet: isVolumeSet) == expected)
}

@Test(arguments: [
    ("Photos.part1.rar", "Photos"),
    ("Photos.zip.001", "Photos"),
    ("Photos.7z.001", "Photos"),
    ("span.z01", "span"),
    ("v1.2 notes.7z.003", "v1.2 notes"),
    // Dots are kept when the set's name is more than a dot name.
    (".hidden.part1.rar", ".hidden"),
    ("....part1.rar", "..."),
    ("a..zip.001", "a."),
])
func folderNameOfAVolumeSetIsTheSetsName(_ name: String, _ expected: String) {
    let url = URL(fileURLWithPath: "/tmp/Downloads").appendingPathComponent(name)
    #expect(ExtractHereNaming.folderName(for: url, isVolumeSet: true) == expected)
}

/// A set's name with nothing but dots before the part suffix is "..", "." or "": as a folder name that is the
/// archive's folder, or the folder above it. `ArchiveBaseName` names the folder after the archive's own file instead.
@Test(arguments: [
    "...part1.rar",
    "..part1.rar",
    "..001",
    "...7z.001",
    "...zip.001",
    "..z01",
])
func folderNameOfAVolumeSetIsNeverADotName(_ name: String) {
    let url = URL(fileURLWithPath: "/tmp/Downloads").appendingPathComponent(name)
    let folderName = ExtractHereNaming.folderName(for: url, isVolumeSet: true)
    #expect(!["", ".", ".."].contains(folderName))
    #expect(folderName == name)
}

/// A single archive's name keeps its dots: a base name that would be a dot name is the file's own name.
@Test(arguments: [
    ("..zip", "..zip"),
    ("...zip", "...zip"),
    // Was "...tar": "tar.gz" is one suffix ("as done in practice").
    ("...tar.gz", "...tar.gz"),
    ("Photos.zip", "Photos"),
])
func folderNameOfASingleArchiveKeepsDots(_ name: String, _ expected: String) {
    let url = URL(fileURLWithPath: "/tmp/Downloads").appendingPathComponent(name)
    #expect(ExtractHereNaming.folderName(for: url, isVolumeSet: false) == expected)
}
