import Testing
import Foundation
import UniformTypeIdentifiers
@testable import Kernir
import KernirCore

// A row dragged out of a Mac archive window as a file promise (`ArchiveDragOut`): the type the
// promise announces, and the file work when Finder asks for it. The work is Extract Here's staging
// (`ExtractHereService.extract(_:from:stagingIn:for:)`) in a hidden `.kernir-` folder of the temporary
// folder, then one exclusive move (or, across volumes, an exclusive copy) to exactly the URL Finder
// gives, never replacing anything: a sandboxed drop may touch that URL and nothing else
// in the drop folder, so nothing there is listed, swept or made but the promised item.
// A symlink planted at the staging path is covered below by calling `makeStagingFolder` (the real
// name has a fresh UUID, so a test can't predict it), its 0700 mode by ExtractHereStagingModeTests.
// Not covered here: the real sandbox (a promise's grant covers only Finder's URL) and a real
// cross-volume drop (EXDEV is simulated through the rename seam). The hidden folder going away after
// a cancel or a failure is ExtractHereService's own, covered by ExtractHereServiceTests; the checks
// below repeat it for the drag's own entry point.

// MARK: - Helpers

private let testDeviceToken = "d4a90d4a90d4a900"

private func file(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
}

private func folder(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
}

private let project: [ArchiveEntry] = [
    file("README.md"), folder("src"), file("src/main.swift"), folder("src/lib"), file("src/lib/util.swift"),
    folder("docs"), file("docs/report.pdf"),
]

/// renamex_np(2) as `ExtractionFileSystem.system` has it, without reading `.system` (its device
/// token lives in the standard defaults); `rule` answers first when it returns non-nil.
private func fileSystem(token: String = testDeviceToken,
                        _ rule: @escaping @Sendable (_ from: String, _ to: String, _ flags: UInt32) -> Int32? = { _, _, _ in nil })
    -> ExtractionFileSystem {
    ExtractionFileSystem(deviceToken: token) { from, to, flags in
        if let answer = rule(from, to, flags) { return answer }
        return renamex_np(from, to, flags) == 0 ? 0 : errno
    }
}

@MainActor
private func makeModel(_ entries: [ArchiveEntry] = project, reader: (any ArchiveReading)? = nil,
                       fileSystem: ExtractionFileSystem = fileSystem()) -> ArchiveModel {
    let model = ArchiveModel(reader: reader ?? FakeReader(entries: entries), undoManager: nil)
    model.extractionFileSystem = fileSystem
    return model
}

/// A fresh empty folder standing for the drop's destination; the caller removes it.
private func makeDestination() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveDragOutTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func makeFile(_ name: String, in directory: URL, contents: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
}

private func contents(of url: URL) throws -> String {
    String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

/// Everything under `directory`, hidden items included: "dir" for folders, "link" for symlinks,
/// else the contents. By lstat, so a dangling symlink shows.
private func snapshot(_ directory: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for relative in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
        let url = directory.appendingPathComponent(relative)
        var status = stat()
        guard lstat(url.path, &status) == 0 else { continue }
        switch status.st_mode & S_IFMT {
        case S_IFDIR: result[relative] = "dir"
        case S_IFLNK: result[relative] = "link"
        default: result[relative] = try contents(of: url)
        }
    }
    return result
}

/// Names directly in `directory` that start with the model's staging prefix.
private func stagingLeft(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix(ArchiveModel.stagingPrefix) }
}

/// The URL Finder hands the promise: the destination folder plus the file name it was given.
private func promised(_ name: String, in directory: URL) -> URL {
    directory.appendingPathComponent(name)
}

/// The hidden staging folder an extraction into `directory` went through: the `.kernir-` folder
/// of the temporary folder `directory` is in (or is), nil when it is in none.
private func stagingFolder(of directory: URL) -> URL? {
    let temporary = FileManager.default.temporaryDirectory
    let resolved = temporary.resolvingSymlinksInPath().path
    let roots = Set([temporary.path, temporary.standardizedFileURL.path, resolved, "/private" + resolved])
        .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
    let path = directory.standardizedFileURL.path
    for root in roots where path.hasPrefix(root + "/") {
        guard let first = path.dropFirst(root.count + 1).split(separator: "/").first,
              first.hasPrefix(ArchiveModel.stagingPrefix) else { return nil }
        return URL(fileURLWithPath: root).appendingPathComponent(String(first), isDirectory: true)
    }
    return nil
}

/// Something is at `url` (lstat: a dangling symlink counts).
private func exists(_ url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0
}

/// `ArchiveDragOut.write`'s result or error.
@MainActor
private func writeOutcome(_ path: String, from model: ArchiveModel, toPromised url: URL) async -> Result<URL, any Error> {
    do {
        return .success(try await ArchiveDragOut.write(path, from: model, toPromised: url))
    } catch {
        return .failure(error)
    }
}

/// `body` throws Cocoa's file-exists error.
@MainActor
private func expectFileExists(_ body: () async throws -> URL, sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        let placed = try await body()
        Issue.record("must throw, placed \(placed.path)", sourceLocation: sourceLocation)
    } catch {
        let nsError = error as NSError
        #expect(nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileWriteFileExists.rawValue,
                "\(error)", sourceLocation: sourceLocation)
    }
}

/// Lists the given entries; extracting fails with `error` once everything is written.
private struct FailingReader: ArchiveReading {
    let base: FakeReader
    let error: ArchiveError

    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        try await base.extract(paths, to: directory, progress: progress)
        throw error
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        try await base.extractToTemporaryFile(path)
    }
}

/// FakeReader that waits, once everything is written, until `release` is called; `written` yields then.
private struct GatedReader: ArchiveReading {
    let base: FakeReader
    /// Records where the engine extracts, when given.
    var spy: ReaderSpy?
    let afterWrite: @Sendable () async throws -> Void

    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        spy?.extracted(to: directory)
        try await base.extract(paths, to: directory, progress: progress)
        try await afterWrite()
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        try await base.extractToTemporaryFile(path)
    }
}

/// Every rename's target, in order.
private final class Renames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var targets: [String] { lock.withLock { stored } }
    func append(_ target: String) { lock.withLock { stored.append(target) } }
}

/// Records where the engine is asked to extract and every `extractToTemporaryFile` call (what
/// `ArchiveModel.localFileURL` uses for a file); the latter fails the test and throws.
private final class ReaderSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var directories: [URL] = []
    private var temporaryFileCalls: [String] = []
    var extractDirectories: [URL] { lock.withLock { directories } }
    var temporaryFilePaths: [String] { lock.withLock { temporaryFileCalls } }
    func extracted(to directory: URL) { lock.withLock { directories.append(directory) } }
    func temporaryFile(_ path: String) { lock.withLock { temporaryFileCalls.append(path) } }
}

private struct SpyReader: ArchiveReading {
    let base: any ArchiveReading
    let spy: ReaderSpy

    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        spy.extracted(to: directory)
        try await base.extract(paths, to: directory, progress: progress)
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        spy.temporaryFile(path)
        throw ArchiveError.entryNotFound(path)
    }
}

/// FakeReader, then `shape` on the folder it extracted into: what an archive can hold and the fake
/// can't write (a symlink, a read-only folder, an unreadable file).
private struct ShapedReader: ArchiveReading {
    let base: FakeReader
    let shape: @Sendable (_ directory: URL) throws -> Void

    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        try await base.extract(paths, to: directory, progress: progress)
        try shape(directory)
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        try await base.extractToTemporaryFile(path)
    }
}

/// Every path any seam of an `ExtractionFileSystem` was given, in order.
private final class SeamPaths: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var paths: [String] { lock.withLock { stored } }
    func record(_ paths: String...) { lock.withLock { stored += paths } }
}

