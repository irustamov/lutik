import Testing
import Foundation
@testable import Kernir
import KernirCore

// MARK: - Helpers

private let file = ExtractHereListings.file
private let folder = ExtractHereListings.folder
private let testDeviceToken = "feedface00000000"

/// A fresh folder holding `name`, standing for the archive the user opened; the caller removes
/// the folder.
private func makeArchiveFolder(_ name: String = "project.zip") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExtractHereServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let archive = directory.appendingPathComponent(name)
    try Data("archive".utf8).write(to: archive)
    return archive
}

@discardableResult
private func makeFile(_ relativePath: String, in directory: URL, contents: String) throws -> URL {
    let url = directory.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
}

private func contents(of url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

/// Everything under `directory`, hidden items included: "dir" for folders, else the contents.
private func snapshot(_ directory: URL) throws -> [String: String] {
    let fileManager = FileManager.default
    var result: [String: String] = [:]
    for relative in try fileManager.subpathsOfDirectory(atPath: directory.path) {
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: directory.appendingPathComponent(relative).path, isDirectory: &isDirectory)
        result[relative] = isDirectory.boolValue ? "dir" : try contents(of: directory.appendingPathComponent(relative))
    }
    return result
}

@MainActor
private func makeModel(_ entries: [ArchiveEntry], reader: (any ArchiveReading)? = nil,
                       fileSystem: ExtractionFileSystem? = nil) -> ArchiveModel {
    let model = ArchiveModel(reader: reader ?? FakeReader(entries: entries), undoManager: nil)
    model.extractionFileSystem = fileSystem ?? ExtractionFileSystem(deviceToken: testDeviceToken,
                                                                    rename: ExtractionFileSystem.system.rename)
    return model
}

@MainActor
private func extractHere(_ paths: [String]?, from model: ArchiveModel, archive: URL) async throws -> URL {
    let plan = try #require(ExtractHerePlan.make(paths, in: model, archiveURL: archive))
    return try await ExtractHereService.extract(plan, from: model, nextTo: archive, progress: nil)
}

/// FakeReader that runs `afterWrite` once everything is written, before returning.
private struct GatedReader: ArchiveReading {
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

/// Renames through `rule` first (nil: the real renamex_np(2)), with the test device token.
private func fakeFileSystem(_ rule: @escaping @Sendable (_ from: String, _ to: String, _ flags: UInt32) -> Int32?)
    -> ExtractionFileSystem {
    ExtractionFileSystem(deviceToken: testDeviceToken) { from, to, flags in
        rule(from, to, flags) ?? ExtractionFileSystem.system.rename(from, to, flags)
    }
}

// MARK: - Another folder

/// A read-only volume: the error offers another folder, and the same result (its name, the
/// wrap) goes there under a free Finder name; the archive's folder is left as it was.
@MainActor @Test func anotherFolderGetsTheSameResult() async throws {
    let archive = try makeArchiveFolder("project.zip")
    let directory = archive.deletingLastPathComponent()
    let other = directory.appendingPathComponent("Other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: other.appendingPathComponent("project"), withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(ExtractHereListings.project)
    let plan = try #require(ExtractHerePlan.make(nil, in: model, archiveURL: archive))

    let placed = try await ExtractHereService.extract(plan, from: model, in: other, progress: nil)

    #expect(placed.standardizedFileURL == other.appendingPathComponent("project 2", isDirectory: true).standardizedFileURL)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["Other", "project.zip"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).sorted() == ["project", "project 2"])
    #expect(FileManager.default.fileExists(atPath: placed.appendingPathComponent("src/main.swift").path))
}

@Test(arguments: [
    (CocoaError(.fileWriteVolumeReadOnly) as any Error, true),
    (NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS)), true),
    (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))]), true),
    // EROFS two levels down (a Cocoa error wrapping another that wraps it), as some writes report it.
    (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                                                      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))])]), true),
    // The Cocoa read-only code under a generic write error, not only at the top.
    (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
             userInfo: [NSUnderlyingErrorKey: CocoaError(.fileWriteVolumeReadOnly) as NSError]), true),
    (CocoaError(.fileWriteNoPermission) as any Error, false),
    // A full disk or quota is not a read-only volume, at any depth.
    (NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT)), false),
    (NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                                                      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))])]), false),
    (NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)), false),
    (NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), false),
    (CancellationError() as any Error, false),
])
func aReadOnlyVolumeIsToldApartFromAMissingGrant(_ error: any Error, _ expected: Bool) {
    #expect(ExtractHereService.isReadOnlyVolume(error) == expected)
}

