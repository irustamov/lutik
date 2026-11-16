import Foundation
import Testing
@testable import Kernir

/// On the iOS 27.2 Simulator's mixed-case scratch volume (`scratchVolumeIsMixedCase`): it says it
/// folds case, but lstat misses a case twin ("readme" with "README" there: ENOENT) while a create still
/// collides. Without RENAME_EXCL (forced here: ENOTSUP, EOPNOTSUPP or EINVAL, as SMB or exFAT answer) the
/// lookup before the plain rename misses the twin, and rename(2) would replace a file or an empty folder: the
/// folder listing by `NameFold.key` (`renameExclusively`) is what refuses. Real volumes, no fakes but the
/// refused RENAME_EXCL; elsewhere these don't run (the Mac's CaseTwinExtractTests fake the lookup instead).
@Suite(.enabled(if: scratchVolumeIsMixedCase(), "only on a mixed-case scratch volume"))
struct MixedCaseVolumeTests {
    /// A fresh temporary folder holding `out` and `staged`; the caller removes it.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MixedCaseVolume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("out"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("staged"),
                                                withIntermediateDirectories: true)
        return folder
    }

    /// No RENAME_EXCL; every other rename is the real one.
    private func noExclusiveRename(_ code: Int32) -> ExtractionFileSystem {
        ExtractionFileSystem(deviceToken: "feedface00000003") { from, to, flags in
            if flags == UInt32(RENAME_EXCL) { return code }
            return renamex_np(from, to, flags) == 0 ? 0 : errno
        }
    }

    /// Every item under `folder` by its name as listed: relative path -> "dir" or contents.
    private func snapshot(_ folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for relative in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            result[relative] = isDirectory.boolValue ? "dir" : String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        return result
    }

    /// README is there, the lookup misses "readme": Keep Both takes "readme 2" and README stays.
    @Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL])
    func aFileTwinTheLookupMissesIsNeverReplaced(_ code: Int32) throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("out")
        try Data("mine".utf8).write(to: output.appendingPathComponent("README"))
        try Data("twin".utf8).write(to: folder.appendingPathComponent("staged/readme"))
        try #require(!FileManager.default.fileExists(atPath: output.appendingPathComponent("readme").path))
        var reserved: Set<String> = []

        let placed = try ArchiveModel.moveKeepingBoth(folder.appendingPathComponent("staged/readme"),
                                                      to: output.appendingPathComponent("readme"),
                                                      isDirectory: false, path: "readme", in: output,
                                                      reserved: &reserved, fileSystem: noExclusiveRename(code))
        #expect(placed.lastPathComponent == "readme 2")
        #expect(try snapshot(output) == ["README": "mine", "readme 2": "twin"])
    }

    /// An empty folder Docs is there, the lookup misses "docs": the folder docs takes "docs 2", and Docs stays.
    @Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL])
    func anEmptyFolderTwinTheLookupMissesIsNeverReplaced(_ code: Int32) throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: output.appendingPathComponent("Docs"),
                                                withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("staged/docs"),
                                                withIntermediateDirectories: false)
        try Data("twin".utf8).write(to: folder.appendingPathComponent("staged/docs/a.txt"))
        try #require(!FileManager.default.fileExists(atPath: output.appendingPathComponent("docs").path))
        var reserved: Set<String> = []

        let placed = try ArchiveModel.moveKeepingBoth(folder.appendingPathComponent("staged/docs"),
                                                      to: output.appendingPathComponent("docs"),
                                                      isDirectory: true, path: "docs", in: output,
                                                      reserved: &reserved, fileSystem: noExclusiveRename(code))
        #expect(placed.lastPathComponent == "docs 2")
        #expect(try snapshot(output) == ["Docs": "dir", "docs 2": "dir", "docs 2/a.txt": "twin"])
    }
}