/// `fileSystem(rule)` with every seam (rename's both paths, exists, isGone, listNames, identity and
/// the case-sensitivity lookups) recording what it is asked about in `seen`.
private func recordingFileSystem(_ seen: SeamPaths,
                                 _ rule: @escaping @Sendable (_ from: String, _ to: String, _ flags: UInt32) -> Int32?
                                     = { _, _, _ in nil }) -> ExtractionFileSystem {
    var recording = fileSystem { from, to, flags in
        seen.record(from, to)
        return rule(from, to, flags)
    }
    let (exists, isGone, listNames, identity) = (recording.exists, recording.isGone, recording.listNames, recording.identity)
    let caseSensitivity = recording.caseSensitivity
    recording.exists = { seen.record($0); return exists($0) }
    recording.isGone = { seen.record($0); return isGone($0) }
    recording.listNames = { seen.record($0); return try listNames($0) }
    recording.identity = { seen.record($0); return try identity($0) }
    recording.caseSensitivity = DestinationCaseSensitivity(
        exists: { seen.record($0.path); return caseSensitivity.exists($0) },
        supportsCaseSensitiveNames: { seen.record($0.path); return caseSensitivity.supportsCaseSensitiveNames($0) })
    return recording
}

/// `path` standardized, a leading "/private" dropped (the temporary folder has both spellings).
private func normalized(_ path: String) -> String {
    let standard = URL(fileURLWithPath: path).standardizedFileURL.path
    return standard.hasPrefix("/private/") ? String(standard.dropFirst("/private".count)) : standard
}

/// Removes `url` with everything in it, read-only folders included.
private func removeTree(_ url: URL) {
    if let paths = FileManager.default.subpaths(atPath: url.path) {
        for relative in paths { _ = lchmod(url.appendingPathComponent(relative).path, 0o700) }
    }
    _ = chmod(url.path, 0o700)
    try? FileManager.default.removeItem(at: url)
}

/// The mode bits of the item at `url` (lstat).
private func mode(_ url: URL) -> mode_t {
    var status = stat()
    return lstat(url.path, &status) == 0 ? status.st_mode & 0o7777 : 0
}

/// A rename seam that answers EXDEV for a move into `destination`, as a drop on another volume does.
private func crossVolume(into destination: URL) -> @Sendable (String, String, UInt32) -> Int32? {
    let folder = destination.path
    return { _, to, _ in (to as NSString).deletingLastPathComponent == folder ? EXDEV : nil }
}

// MARK: - The promised type

@Test(arguments: [
    ("report.pdf", false, UTType.pdf),
    ("photo.JPG", false, UTType.jpeg),
    ("notes.txt", false, UTType.plainText),
    ("archive.tar.gz", false, UTType(filenameExtension: "gz")!),
    ("Makefile", false, UTType.data),
    (".hidden", false, UTType.data),
    ("src", true, UTType.folder),
    ("Photos.app", true, UTType.folder),
    ("report.pdf", true, UTType.folder),
    // AppKit takes only a type conforming to public.data or public.directory.
    ("x.zip", true, UTType.folder),
    ("x.zip", false, UTType.zip),
])
func contentTypeFollowsTheNameAndKind(_ name: String, _ isDirectory: Bool, _ expected: UTType) {
    #expect(ArchiveDragOut.contentType(name: name, isDirectory: isDirectory) == expected)
}

/// An extension the system has no type for still gives a type of its own (a dynamic one), as on
/// iOS; only an empty extension falls back to .data.
@Test func anUnknownExtensionGetsADynamicType() {
    let type = ArchiveDragOut.contentType(name: "data.kernirunknownext", isDirectory: false)
    #expect(type == UTType(filenameExtension: "kernirunknownext"))
    #expect(type.isDynamic)
}

/// A bundle's extension on a file ("x.app", "Notes.rtfd" as plain files): UTType(filenameExtension:)
/// answers with a type conforming to public.data (com.apple.application-file for "app", a dynamic
/// one otherwise), never the bundle type, which AppKit would refuse as a promise of a file.
@Test(arguments: ["x.app", "Notes.rtfd", "Kit.framework", "A.bundle", "B.kext"])
func aBundleExtensionOnAFileIsStillData(_ name: String) {
    let type = ArchiveDragOut.contentType(name: name, isDirectory: false)
    #expect(type.conforms(to: .data))
    #expect(!type.conforms(to: .directory))
    #expect(!type.conforms(to: .package))
}

/// Whatever the name, the type conforms to public.data (a file) or public.directory (a folder).
@Test(arguments: ["app", "bundle", "framework", "rtfd", "pages", "key", "photoslibrary", "kext", "plugin",
                  "xcodeproj", "pkg", "dmg", "zip", "txt", "", "kernirunknownext", "public.item"])
func contentTypeIsAlwaysDataOrAFolder(_ ext: String) {
    let name = ext.isEmpty ? "file" : "file.\(ext)"
    #expect(ArchiveDragOut.contentType(name: name, isDirectory: false).conforms(to: .data))
    #expect(ArchiveDragOut.contentType(name: name, isDirectory: true).conforms(to: .directory))
}

@Test(arguments: [
    ("report.pdf", true), ("a:b.txt", true), ("cafe\u{301}.txt", true), (".hidden", true), ("...", true),
    ("", false), (".", false), ("..", false), ("a/b", false), ("/", false),
    (String(repeating: "a", count: 255), true), (String(repeating: "a", count: 256), false),
    (String(repeating: "\u{E9}", count: 127), true), (String(repeating: "\u{E9}", count: 128), false),
    ("a\0b", false), ("\0", false), ("report.pdf\0", false),
])
func promisedNamesAreChecked(_ name: String, _ valid: Bool) {
    #expect(ArchiveDragOut.isValidFileName(name) == valid)
}

/// The name offered to Finder is the item's own, made usable when the archive's isn't: "/" and NUL as
/// ":" and "_", "." and ".." as "_" and "__", too long cut to 255 bytes keeping a short extension.
/// Whatever the entry, the result is a name `isValidFileName` accepts.
@Test(arguments: [
    ("README.md", "README.md"), ("docs/report.pdf", "report.pdf"), ("src/", "src"), ("a/b:c", "b:c"),
    ("/", ":"), ("", "_"), (".", "_"), ("..", "__"), ("dir/..", "__"), ("a/.", "_"), ("...", "..."), (".hidden", ".hidden"),
    ("a\0b.txt", "a_b.txt"), ("\0", "_"),
    // The last component is cut on the "/" scalar: a "/" followed by a combining mark or a ZWJ is one
    // Character ("/\u{301}"), but still a separator; a format character in a folder name is no separator.
    ("d/\u{301}x", "\u{301}x"), ("d/\u{200D}x", "\u{200D}x"), ("d\u{600}/x", "x"), ("d\u{600}/x/y", "y"),
    ("d/x\u{600}/y", "y"), ("d/e/\u{301}x", "\u{301}x"), ("a/b.txt", "b.txt"), ("top", "top"), ("e\u{301}/f", "f"),
])
func theOfferedNameIsUsable(_ path: String, _ expected: String) {
    #expect(ArchiveDragOut.offeredName(forPath: path) == expected)
    #expect(ArchiveDragOut.isValidFileName(ArchiveDragOut.offeredName(forPath: path)))
}

@Test func aTooLongNameIsCutToFitKeepingItsExtension() {
    let long = String(repeating: "a", count: 300)
    let cut = ArchiveDragOut.offeredName(forPath: "dir/\(long).pdf")
    #expect(cut.utf8.count == 255)
    #expect(cut.hasSuffix(".pdf"))
    #expect(cut.hasPrefix("aaa"))
    #expect(ArchiveDragOut.isValidFileName(cut))

    // Whole characters only: never half of a two-byte one, nor of a combining sequence.
    let accents = String(repeating: "e\u{301}", count: 200) + ".txt"
    let accented = ArchiveDragOut.offeredName(forPath: accents)
    #expect(accented.utf8.count <= 255 && accented.hasSuffix(".txt"))
    #expect(accented.unicodeScalars.last != "\u{301}")
    #expect(ArchiveDragOut.isValidFileName(accented))
    #expect(String(accented.dropLast(4)).allSatisfy { $0 == "e\u{301}" })

    // An extension too long to keep is cut with the rest.
    let hugeExtension = "x." + String(repeating: "b", count: 300)
    let cutAll = ArchiveDragOut.offeredName(forPath: hugeExtension)
    #expect(cutAll.utf8.count <= 255 && ArchiveDragOut.isValidFileName(cutAll))

    // One character that alone exceeds a name's limit.
    let zalgo = "a" + String(repeating: "\u{301}", count: 200)
    #expect(ArchiveDragOut.isValidFileName(ArchiveDragOut.offeredName(forPath: zalgo)))
}

