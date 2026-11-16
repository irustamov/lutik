import Testing
import Foundation
@testable import Kernir

/// Option-Extract (`ArchiveActions`) names its folder beside the archive as Extract Here does
/// (`ExtractHereNaming.folderName`): a set whose name is a dot name gets the archive's own file name.
struct OptionExtractFolderNameTests {
    @Test(arguments: [
        ("...part1.rar", true), ("..part1.rar", true), ("..001", true), ("...7z.001", true), ("...zip.001", true),
        ("..z01", true), ("Photos.part1.rar", true), ("....part1.rar", true), ("project.tar.gz", false),
        ("..zip", false), ("...zip", false),
    ])
    func folderNameIsExtractHeresName(_ name: String, _ isVolumeSet: Bool) {
        let url = URL(fileURLWithPath: "/a").appendingPathComponent(name)
        let folderName = ArchiveActions.extractionFolderName(for: url, isVolumeSet: isVolumeSet)
        #expect(folderName == ExtractHereNaming.folderName(for: url, isVolumeSet: isVolumeSet))
        #expect(!["", ".", ".."].contains(folderName))
    }

    /// The first part is in the way of its own name: the folder is that name with " 2", beside the archive.
    @Test func aDotNamedSetsFolderIsNumberedPastThePart() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OptionExtractFolderNameTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let part = folder.appendingPathComponent("...part1.rar")
        try Data("part".utf8).write(to: part)

        let name = ArchiveActions.extractionFolderName(for: part, isVolumeSet: true)
        #expect(name == "...part1.rar")
        let destination = ArchiveActions.uniqueFolder(named: name, in: folder)
        #expect(destination.lastPathComponent == "...part1.rar 2")
        #expect(destination.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path)
    }
}
