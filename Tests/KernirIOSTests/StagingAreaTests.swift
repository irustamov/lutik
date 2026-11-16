import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Kernir

struct StagingAreaTests {
    /// A fresh temporary folder for one test's source files.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagingSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeStaging() -> StagingArea {
        StagingArea(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("StagingTest-\(UUID().uuidString)", isDirectory: true))
    }

    /// Plan constraint 3: a picked file stays readable at save time, after the source is gone.
    @Test func stagedCopySurvivesSourceDeletion() throws {
        let source = try makeFolder().appendingPathComponent("report.txt")
        let bytes = Data("quarterly numbers".utf8)
        try bytes.write(to: source)
        let staging = makeStaging()
        defer { staging.remove() }

        let staged = try staging.stage([source])
        try FileManager.default.removeItem(at: source)

        #expect(staged.count == 1)
        #expect(staged[0].lastPathComponent == "report.txt")
        #expect(try Data(contentsOf: staged[0]) == bytes)
    }

    @Test func stageFolderIsRecursive() throws {
        let folder = try makeFolder().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("a"), withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: folder.appendingPathComponent("a/b.txt"))
        let staging = makeStaging()
        defer { staging.remove() }

        let staged = try staging.stage([folder])
        try FileManager.default.removeItem(at: folder)

        #expect(staged.count == 1)
        #expect(staged[0].lastPathComponent == "project")
        #expect(try Data(contentsOf: staged[0].appendingPathComponent("a/b.txt")) == Data("inner".utf8))
    }

    @Test func stageNameCollision() throws {
        let first = try makeFolder().appendingPathComponent("x.txt")
        let second = try makeFolder().appendingPathComponent("x.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let staging = makeStaging()
        defer { staging.remove() }

        let staged = try staging.stage([first, second])

        #expect(staged.count == 2)
        #expect(staged[0] != staged[1])
        #expect(staged[0].lastPathComponent == "x.txt")
        #expect(staged[1].lastPathComponent == "x 2.txt")
        #expect(try Data(contentsOf: staged[0]) == Data("first".utf8))
        #expect(try Data(contentsOf: staged[1]) == Data("second".utf8))
    }

    /// Adding the same name again later keeps the name, so the archive can ask to replace it,
    /// and never overwrites the copy an earlier (undoable) addition still points at.
    @Test func laterStagingKeepsNameAndEarlierCopy() throws {
        let source = try makeFolder().appendingPathComponent("x.txt")
        try Data("old".utf8).write(to: source)
        let staging = makeStaging()
        defer { staging.remove() }

        let earlier = try staging.stage([source])
        try Data("new".utf8).write(to: source)
        let later = try staging.stage([source])

        #expect(later[0].lastPathComponent == "x.txt")
        #expect(later[0] != earlier[0])
        #expect(try Data(contentsOf: earlier[0]) == Data("old".utf8))
        #expect(try Data(contentsOf: later[0]) == Data("new".utf8))
    }

    @Test func stageDataUsesSuggestedName() throws {
        let staging = makeStaging()
        defer { staging.remove() }

        let staged = try staging.stage(data: Data("pixels".utf8), suggestedName: "IMG_0001.HEIC")

        #expect(staged.lastPathComponent == "IMG_0001.HEIC")
        #expect(try Data(contentsOf: staged) == Data("pixels".utf8))
    }

    @Test func removeDeletesStagedFiles() throws {
        let source = try makeFolder().appendingPathComponent("x.txt")
        try Data("x".utf8).write(to: source)
        let staging = makeStaging()

        let staged = try staging.stage([source])
        staging.remove()

        #expect(!FileManager.default.fileExists(atPath: staged[0].path))
    }

    // MARK: - Picked photos and videos

    @Test(arguments: [
        // Photos' own name is kept, with its extension.
        ("IMG_0001.HEIC", [UTType.heic], "IMG_0001.HEIC"),
        ("IMG_0002.MOV", [UTType.quickTimeMovie], "IMG_0002.MOV"),
        // A delivered JPEG keeps its extension though the original is HEIC.
        ("IMG_0003.jpeg", [UTType.heic, .jpeg], "IMG_0003.jpeg"),
        // A missing or wrong extension comes from the item's type.
        ("IMG_0004", [UTType.heic], "IMG_0004.heic"),
        ("IMG_0005.tmp", [UTType.mpeg4Movie], "IMG_0005.mp4"),
        // An identifier is no name.
        ("3F2504E0-4F89-11D3-9A0C-0305E82C3301.jpeg", [UTType.jpeg], "Photo.jpeg"),
        ("version=1&uuid=3F2504E0&mode=current.mov", [UTType.quickTimeMovie], "Video.mov"),
    ])
    func pickedFileName(received: String, types: [UTType], expected: String) {
        #expect(PickedMedia.fileName(received: received, contentTypes: types) == expected)
    }

    /// Photos gives data no name: the item's kind and type's extension.
    @Test func pickedDataFileName() {
        #expect(PickedMedia.fileName(received: nil, contentTypes: [.heic]) == "Photo.heic")
        #expect(PickedMedia.fileName(received: nil, contentTypes: [.png, .jpeg]) == "Photo.png")
        #expect(PickedMedia.fileName(received: nil, contentTypes: []) == "Photo")
    }

    /// Only images may be loaded into memory; a video never is.
    @Test func onlyImagesLoadIntoMemory() {
        #expect(PickedMedia.mayLoadIntoMemory([.heic, .jpeg]))
        #expect(!PickedMedia.mayLoadIntoMemory([.quickTimeMovie]))
        #expect(!PickedMedia.mayLoadIntoMemory([.mpeg4Movie, .jpeg]))
        #expect(!PickedMedia.mayLoadIntoMemory([.pdf]))
        #expect(!PickedMedia.mayLoadIntoMemory([]))
    }

    @Test func pickedMediaRenamesInPlace() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("IMG_0001")
        try Data("pixels".utf8).write(to: file)

        let renamed = try PickedMedia(url: file).renamed(to: "IMG_0001.heic")

        #expect(renamed.url.lastPathComponent == "IMG_0001.heic")
        #expect(renamed.folder.standardizedFileURL == folder.standardizedFileURL)
        #expect(try Data(contentsOf: renamed.url) == Data("pixels".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