/// A cancel reports Cocoa's user-cancelled error (no alert); anything else goes out as it is.
@Test func aCancelIsReportedAsUserCancelled() {
    let cancelled = ArchiveDragOut.promiseError(for: CancellationError()) as NSError
    #expect(cancelled.domain == NSCocoaErrorDomain && cancelled.code == CocoaError.userCancelled.rawValue)
    for error: any Error in [POSIXError(.ENOSPC), POSIXError(.EDQUOT), POSIXError(.EROFS), POSIXError(.EPERM),
                             ArchiveError.entryNotFound("x"), ArchiveError.wrongPassword,
                             ExtractionContainmentError(name: "x", destination: URL(fileURLWithPath: "/tmp"))] {
        let reported = ArchiveDragOut.promiseError(for: error) as NSError
        #expect(reported.domain == (error as NSError).domain && reported.code == (error as NSError).code)
    }
}

// MARK: - Writing the promise

@MainActor @Test func aFileLandsInTheDropFolderUnderItsName() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }

    let placed = try await ArchiveDragOut.write("README.md", from: makeModel(),
                                                toPromised: promised("README.md", in: destination))

    #expect(placed.standardizedFileURL == destination.appendingPathComponent("README.md").standardizedFileURL)
    #expect(try snapshot(destination) == ["README.md": "README.md"])
}

@MainActor @Test func aFolderLandsWithItsWholeTree() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }

    let placed = try await ArchiveDragOut.write("src", from: makeModel(), toPromised: promised("src", in: destination))

    #expect(placed.lastPathComponent == "src")
    #expect(placed.hasDirectoryPath)
    #expect(try snapshot(destination) == [
        "src": "dir", "src/main.swift": "src/main.swift", "src/lib": "dir", "src/lib/util.swift": "src/lib/util.swift",
    ])
}

/// A nested row comes out on its own, without the folders above it, file or folder.
@MainActor @Test func aNestedRowComesOutOnItsOwn() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let model = makeModel()

    let file = try await ArchiveDragOut.write("src/lib/util.swift", from: model,
                                              toPromised: promised("util.swift", in: destination))
    let folder = try await ArchiveDragOut.write("src/lib", from: model, toPromised: promised("lib", in: destination))

    #expect(file.lastPathComponent == "util.swift")
    #expect(folder.lastPathComponent == "lib")
    #expect(try snapshot(destination) == [
        "util.swift": "src/lib/util.swift", "lib": "dir", "lib/util.swift": "src/lib/util.swift",
    ])
}

/// The item lands exactly at Finder's URL, whatever name it has there ("Always use the supplied
/// URL"): another name, a ":" (a hidden "/" as Finder shows it), an NFD spelling kept as given.
@MainActor @Test(arguments: ["Untitled", "a:b.pdf", "cafe\u{301}.pdf"])
func theItemLandsAtThePromisedURL(_ name: String) async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let url = promised(name, in: destination)

    let placed = try await ArchiveDragOut.write("docs/report.pdf", from: makeModel(), toPromised: url)

    #expect(placed.standardizedFileURL == url.standardizedFileURL)
    let listed = try FileManager.default.contentsOfDirectory(atPath: destination.path)
    #expect(listed.map { Array($0.unicodeScalars) } == [Array(name.unicodeScalars)])
    #expect(try contents(of: url) == "docs/report.pdf")
}

/// A folder too, at Finder's name.
@MainActor @Test func aFolderLandsAtThePromisedURL() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }

    let placed = try await ArchiveDragOut.write("src", from: makeModel(), toPromised: promised("Sources", in: destination))

    #expect(placed.lastPathComponent == "Sources")
    #expect(try contents(of: destination.appendingPathComponent("Sources/lib/util.swift")) == "src/lib/util.swift")
}

/// A URL whose name can't be a file's: refused before anything is written.
@MainActor @Test(arguments: [".", "..", String(repeating: "n", count: 256)])
func aBadPromisedNameIsRefused(_ name: String) async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }

    await #expect(throws: CocoaError.self) {
        try await ArchiveDragOut.write("README.md", from: makeModel(), toPromised: destination.appendingPathComponent(name))
    }
    #expect(try snapshot(destination).isEmpty)
}

/// A taken name is never replaced and never swapped for another (no "report 2.pdf": the sandbox lets
/// the drop write Finder's URL only): Cocoa's file-exists error, before anything is extracted, and the
/// drop folder stays as it was.
@MainActor @Test func aTakenNameIsRefusedAndLeftAlone() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    try makeFile("report.pdf", in: destination, contents: "mine")
    try FileManager.default.createDirectory(at: destination.appendingPathComponent("src"), withIntermediateDirectories: false)
    let spy = ReaderSpy()
    let model = makeModel(reader: SpyReader(base: FakeReader(entries: project), spy: spy))
    let before = try snapshot(destination)

    await expectFileExists {
        try await ArchiveDragOut.write("docs/report.pdf", from: model, toPromised: promised("report.pdf", in: destination))
    }
    await expectFileExists {
        try await ArchiveDragOut.write("src", from: model, toPromised: promised("src", in: destination))
    }

    #expect(spy.extractDirectories.isEmpty)
    #expect(try snapshot(destination) == before)
}

/// On a case-insensitive volume a case twin in the drop folder takes the name: refused the same way.
@MainActor @Test func aCaseTwinInTheDropFolderIsRefused() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    try #require(isCaseInsensitive(destination), "needs a case-insensitive volume")
    try makeFile("REPORT.PDF", in: destination, contents: "mine")

    await expectFileExists {
        try await ArchiveDragOut.write("docs/report.pdf", from: makeModel(), toPromised: promised("report.pdf", in: destination))
    }

    #expect(try snapshot(destination) == ["REPORT.PDF": "mine"])
}

/// An NFD spelling in the drop folder takes the NFC name where the volume treats them as one
/// (APFS does): refused; elsewhere the item lands under its own name. Nothing is replaced either way.
@MainActor @Test func anNFDTwinInTheDropFolderIsNeverReplaced() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let nfc = "caf\u{E9}.txt", nfd = "cafe\u{301}.txt"
    try makeFile(nfd, in: destination, contents: "mine")
    let folds = exists(destination.appendingPathComponent(nfc))
    let model = makeModel([folder("docs"), file("docs/\(nfc)")])

    if folds {
        await expectFileExists {
            try await ArchiveDragOut.write("docs/\(nfc)", from: model, toPromised: promised(nfc, in: destination))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 1)
    } else {
        let placed = try await ArchiveDragOut.write("docs/\(nfc)", from: model, toPromised: promised(nfc, in: destination))
        #expect(try contents(of: placed) == "docs/\(nfc)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 2)
    }
    #expect(try contents(of: destination.appendingPathComponent(nfd)) == "mine")
}

/// A dangling symlink at the name counts as taken (lstat): refused, and the link left as it was.
@MainActor @Test func aDanglingSymlinkAtTheNameIsLeftAlone() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let link = destination.appendingPathComponent("README.md")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "nowhere/at/all")

    await expectFileExists {
        try await ArchiveDragOut.write("README.md", from: makeModel(), toPromised: promised("README.md", in: destination))
    }

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "nowhere/at/all")
    #expect(try snapshot(destination) == ["README.md": "link"])
}

/// Two rows promised to one URL (Finder never does this; it names each promise apart): the first
/// lands, the second is refused and leaves the first as it was.
@MainActor @Test func aSecondWriteToOneURLIsRefused() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let model = makeModel([folder("a"), file("a/x"), folder("b"), file("b/x")])

    let first = try await ArchiveDragOut.write("a/x", from: model, toPromised: promised("x", in: destination))
    await expectFileExists {
        try await ArchiveDragOut.write("b/x", from: model, toPromised: promised("x", in: destination))
    }

    #expect(first.lastPathComponent == "x")
    #expect(try snapshot(destination) == ["x": "a/x"])
}

