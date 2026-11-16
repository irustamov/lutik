import Foundation
import Testing
@testable import KernirCore

/// 0.1.0 API batch (E0): the new public API's defaults change nothing, and every engine path behind it
/// that has not landed yet throws `.notImplemented` and writes nothing.
struct APIBatchTests {
    /// A zip holding `a.txt` and `dir/b.txt`, written by Kernir; returns the archive and a spare file to add.
    static func makeSource() async throws -> (archive: URL, spare: URL) {
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles([
            "in/a.txt": Data("a".utf8),
            "in/dir/b.txt": Data("b".utf8),
            "spare.txt": Data("spare".utf8),
        ], in: dir)
        let archive = dir.appendingPathComponent("source.zip")
        let changes = ArchiveChangeSet(additions: [
            .init(sourceURL: dir.appendingPathComponent("in/a.txt"), destinationDirectory: ""),
            .init(sourceURL: dir.appendingPathComponent("in/dir"), destinationDirectory: ""),
        ])
        try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: archive, options: nil)
        return (archive, dir.appendingPathComponent("spare.txt"))
    }

    static func paths(_ url: URL) async throws -> [String] {
        try await Archive.open(at: url).entries.map(\.path).sorted()
    }

    // MARK: Defaults

    @Test func changeSetDefaults() {
        let empty = ArchiveChangeSet()
        #expect(empty.renamedPaths.isEmpty)
        #expect(empty.comment == .keep)
        #expect(empty.isEmpty)
        #expect(ArchiveChangeSet(removedPaths: [], additions: []) == empty)
        let addition = ArchiveChangeSet.Addition(sourceURL: URL(fileURLWithPath: "/tmp/x"), destinationDirectory: "")
        #expect(addition.archiveName == nil)
        #expect(addition == .init(sourceURL: URL(fileURLWithPath: "/tmp/x"), destinationDirectory: "", archiveName: nil))
        #expect(addition != .init(sourceURL: URL(fileURLWithPath: "/tmp/x"), destinationDirectory: "", archiveName: "y"))
    }

    @Test func changeSetIsEmptyAndEquatableSeeEveryField() {
        let addition = ArchiveChangeSet.Addition(sourceURL: URL(fileURLWithPath: "/tmp/x"), destinationDirectory: "")
        let sets = [
            ArchiveChangeSet(removedPaths: ["a"]),
            ArchiveChangeSet(additions: [addition]),
            ArchiveChangeSet(renamedPaths: ["a": "b"]),
            ArchiveChangeSet(comment: .set("hi")),
            ArchiveChangeSet(comment: .set("")),
            ArchiveChangeSet(comment: .remove),
        ]
        for (i, set) in sets.enumerated() {
            #expect(!set.isEmpty)
            #expect(set != ArchiveChangeSet())
            for (j, other) in sets.enumerated() where j != i { #expect(set != other) }
        }
        var edited = ArchiveChangeSet()
        edited.renamedPaths["a"] = "b"
        edited.comment = .remove
        #expect(edited == ArchiveChangeSet(renamedPaths: ["a": "b"], comment: .remove))
    }

    @Test func writeOptionsDefaults() {
        let options = ArchiveWriteOptions()
        #expect(options.excludesMacMetadata == false)
        #expect(options.volumeSize == nil)
        #expect(options == ArchiveWriteOptions(method: nil, compressionLevel: nil, encryption: .none,
                                               password: nil, solid: nil))
        #expect(options != ArchiveWriteOptions(excludesMacMetadata: true))
        #expect(options != ArchiveWriteOptions(volumeSize: 1 << 20))
    }

    @Test func formatCapabilities() {
        #expect(ArchiveFormat.allCases.filter(\.supportsVolumes) == [.zip, .sevenZip])
        #expect(ArchiveFormat.allCases.filter(\.supportsComments) == [.zip])
        for format in ArchiveFormat.allCases where format.supportsVolumes || format.supportsComments {
            #expect(format.isWritable)
        }
    }

    @Test func commentDefaultsToNil() async throws {
        #expect(SampleArchive().comment == nil)
        let (archive, _) = try await Self.makeSource()
        let reader = try await Archive.open(at: archive)
        #expect(reader.comment == nil)
        let comment = ArchiveComment(bytes: Array("hi".utf8), text: "hi", isWritable: true)
        #expect(comment == ArchiveComment(bytes: [0x68, 0x69], text: "hi", isWritable: true))
        #expect(ArchiveComment.maximumWritableLength == 16_000)
    }

    /// Explicit default values for every new field write what the old call writes.
    @Test func defaultsWriteAsBefore() async throws {
        let (archive, spare) = try await Self.makeSource()
        let reader = try await Archive.open(at: archive)
        let old = ArchiveChangeSet(removedPaths: ["a.txt"],
                                   additions: [.init(sourceURL: spare, destinationDirectory: "dir")])
        let new = ArchiveChangeSet(removedPaths: ["a.txt"],
                                   additions: [.init(sourceURL: spare, destinationDirectory: "dir", archiveName: nil)],
                                   renamedPaths: [:], comment: .keep)
        let out = Fixtures.tempDir()
        let first = out.appendingPathComponent("first.zip")
        let second = out.appendingPathComponent("second.zip")
        try await ArchiveWriter.write(source: reader, changes: old, format: .zip, to: first,
                                      options: ArchiveWriteOptions())
        try await ArchiveWriter.write(source: reader, changes: new, format: .zip, to: second,
                                      options: ArchiveWriteOptions(excludesMacMetadata: false, volumeSize: nil))
        #expect(try await Self.paths(first) == ["dir", "dir/b.txt", "dir/spare.txt"])
        #expect(try await Self.paths(second) == Self.paths(first))
    }

    // MARK: Stubs

    enum Stub: String, CaseIterable, Sendable {
        case commentSet, commentSetEmpty, commentRemove, volumeSize
        /// `write` takes a comment change (`ArchiveCommentTests`); `writeVolumes` refuses it with `.io`.
        var isComment: Bool { self == .commentSet || self == .commentSetEmpty || self == .commentRemove }
    }

    /// Each stub still refused throws `.notImplemented` on an in-place save, and the source file is untouched.
    @Test(arguments: Stub.allCases.filter { !$0.isComment }) func stubThrowsAndWritesNothing(_ stub: Stub) async throws {
        let (archive, _) = try await Self.makeSource()
        let before = Fixtures.sha256(archive)
        let reader = try await Archive.open(at: archive)
        var changes = ArchiveChangeSet()
        var options: ArchiveWriteOptions? = nil
        switch stub {
        case .commentSet: changes.comment = .set("hello")
        case .commentSetEmpty: changes.comment = .set("")
        case .commentRemove: changes.comment = .remove
        case .volumeSize: options = ArchiveWriteOptions(volumeSize: 1 << 20)
        }
        await #expect(throws: ArchiveError.notImplemented) {
            try await ArchiveWriter.write(source: reader, changes: changes, format: .zip, to: archive,
                                          options: options)
        }
        #expect(Fixtures.sha256(archive) == before)

        // A new archive: nothing appears at the destination.
        let destination = Fixtures.tempDir().appendingPathComponent("new.zip")
        await #expect(throws: ArchiveError.notImplemented) {
            try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: destination,
                                          options: options)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: writeVolumes (the caller owns the folder)

    /// A new, empty folder the caller made.
    static func emptyFolder() -> URL {
        let folder = Fixtures.tempDir().appendingPathComponent("Split", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func contents(_ folder: URL) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// The error `writeVolumes` throws (nil when it returns).
    static func volumesError(source: (any ArchiveReading)? = nil, changes: ArchiveChangeSet = ArchiveChangeSet(),
                             format: ArchiveFormat = .zip, into directory: URL,
                             volumeSize: Int64? = ArchiveWriteOptions.minimumVolumeSize) async -> ArchiveError? {
        do {
            try await ArchiveWriter.writeVolumes(source: source, changes: changes, format: format, into: directory,
                                                 baseName: "Split", options: ArchiveWriteOptions(volumeSize: volumeSize))
            return nil
        } catch let error as ArchiveError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    static func isIO(_ error: ArchiveError?, containing text: String) -> Bool {
        if case .io(let message)? = error { return message.contains(text) }
        return false
    }

    @Test func volumeConstants() {
        #expect(ArchiveWriteOptions.minimumVolumeSize == 1_000_000)
        #expect(ArchiveWriteOptions.maximumVolumeCount == 999)
    }

    /// A valid request passes every refusal and reaches the split writer, which writes the set into the
    /// caller's folder: one plain file here, as this small archive fits in one volume (or `volumeSize` is nil).
    @Test(arguments: [ArchiveFormat.zip, .sevenZip], [Int64?.none, 1_000_000, 1 << 20])
    func writeVolumesWritesIntoTheFolder(_ format: ArchiveFormat, _ volumeSize: Int64?) async throws {
        let (archive, _) = try await Self.makeSource()
        let reader = try await Archive.open(at: archive)
        let folder = Self.emptyFolder()
        let error = await Self.volumesError(source: reader, format: format, into: folder, volumeSize: volumeSize)
        #expect(error == nil)
        #expect(Self.contents(folder) == ["Split.\(format.fileExtension)"])
        let written = try await Self.paths(folder.appendingPathComponent("Split.\(format.fileExtension)"))
        #expect(written == (try await Self.paths(archive)))
    }

    @Test func writeVolumesRefusesFormatsWithoutVolumes() async {
        for format in ArchiveFormat.allCases where !format.supportsVolumes {
            let folder = Self.emptyFolder()
            #expect(await Self.volumesError(format: format, into: folder) == .unsupportedFormat)
            #expect(Self.contents(folder) == [])
        }
    }

    @Test func writeVolumesRefusesSmallVolumes() async {
        let folder = Self.emptyFolder()
        let error = await Self.volumesError(into: folder, volumeSize: ArchiveWriteOptions.minimumVolumeSize - 1)
        #expect(Self.isIO(error, containing: "at least"))
        #expect(Self.contents(folder) == [])
    }

    @Test func writeVolumesRefusesAMissingFolderAndCreatesNone() async {
        let folder = Fixtures.tempDir().appendingPathComponent("Missing", isDirectory: true)
        #expect(Self.isIO(await Self.volumesError(into: folder), containing: "does not exist"))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func writeVolumesRefusesAFile() async throws {
        let file = Fixtures.tempDir().appendingPathComponent("Split")
        FileManager.default.createFile(atPath: file.path, contents: Data("keep".utf8))
        #expect(Self.isIO(await Self.volumesError(into: file), containing: "not a folder"))
        #expect(try Data(contentsOf: file) == Data("keep".utf8))
    }

    @Test func writeVolumesRefusesANonEmptyFolder() async {
        let folder = Self.emptyFolder()
        FileManager.default.createFile(atPath: folder.appendingPathComponent(".hidden").path, contents: Data("x".utf8))
        #expect(Self.isIO(await Self.volumesError(into: folder), containing: "not empty"))
        #expect(Self.contents(folder) == [".hidden"])
    }

    @Test func writeVolumesRefusesASourceInsideTheFolder() async throws {
        let (archive, _) = try await Self.makeSource()
        let folder = Self.emptyFolder()
        let inside = folder.appendingPathComponent("sub/source.zip")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: archive, to: inside)
        let before = Fixtures.sha256(inside)
        let reader = try await Archive.open(at: inside)
        #expect(Self.isIO(await Self.volumesError(source: reader, into: folder), containing: "inside"))
        #expect(Fixtures.sha256(inside) == before)
        #expect(Self.contents(folder) == ["sub"])
    }

    /// The same refusal when the source's path below the folder starts with a combining mark or a ZWJ: `/` plus
    /// that scalar is one Character that is not "/", so a Character prefix test did not see the source inside and
    /// the emptiness check refused with the wrong reason instead. Checked on scalars.
    @Test(arguments: ["\u{301}sub/source.zip", "\u{301}source.zip", "\u{200D}source.zip"])
    func writeVolumesRefusesASourceInsideTheFolderBehindAHiddenSlash(_ below: String) async throws {
        let (archive, _) = try await Self.makeSource()
        let folder = Self.emptyFolder()
        let inside = folder.appendingPathComponent(below)
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: archive, to: inside)
        let before = Fixtures.sha256(inside)
        let reader = try await Archive.open(at: inside)
        let error = await Self.volumesError(source: reader, into: folder)
        #expect(Self.isIO(error, containing: "being saved is inside"), "\(String(describing: error))")
        #expect(Fixtures.sha256(inside) == before)
        #expect(Self.contents(folder)?.count == 1)
    }

    /// A source next to the folder whose name starts with the folder's name (plain, or with a combining mark that
    /// a Character test would join to it) is not inside it.
    @Test(arguments: ["Split\u{301}.zip", "Splitx.zip", "Split.zip"])
    func writeVolumesTakesASourceNextToTheFolder(_ sibling: String) async throws {
        let (archive, _) = try await Self.makeSource()
        let folder = Self.emptyFolder()
        let next = folder.deletingLastPathComponent().appendingPathComponent(sibling)
        try FileManager.default.copyItem(at: archive, to: next)
        let reader = try await Archive.open(at: next)
        let error = await Self.volumesError(source: reader, into: folder)
        #expect(error == nil, "\(String(describing: error))")
        #expect(Self.contents(folder) == ["Split.zip"])
    }

    /// `writeVolumes` refuses any comment change with `.io` before anything is written: a set has no comment. The
    /// input is a real file, so a writer that ran first would leave a volume behind.
    @Test(arguments: Stub.allCases.filter(\.isComment))
    func writeVolumesRefusesAnyCommentChange(_ stub: Stub) async throws {
        let (_, spare) = try await Self.makeSource()
        var changes = ArchiveChangeSet(additions: [.init(sourceURL: spare, destinationDirectory: "")])
        switch stub {
        case .commentSet: changes.comment = .set("hello")
        case .commentSetEmpty: changes.comment = .set("")
        case .commentRemove: changes.comment = .remove
        case .volumeSize: Issue.record("not a comment change")
        }
        let folder = Self.emptyFolder()
        #expect(await Self.volumesError(changes: changes, format: .sevenZip, into: folder)
                == .io("A split archive cannot have a comment"))
        #expect(Self.contents(folder) == [])
    }

    /// Control for the test above: the same request without a comment change is written, `excludesMacMetadata`
    /// included.
    @Test(arguments: [false, true])
    func writeVolumesReachesTheSplitWriterWithoutACommentChange(excludesMacMetadata: Bool) async throws {
        let (_, spare) = try await Self.makeSource()
        let folder = Self.emptyFolder()
        let urls = try await ArchiveWriter.writeVolumes(
            source: nil, changes: ArchiveChangeSet(additions: [.init(sourceURL: spare, destinationDirectory: "")]),
            format: .sevenZip, into: folder, baseName: "Split",
            options: ArchiveWriteOptions(excludesMacMetadata: excludesMacMetadata,
                                         volumeSize: ArchiveWriteOptions.minimumVolumeSize))
        #expect(urls.map(\.lastPathComponent) == ["Split.7z"])
        #expect(Self.contents(folder) == ["Split.7z"])
    }

    /// The folder checks run before the comment refusal: a bad folder is reported even with a comment change.
    @Test func writeVolumesFolderChecksComeBeforeTheCommentRefusal() async {
        let folder = Fixtures.tempDir().appendingPathComponent("Missing", isDirectory: true)
        let error = await Self.volumesError(changes: ArchiveChangeSet(comment: .remove), into: folder)
        #expect(Self.isIO(error, containing: "does not exist"))
    }
}