// MARK: - Placement

@MainActor @Test func aSingleFileLandsNextToTheArchiveAsItIs() async throws {
    let archive = try makeArchiveFolder("report.pdf.zip")
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }

    let placed = try await extractHere(nil, from: makeModel([file("report.pdf")]), archive: archive)

    #expect(placed == directory.appendingPathComponent("report.pdf"))
    #expect(try snapshot(directory) == ["report.pdf.zip": "archive", "report.pdf": "report.pdf"])
}

@MainActor @Test func aSingleFolderLandsWithItsContents() async throws {
    let archive = try makeArchiveFolder("macos-finder.zip")
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }

    let placed = try await extractHere(nil, from: makeModel(ExtractHereListings.macOSFinder), archive: archive)

    #expect(placed.lastPathComponent == "Project")
    #expect(placed.hasDirectoryPath)
    // Hidden metadata is never written.
    #expect(try snapshot(directory) == [
        "macos-finder.zip": "archive", "Project": "dir", "Project/docs": "dir",
        "Project/docs/readme.md": "Project/docs/readme.md", "Project/hello.txt": "Project/hello.txt",
    ])
}

@MainActor @Test func aTakenFileNameGetsFindersNextName() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeFile("report.pdf", in: directory, contents: "mine")

    let placed = try await extractHere(nil, from: makeModel([file("report.pdf")]), archive: archive)

    #expect(placed.lastPathComponent == "report 2.pdf")
    #expect(try snapshot(directory) == ["project.zip": "archive", "report.pdf": "mine", "report 2.pdf": "report.pdf"])
}

@MainActor @Test func aTakenFolderNameGetsFindersNextName() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeFile("project/mine.txt", in: directory, contents: "mine")

    let placed = try await extractHere(nil, from: makeModel(ExtractHereListings.project), archive: archive)

    #expect(placed.lastPathComponent == "project 2")
    #expect(try contents(of: directory.appendingPathComponent("project/mine.txt")) == "mine")
    #expect(try contents(of: placed.appendingPathComponent("src/main.swift")) == "src/main.swift")
}

@MainActor @Test func aWrappedResultHoldsTheArchivePaths() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }

    let placed = try await extractHere(["assets/logo.svg", "src/main.swift"],
                                       from: makeModel(ExtractHereListings.project), archive: archive)

    #expect(placed == directory.appendingPathComponent("project", isDirectory: true))
    #expect(try snapshot(directory) == [
        "project.zip": "archive", "project": "dir", "project/assets": "dir", "project/src": "dir",
        "project/assets/logo.svg": "assets/logo.svg", "project/src/main.swift": "src/main.swift",
    ])
}

@MainActor @Test func oneNestedItemComesOutOnItsOwn() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel([folder("a"), folder("a/b"), file("a/b/report.pdf"), file("a/other.txt")])

    let placed = try await extractHere(["a/b/report.pdf"], from: model, archive: archive)

    #expect(placed.lastPathComponent == "report.pdf")
    #expect(try snapshot(directory) == ["project.zip": "archive", "report.pdf": "a/b/report.pdf"])
}

// MARK: - Case twins

/// Says the destination folds case, whatever the disk is (local volumes fold case anyway).
private let foldsCase = DestinationCaseSensitivity(exists: { _ in true }, supportsCaseSensitiveNames: { _ in false })

