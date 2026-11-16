import Testing
import Foundation
@testable import Kernir
import KernirCore

/// "Exclude Mac metadata" through the real engine (`ArchiveEngine.live`), no UI.
/// With the flag on, a save leaves out Finder metadata in the additions (by on-disk name, at any
/// depth: `__MACOSX` folders, `._*`, `.DS_Store`) and metadata already in the archive
/// (`MacOSMetadata`, also at any depth: a `__MACOSX` folder with everything in it, `._*` and
/// `.DS_Store`; a nested `__MACOSX` counts like the root one). The toggle applies to
/// every save, plain ⌘S included, which writes with `model.saveOptions`. The engine strips only
/// through explicit options; nil options never do.
///
/// The source archive is built by hand (`storedZip`), so the tests read no repo fixture and run
/// the same in the sandboxed test host.
struct LiveMetadataSaveTests {
    /// A source ZIP as Finder and an exFAT copy leave it: real files, a `__MACOSX` tree,
    /// `._*` and `.DS_Store` at the top and inside a folder, and a `__MACOSX` below the root,
    /// which `MacOSMetadata` counts as metadata like the root one.
    private static let sourceEntries: [(path: String, contents: String?)] = [
        ("Project/", nil),
        ("Project/hello.txt", "hello"),
        ("Project/._hello.txt", "apple double"),
        ("Project/.DS_Store", "finder"),
        ("Project/docs/", nil),
        ("Project/docs/readme.md", "readme"),
        ("Project/docs/__MACOSX/nested.txt", "metadata below the root too"),
        ("._Project", "apple double"),
        (".DS_Store", "finder"),
        ("__MACOSX/", nil),
        ("__MACOSX/Project/", nil),
        ("__MACOSX/Project/._hello.txt", "apple double"),
    ]

    private static let sourceWithoutMetadata: Set<String> = [
        "Project", "Project/hello.txt", "Project/docs", "Project/docs/readme.md",
    ]

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveMetadataSaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `source.zip` in `directory`, opened with the live engine.
    private func openSource(in directory: URL) async throws -> any ArchiveReading {
        let url = directory.appendingPathComponent("source.zip")
        try Self.storedZip(Self.sourceEntries).write(to: url)
        return try await ArchiveEngine.live.open(url, nil)
    }

    /// A folder `added` holding `.DS_Store`, `._a`, `__MACOSX/x`, `a`, and `sub/` with its own
    /// `__MACOSX/y` and `b`, plus a file `._top` beside it.
    private func makeAdditions(in directory: URL) throws -> ArchiveChangeSet {
        let folder = directory.appendingPathComponent("added", isDirectory: true)
        for path in [".DS_Store", "._a", "__MACOSX/x", "a", "sub/__MACOSX/y", "sub/b"] {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        let top = directory.appendingPathComponent("._top")
        try Data("apple double".utf8).write(to: top)
        return ArchiveChangeSet(additions: [.init(sourceURL: folder, destinationDirectory: ""),
                                            .init(sourceURL: top, destinationDirectory: "")])
    }

    private func paths(of url: URL) async throws -> Set<String> {
        Set(try await ArchiveEngine.live.open(url, nil).entries.map(\.path))
    }

    @Test func theHandBuiltSourceHoldsItsMetadata() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await openSource(in: directory)
        let all = Set(Self.sourceEntries.map { $0.path.hasSuffix("/") ? String($0.path.dropLast()) : $0.path })
        #expect(Set(reader.entries.map(\.path)).isSuperset(of: all))
        #expect(Set(reader.entries.map(\.path)).isSuperset(of: Self.sourceWithoutMetadata))
    }

    /// ⌘S after a panel chose the toggle writes with `model.saveOptions`, and that
    /// drops the metadata already in the archive, with no other change pending.
    @Test func aPlainSaveWithTheToggleOnDropsMetadataAlreadyInTheArchive() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await openSource(in: directory)
        let options = try await MainActor.run {
            let model = ArchiveModel(reader: reader, undoManager: nil)
            var settings = ArchiveSaveSettings(model: model)
            settings.options.excludesMacMetadata = true
            model.apply(settings)
            return try #require(model.saveOptions)
        }
        let saved = directory.appendingPathComponent("saved.zip")