/// The same with both writes in flight at once: one lands whole, the other is refused at the
/// exclusive move, and neither leaves staging anywhere.
@MainActor @Test func twoWritesToOneURLInFlightKeepOneWhole() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let spy = ReaderSpy()
    let model = makeModel([folder("a"), file("a/x"), folder("b"), file("b/x")],
                          reader: SpyReader(base: FakeReader(entries: [folder("a"), file("a/x"), folder("b"), file("b/x")]),
                                            spy: spy))

    async let first = writeOutcome("a/x", from: model, toPromised: promised("x", in: destination))
    async let second = writeOutcome("b/x", from: model, toPromised: promised("x", in: destination))
    let results = await [first, second]

    #expect(results.compactMap { try? $0.get() }.count == 1)
    for case let .failure(error) in results {
        #expect((error as NSError).code == CocoaError.fileWriteFileExists.rawValue, "\(error)")
    }
    let left = try snapshot(destination)
    #expect(left.count == 1 && ["a/x", "b/x"].contains(left["x"]))
    for directory in spy.extractDirectories {
        let staging = try #require(stagingFolder(of: directory))
        #expect(!exists(staging), "\(staging.path)")
    }
}

@MainActor @Test func noHiddenFolderIsLeftAfterASuccess() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let spy = ReaderSpy()
    let model = makeModel(reader: SpyReader(base: FakeReader(entries: project), spy: spy))

    _ = try await ArchiveDragOut.write("src", from: model, toPromised: promised("src", in: destination))
    _ = try await ArchiveDragOut.write("README.md", from: model, toPromised: promised("README.md", in: destination))

    #expect(try stagingLeft(in: destination).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted() == ["README.md", "src"])
    #expect(spy.extractDirectories.count == 2)
    for directory in spy.extractDirectories {
        let staging = try #require(stagingFolder(of: directory))
        #expect(!exists(staging), "\(staging.path)")
    }
}

/// A row the model no longer has (removed meanwhile): the entry-not-found error, nothing on disk.
@MainActor @Test func aMissingRowThrowsAndLeavesNothing() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }

    await #expect(throws: ArchiveError.entryNotFound("gone.txt")) {
        try await ArchiveDragOut.write("gone.txt", from: makeModel(), toPromised: promised("gone.txt", in: destination))
    }
    #expect(try snapshot(destination).isEmpty)
}

/// The reader fails after writing (an entry it lists but can't extract): the error comes through
/// and the hidden folder in the temporary folder goes with everything in it.
@MainActor @Test func aFailingExtractionLeavesNothing() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let spy = ReaderSpy()
    let reader = SpyReader(base: FailingReader(base: FakeReader(entries: project), error: .entryNotFound("src/main.swift")),
                           spy: spy)

    await #expect(throws: ArchiveError.entryNotFound("src/main.swift")) {
        try await ArchiveDragOut.write("src", from: makeModel(reader: reader), toPromised: promised("src", in: destination))
    }
    #expect(try snapshot(destination).isEmpty)
    let staging = try #require(spy.extractDirectories.first.flatMap(stagingFolder(of:)))
    #expect(!exists(staging), "\(staging.path)")
}

/// The only rename into the drop folder is the last one, to exactly the promised URL, exclusive
/// (RENAME_EXCL); every other rename stays inside the hidden staging folder in the temporary folder.
@MainActor @Test func theOnlyRenameIntoTheDropFolderIsToThePromisedURL() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let renames = Renames()
    let excl = Renames()
    let model = makeModel(fileSystem: fileSystem { _, to, flags in
        renames.append(to)
        if flags & UInt32(RENAME_EXCL) != 0 { excl.append(to) }
        return nil
    })
    let url = promised("Sources", in: destination)

    let placed = try await ArchiveDragOut.write("src", from: model, toPromised: url)

    #expect(placed.standardizedFileURL.path == url.standardizedFileURL.path)
    let targets = renames.targets.map { URL(fileURLWithPath: $0) }
    #expect(targets.last?.standardizedFileURL.path == url.standardizedFileURL.path)
    #expect(excl.targets.last.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == url.standardizedFileURL.path)
    for target in targets.dropLast() {
        #expect(stagingFolder(of: target) != nil, "\(target.path)")
    }
}

/// Nothing in the drop folder but the promised item is listed, made, swept or changed, whatever
/// happens: a success, a taken name, a missing row, a failing engine, a failed final move. A stale
/// staging folder of this device's (what a sweep would remove) and a user's file stay as they were.
@MainActor @Test func nothingButThePromisedURLIsTouchedInTheDropFolder() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let stale = try makeTestStaging(in: destination, token: testDeviceToken, pid: try reapedPid(),
                                    modified: Date(timeIntervalSinceNow: -3600))
    try makeFile("keep.txt", in: destination, contents: "mine")
    let before = try snapshot(destination)
    let renames = Renames()
    let recording = fileSystem { _, to, _ in
        renames.append(to)
        return nil
    }
    let refusing = fileSystem { _, to, _ in
        renames.append(to)
        return (to as NSString).deletingLastPathComponent == destination.path ? EACCES : nil
    }
    let failing = FailingReader(base: FakeReader(entries: project), error: .entryNotFound("src/main.swift"))

    _ = try? await ArchiveDragOut.write("gone.txt", from: makeModel(fileSystem: recording),
                                        toPromised: promised("gone.txt", in: destination))
    _ = try? await ArchiveDragOut.write("keep.txt", from: makeModel([file("keep.txt")], fileSystem: recording),
                                        toPromised: promised("keep.txt", in: destination))
    _ = try? await ArchiveDragOut.write("src", from: makeModel(reader: failing, fileSystem: recording),
                                        toPromised: promised("src", in: destination))
    _ = try? await ArchiveDragOut.write("src", from: makeModel(fileSystem: refusing),
                                        toPromised: promised("src", in: destination))
    #expect(try snapshot(destination) == before)

    _ = try await ArchiveDragOut.write("src", from: makeModel(fileSystem: recording),
                                       toPromised: promised("src", in: destination))
    var after = try snapshot(destination)
    for key in after.keys where key == "src" || key.hasPrefix("src/") { after[key] = nil }
    #expect(after == before)
    #expect(exists(stale))
    let promisedPath = promised("src", in: destination).standardizedFileURL.path
    for target in renames.targets.map({ URL(fileURLWithPath: $0) }) {
        #expect(stagingFolder(of: target) != nil || target.standardizedFileURL.path == promisedPath, "\(target.path)")
    }
}

/// No file-system seam the write goes through (rename, exists, isGone, listNames, identity, the
/// case-sensitivity lookups) is ever asked about the drop folder or anything in it but the promised
/// item and what is inside it, whatever happens: a success, a taken name or a case twin, a volume
/// without exclusive renames or another volume, a missing row, a failing engine. A placement that
/// lists the folder or tries another name (`UniquePlacement`) fails this.
@MainActor @Test func noSeamIsAskedAboutTheDropFolderButThePromisedItem() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    try makeFile("keep.txt", in: destination, contents: "mine")
    let seen = SeamPaths()
    let plain = recordingFileSystem(seen)
    let otherVolume = recordingFileSystem(seen, crossVolume(into: destination))
    let noExclusive = recordingFileSystem(seen) { _, _, flags in flags == UInt32(RENAME_EXCL) ? ENOTSUP : nil }
    let failing = FailingReader(base: FakeReader(entries: project), error: .entryNotFound("src/main.swift"))
    let drops: [(path: String, name: String, model: ArchiveModel)] = [
        ("README.md", "README.md", makeModel(fileSystem: plain)),
        ("src", "Sources", makeModel(fileSystem: plain)),
        ("README.md", "keep.txt", makeModel(fileSystem: plain)),
        ("README.md", "KEEP.TXT", makeModel(fileSystem: plain)),
        ("src", "copied", makeModel(fileSystem: otherVolume)),
        ("src", "plain", makeModel(fileSystem: noExclusive)),
        ("docs/report.pdf", "report.pdf", makeModel(fileSystem: noExclusive)),
        ("gone.txt", "gone.txt", makeModel(fileSystem: plain)),
        ("src", "failed", makeModel(reader: failing, fileSystem: plain)),
    ]

    for drop in drops {
        _ = try? await ArchiveDragOut.write(drop.path, from: drop.model, toPromised: promised(drop.name, in: destination))
    }

    let folder = normalized(destination.path)
    let allowed = drops.map { normalized(promised($0.name, in: destination).path) }
    let paths = seen.paths.map(normalized)
    #expect(paths.contains(allowed[0]), "the seams must be the ones the write uses")
    let strays = paths.filter { path in
        (path == folder || path.hasPrefix(folder + "/")) && !allowed.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    #expect(strays.isEmpty, "\(strays)")
    #expect(try contents(of: destination.appendingPathComponent("keep.txt")) == "mine")
}

