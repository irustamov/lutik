import Testing
import Foundation
import os
import KernirCore
@testable import Kernir

// The sweep reads the keep marker and the recovered folder's name from ArchiveModel itself
// (`ArchiveModel.keepMarker`, `.recoveredName`), but it still has to recognise what the model really
// leaves, by the real path (a Replace whose old item cannot be put back anywhere), or it would delete a
// user's item. This makes the model leave it and has the sweep look at the result. Slot-free.

private let token = "5eed5eed5eed5eed"

/// What the real path leaves in staging when Replace cannot put the user's old item back.
private struct LeftStaging {
    let output: URL
    /// The staging folder, renamed to a dead process's pid so the sweep may consider it.
    let staging: URL
    /// The regular file in it that is not the extracted README.md: the keep marker.
    let marker: URL
    /// The one folder in it: the recovered folder, holding the old item.
    let recovered: URL
}

/// Runs `ArchiveModel.extract` with Replace on a README.md that something else takes the name of meanwhile,
/// and every move after that failing: the old item stays in staging, marked.
@MainActor
private func leaveMarkedStaging(in output: URL) async throws -> LeftStaging {
    try Data("mine".utf8).write(to: output.appendingPathComponent("README.md"))
    let target = output.appendingPathComponent("README.md").path
    let tookTheName = OSAllocatedUnfairLock(initialState: false)
    let model = ArchiveModel(reader: FakeReader(entries: [
        ArchiveEntry(path: "README.md", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
    ]), undoManager: nil)
    model.extractionFileSystem = ExtractionFileSystem(deviceToken: token) { from, to, flags in
        if flags == UInt32(RENAME_SWAP) { return ENOTSUP }
        if tookTheName.withLock({ $0 }) { return EIO }
        if to == target {
            // The new item cannot go in: something else has the name by now.
            try? Data("arrived meanwhile".utf8).write(to: URL(fileURLWithPath: target))
            tookTheName.withLock { $0 = true }
            return EEXIST
        }
        return renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    await #expect(throws: ExtractionRecoveryError.self) {
        try await model.extract(["README.md"], to: output, resolutions: ["README.md": .replace], progress: nil)
    }

    let found = try FileManager.default.contentsOfDirectory(atPath: output.path)
        .filter { ArchiveModel.stagingNameFields($0) != nil }
    let original = try #require(found.first, "the model left no staging folder")
    #expect(found.count == 1)
    let staging = output.appendingPathComponent("\(ArchiveModel.stagingPrefix)\(token)-\(try reapedPid())-\(UUID().uuidString)",
                                                isDirectory: true)
    try FileManager.default.moveItem(at: output.appendingPathComponent(original, isDirectory: true), to: staging)

    var marker: URL?, recovered: URL?
    for name in try FileManager.default.contentsOfDirectory(atPath: staging.path) {
        let url = staging.appendingPathComponent(name)
        var status = stat()
        #expect(lstat(url.path, &status) == 0)
        if status.st_mode & S_IFMT == S_IFDIR { recovered = url } else if name != "README.md" { marker = url }
    }
    return LeftStaging(output: output, staging: staging, marker: try #require(marker, "no keep marker in staging"),
                       recovered: try #require(recovered, "no recovered folder in staging"))
}

private func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("StagingSweepDriftTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A staging the model marked, or that holds its recovered folder, is never swept: the marker alone,
/// the recovered folder alone, and both. With neither, it goes.
@MainActor @Test(arguments: [
    (removeMarker: false, removeRecovered: false, swept: false),
    (removeMarker: true, removeRecovered: false, swept: false),
    (removeMarker: false, removeRecovered: true, swept: false),
    (removeMarker: true, removeRecovered: true, swept: true),
])
func theSweepKeepsWhatTheModelMarked(removeMarker: Bool, removeRecovered: Bool, swept: Bool) async throws {
    let output = try makeFolder()
    defer { try? FileManager.default.removeItem(at: output) }
    let left = try await leaveMarkedStaging(in: output)
    if removeMarker { try FileManager.default.removeItem(at: left.marker) }
    if removeRecovered { try FileManager.default.removeItem(at: left.recovered) }
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                          ofItemAtPath: left.staging.path)

    StagingSweep.sweep(in: output, deviceToken: token)

    #expect(FileManager.default.fileExists(atPath: left.staging.path) == !swept)
}