/// Case-only twins ("README", "Readme") on a case-insensitive volume: Extract Here never asks and
/// never throws; the later twin takes the dialog's Keep Both name ("Readme 2"), as Keep Both does.
@MainActor @Test func caseTwinsAreBothKeptInAWrappedResult() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try #require(isCaseInsensitive(directory))
    let model = makeModel([file("README"), file("Readme"), file("other.txt")])
    model.caseSensitivity = foldsCase

    let placed = try await extractHere(nil, from: model, archive: archive)

    #expect(placed.lastPathComponent == "project")
    #expect(try snapshot(placed) == ["README": "README", "Readme 2": "Readme", "other.txt": "other.txt"])
}

/// The same inside one folder placed on its own (`.single`).
@MainActor @Test func caseTwinsAreBothKeptInASingleFolder() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try #require(isCaseInsensitive(directory))
    let model = makeModel([folder("docs"), file("docs/README"), file("docs/Readme")])
    model.caseSensitivity = foldsCase

    let placed = try await extractHere(nil, from: model, archive: archive)

    #expect(placed.lastPathComponent == "docs")
    #expect(try snapshot(placed) == ["README": "docs/README", "Readme 2": "docs/Readme"])
}

/// A real "Readme 2" in the archive is never taken by the twin: it keeps its own bytes, and the
/// twin numbers on to "Readme 3".
@MainActor @Test func aCaseTwinSkipsAKeepBothNameTheArchiveHolds() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try #require(isCaseInsensitive(directory))
    let model = makeModel([file("README"), file("Readme"), file("Readme 2")])
    model.caseSensitivity = foldsCase

    let placed = try await extractHere(nil, from: model, archive: archive)

    #expect(placed.lastPathComponent == "project")
    #expect(try snapshot(placed) == ["README": "README", "Readme 2": "Readme 2", "Readme 3": "Readme"])
}

/// A file and a folder whose names differ only by case ("Docs", "docs/"), wrapped: the later one,
/// the folder, is kept as "docs 2" with its contents, as `fileFolderTwin` does in the model.
@MainActor @Test func aFileFolderCaseTwinIsKeptInAWrappedResult() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try #require(isCaseInsensitive(directory))
    let model = makeModel([file("Docs"), folder("docs"), file("docs/x.txt")])
    model.caseSensitivity = foldsCase

    let placed = try await extractHere(nil, from: model, archive: archive)

    #expect(placed.lastPathComponent == "project")
    #expect(try snapshot(placed) == ["Docs": "Docs", "docs 2": "dir", "docs 2/x.txt": "docs/x.txt"])
}

/// Keep Both for every conflict is given only in the fresh hidden folder (or a child of it, missing or
/// empty), in release builds too: anywhere else nothing is answered, so a conflict stays a conflict
/// (the checks were debug-only asserts).
@MainActor @Test func keepBothForEveryConflictOnlyInAFreshStagingFolder() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExtractHereServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel([file("README"), file("Readme")])
    model.caseSensitivity = foldsCase
    let paths = ["README", "Readme"]
    func answers(in destination: URL, staging outer: URL) -> [String: ExtractionConflictResolution] {
        ExtractHereService.keepBothTwins(paths, of: model, in: destination, staging: outer)
    }
    let outer = directory.appendingPathComponent(
        "\(ArchiveModel.stagingPrefix)\(testDeviceToken)-\(getpid())-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: false)
    let child = outer.appendingPathComponent("project", isDirectory: true)

    #expect(answers(in: outer, staging: outer) == ["Readme": .keepBoth])
    #expect(answers(in: child, staging: outer) == ["Readme": .keepBoth], "a child not made yet")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
    #expect(answers(in: child, staging: outer) == ["Readme": .keepBoth], "an empty child")

    // Not a staging folder, deeper than its child, or a link: nothing answered.
    let plain = directory.appendingPathComponent("plain", isDirectory: true)
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
    #expect(answers(in: plain, staging: plain).isEmpty)
    #expect(answers(in: child.appendingPathComponent("deeper"), staging: outer).isEmpty)
    let link = outer.appendingPathComponent("link", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: plain)
    #expect(answers(in: link, staging: outer).isEmpty)
    // A child that holds an item: its conflict (README on disk) is never answered Keep Both.
    try makeFile("README", in: child, contents: "the user's")
    #expect(model.extractionConflicts(paths, in: child).contains("README"))
    #expect(answers(in: child, staging: outer).isEmpty)
    // The staging folder itself, no longer empty (it holds the child): nothing answered.
    #expect(answers(in: outer, staging: outer).isEmpty)
}