        try await ArchiveEngine.live.write(reader, ArchiveChangeSet(), .zip, saved, options, nil)
        #expect(try await paths(of: saved) == Self.sourceWithoutMetadata)
    }

    /// With the flag on, metadata goes from both sides at once: the archive's and the additions'.
    @Test func aSaveWithAdditionsDropsMetadataFromBoth() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await openSource(in: directory)
        let changes = try makeAdditions(in: directory)
        let saved = directory.appendingPathComponent("saved.zip")

        try await ArchiveEngine.live.write(reader, changes, .zip, saved,
                                           ArchiveWriteOptions(excludesMacMetadata: true), nil)
        #expect(try await paths(of: saved)
            == Self.sourceWithoutMetadata.union(["added", "added/a", "added/sub", "added/sub/b"]))
    }

    /// A new archive from a folder with metadata, flag on: only `a`, and `sub/b` (additions
    /// are filtered by on-disk name at any depth, so the nested `__MACOSX` goes too), and a `._*`
    /// file added on its own goes as well.
    @Test func aNewArchiveWithTheFlagOnWritesOnlyTheFiles() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let changes = try makeAdditions(in: directory)
        let saved = directory.appendingPathComponent("new.zip")

        try await ArchiveEngine.live.write(nil, changes, .zip, saved,
                                           ArchiveWriteOptions(excludesMacMetadata: true), nil)
        #expect(try await paths(of: saved) == ["added", "added/a", "added/sub", "added/sub/b"])
    }

    /// Flag off: the archive's metadata is kept, and additions keep `__MACOSX` folders and a
    /// `._*` file added on its own; `.DS_Store` is always skipped. A `._*` file inside an added
    /// folder is never written either way: Foundation's directory enumerator, which the engine's
    /// `AdditionWalker` uses, doesn't list `._*` names (seen on APFS, 2026-11-10; the engine tests pin it in
    /// `MacMetadataWriteTests.foundationNeverListsAppleDoubleFilesInAFolder`). The
    /// byte-identical repack check is the engine's `RepackTests`.
    @Test func theFlagOffKeepsMetadata() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await openSource(in: directory)
        let changes = try makeAdditions(in: directory)
        let saved = directory.appendingPathComponent("saved.zip")

        try await ArchiveEngine.live.write(reader, changes, .zip, saved, ArchiveWriteOptions(), nil)
        let written = try await paths(of: saved)
        #expect(written.isSuperset(of: Set(reader.entries.map(\.path))))
        #expect(written.isSuperset(of: ["._top", "added/__MACOSX/x", "added/a", "added/sub/__MACOSX/y"]))
        #expect(!written.contains("added/.DS_Store"))
        #expect(!written.contains("added/._a"))

        // A plain save with nil options (⌘S of a document no panel saved) keeps them too.
        let plain = directory.appendingPathComponent("plain.zip")
        try await ArchiveEngine.live.write(reader, ArchiveChangeSet(), .zip, plain, nil, nil)
        #expect(try await paths(of: plain) == Set(reader.entries.map(\.path)))
    }

    /// A split save goes through `ArchiveEngine.live.writeVolumes`, and the flag drops
    /// metadata from the set exactly as from one file. 2.5 MB that doesn't compress, stored, at 1 MB
    /// volumes: three parts, named after the folder, and the first opens as the whole archive. ZIP and
    /// 7z, the two formats that split.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func aSplitSaveDropsMetadataToo(_ format: ArchiveFormat) async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = try await openSource(in: directory)
        let big = directory.appendingPathComponent("big.bin")
        var generator = SystemRandomNumberGenerator()
        try Data((0..<2_500_000).map { _ in UInt8.random(in: 0...255, using: &generator) }).write(to: big)
        let folder = directory.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var options = ArchiveWriteOptions(method: .store, excludesMacMetadata: true)
        options.volumeSize = 1_000_000

        let volumes = try await ArchiveEngine.live.writeVolumes(
            reader, ArchiveChangeSet(additions: [.init(sourceURL: big, destinationDirectory: "")]), format,
            folder, "Photos", options, nil)

        let ext = format.fileExtension
        #expect(volumes.map(\.lastPathComponent) == ["Photos.\(ext).001", "Photos.\(ext).002", "Photos.\(ext).003"])
        #expect(try await paths(of: volumes[0]) == Self.sourceWithoutMetadata.union(["big.bin"]))
    }

    // MARK: - A stored ZIP, by hand

    /// A ZIP of `entries` (a trailing "/" makes a folder), every file stored uncompressed.
    static func storedZip(_ entries: [(path: String, contents: String?)]) -> Data {
        var archive = Data()
        var central = Data()
        let dosTime: UInt16 = 0
        let dosDate: UInt16 = (40 << 9) | (1 << 5) | 1 // 2020-01-01
        for (path, contents) in entries {
            let name = Data(path.utf8)
            let data = Data((contents ?? "").utf8)
            let crc = crc32(data)
            let offset = UInt32(archive.count)
            archive.append(le32: 0x0403_4b50)
            archive.append(le16: 20); archive.append(le16: 0x0800); archive.append(le16: 0)
            archive.append(le16: dosTime); archive.append(le16: dosDate)
            archive.append(le32: crc); archive.append(le32: UInt32(data.count)); archive.append(le32: UInt32(data.count))
            archive.append(le16: UInt16(name.count)); archive.append(le16: 0)
            archive.append(name); archive.append(data)

            let mode: UInt32 = contents == nil ? 0o040755 : 0o100644
            central.append(le32: 0x0201_4b50)
            central.append(le16: 0x031E); central.append(le16: 20); central.append(le16: 0x0800); central.append(le16: 0)
            central.append(le16: dosTime); central.append(le16: dosDate)
            central.append(le32: crc); central.append(le32: UInt32(data.count)); central.append(le32: UInt32(data.count))
            central.append(le16: UInt16(name.count)); central.append(le16: 0); central.append(le16: 0)
            central.append(le16: 0); central.append(le16: 0)
            central.append(le32: (mode << 16) | (contents == nil ? 0x10 : 0))
            central.append(le32: offset)
            central.append(name)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        archive.append(le32: 0x0605_4b50)
        archive.append(le16: 0); archive.append(le16: 0)
        archive.append(le16: UInt16(entries.count)); archive.append(le16: UInt16(entries.count))
        archive.append(le32: UInt32(central.count)); archive.append(le32: centralOffset)
        archive.append(le16: 0)
        return archive
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB8_8320) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
