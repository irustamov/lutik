import Testing
import Foundation
import CryptoKit
@testable import Kernir
import KernirCore

struct CompressServiceTests {
    private static let token = "0123456789abcdef"

    /// A fresh folder, removed when `body` ends.
    private func withFolder<T>(_ body: (URL) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompressServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            // An unreadable source must not keep its folder around.
            if let names = try? FileManager.default.subpathsOfDirectory(atPath: folder.path) {
                for name in names { chmod(folder.appendingPathComponent(name).path, 0o755) }
            }
            try? FileManager.default.removeItem(at: folder)
        }
        return try await body(folder)
    }

    private func service(rename: (@Sendable (String, String, UInt32) -> Int32?)? = nil) -> CompressService {
        CompressService(fileSystem: ExtractionFileSystem(deviceToken: Self.token) { from, to, flags in
            rename?(from, to, flags) ?? ExtractionFileSystem.system.rename(from, to, flags)
        })
    }

    @discardableResult
    private func write(_ text: String, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// NFC path below the items' folder → SHA-256 of each file, "dir" for each folder.
    private func digests(of urls: [URL]) throws -> [String: String] {
        var result: [String: String] = [:]
        func visit(_ url: URL, at path: String) throws {
            let path = path.precomposedStringWithCanonicalMapping
            if (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                result[path] = "dir"
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, at: path + "/" + child.lastPathComponent)
                }
            } else {
                result[path] = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        }
        for url in urls { try visit(url, at: url.lastPathComponent) }
        return result
    }

    /// Extracts `archive` into a new folder beside it and returns the digests of what came out.
    private func extracted(_ archive: URL, in folder: URL) async throws -> [String: String] {
        let out = folder.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        try await Archive.open(at: archive).extract(nil, to: out, progress: nil)
        let top = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        return try digests(of: top)
    }

    private func staging(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".kernir-") }
    }

    @Test func oneFileRoundTrips() async throws {
        try await withFolder { folder in
            let file = try write("quarterly numbers", to: folder.appendingPathComponent("report.pdf"))
            let archive = try await service().compress([file], format: .zip)
            #expect(archive.lastPathComponent == "report.pdf.zip")
            #expect(archive.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
            #expect(try await extracted(archive, in: folder) == digests(of: [file]))
            #expect(try staging(in: folder).isEmpty)
        }
    }

    /// A folder given (the items' refuses writes) gets the archive, under the
    /// usual free name; the items' folder is left as it was.
    @Test func aFolderGivenGetsTheArchive() async throws {
        try await withFolder { folder in
            let items = folder.appendingPathComponent("items", isDirectory: true)
            let other = folder.appendingPathComponent("other", isDirectory: true)
            let file = try write("quarterly numbers", to: items.appendingPathComponent("report.pdf"))
            try write("taken", to: other.appendingPathComponent("report.pdf.zip"))
            let archive = try await service().compress([file], format: .zip, in: other)
            #expect(archive.standardizedFileURL == other.appendingPathComponent("report.pdf 2.zip").standardizedFileURL)
            #expect(try await extracted(archive, in: folder) == digests(of: [file]))
            #expect(try FileManager.default.contentsOfDirectory(atPath: items.path) == ["report.pdf"])
            #expect(try staging(in: other).isEmpty)
        }
    }

    @Test func severalFilesRoundTripAsArchive() async throws {
        try await withFolder { folder in
            let files = try ["a.txt", "b.txt", "c.bin"].map { try write("content of \($0)", to: folder.appendingPathComponent($0)) }
            let archive = try await service().compress(files, format: .zip)
            #expect(archive.lastPathComponent == "Archive.zip")
            #expect(try await extracted(archive, in: folder) == digests(of: files))
        }
    }

    /// A folder with a decomposed (NFD) name inside, an empty subfolder and a Finder `.DS_Store`.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip, .tarGzip])
    func nestedFolderRoundTrips(format: ArchiveFormat) async throws {
        try await withFolder { folder in
            let photos = folder.appendingPathComponent("Photos", isDirectory: true)
            try write("one", to: photos.appendingPathComponent("Cafe\u{301}/1.jpg"))
            try write("two", to: photos.appendingPathComponent("trip/2.jpg"))
            try FileManager.default.createDirectory(at: photos.appendingPathComponent("empty"), withIntermediateDirectories: true)
            let expected = try digests(of: [photos])
            try write("finder", to: photos.appendingPathComponent(".DS_Store"))

            let archive = try await service().compress([photos], format: format)
            #expect(archive.lastPathComponent == "Photos." + format.fileExtension)
            let contents = try await extracted(archive, in: folder)
            #expect(contents == expected)
            let entries = try await Archive.open(at: archive).entries
            #expect(!entries.contains { $0.name == ".DS_Store" })
        }
    }

    @Test func anExistingArchiveIsKeptAndTheNewOneIsNumbered() async throws {
        try await withFolder { folder in
            let files = try ["a", "b"].map { try write($0, to: folder.appendingPathComponent($0)) }
            let existing = try write("not an archive", to: folder.appendingPathComponent("Archive.zip"))
            let archive = try await service().compress(files, format: .zip)
            #expect(archive.lastPathComponent == "Archive 2.zip")
            #expect(try Data(contentsOf: existing) == Data("not an archive".utf8))
        }
    }

    /// Something takes the planned name after the folder was listed: the move never replaces it.
    @Test func aNameTakenBeforeTheMoveIsNotReplaced() async throws {
        try await withFolder { folder in
            let files = try ["a", "b"].map { try write($0, to: folder.appendingPathComponent($0)) }
            let intruder = folder.appendingPathComponent("Archive.zip")
            let archive = try await service(rename: { _, to, _ in
                if to == intruder.path, !FileManager.default.fileExists(atPath: to) {
                    try? Data("intruder".utf8).write(to: intruder)
                }
                return nil
            }).compress(files, format: .zip)
            #expect(archive.lastPathComponent == "Archive 2.zip")
            #expect(try Data(contentsOf: intruder) == Data("intruder".utf8))
            #expect(try staging(in: folder).isEmpty)
        }
    }

    /// Numbers count on past every taken one, Finder style: "Archive.zip" and "Archive 2.zip"
    /// give "Archive 3.zip", with names taken in the listing and at the move alike.
    @Test(arguments: [0, 1, 2]) func takenNumbersAreSkipped(takenAtTheMove: Int) async throws {
        try await withFolder { folder in
            let files = try ["a", "b"].map { try write($0, to: folder.appendingPathComponent($0)) }
            let names = ["Archive.zip", "Archive 2.zip"]
            for name in names.dropLast(takenAtTheMove) { try write("old", to: folder.appendingPathComponent(name)) }
            let intruders = Set(names.suffix(takenAtTheMove).map { folder.appendingPathComponent($0).path })
            let archive = try await service(rename: { _, to, _ in
                if intruders.contains(to), !FileManager.default.fileExists(atPath: to) {
                    try? Data("intruder".utf8).write(to: URL(fileURLWithPath: to))
                }
                return nil
            }).compress(files, format: .zip)
            #expect(archive.lastPathComponent == "Archive 3.zip")
            for name in names { #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)) }
            #expect(try staging(in: folder).isEmpty)
        }
    }

    /// A name refused at the move (EEXIST, even with nothing to see there) gets CompressPlan's next
    /// name, trimmed to fit like the first: a 250-byte name's "… 2.zip" drops a character rather
    /// than going over 255 bytes.
    @Test func theNextNameAfterARefusedMoveIsCompressPlansTrimmedName() async throws {
        try await withFolder { folder in
            let base = String(repeating: "a", count: 250)
            let file = try write("x", to: folder.appendingPathComponent(base))
            let refused = folder.appendingPathComponent(base + ".zip").path
            let archive = try await service(rename: { _, to, _ in to == refused ? EEXIST : nil })
                .compress([file], format: .zip)
            #expect(archive.lastPathComponent == String(repeating: "a", count: 249) + " 2.zip")
            #expect(FileManager.default.fileExists(atPath: archive.path))
            #expect(try staging(in: folder).isEmpty)
        }
    }

    /// A folder that refuses every name ends with EEXIST after `UniquePlacement.maxAttempts` tries
    /// instead of trying forever, and leaves no staging.
    @Test func aFolderThatRefusesEveryNameEnds() async throws {
        try await withFolder { folder in
            let file = try write("x", to: folder.appendingPathComponent("x.txt"))
            await #expect(throws: POSIXError(.EEXIST)) {
                try await service(rename: { _, _, flags in flags == UInt32(RENAME_EXCL) ? EEXIST : nil })
                    .compress([file], format: .zip)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["x.txt"])
        }
    }

    /// A volume without RENAME_EXCL: checked, then a plain rename.
    @Test func aVolumeWithoutExclusiveRenameStillMoves() async throws {
        try await withFolder { folder in
            let file = try write("x", to: folder.appendingPathComponent("x.txt"))
            let archive = try await service(rename: { _, _, flags in flags == UInt32(RENAME_EXCL) ? ENOTSUP : nil })
                .compress([file], format: .zip)
            #expect(archive.lastPathComponent == "x.txt.zip")
            #expect(try staging(in: folder).isEmpty)
        }
    }

    /// The ENOTSUP fallback checks the name first: an item that took it after the folder was
    /// listed is not replaced by the plain rename.
    @Test func aVolumeWithoutExclusiveRenameDoesNotReplaceATakenName() async throws {
        try await withFolder { folder in
            let file = try write("x", to: folder.appendingPathComponent("x.txt"))
            let intruder = folder.appendingPathComponent("x.txt.zip")
            let archive = try await service(rename: { _, to, flags in
                if to == intruder.path, !FileManager.default.fileExists(atPath: to) {
                    try? Data("intruder".utf8).write(to: intruder)
                }
                return flags == UInt32(RENAME_EXCL) ? ENOTSUP : nil
            }).compress([file], format: .zip)
            #expect(archive.lastPathComponent == "x.txt 2.zip")
            #expect(try Data(contentsOf: intruder) == Data("intruder".utf8))
            #expect(try staging(in: folder).isEmpty)
        }
    }

    /// The archive is written in a `.kernir-<token>-<pid>-<uuid>` folder in the destination (same
    /// volume, so the move is a rename; ArchiveModel's sweep reads this name).
    @Test func stagingIsANamedFolderInTheDestination() async throws {
        try await withFolder { folder in
            let file = try write("x", to: folder.appendingPathComponent("x.txt"))
            let moves = Moves()
            _ = try await service(rename: { from, _, _ in moves.append(from); return nil }).compress([file], format: .zip)
            let from = try #require(moves.first)
            let stagingFolder = URL(fileURLWithPath: from).deletingLastPathComponent()
            #expect(stagingFolder.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path)
            let name = stagingFolder.lastPathComponent
            let fields = name.dropFirst(".kernir-".count).split(separator: "-", maxSplits: 2).map(String.init)
            #expect(name.hasPrefix(".kernir-"))
            #expect(fields.count == 3)
            #expect(fields.first == Self.token)
            #expect(fields.dropFirst().first == String(getpid()))
            #expect(UUID(uuidString: fields.last ?? "") != nil)
        }
    }

    /// Finder's list view can select a folder and an item inside it. Compress keeps both, as
    /// Finder's own Compress does: the archive holds "a.txt" and "sub/a.txt". It goes beside "sub",
    /// and its staging folder never becomes part of what it archives.
    /// Also when the file comes spelled through a symlink to "sub", which a plain path comparison
    /// would not see as inside "sub".
    @Test(arguments: ["file first", "sub first", "file first, other spelling"])
    func nestedItemsAreBothArchivedWithoutTheStaging(order: String) async throws {
        try await withFolder { folder in
            let sub = folder.appendingPathComponent("sub", isDirectory: true)
            let file = try write("a", to: sub.appendingPathComponent("a.txt"))
            try write("b", to: sub.appendingPathComponent("deep/b.txt"))
            let alias = folder.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sub)
            let items = switch order {
            case "sub first": [sub, file]
            case "file first": [file, sub]
            default: [alias.appendingPathComponent("a.txt"), sub]
            }
            let expected = try digests(of: items)
            let moves = Moves()
            let archive = try await service(rename: { from, _, _ in moves.append(from); return nil })
                .compress(items, format: .zip)
            #expect(archive.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path)
            #expect(archive.lastPathComponent == "Archive.zip")
            let entries = try await Archive.open(at: archive).entries.map(\.path)
            #expect(!entries.contains { $0.contains(".kernir-") })
            #expect(try await extracted(archive, in: folder) == expected)
            // The staging was beside "sub", not in it, and is gone.
            let stagingFolder = try #require(moves.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
            #expect(stagingFolder.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path)
            #expect(try staging(in: folder).isEmpty)
            #expect(try staging(in: sub).isEmpty)
        }
    }

    /// A name a volume would refuse (over 255 bytes with the extension) is trimmed, and the write works.
    @Test func aLongNameIsTrimmedAndWritten() async throws {
        try await withFolder { folder in
            let file = try write("x", to: folder.appendingPathComponent(String(repeating: "я", count: 125) + ".txt"))
            let archive = try await service().compress([file], format: .zip)
            #expect(archive.lastPathComponent == String(repeating: "я", count: 125) + ".zip")
            #expect(FileManager.default.fileExists(atPath: archive.path))
            #expect(try staging(in: folder).isEmpty)
        }
    }

    @Test func cancellingLeavesNothing() async throws {
        try await withFolder { folder in
            let files = try (0..<200).map { try write(String(repeating: "\($0)", count: 4096), to: folder.appendingPathComponent("f\($0).txt")) }
            let before = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path))
            let task = Task {
                try await service().compress(files, format: .zip) { _, _ in
                    // The writer reports progress on the calling task: cancel it mid-write.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            await #expect(throws: ArchiveError.cancelled) { try await task.value }
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: folder.path)) == before)
        }
    }

    @Test func cancelledBeforeTheMoveLeavesNothing() async throws {
        try await withFolder { folder in
            let file = try write("x", to: folder.appendingPathComponent("x.txt"))
            let task = Task {
                try await service(rename: { _, _, _ in Issue.record("moved after cancel"); return nil })
                    .compress([file], format: .zip) { fraction, _ in
                        if fraction >= 1 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
            }
            await #expect(throws: ArchiveError.cancelled) { try await task.value }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["x.txt"])
        }
    }

    @Test func anUnreadableSourceThrowsAndLeavesNoStaging() async throws {
        try await withFolder { folder in
            let file = try write("secret", to: folder.appendingPathComponent("secret.txt"))
            chmod(file.path, 0)
            await #expect(throws: (any Error).self) { try await service().compress([file], format: .zip) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["secret.txt"])
        }
    }

    @Test func nothingToCompressThrows() async throws {
        await #expect(throws: CompressService.NothingToCompress()) { try await service().compress([], format: .zip) }
    }

    /// No items with a folder given: the same error, before the folder is touched (one that isn't
    /// there would fail otherwise).
    @Test func nothingToCompressInAFolderThrowsBeforeWriting() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompressServiceTests-missing-\(UUID().uuidString)", isDirectory: true)
        await #expect(throws: CompressService.NothingToCompress()) {
            try await service().compress([], format: .zip, in: missing)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}

/// The paths the service moved from, in order.
private final class Moves: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func append(_ path: String) { lock.withLock { paths.append(path) } }
    var first: String? { lock.withLock { paths.first } }
}