/// A drop on another volume (exFAT, SMB, another disk: the rename says EXDEV): the item is copied
/// to exactly the promised URL, a folder whole with its tree, modes kept, and the staging goes.
@MainActor @Test func aCrossVolumeDropCopiesToThePromisedURL() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let spy = ReaderSpy()
    let model = makeModel(reader: SpyReader(base: FakeReader(entries: project), spy: spy), fileSystem: fileSystem { _, to, _ in
        (to as NSString).deletingLastPathComponent == destination.path ? EXDEV : nil
    })

    let file = try await ArchiveDragOut.write("README.md", from: model, toPromised: promised("Read Me.md", in: destination))
    let folder = try await ArchiveDragOut.write("src", from: model, toPromised: promised("Sources", in: destination))

    #expect(file.lastPathComponent == "Read Me.md")
    #expect(folder.lastPathComponent == "Sources" && folder.hasDirectoryPath)
    #expect(try snapshot(destination) == [
        "Read Me.md": "README.md", "Sources": "dir", "Sources/main.swift": "src/main.swift", "Sources/lib": "dir",
        "Sources/lib/util.swift": "src/lib/util.swift",
    ])
    // The folder's own mode comes along, not the 0700 the copy starts it with.
    let mode = try #require(FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int)
    #expect(mode & 0o077 != 0, "\(String(mode, radix: 8))")
    for directory in spy.extractDirectories {
        let staging = try #require(stagingFolder(of: directory))
        #expect(!exists(staging), "\(staging.path)")
    }
}

/// Something lands at the promised URL between the check and a cross-volume copy (a race): the copy
/// never writes over it or into it (a folder there stays as it was, nothing copied inside): the
/// file-exists error, and the racer's item stays.
@MainActor @Test(arguments: [false, true])
func aCrossVolumeCopyNeverWritesIntoARacersItem(_ racerIsAFolder: Bool) async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let model = makeModel(fileSystem: fileSystem { _, to, _ in
        guard (to as NSString).deletingLastPathComponent == destination.path else { return nil }
        if racerIsAFolder {
            try? FileManager.default.createDirectory(atPath: to, withIntermediateDirectories: false)
        } else {
            try? Data("racer".utf8).write(to: URL(fileURLWithPath: to))
        }
        return EXDEV
    })

    for (path, name) in [("README.md", "README.md"), ("src", "src")] {
        await expectFileExists {
            try await ArchiveDragOut.write(path, from: model, toPromised: promised(name, in: destination))
        }
    }

    #expect(try snapshot(destination) == (racerIsAFolder ? ["README.md": "dir", "src": "dir"]
                                                         : ["README.md": "racer", "src": "racer"]))
}

/// A volume without exclusive renames (ENOTSUP or EOPNOTSUPP for RENAME_EXCL, as exFAT or SMB can
/// answer): the item is copied exclusively instead, still never replacing.
@MainActor @Test(arguments: [ENOTSUP, EOPNOTSUPP])
func dragOutWithoutExclusiveRenamesStillNeverReplaces(_ code: Int32) async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    try makeFile("README.md", in: destination, contents: "mine")
    let model = makeModel(fileSystem: fileSystem { _, _, flags in flags == UInt32(RENAME_EXCL) ? code : nil })

    await expectFileExists {
        try await ArchiveDragOut.write("README.md", from: model, toPromised: promised("README.md", in: destination))
    }
    let folder = try await ArchiveDragOut.write("src", from: model, toPromised: promised("src", in: destination))

    #expect(folder.lastPathComponent == "src")
    #expect(try contents(of: destination.appendingPathComponent("README.md")) == "mine")
    #expect(try contents(of: folder.appendingPathComponent("lib/util.swift")) == "src/lib/util.swift")
    #expect(try stagingLeft(in: destination).isEmpty)
}

/// The cross-volume copy failing midway (an item it can't read) removes what it made at the target,
/// and only that; a target already there is refused before anything is copied.
@Test func aFailedCopyRemovesOnlyWhatItMade() throws {
    let root = try makeDestination()
    defer {
        _ = chmod(root.appendingPathComponent("source/locked.txt").path, 0o644)
        try? FileManager.default.removeItem(at: root)
    }
    let source = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try makeFile("a.txt", in: source, contents: "a")
    let locked = try makeFile("locked.txt", in: source, contents: "secret")
    try #require(chmod(locked.path, 0) == 0)
    try #require(open(locked.path, O_RDONLY) < 0, "running as root: an unreadable file can't be made")
    let drop = root.appendingPathComponent("drop", isDirectory: true)
    try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: false)

    #expect(throws: (any Error).self) {
        try ExclusiveCopy.copy(source, to: drop.appendingPathComponent("copy"))
    }
    #expect(throws: (any Error).self) {
        try ExclusiveCopy.copy(locked, to: drop.appendingPathComponent("file"))
    }
    #expect(try snapshot(drop).isEmpty)

    try makeFile("taken", in: drop, contents: "mine")
    expectCocoaFileExists { try ExclusiveCopy.copy(source, to: drop.appendingPathComponent("taken")) }
    expectCocoaFileExists {
        try ExclusiveCopy.copy(source.appendingPathComponent("a.txt"), to: drop.appendingPathComponent("taken"))
    }
    #expect(try snapshot(drop) == ["taken": "mine"])
}

private func expectCocoaFileExists(_ body: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try body()
        Issue.record("must throw", sourceLocation: sourceLocation)
    } catch {
        #expect((error as NSError).domain == NSCocoaErrorDomain
                    && (error as NSError).code == CocoaError.fileWriteFileExists.rawValue, "\(error)",
                sourceLocation: sourceLocation)
    }
}

/// Across volumes the item comes as the archive made it: a read-only (0555) folder whole, with its
/// items in it, every file's and folder's mode, and the symlink in the tree copied as a link, never followed;
/// the one pointing out of it is left out (`ExportLinkSweep`); the staging goes, read-only folder and all.
@MainActor @Test func aCrossVolumeCopyKeepsReadOnlyFoldersModesAndLinks() async throws {
    let destination = try makeDestination()
    defer { removeTree(destination) }
    let outside = try makeFile("outside-\(UUID().uuidString).txt", in: FileManager.default.temporaryDirectory,
                               contents: "outside")
    defer { try? FileManager.default.removeItem(at: outside) }
    let spy = ReaderSpy()
    let reader = ShapedReader(base: FakeReader(entries: project)) { directory in
        let src = directory.appendingPathComponent("src")
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("link").path,
                                                   withDestinationPath: "main.swift")
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("lib/out").path,
                                                   withDestinationPath: outside.path)
        for (path, mode) in [("main.swift", 0o640), ("lib/util.swift", 0o444), ("lib", 0o555)] {
            guard chmod(src.appendingPathComponent(path).path, mode_t(mode)) == 0 else { throw POSIXError(.EPERM) }
        }
    }
    let model = makeModel(reader: SpyReader(base: reader, spy: spy), fileSystem: fileSystem(crossVolume(into: destination)))

    let placed = try await ArchiveDragOut.write("src", from: model, toPromised: promised("Sources", in: destination))

    #expect(try snapshot(destination) == [
        "Sources": "dir", "Sources/main.swift": "src/main.swift", "Sources/link": "link", "Sources/lib": "dir",
        "Sources/lib/util.swift": "src/lib/util.swift",
    ])
    #expect(mode(placed.appendingPathComponent("lib")) == 0o555)
    #expect(mode(placed.appendingPathComponent("lib/util.swift")) == 0o444)
    #expect(mode(placed.appendingPathComponent("main.swift")) == 0o640)
    #expect(mode(placed) & 0o077 != 0, "the folder's own mode, not the copy's 0700")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: placed.appendingPathComponent("link").path) == "main.swift")
    #expect(try contents(of: outside) == "outside")
    let staging = try #require(spy.extractDirectories.first.flatMap(stagingFolder(of:)))
    #expect(!exists(staging), "\(staging.path)")
}