@MainActor @Test func pendingAdditionsAreExtractedAsTheUserSeesThem() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let added = try makeFile("elsewhere/notes.txt", in: FileManager.default.temporaryDirectory
        .appendingPathComponent("ExtractHereServiceTests-\(UUID().uuidString)"), contents: "added")
    defer { try? FileManager.default.removeItem(at: added.deletingLastPathComponent().deletingLastPathComponent()) }
    let model = makeModel([file("report.pdf")])
    model.add([added], to: "")

    let placed = try await extractHere(nil, from: model, archive: archive)

    #expect(placed.lastPathComponent == "project")
    #expect(try snapshot(placed) == ["notes.txt": "added", "report.pdf": "report.pdf"])
}

@MainActor @Test func aNameTakenDuringExtractionIsNeverReplaced() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let reader = GatedReader(base: FakeReader(entries: [file("report.pdf")])) {
        try makeFile("report.pdf", in: directory, contents: "arrived meanwhile")
    }

    let placed = try await extractHere(nil, from: makeModel([], reader: reader), archive: archive)

    #expect(placed.lastPathComponent == "report 2.pdf")
    #expect(try snapshot(directory) == ["project.zip": "archive", "report.pdf": "arrived meanwhile",
                                        "report 2.pdf": "report.pdf"])
}

@MainActor @Test func aNameTakenAtTheFinalRenameIsNeverReplaced() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let newcomer = directory.appendingPathComponent("report.pdf").path
    let fileSystem = fakeFileSystem { _, to, _ in
        guard to == newcomer, !FileManager.default.fileExists(atPath: newcomer) else { return nil }
        FileManager.default.createFile(atPath: newcomer, contents: Data("newcomer".utf8))
        return EEXIST
    }

    let placed = try await extractHere(nil, from: makeModel([file("report.pdf")], fileSystem: fileSystem),
                                       archive: archive)

    #expect(placed.lastPathComponent == "report 2.pdf")
    #expect(try snapshot(directory) == ["project.zip": "archive", "report.pdf": "newcomer",
                                        "report 2.pdf": "report.pdf"])
}

/// ENOTSUP, or EOPNOTSUPP (a separate number on Darwin).
@MainActor @Test(arguments: [ENOTSUP, EOPNOTSUPP])
func withoutExclusiveRenamesItStillNeverReplaces(_ code: Int32) async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeFile("project/mine.txt", in: directory, contents: "mine")
    let fileSystem = fakeFileSystem { _, _, flags in flags == UInt32(RENAME_EXCL) ? code : nil }

    let placed = try await extractHere(nil, from: makeModel(ExtractHereListings.project, fileSystem: fileSystem),
                                       archive: archive)

    #expect(placed.lastPathComponent == "project 2")
    #expect(try contents(of: directory.appendingPathComponent("project/mine.txt")) == "mine")
    #expect(try contents(of: placed.appendingPathComponent("README.md")) == "README.md")
}

// MARK: - Nothing left behind

