import Testing
import Foundation
@testable import Kernir
import KernirCore

// Extract Here's hidden staging folder is made 0700, and only it: a file and a folder
// placed out of it keep the modes the extraction gave them, the same as one made outside staging.

/// Holds the reader once everything is written, until `release`.
private struct HeldReader: ArchiveReading {
    let base: FakeReader
    let afterWrite: @Sendable () async throws -> Void

    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        try await base.extract(paths, to: directory, progress: progress)
        try await afterWrite()
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        try await base.extractToTemporaryFile(path)
    }
}

private func mode(_ url: URL) throws -> mode_t {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return status.st_mode & 0o7777
}

// umask(2) is process-wide and Swift Testing runs tests in parallel, so no test can rely on it
// holding a value: besides the tests here that set it, libarchive's `__archive_get_umask` sets it
// to 0 for a moment to read it, in every extraction that runs in another suite. This suite is
// serialized so its own tests never overlap, but that does not keep others out. So the mode
// assertions below hold under any umask a run can see: 022 (the pinned, usual one) or 0 (a
// libarchive read caught mid-way). The staging folder's 0700 does not depend on it at all (mkdir(2)
// with 0700); a placed item must be one of the two outcomes, never 0700/0600.
@Suite(.serialized) @MainActor struct ExtractHereStagingMode {
    /// A folder or file made by FakeReader's writes (0777 / 0666 less the umask), here 022 or 0.
    private static let folderModes: [mode_t] = [0o755, 0o777]
    private static let fileModes: [mode_t] = [0o644, 0o666]

    @Test func onlyTheStagingFolderIs0700() async throws {
        let token = "0700070007000700"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractHereStagingModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The usual umask, pinned: under 077 every folder is 0700 and nothing tells staging's mode apart.
        // Another suite's extraction can still flip it to 0 meanwhile (see above), hence the two modes
        // accepted below; the pin only keeps a stricter umask of the host out.
        let previousUmask = umask(0o022)
        defer { umask(previousUmask) }

        let (written, wroteAll) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        let reader = HeldReader(base: FakeReader(entries: [
            ArchiveEntry(path: "docs", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil),
            ArchiveEntry(path: "docs/a.txt", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
            ArchiveEntry(path: "b.txt", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
        ])) {
            wroteAll.yield()
            for await _ in released { break }
        }
        let model = ArchiveModel(reader: reader, undoManager: nil)
        model.extractionFileSystem = ExtractionFileSystem(deviceToken: token) { from, to, flags in
            renamex_np(from, to, flags) == 0 ? 0 : errno
        }

        // The folder: the staging is 0700 while it fills.
        let task = Task { @MainActor in
            try await ExtractHereService.extract(.single(path: "docs", name: "docs", isDirectory: true),
                                                 from: model, in: directory, progress: nil)
        }
        for await _ in written { break }
        let staging = try #require(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .first { ArchiveModel.stagingNameFields($0) != nil })
        #expect(try mode(directory.appendingPathComponent(staging)) == 0o700)
        release.yield()
        let folder = try await task.value

        #expect(Self.folderModes.contains(try mode(folder)))
        #expect(Self.fileModes.contains(try mode(folder.appendingPathComponent("a.txt"))))

        // The file.
        release.yield()
        let file = try await ExtractHereService.extract(.single(path: "b.txt", name: "b.txt", isDirectory: false),
                                                        from: model, in: directory, progress: nil)
        #expect(Self.fileModes.contains(try mode(file)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["b.txt", "docs"])
    }

    /// `makeStagingFolder` is mkdir(2) with 0700 itself, not the umask's or a chmod's doing: 0700
    /// under the usual umask and under none (the mode asked for, less the umask, and only less).
    @Test(arguments: [mode_t(0o022), mode_t(0)])
    func theStagingFolderIsMadeWith0700(_ pinnedUmask: mode_t) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractHereStagingModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Set for this test and put back; other suites' extractions touch it too (see above), which
        // cannot change the result: mkdir(2) with 0700 gives 0700 under 022, under 0 and in between.
        let previousUmask = umask(pinnedUmask)
        defer { umask(previousUmask) }

        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        try ExtractHereService.makeStagingFolder(staging)

        #expect(try mode(staging) == 0o700)
    }
}