/// A symlink row (here across volumes, as on one): never handed out (`ExportLinkSweep`), so the write fails
/// with `ExportedLinksError`, nothing lands at the promised URL, and the staging goes.
@MainActor @Test func aSymlinkRowFails() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let spy = ReaderSpy()
    let reader = ShapedReader(base: FakeReader(entries: [file("alias")])) { directory in
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "../somewhere/else")
    }
    let model = makeModel(reader: SpyReader(base: reader, spy: spy), fileSystem: fileSystem(crossVolume(into: destination)))

    await #expect(throws: ExportedLinksError(names: ["alias"])) {
        try await ArchiveDragOut.write("alias", from: model, toPromised: promised("alias", in: destination))
    }

    #expect(try snapshot(destination) == [:])
    let staging = try #require(spy.extractDirectories.first.flatMap(stagingFolder(of:)))
    #expect(!exists(staging), "\(staging.path)")
}

/// A cross-volume copy failing partway (a FIFO, which only a rename on one volume can place, after a
/// read-only folder was copied whole): its error, nothing at the promised URL or anywhere in the drop
/// folder, and the staging goes. (An unreadable file no longer fails it, see below.)
@MainActor @Test func aCrossVolumeCopyFailingPartwayLeavesNothing() async throws {
    let destination = try makeDestination()
    defer { removeTree(destination) }
    let spy = ReaderSpy()
    let reader = ShapedReader(base: FakeReader(entries: project)) { directory in
        let src = directory.appendingPathComponent("src")
        // Copied in name order: "lib" (read-only, finished first), "main.swift", then "zz-pipe".
        guard mkfifo(src.appendingPathComponent("zz-pipe").path, 0o644) == 0,
              chmod(src.appendingPathComponent("lib").path, 0o555) == 0 else {
            throw POSIXError(.EPERM)
        }
    }
    let model = makeModel(reader: SpyReader(base: reader, spy: spy), fileSystem: fileSystem(crossVolume(into: destination)))

    await #expect(throws: POSIXError(.ENOTSUP)) {
        try await ArchiveDragOut.write("src", from: model, toPromised: promised("src", in: destination))
    }

    #expect(try snapshot(destination).isEmpty)
    let staging = try #require(spy.extractDirectories.first.flatMap(stagingFolder(of:)))
    #expect(!exists(staging), "\(staging.path)")
}

/// Across volumes, what the archive made unreadable in the app's own staging (a 0000 file, a 0300
/// folder that can't be listed) is copied all the same, as a rename on one volume would place it,
/// and lands with its own modes; the staging goes.
@MainActor @Test func aCrossVolumeCopyCarriesUnreadableItemsWithTheirModes() async throws {
    let destination = try makeDestination()
    defer { try? ExclusiveCopy.removeItem(at: destination) }
    let spy = ReaderSpy()
    let reader = ShapedReader(base: FakeReader(entries: project)) { directory in
        let src = directory.appendingPathComponent("src")
        for (path, mode) in [("main.swift", 0o000), ("lib", 0o300)] {
            guard chmod(src.appendingPathComponent(path).path, mode_t(mode)) == 0 else { throw POSIXError(.EPERM) }
        }
    }
    let model = makeModel(reader: SpyReader(base: reader, spy: spy), fileSystem: fileSystem(crossVolume(into: destination)))

    let placed = try await ArchiveDragOut.write("src", from: model, toPromised: promised("Sources", in: destination))

    #expect(mode(placed.appendingPathComponent("main.swift")) == 0)
    #expect(mode(placed.appendingPathComponent("lib")) == 0o300)
    // Opened up only to read what came across.
    try #require(chmod(placed.appendingPathComponent("lib").path, 0o700) == 0)
    try #require(chmod(placed.appendingPathComponent("main.swift").path, 0o600) == 0)
    #expect(try snapshot(destination) == [
        "Sources": "dir", "Sources/main.swift": "src/main.swift", "Sources/lib": "dir",
        "Sources/lib/util.swift": "src/lib/util.swift",
    ])
    let staging = try #require(spy.extractDirectories.first.flatMap(stagingFolder(of:)))
    #expect(!exists(staging), "\(staging.path)")
}

/// A drop cancelled during a cross-volume copy (the copy runs off the main actor): the copy stops
/// with `CancellationError` and leaves nothing at the target.
@MainActor @Test func aCancelStopsACrossVolumeCopy() async throws {
    let root = try makeDestination()
    defer { try? FileManager.default.removeItem(at: root) }
    let staged = root.appendingPathComponent("staged", isDirectory: true)
    try FileManager.default.createDirectory(at: staged.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try makeFile("a.txt", in: staged, contents: "a")
    let target = root.appendingPathComponent("drop/staged", isDirectory: true)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: false)
    let otherVolume = fileSystem(crossVolume(into: target.deletingLastPathComponent()))

    // Cancelled before it runs (it starts on the main actor once this awaits): the copy is asked at its start.
    let task = Task { try await ArchiveDragOut.place(staged, at: target, fileSystem: otherVolume) }
    task.cancel()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!exists(target))
    #expect(exists(staged.appendingPathComponent("sub")))
}

/// The copy asks about a cancel before each item, and a yes midway removes what it made.
@Test func aCopyCancelledMidwayLeavesNothing() throws {
    let root = try makeDestination()
    defer { removeTree(root) }
    let source = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("b"), withIntermediateDirectories: true)
    try makeFile("a.txt", in: source, contents: "a")
    try makeFile("inner.txt", in: source.appendingPathComponent("b"), contents: "inner")
    try makeFile("c.txt", in: source, contents: "c")
    try #require(chmod(source.appendingPathComponent("b").path, 0o555) == 0)
    let target = root.appendingPathComponent("copy", isDirectory: true)
    var stoppedAfterB = false

    // Asked before each item (and within each file, after each chunk): a yes once the read-only "b"
    // is copied whole (its own 0555 given), which is before "c.txt", stops it there.
    #expect(throws: CancellationError.self) {
        try ExclusiveCopy.copy(source, to: target) {
            stoppedAfterB = mode(target.appendingPathComponent("b")) == 0o555
            return stoppedAfterB
        }
    }
    #expect(stoppedAfterB)
    #expect(!exists(target))
}

/// The target swapped for a symlink to another folder once the copy made it (a racer in the drop
/// folder): nothing is written through the link; what follows goes into the folder the copy made,
/// which it still holds open.
@Test func aTargetSwappedForASymlinkIsNeverWrittenThrough() throws {
    let root = try makeDestination()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try makeFile("a.txt", in: source, contents: "a")
    try makeFile("b.txt", in: source.appendingPathComponent("sub"), contents: "b")
    let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
    let target = root.appendingPathComponent("copy", isDirectory: true)
    let aside = root.appendingPathComponent("aside", isDirectory: true)
    var asked = 0

    try ExclusiveCopy.copy(source, to: target) {
        asked += 1
        if asked == 2 {  // the target is made and open, nothing is in it yet
            _ = rename(target.path, aside.path)
            _ = symlink(elsewhere.path, target.path)
        }
        return false
    }

    #expect(asked > 2)
    #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    #expect(try snapshot(aside) == ["a.txt": "a", "sub": "dir", "sub/b.txt": "b"])
}

// MARK: - Nothing left behind

/// A cancel once the reader wrote everything: CancellationError, nothing in the drop folder.
@MainActor @Test func aCancelledWriteLeavesNothing() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let (written, wroteAll) = AsyncStream.makeStream(of: Void.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    let spy = ReaderSpy()
    let reader = GatedReader(base: FakeReader(entries: project), spy: spy) {
        wroteAll.yield()
        for await _ in released { break }
    }
    let model = makeModel(reader: reader)

    let task = Task { try await ArchiveDragOut.write("src", from: model, toPromised: promised("src", in: destination)) }
    for await _ in written { break }
    let staging = try #require(spy.extractDirectories.first.flatMap(stagingFolder(of:)))
    #expect(exists(staging))
    task.cancel()
    release.yield()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try snapshot(destination).isEmpty)
    #expect(!exists(staging))
}