@MainActor @Test func cancellingMidwayLeavesTheFolderAsItWas() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeFile("report.pdf", in: directory, contents: "mine")
    let before = try snapshot(directory)
    let probe = SuspendingReaderProbe()
    let model = makeModel([], reader: SuspendingReader(entries: ExtractHereListings.project, probe: probe))
    let plan = try #require(ExtractHerePlan.make(nil, in: model, archiveURL: archive))

    let task = Task { try await ExtractHereService.extract(plan, from: model, nextTo: archive, progress: nil) }
    // Bounded, so a reader that never starts fails the test instead of hanging the run.
    let deadline = ContinuousClock.now + .seconds(10)
    while probe.started == 0 {
        guard ContinuousClock.now < deadline else {
            Issue.record("The reader didn't start within 10 seconds")
            task.cancel()
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    // While it runs, the only new item is one hidden folder named as the model's staging is, so a
    // sweep can recognize a crash's remnant.
    let during = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { before[$0] == nil }
    #expect(during.count == 1)
    let fields = try #require(during.first).dropFirst(".kernir-".count).split(separator: "-", maxSplits: 2)
    #expect(during.first?.hasPrefix(".kernir-") == true)
    #expect(fields.count == 3 && fields[0] == testDeviceToken && fields[1] == "\(getpid())"
                && UUID(uuidString: String(fields[2])) != nil)
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(probe.cancelled == 1)
    #expect(try snapshot(directory) == before)
}

@MainActor @Test func cancellingAfterTheReaderWroteEverythingLeavesNothing() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let before = try snapshot(directory)
    let (written, wroteAll) = AsyncStream.makeStream(of: Void.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    let reader = GatedReader(base: FakeReader(entries: ExtractHereListings.project)) {
        wroteAll.yield()
        for await _ in released { break }
    }
    let model = makeModel([], reader: reader)
    let plan = try #require(ExtractHerePlan.make(nil, in: model, archiveURL: archive))

    let task = Task { try await ExtractHereService.extract(plan, from: model, nextTo: archive, progress: nil) }
    for await _ in written { break }
    task.cancel()
    release.yield()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try snapshot(directory) == before)
}

@MainActor @Test func aFailingReaderLeavesTheFolderAsItWas() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let before = try snapshot(directory)
    let reader = GatedReader(base: FakeReader(entries: ExtractHereListings.project)) {
        throw ArchiveError.corrupted("bad block")
    }

    await #expect(throws: ArchiveError.corrupted("bad block")) {
        try await extractHere(nil, from: makeModel([], reader: reader), archive: archive)
    }
    #expect(try snapshot(directory) == before)
}

@MainActor @Test func aFailedFinalRenameLeavesNothingVisible() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let before = try snapshot(directory)
    // Only the move out next to the archive fails; the model's own moves inside staging work.
    let fileSystem = fakeFileSystem { _, to, _ in
        (to as NSString).deletingLastPathComponent == directory.path ? EIO : nil
    }

    await #expect(throws: POSIXError(.EIO)) {
        try await extractHere(nil, from: makeModel(ExtractHereListings.project, fileSystem: fileSystem),
                              archive: archive)
    }
    #expect(try snapshot(directory) == before)
}

/// A cancel that lands while the model moves its result out of its own staging (after the model's
/// last check) is caught by the service's own check: nothing is put in place.
@MainActor @Test func aCancelDuringTheModelsMoveIsCaughtBeforeThePlacement() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let before = try snapshot(directory)
    let box = TaskBox()
    // The model's moves go into the hidden outer folder; the service's final one goes to `directory`.
    let fileSystem = fakeFileSystem { _, to, _ in
        if (to as NSString).deletingLastPathComponent != directory.path { box.cancel() }
        return nil
    }
    let model = makeModel(ExtractHereListings.project, fileSystem: fileSystem)
    let plan = try #require(ExtractHerePlan.make(nil, in: model, archiveURL: archive))

    let task = Task { try await ExtractHereService.extract(plan, from: model, nextTo: archive, progress: nil) }
    box.set(task)

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(box.cancels > 0)
    #expect(try snapshot(directory) == before)
}