#if DEBUG
/// A cancel while the link sweep runs on the staged item: once the sweep returns, the write throws
/// `CancellationError`, places nothing in the drop folder and removes the staging.
@MainActor @Test func aCancelDuringTheLinkSweepPlacesNothing() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let (swept, sweeping) = AsyncStream.makeStream(of: Void.self)
    let gate = DispatchSemaphore(value: 0)
    let spy = ReaderSpy()
    let model = makeModel(reader: SpyReader(base: FakeReader(entries: project), spy: spy))

    let task = Task {
        try await ArchiveDragOut.write("src", from: model, toPromised: promised("src", in: destination),
                                       sanitize: { items in
                                           sweeping.yield()
                                           // Bounded: a test that never releases it fails instead of hanging.
                                           _ = gate.wait(timeout: .now() + 30)
                                           return try ExportLinkSweep.sanitize(items)
                                       })
    }
    for await _ in swept { break }
    let staging = try #require(spy.extractDirectories.first.flatMap(stagingFolder(of:)))
    #expect(exists(staging))
    task.cancel()
    gate.signal()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try snapshot(destination).isEmpty)
    #expect(!exists(staging))
}
#endif

/// A Cancel while the engine is writing (a zip bomb stopped midway): whatever the engine throws for
/// it, the drop folder is left as it was, the promise reports Cocoa's user-cancelled error and the
/// window shows no alert.
@MainActor @Test(arguments: [
    ArchiveError.cancelled as any Error & Sendable, CancellationError() as any Error & Sendable,
])
func aMidWriteCancelLeavesNothingAndNoAlert(_ engineError: any Error & Sendable) async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let (written, wrote) = AsyncStream.makeStream(of: Void.self)
    let spy = ReaderSpy()
    let reader = SpyReader(base: MidWriteCancelReader(base: FakeReader(entries: project), wrote: { wrote.yield() },
                                                      error: engineError),
                           spy: spy)
    let model = makeModel(reader: reader)

    let task = Task { try await ArchiveDragOut.write("src", from: model, toPromised: promised("src", in: destination)) }
    for await _ in written { break }
    // Mid-write the staging holds the partial item, in the temporary folder, none in the drop folder.
    let staging = try #require(spy.extractDirectories.first.flatMap(stagingFolder(of:)))
    #expect(exists(spy.extractDirectories[0].appendingPathComponent("src/main.swift")))
    #expect(try stagingLeft(in: destination).isEmpty)
    task.cancel()

    let thrown: any Error
    do {
        _ = try await task.value
        Issue.record("the write must throw")
        return
    } catch {
        thrown = error
    }
    let reported = ArchiveDragOut.promiseError(for: thrown) as NSError
    #expect(reported.domain == NSCocoaErrorDomain && reported.code == CocoaError.userCancelled.rawValue, "\(thrown)")
    #expect(ArchiveDragOut.alertError(for: reported) == nil)
    #expect(ArchiveDragOut.alertError(for: thrown) == nil)
    #expect(try snapshot(destination).isEmpty)
    #expect(!exists(staging), "\(staging.path)")
}

/// A full disk (or quota), from the engine or at the final move: the error comes out, staging goes.
@MainActor @Test(arguments: [ENOSPC, EDQUOT])
func aFullDiskLeavesNothingAndReportsIt(_ code: Int32) async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let error = POSIXError(POSIXErrorCode(rawValue: code)!)
    let spy = ReaderSpy()
    let reader = GatedReader(base: FakeReader(entries: project), spy: spy) { throw error }

    await #expect(throws: error) {
        try await ArchiveDragOut.write("src", from: makeModel(reader: reader), toPromised: promised("src", in: destination))
    }
    #expect(try snapshot(destination).isEmpty)

    let full = makeModel(reader: SpyReader(base: FakeReader(entries: project), spy: spy),
                         fileSystem: fileSystem { _, to, _ in
        (to as NSString).deletingLastPathComponent == destination.path ? code : nil
    })
    await #expect(throws: error) {
        try await ArchiveDragOut.write("src", from: full, toPromised: promised("src", in: destination))
    }
    #expect(try snapshot(destination).isEmpty)
    #expect(spy.extractDirectories.count == 2)
    for directory in spy.extractDirectories {
        let staging = try #require(stagingFolder(of: directory))
        #expect(!exists(staging), "\(staging.path)")
    }
}

// MARK: - Staging in the temporary folder, never in the drop folder

/// A drop never lists or sweeps the drop folder (the sandbox denies it): even a crashed run's staging
/// there (this device's, its process gone, old) stays, as do a live run's, another device's and a
/// foreign one.
@MainActor @Test func aDropNeverSweepsTheDropFolder() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let gone = try reapedPid()
    let old = Date(timeIntervalSinceNow: -3600)
    let stale = try makeTestStaging(in: destination, token: testDeviceToken, pid: gone, modified: old)
    let live = try makeTestStaging(in: destination, token: testDeviceToken, pid: getppid(), modified: old)
    let other = try makeTestStaging(in: destination, token: "0123456789abcdef", pid: gone, modified: old)
    try FileManager.default.createDirectory(at: destination.appendingPathComponent(".kernir-foo"), withIntermediateDirectories: false)

    _ = try await ArchiveDragOut.write("README.md", from: makeModel(), toPromised: promised("README.md", in: destination))

    let left = Set(try FileManager.default.contentsOfDirectory(atPath: destination.path))
    #expect(left == [stale.lastPathComponent, live.lastPathComponent, other.lastPathComponent, ".kernir-foo", "README.md"])
}

/// A crashed run's staging in the temporary folder (this device's, its process gone, untouched for 10
/// minutes) goes when the next drop starts (`StagingSweep`, the app's own folder); a live run's, a
/// young one and another device's stay. Its own device token: the sweep runs once per folder and
/// token per `StagingSweep.interval`, and another test's drop must not have taken this one's turn.
@MainActor @Test func aDropSweepsStaleStagingInTheTemporaryFolder() async throws {
    let token = "5ee95ee95ee95ee9"
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let temporary = FileManager.default.temporaryDirectory
    let gone = try reapedPid()
    let old = Date(timeIntervalSinceNow: -3600)
    let stale = try makeTestStaging(in: temporary, token: token, pid: gone, modified: old)
    let live = try makeTestStaging(in: temporary, token: token, pid: getppid(), modified: old)
    let young = try makeTestStaging(in: temporary, token: token, pid: gone, modified: Date())
    let other = try makeTestStaging(in: temporary, token: "0123456789abcdef", pid: gone, modified: old)
    defer { for staging in [stale, live, young, other] { try? FileManager.default.removeItem(at: staging) } }

    _ = try await ArchiveDragOut.write("README.md", from: makeModel(fileSystem: fileSystem(token: token)),
                                       toPromised: promised("README.md", in: destination))

    #expect(!exists(stale))
    #expect(exists(live) && exists(young) && exists(other))
}

/// A drop of many rows writes each one through `write`, and the temporary folder is swept once per
/// `StagingSweep.interval`, not once per row: stale staging that shows up between two
/// rows waits for a later sweep. Its own device token, so no other test's drop has swept this
/// folder and token before; the interval is the real one (a minute), long past a test's two writes.
@MainActor @Test func twoRowsDroppedSoonAfterEachOtherSweepTheTemporaryFolderOnce() async throws {
    let token = "5ee95ee95ee95eea"
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let temporary = FileManager.default.temporaryDirectory
    let gone = try reapedPid()
    let old = Date(timeIntervalSinceNow: -3600)
    let first = try makeTestStaging(in: temporary, token: token, pid: gone, modified: old)
    defer { try? FileManager.default.removeItem(at: first) }
    let model = makeModel(fileSystem: fileSystem(token: token))

    _ = try await ArchiveDragOut.write("README.md", from: model, toPromised: promised("README.md", in: destination))
    #expect(!exists(first))

    let second = try makeTestStaging(in: temporary, token: token, pid: gone, modified: old)
    defer { try? FileManager.default.removeItem(at: second) }
    _ = try await ArchiveDragOut.write("src", from: model, toPromised: promised("src", in: destination))

    #expect(exists(second))
}

/// A write in flight stages in a hidden folder of the temporary folder (the app container's in the
/// sandbox), named as `ArchiveModel.stagingNameFields` parses (this device's token, this pid), with
/// nothing in the drop folder until the item lands; the staging is gone once it has.
@MainActor @Test func aWriteInFlightStagesInTheTemporaryFolder() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let (written, wroteAll) = AsyncStream.makeStream(of: Void.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    let spy = ReaderSpy()
    let reader = GatedReader(base: FakeReader(entries: project), spy: spy) {
        wroteAll.yield()
        for await _ in released { break }
    }
    let model = makeModel(reader: reader)

    let task = Task { try await ArchiveDragOut.write("src", from: model, toPromised: promised("src", in: destination)) }
    for await _ in written { break }
    let staging = try #require(spy.extractDirectories.first.flatMap(stagingFolder(of:)))
    let fields = try #require(ArchiveModel.stagingNameFields(staging.lastPathComponent))
    #expect(fields.deviceToken == testDeviceToken && fields.pid == getpid())
    #expect(try snapshot(destination).isEmpty)
    release.yield()

    let placed = try await task.value
    #expect(placed.lastPathComponent == "src")
    #expect(!exists(staging))
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["src"])
}

/// A containment refusal from the inner extraction (the model refuses a staged symlink out of its
/// folder): the staging goes, nothing reaches the drop folder, and the error names the folder the
/// user sees, never the hidden one.
@MainActor @Test func aContainmentRefusalLeavesNothingAndNamesTheDropFolder() async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let hidden = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(ArchiveModel.stagingPrefix)hidden", isDirectory: true)
    let reader = GatedReader(base: FakeReader(entries: project)) {
        throw ExtractionContainmentError(name: "src", destination: hidden)
    }

    do {
        _ = try await ArchiveDragOut.write("src", from: makeModel(reader: reader),
                                           toPromised: promised("src", in: destination))
        Issue.record("the write must throw")
    } catch let refused as ExtractionContainmentError {
        #expect(refused.name == "src")
        #expect(refused.destination.standardizedFileURL.path == destination.standardizedFileURL.path)
    }
    #expect(try snapshot(destination).isEmpty)
}

/// ExtractHereService makes its staging folder with an exclusive mkdir(2) (`makeStagingFolder`):
/// anything already at that path, a symlink to a folder or a dangling one included, makes it fail
/// with EEXIST without following it, and the symlink's target stays as it was. The real staging
/// name carries a fresh UUID, so a test can't plant one at it; this calls the function itself with a
/// planted path.
@Test(arguments: [true, false])
func aPlantedSymlinkAtTheStagingPathIsNeverFollowed(_ pointsAtAFolder: Bool) throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let target = destination.appendingPathComponent("target", isDirectory: true)
    if pointsAtAFolder {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
    }
    let staging = destination.appendingPathComponent("\(ArchiveModel.stagingPrefix)\(testDeviceToken)-\(getpid())-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: target)

    expectExists(throwing: { try ExtractHereService.makeStagingFolder(staging) }, path: staging.path)

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: staging.path) == target.path)
    if pointsAtAFolder {
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["keep.txt"])
    } else {
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }
}

/// An existing folder at the staging path (mkdir would not have changed it) is refused too, and
/// what is in it stays: there is no "existing folder with the wrong mode" case.
@Test func anExistingFolderAtTheStagingPathIsRefusedAndLeftAlone() throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let staging = destination.appendingPathComponent("\(ArchiveModel.stagingPrefix)\(testDeviceToken)-\(getpid())-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    try Data("keep".utf8).write(to: staging.appendingPathComponent("keep.txt"))

    expectExists(throwing: { try ExtractHereService.makeStagingFolder(staging) }, path: staging.path)

    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path) == ["keep.txt"])
}

/// `makeStagingFolder` failed because the path exists: Cocoa's file-exists error with EEXIST under
/// it and the path in its info, as `createDirectory` would have thrown.
private func expectExists(throwing body: () throws -> Void, path: String,
                          sourceLocation: SourceLocation = #_sourceLocation) {
    do {
        try body()
        Issue.record("makeStagingFolder must throw", sourceLocation: sourceLocation)
    } catch {
        let nsError = error as NSError
        #expect(nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileWriteFileExists.rawValue,
                "\(error)", sourceLocation: sourceLocation)
        #expect((nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EEXIST), sourceLocation: sourceLocation)
        #expect(nsError.userInfo[NSFilePathErrorKey] as? String == path, sourceLocation: sourceLocation)
    }
}

/// Drag-out never goes through the temporary-file path: no `extractToTemporaryFile`
/// (so no `ArchiveModel.localFileURL` for a file), and no extraction anywhere but into its own hidden
/// staging folder of the temporary folder (`localFileURL` extracts a folder into a `Kernir-<UUID>`
/// folder there), never into the drop folder, for a file and for a folder. The result is in the drop
/// folder, nothing is left beside it.
@MainActor @Test(arguments: ["README.md", "src"])
func dragOutNeverGoesThroughTheTemporaryFilePath(_ path: String) async throws {
    let destination = try makeDestination()
    defer { try? FileManager.default.removeItem(at: destination) }
    let spy = ReaderSpy()
    let model = makeModel(reader: SpyReader(base: FakeReader(entries: project), spy: spy))

    let placed = try await ArchiveDragOut.write(path, from: model, toPromised: promised(path, in: destination))

    #expect(spy.temporaryFilePaths.isEmpty)
    let directories = spy.extractDirectories
    #expect(!directories.isEmpty)
    let root = destination.standardizedFileURL.path + "/"
    for directory in directories {
        #expect(stagingFolder(of: directory) != nil, "\(directory.path)")
        #expect(!directory.standardizedFileURL.path.hasPrefix(root), "\(directory.path)")
        #expect(!directory.pathComponents.contains { $0.hasPrefix("Kernir-") }, "\(directory.path)")
    }
    #expect(placed.standardizedFileURL == destination.appendingPathComponent(path).standardizedFileURL)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).contains(path))
    #expect(try stagingLeft(in: destination).isEmpty)
}

// MARK: - Which failures the window shows

/// The engine's own cancel (a zip bomb stopped with Cancel mid-extraction) is a cancel too: Cocoa's
/// user-cancelled error, never "The operation was cancelled." in an alert.
@Test func theEnginesCancelIsReportedAsUserCancelled() {
    let reported = ArchiveDragOut.promiseError(for: ArchiveError.cancelled) as NSError
    #expect(reported.domain == NSCocoaErrorDomain && reported.code == CocoaError.userCancelled.rawValue)
}

/// Every failure but a cancel gets the window's alert, with the error as it is; a success or any
/// kind of cancel gets none.
@Test func everyFailureButACancelIsShown() {
    #expect(ArchiveDragOut.alertError(for: nil) == nil)
    for cancel: any Error in [CocoaError(.userCancelled), CancellationError(), ArchiveError.cancelled] {
        #expect(ArchiveDragOut.alertError(for: cancel) == nil, "\(cancel)")
    }
    let failures: [any Error] = [
        POSIXError(.ENOSPC), POSIXError(.EDQUOT), POSIXError(.EROFS), POSIXError(.EPERM),
        CocoaError(.fileWriteOutOfSpace), CocoaError(.fileWriteVolumeReadOnly), CocoaError(.fileWriteNoPermission),
        CocoaError(.fileWriteInvalidFileName),
        ArchiveError.entryNotFound("x"), ArchiveError.wrongPassword, ArchiveError.passwordRequired,
        ExtractionContainmentError(name: "x", destination: URL(fileURLWithPath: "/tmp")),
    ]
    for failure in failures {
        let shown = ArchiveDragOut.alertError(for: failure) as NSError?
        #expect(shown?.domain == (failure as NSError).domain && shown?.code == (failure as NSError).code, "\(failure)")
    }
}

#if os(macOS)
/// A folder of a downloaded archive dropped on another volume (an exclusive copy, not a move) stays
/// quarantined all through: in the sandbox the copy can't carry a quarantine over itself, so what it
/// placed is marked again, inside too.
@MainActor @Test func aCrossVolumeDropOfADownloadedFolderStaysQuarantinedInside() async throws {
    let root = try makeDestination()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try await writeQuarantineSample(in: root, quarantined: true)
    let destination = root.appendingPathComponent("drop", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let model = makeModel(reader: try await Archive.open(at: archive),
                          fileSystem: fileSystem(crossVolume(into: destination)))

    let placed = try await ArchiveDragOut.write("proj", from: model, toPromised: promised("proj", in: destination))

    for path in ["", "a.txt", "sub", "sub/b.txt"] {
        let item = path.isEmpty ? placed : placed.appendingPathComponent(path)
        #expect(exists(item), "\(path)")
        #expect(try quarantineEvent(of: item) == sampleQuarantineEvent, "\(path)")
    }
}
#endif