/// The hidden folder goes off the main thread (a big tree takes a while), and it still goes before
/// `extract` returns: after a success, a failed final rename and a late cancel.
@MainActor @Test func theHiddenFolderIsRemovedOffTheMainThreadBeforeReturning() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let removals = Removals()
    let model = makeModel(ExtractHereListings.project)
    let plan = try #require(ExtractHerePlan.make(nil, in: model, archiveURL: archive))

    let placed = try await ExtractHereService.extract(plan, from: model, nextTo: archive, progress: nil,
                                                      removeItem: removals.remove)
    #expect(removals.onMainThread == [false])
    #expect(try snapshot(directory).keys.filter { $0.hasPrefix(".") }.isEmpty)
    try FileManager.default.removeItem(at: placed)
    let before = try snapshot(directory)

    let failing = makeModel(ExtractHereListings.project, fileSystem: fakeFileSystem { _, to, _ in
        (to as NSString).deletingLastPathComponent == directory.path ? EIO : nil
    })
    await #expect(throws: POSIXError(.EIO)) {
        try await ExtractHereService.extract(plan, from: failing, nextTo: archive, progress: nil,
                                             removeItem: removals.remove)
    }
    #expect(removals.onMainThread == [false, false])
    #expect(try snapshot(directory) == before)

    let box = TaskBox()
    let cancelling = makeModel(ExtractHereListings.project, fileSystem: fakeFileSystem { _, to, _ in
        if (to as NSString).deletingLastPathComponent != directory.path { box.cancel() }
        return nil
    })
    let task = Task {
        try await ExtractHereService.extract(plan, from: cancelling, nextTo: archive, progress: nil,
                                             removeItem: removals.remove)
    }
    box.set(task)
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(removals.onMainThread == [false, false, false])
    #expect(try snapshot(directory) == before)
}

@MainActor @Test func progressReachesTheCaller() async throws {
    let archive = try makeArchiveFolder()
    let directory = archive.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = makeModel(ExtractHereListings.project)
    let plan = try #require(ExtractHerePlan.make(nil, in: model, archiveURL: archive))
    let fractions = Fractions()

    _ = try await ExtractHereService.extract(plan, from: model, nextTo: archive) { fraction, _ in
        fractions.append(fraction)
    }

    let values = fractions.values
    #expect(values.count > 1)
    #expect(values == values.sorted())
    #expect(values.last == 1)
}

private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    var values: [Double] { lock.withLock { stored } }
    func append(_ value: Double) { lock.withLock { stored.append(value) } }
}


/// Holds a task so a fake rename can cancel it; counts the cancels.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<URL, any Error>?
    private var count = 0
    var cancels: Int { lock.withLock { count } }
    func set(_ task: Task<URL, any Error>) { lock.withLock { self.task = task } }
    func cancel() {
        lock.withLock {
            count += 1
            task?.cancel()
        }
    }
}

/// Removes for real and records whether each removal ran on the main thread.
private final class Removals: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    var onMainThread: [Bool] { lock.withLock { stored } }
    var remove: @Sendable (URL) throws -> Void {
        { url in
            self.lock.withLock { self.stored.append(pthread_main_np() != 0) }
            try FileManager.default.removeItem(at: url)
        }
    }
}

#if os(macOS)
/// In the sandbox, moving the result out of the hidden folder drops its quarantine (probe on macOS 26,
/// 2026-11-16): the service marks the placed item again. `place` here hands back a fresh copy, as that
/// move leaves it.
@MainActor @Test func extractHereQuarantinesThePlacedItemOfADownloadedArchive() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExtractHereQuarantine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = try await writeQuarantineSample(in: dir, quarantined: true)
    let model = ArchiveModel(reader: try await Archive.open(at: archive), undoManager: nil)
    let folder = dir.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

    let placed = try await ExtractHereService.extract(.single(path: "proj/a.txt", name: "a.txt", isDirectory: false),
                                                      from: model, stagingIn: folder, for: folder, progress: nil) {
        result, name, _ in
        let fresh = folder.appendingPathComponent(name)
        try Data(contentsOf: result).write(to: fresh)
        #expect(try quarantineEvent(of: fresh) == nil)
        return fresh
    }

    #expect(try quarantineEvent(of: placed) == sampleQuarantineEvent)
}
#endif
