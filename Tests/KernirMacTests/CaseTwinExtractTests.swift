import Testing
import Foundation
@testable import Kernir
import KernirCore

// Case-only twins (`README` / `Readme`) extracted onto a case-insensitive volume ask through
// `extractionConflicts` like a name already on disk. The later twin, in archive
// order, is the conflict. Keep Both gives it the dialog's `keepBothName`; Replace leaves what the engine
// leaves (the later twin's name and bytes); Skip leaves it out. A case-sensitive destination never asks.
// The harness volume (APFS, case-insensitive) is required where the real disk matters; a case-sensitive
// destination is injected through `DestinationCaseSensitivity`.

// MARK: - Helpers

/// Fresh empty directory; the caller removes it.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CaseTwinExtractTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ contents: String, at relativePath: String, in directory: URL) throws {
    let url = directory.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
}

/// Every item under `directory`, by its name on disk (case as stored): relative path -> "dir" or contents.
private func snapshot(_ directory: URL) throws -> [String: String] {
    let fileManager = FileManager.default
    var result: [String: String] = [:]
    for relative in try fileManager.subpathsOfDirectory(atPath: directory.path) {
        let url = directory.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        result[relative] = isDirectory.boolValue ? "dir" : String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
    return result
}

private func file(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
}

private func folder(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
}

@MainActor
private func makeModel(_ entries: [ArchiveEntry]) -> ArchiveModel {
    ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil)
}

/// The case-twin corpus (Fixtures/, tag case-twins): the nearest ancestor of this file (symlinks resolved, so a
/// scratch package linking it finds it too) holding Fixtures/manifest.json.
private let fixtures: URL = {
    var url = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Fixtures/manifest.json").path) {
            return url.appendingPathComponent("Fixtures", isDirectory: true)
        }
        url.deleteLastPathComponent()
    }
    return url
}()

/// `zip/case-twins.zip` and `tar/case-twins.tar`: README, Readme, other.txt, in that order.
private let twinFixtures = ["zip/case-twins.zip", "tar/case-twins.tar"]
private let upper = "README, upper case\n"
private let mixed = "Readme, mixed case, longer\n"
private let other = "other\n"

@MainActor
private func openFixture(_ name: String) async throws -> ArchiveModel {
    let reader = try await Archive.open(at: fixtures.appendingPathComponent(name))
    return ArchiveModel(reader: reader, undoManager: nil)
}

/// A ustar archive of `entries` (path and contents; nil contents is a folder), in that order, in `directory`.
/// No case-insensitive disk can hold three twins to archive them from, but the engine reads them from this.
private func makeTar(_ entries: [(path: String, contents: String?)], in directory: URL) throws -> URL {
    func field(_ string: String, _ length: Int) -> [UInt8] {
        let bytes = Array(string.utf8.prefix(length))
        return bytes + Array(repeating: 0, count: length - bytes.count)
    }
    func octal(_ value: Int, _ length: Int) -> [UInt8] { field(String(value, radix: 8).leftPadded(length - 1), length) }
    var data: [UInt8] = []
    for entry in entries {
        let body = Array((entry.contents ?? "").utf8)
        let isFolder = entry.contents == nil
        var header = field(isFolder ? entry.path + "/" : entry.path, 100)
        header += octal(isFolder ? 0o755 : 0o644, 8) + octal(0, 8) + octal(0, 8) + octal(body.count, 12) + octal(0, 12)
        header += Array(repeating: UInt8(ascii: " "), count: 8)  // checksum, counted as spaces
        header += [UInt8(ascii: isFolder ? "5" : "0")] + field("", 100) + Array("ustar\0".utf8) + Array("00".utf8)
        header += field("", 32 + 32 + 8 + 8 + 155 + 12)
        let checksum = header.reduce(0) { $0 + Int($1) }
        header.replaceSubrange(148..<156, with: field(String(checksum, radix: 8).leftPadded(6), 7) + [UInt8(ascii: " ")])
        data += header + body + Array(repeating: 0, count: (512 - body.count % 512) % 512)
    }
    data += Array(repeating: 0, count: 1024)
    let url = directory.appendingPathComponent("twins-\(UUID().uuidString).tar")
    try Data(data).write(to: url)
    return url
}

private extension String {
    func leftPadded(_ length: Int) -> String { String(repeating: "0", count: max(0, length - count)) + self }
}

/// The generated archive opened in a model, and the engine's own extraction of it into `engine`.
@MainActor
private func openTar(_ entries: [(path: String, contents: String?)], in root: URL) async throws
    -> (model: ArchiveModel, engine: [String: String]) {
    let url = try makeTar(entries, in: root)
    let engine = root.appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: false)
    try await Archive.open(at: url).extract(nil, to: engine, progress: nil)
    return (ArchiveModel(reader: try await Archive.open(at: url), undoManager: nil), try snapshot(engine))
}

/// Three (or more) files on one folded name, and one more; each holds its own path.
private func twinFiles(_ names: [String]) -> [(path: String, contents: String?)] {
    (names + ["other.txt"]).map { ($0, $0) }
}

/// Says the destination is case-sensitive, whatever the disk is.
private let caseSensitive = DestinationCaseSensitivity(exists: { _ in true }, supportsCaseSensitiveNames: { _ in true })

// MARK: - Real engine, case-twin fixtures

@MainActor @Test(arguments: twinFixtures)
func twinsInAFreshFolderAreTheOnlyConflicts(_ fixture: String) async throws {
    // A fresh folder holds nothing, so the twin is the only conflict, never a disk one, and the
    // extraction with it answered meets no disk conflict either.
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let model = try await openFixture(fixture)
    let empty = root.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
    let missing = root.appendingPathComponent("not yet/made", isDirectory: true)

    #expect(model.extractionConflicts(nil, in: empty) == ["Readme"])
    #expect(model.extractionConflicts(nil, in: missing) == ["Readme"])
    #expect(model.extractionConflicts(["README", "Readme"], in: empty) == ["Readme"])
    // One twin alone lands on its own name.
    #expect(model.extractionConflicts(["README", "other.txt"], in: empty).isEmpty)
    #expect(model.extractionConflicts(["Readme"], in: empty).isEmpty)

    // Unanswered: nothing is written, the destination isn't even made.
    await #expect(throws: ExtractionConflictError(paths: ["Readme"])) {
        try await model.extract(nil, to: missing, progress: nil)
    }
    #expect(!FileManager.default.fileExists(atPath: missing.path))
    #expect(try snapshot(empty).isEmpty)

    for (destination, resolution) in [(empty, ExtractionConflictResolution.keepBoth), (missing, .replace)] {
        do {
            try await model.extract(nil, to: destination, resolutions: ["Readme": resolution], progress: nil)
        } catch {
            Issue.record("\(resolution) in a fresh folder: \(error)")
        }
    }
}

@MainActor @Test(arguments: twinFixtures)
func twinAskThenKeepBoth(_ fixture: String) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let model = try await openFixture(fixture)

    let written = try await model.extract(nil, to: output, resolutions: ["Readme": .keepBoth], progress: nil)

    #expect(try snapshot(output) == ["README": upper, "Readme 2": mixed, "other.txt": other])
    // In the order asked for: everything (nil) is the top level in Finder order, "Readme" before "README".
    #expect(written.map(\.lastPathComponent) == ["other.txt", "Readme 2", "README"])
}

@MainActor @Test(arguments: twinFixtures)
func keepBothForEveryConflictInOneCall(_ fixture: String) async throws {
    // A caller without UI answers every conflict extractionConflicts returns, keyed by path, in one
    // extract call; disk conflicts and twins alike.
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    try write("mine\n", at: "other.txt", in: output)
    let model = try await openFixture(fixture)

    let conflicts = model.extractionConflicts(nil, in: output)
    #expect(conflicts == ["other.txt", "Readme"])
    let resolutions = Dictionary(uniqueKeysWithValues: conflicts.map { ($0, ExtractionConflictResolution.keepBoth) })
    let written = try await model.extract(nil, to: output, resolutions: resolutions, progress: nil)

    #expect(try snapshot(output) == ["README": upper, "Readme 2": mixed, "other.txt": "mine\n", "other 2.txt": other])
    #expect(written.map(\.lastPathComponent) == ["other 2.txt", "Readme 2", "README"])
}

@MainActor @Test(arguments: twinFixtures)
func twinKeepBothNameIsTheDialogsKeepBothName(_ fixture: String) async throws {
    // The twin's Keep Both name comes from the same keepBothName as the dialog's Keep Both for a
    // name already on disk, numbering on past names already taken, and the same on every run.
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let model = try await openFixture(fixture)
    var names: [[String]] = []
    for taken in [[], ["Readme 2"], ["readme 2", "README 3"]] {
        // Twin route: both twins extracted, the later one kept beside the earlier.
        let twins = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Disk route: README is already there, Readme alone is extracted onto it.
        let disk = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: twins, withIntermediateDirectories: false)
        try write("mine\n", at: "README", in: disk)
        for name in taken {
            try write("taken\n", at: name, in: twins)
            try write("taken\n", at: name, in: disk)
        }
        #expect(model.extractionConflicts(["README", "Readme"], in: twins) == ["Readme"])
        #expect(model.extractionConflicts(["Readme"], in: disk) == ["Readme"])

        let viaTwin = try await model.extract(["README", "Readme"], to: twins, resolutions: ["Readme": .keepBoth],
                                              progress: nil)
        let viaDisk = try await model.extract(["Readme"], to: disk, resolutions: ["Readme": .keepBoth], progress: nil)

        #expect(viaTwin.last?.lastPathComponent == viaDisk.last?.lastPathComponent)
        let kept = try #require(viaTwin.last)
        #expect(try String(decoding: Data(contentsOf: kept), as: UTF8.self) == mixed)
        names.append(viaTwin.map(\.lastPathComponent))
    }
    #expect(names == [["README", "Readme 2"], ["README", "Readme 3"], ["README", "Readme 4"]])
}

@MainActor @Test(arguments: twinFixtures)
func twinReplaceKeepsLaterWins(_ fixture: String) async throws {
    // Measured on the engine on its own (DataSafetyTests): extracting both twins onto a
    // case-insensitive volume leaves one file, named Readme (the LATER entry's name), with Readme's bytes.
    // Replace leaves exactly that.
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let model = try await openFixture(fixture)
    let engineOnly = root.appendingPathComponent("engine", isDirectory: true)
    let output = root.appendingPathComponent("model", isDirectory: true)
    try FileManager.default.createDirectory(at: engineOnly, withIntermediateDirectories: false)
    let reader = try await Archive.open(at: fixtures.appendingPathComponent(fixture))
    try await reader.extract(nil, to: engineOnly, progress: nil)

    let written = try await model.extract(nil, to: output, resolutions: ["Readme": .replace], progress: nil)

    let expected = ["Readme": mixed, "other.txt": other]
    #expect(try snapshot(engineOnly) == expected)
    #expect(try snapshot(output) == expected)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["Readme", "other.txt"])
    #expect(written.map(\.lastPathComponent) == ["other.txt", "Readme"])
}

@MainActor @Test(arguments: twinFixtures)
func twinSkip(_ fixture: String) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let model = try await openFixture(fixture)

    let written = try await model.extract(nil, to: output, resolutions: ["Readme": .skip], progress: nil)

    #expect(try snapshot(output) == ["README": upper, "other.txt": other])
    #expect(written.map(\.lastPathComponent) == ["other.txt", "README"])
}

@MainActor @Test func caseSensitiveDestinationDoesNotAsk() async throws {
    // A case-sensitive destination asks nothing and leaves the twins to the engine: the model's result is
    // the engine's own extraction, byte for byte, on whatever disk the harness has. (On a case-sensitive
    // disk that is every twin under its own name; the harness volume folds case, so the engine's later
    // twin wins there. The twins sit in a folder, which moves whole, so the result is the same either way.)
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for fixture in twinFixtures {
        let model = try await openFixture(fixture)
        model.caseSensitivity = caseSensitive
        #expect(model.extractionConflicts(nil, in: root).isEmpty)
        #expect(model.extractionConflicts(["README", "Readme"], in: root).isEmpty)
    }
    let (model, engine) = try await openTar([("docs", nil), ("docs/README", "README"), ("docs/Readme", "Readme"),
                                             ("docs/readme", "readme"), ("z.txt", "z.txt")], in: root)
    model.caseSensitivity = caseSensitive
    let output = root.appendingPathComponent("model", isDirectory: true)
    #expect(model.extractionConflicts(nil, in: output).isEmpty)

    let written = try await model.extract(nil, to: output, progress: nil)

    #expect(try snapshot(output) == engine)
    #expect(written.map(\.lastPathComponent).sorted() == ["docs", "z.txt"])
    if !isCaseInsensitive(output) {
        #expect(engine == ["docs": "dir", "docs/README": "README", "docs/Readme": "Readme", "docs/readme": "readme",
                           "z.txt": "z.txt"])
    } else {
        #expect(engine == ["docs": "dir", "docs/readme": "readme", "z.txt": "z.txt"])
    }
}

@MainActor @Test func liveCaseSensitivityAsksTheNearestExistingFolder() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appendingPathComponent("a/b/c", isDirectory: true)
    #expect(DestinationCaseSensitivity.live.isCaseInsensitive(missing) == isCaseInsensitive(root))
}

// MARK: - Shapes (FakeReader: each file holds its archive path)

@MainActor @Test func folderTwinsMergeWithoutAsking() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let model = makeModel([folder("D"), file("D/a.txt"), folder("d"), file("d/b.txt")])

    #expect(model.extractionConflicts(nil, in: output).isEmpty)
    try await model.extract(nil, to: output, progress: nil)

    #expect(try snapshot(output) == ["D": "dir", "D/a.txt": "D/a.txt", "D/b.txt": "d/b.txt"])
    // Nested below folder twins, each requested item moves on its own into the one folder.
    let nested = output.appendingPathComponent("nested", isDirectory: true)
    #expect(model.extractionConflicts(["D/a.txt", "d/b.txt"], in: nested).isEmpty)
    try await model.extract(["D/a.txt", "d/b.txt"], to: nested, progress: nil)
    #expect(try snapshot(nested) == ["D": "dir", "D/a.txt": "D/a.txt", "D/b.txt": "d/b.txt"])
}

@MainActor @Test func fileFolderTwin() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let model = makeModel([file("d"), folder("D"), file("D/x.txt")])
    #expect(model.extractionConflicts(nil, in: root) == ["D"])

    let keepBoth = root.appendingPathComponent("keepBoth", isDirectory: true)
    let written = try await model.extract(nil, to: keepBoth, resolutions: ["D": .keepBoth], progress: nil)
    #expect(try snapshot(keepBoth) == ["d": "d", "D 2": "dir", "D 2/x.txt": "D/x.txt"])
    #expect(written.map(\.lastPathComponent) == ["D 2", "d"])

    // Replace: the later item takes the name, whole, as the engine would leave a later file.
    let replace = root.appendingPathComponent("replace", isDirectory: true)
    try await model.extract(nil, to: replace, resolutions: ["D": .replace], progress: nil)
    #expect(try snapshot(replace) == ["D": "dir", "D/x.txt": "D/x.txt"])

    let skip = root.appendingPathComponent("skip", isDirectory: true)
    try await model.extract(nil, to: skip, resolutions: ["D": .skip], progress: nil)
    #expect(try snapshot(skip) == ["d": "d"])

    // The twin is the folder above a requested item: the requested item goes along into "D 2".
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    #expect(model.extractionConflicts(["d", "D/x.txt"], in: nested) == ["D"])
    let placed = try await model.extract(["d", "D/x.txt"], to: nested, resolutions: ["D": .keepBoth], progress: nil)
    #expect(try snapshot(nested) == ["d": "d", "D 2": "dir", "D 2/x.txt": "D/x.txt"])
    #expect(placed.map { $0.path.replacingOccurrences(of: nested.path + "/", with: "") } == ["d", "D 2/x.txt"])
}

@MainActor @Test func twinInsideRequestedFolder() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let model = makeModel([folder("docs"), file("docs/a.txt"), file("docs/A.txt"), file("docs/sub/b.txt"),
                           file("docs/sub/B.txt"), file("docs/z.txt")])
    #expect(model.extractionConflicts(["docs"], in: root) == ["docs/A.txt", "docs/sub/B.txt"])

    let keepBoth = root.appendingPathComponent("keepBoth", isDirectory: true)
    let written = try await model.extract(["docs"], to: keepBoth,
                                          resolutions: ["docs/A.txt": .keepBoth, "docs/sub/B.txt": .keepBoth],
                                          progress: nil)
    #expect(try snapshot(keepBoth) == ["docs": "dir", "docs/a.txt": "docs/a.txt", "docs/A 2.txt": "docs/A.txt",
                                       "docs/sub": "dir", "docs/sub/b.txt": "docs/sub/b.txt",
                                       "docs/sub/B 2.txt": "docs/sub/B.txt", "docs/z.txt": "docs/z.txt"])
    #expect(written.map(\.lastPathComponent) == ["docs"])

    let mixedAnswers = root.appendingPathComponent("mixed", isDirectory: true)
    try await model.extract(["docs"], to: mixedAnswers,
                            resolutions: ["docs/A.txt": .replace, "docs/sub/B.txt": .skip], progress: nil)
    #expect(try snapshot(mixedAnswers) == ["docs": "dir", "docs/A.txt": "docs/A.txt", "docs/sub": "dir",
                                           "docs/sub/b.txt": "docs/sub/b.txt", "docs/z.txt": "docs/z.txt"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: mixedAnswers.appendingPathComponent("docs").path)
        .sorted() == ["A.txt", "sub", "z.txt"])

    // The folder itself is kept beside one on disk: its twin goes along into "docs 2".
    let taken = root.appendingPathComponent("taken", isDirectory: true)
    try write("mine", at: "docs/mine.txt", in: taken)
    #expect(model.extractionConflicts(["docs"], in: taken) == ["docs", "docs/A.txt", "docs/sub/B.txt"])
    try await model.extract(["docs"], to: taken, resolutions: ["docs": .keepBoth, "docs/A.txt": .keepBoth,
                                                               "docs/sub/B.txt": .keepBoth], progress: nil)
    #expect(try snapshot(taken) == ["docs": "dir", "docs/mine.txt": "mine", "docs 2": "dir",
                                    "docs 2/a.txt": "docs/a.txt", "docs 2/A 2.txt": "docs/A.txt",
                                    "docs 2/sub": "dir", "docs 2/sub/b.txt": "docs/sub/b.txt",
                                    "docs 2/sub/B 2.txt": "docs/sub/B.txt", "docs 2/z.txt": "docs/z.txt"])
}

@MainActor @Test func threeTwinsKeepBothNumberOn() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let model = makeModel([file("README"), file("Readme"), file("readme")])
    #expect(model.extractionConflicts(nil, in: output) == ["Readme", "readme"])

    let written = try await model.extract(nil, to: output, resolutions: ["Readme": .keepBoth, "readme": .keepBoth],
                                          progress: nil)

    #expect(try snapshot(output) == ["README": "README", "Readme 2": "Readme", "readme 3": "readme"])
    #expect(written.map(\.lastPathComponent) == ["readme 3", "Readme 2", "README"])
}

/// APFS folds more than `lowercased()`: full case folding (ß/SS, ligatures, final sigma) and the Unicode 9
/// Cyrillic variants Foundation's fold lacks. Unasked, the later twin met the earlier on one name in
/// staging: a bare ENOENT and one file lost.
@MainActor @Test(arguments: [("stra\u{DF}e", "STRASSE"), ("\u{FB00}", "FF"), ("\u{3C2}", "\u{3C3}"), ("\u{1C80}", "\u{412}")])
func fullCaseFoldingTwinsAreAsked(_ first: String, _ second: String) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let model = makeModel([file(first), file(second)])
    #expect(model.extractionConflicts(nil, in: output) == [second])
    await #expect(throws: ExtractionConflictError(paths: [second])) {
        try await model.extract(nil, to: output, progress: nil)
    }
    #expect(try snapshot(output).isEmpty)

    try await model.extract(nil, to: output, resolutions: [second: .keepBoth], progress: nil)

    #expect(try snapshot(output) == [first: first, "\(second) 2": second])
}

/// Sequences, not single scalars: APFS folds on NFD (canonical caseless matching), so a Greek iota
/// subscript after another mark and its capital spelling are one name there, and so is a Deseret letter
/// with a diaeresis and its other case, which Foundation's NFC would rewrite to a Cyrillic letter. A fold
/// on NFC kept them apart: no question, then a bare ENOENT and one twin not extracted.
/// Each pair is first checked on the live volume (O_EXCL).
private let sequenceTwins: [(String, String)] = [
    ("\u{1FB7}", "\u{391}\u{342}\u{345}"),
    ("\u{1FB2}\u{301}", "\u{1FBA}\u{345}\u{301}"),
    ("\u{1FF7}.txt", "\u{3A9}\u{342}\u{345}.txt"),
    ("\u{10403}\u{308}", "\u{1042B}\u{308}"),
    ("\u{10415}\u{306}", "\u{1043D}\u{306}"),
]

/// `a` then `b` created with O_EXCL in a fresh folder in `directory`: true when `b` meets `a` (EEXIST).
private func volumeJoins(_ a: String, _ b: String, in directory: URL) throws -> Bool {
    let probe = directory.appendingPathComponent("probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: probe) }
    let first = open(probe.appendingPathComponent(a).path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard first >= 0 else { return false }
    close(first)
    let second = open(probe.appendingPathComponent(b).path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    if second >= 0 { close(second); return false }
    return errno == EEXIST
}

@MainActor @Test(arguments: sequenceTwins.indices)
func sequenceTwinsTheVolumeJoinsAreAsked(_ index: Int) async throws {
    let (first, second) = sequenceTwins[index]
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    try #require(try volumeJoins(first, second, in: output))
    let model = makeModel([file(first), file(second)])
    #expect(model.extractionConflicts(nil, in: output) == [second])
    await #expect(throws: ExtractionConflictError(paths: [second])) {
        try await model.extract(nil, to: output, progress: nil)
    }
    #expect(try snapshot(output).isEmpty)

    try await model.extract(nil, to: output, resolutions: [second: .keepBoth], progress: nil)

    let names = try FileManager.default.contentsOfDirectory(atPath: output.path)
    #expect(names.count == 2)
    #expect(!names.contains { $0.hasPrefix(".kernir-") })
}

// Each fold call site pinned on a fold NFC + lowercased() misses (ß / SS), on the live case-insensitive
// volume.

/// Three twins on one name, all Replace: the last lands, once, with its own bytes. The survivor chain is
/// keyed by the fold, so `Straße` finds `STRASSE` as the survivor it replaces (`extract`'s survivors).
@MainActor @Test func threeFullFoldTwinsAllReplaceLandTheLast() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let model = makeModel([file("stra\u{DF}e"), file("STRASSE"), file("Stra\u{DF}e")])
    #expect(model.extractionConflicts(nil, in: output) == ["STRASSE", "Stra\u{DF}e"])

    try await model.extract(nil, to: output, resolutions: ["STRASSE": .replace, "Stra\u{DF}e": .replace],
                            progress: nil)

    #expect(try snapshot(output) == ["Stra\u{DF}e": "Stra\u{DF}e"])
}

/// Two requested folders the volume holds as one (`straße/`, `STRASSE/`) merge without asking
/// (`moveStaged`'s `foldedPath`).
@MainActor @Test func fullFoldFolderTwinsMergeWithoutAsking() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let model = makeModel([folder("stra\u{DF}e"), file("stra\u{DF}e/a"), folder("STRASSE"), file("STRASSE/b")])
    #expect(model.extractionConflicts(nil, in: output).isEmpty)

    try await model.extract(nil, to: output, progress: nil)

    #expect(try snapshot(output) == ["stra\u{DF}e": "dir", "stra\u{DF}e/a": "stra\u{DF}e/a", "stra\u{DF}e/b": "STRASSE/b"])
}

// The same two call sites keyed by `NameFold.key` on the name as spelled, never Foundation-NFC'd first:
// Foundation's NFC turns `\u{1042B}\u{308}` into `\u{4F8}` but leaves `\u{10403}\u{308}` a Cyrillic `\u{403}`
// and a mark, so an NFC-first key splits Deseret twins the volume joins.

/// Three Deseret twins on one name, all Replace: the last lands, alone. An NFC-first survivors key misses
/// the second twin as the third's survivor, and both reach staging (`extract`'s survivors).
@MainActor @Test func threeDeseretTwinsAllReplaceLandTheLast() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let (first, second, third) = ("\u{1042B}\u{308}a", "\u{10403}\u{308}a", "\u{1042B}\u{308}A")
    try #require(try volumeJoins(first, second, in: output) && volumeJoins(first, third, in: output))
    let model = makeModel([file(first), file(second), file(third)])
    #expect(model.extractionConflicts(nil, in: output) == [second, third])

    try await model.extract(nil, to: output, resolutions: [second: .replace, third: .replace], progress: nil)

    let landed = try snapshot(output)
    #expect(Array(landed.values) == [third])
    #expect(landed.keys.first.map { $0.unicodeScalars.elementsEqual(third.unicodeScalars) } == true)
}

/// Two requested Deseret folders the volume holds as one merge without asking. Keyed NFC-first, they are two
/// units on one staged folder: a conflict before anything moves (`moveStaged`'s `foldedPath`).
@MainActor @Test func deseretFolderTwinsMergeWithoutAsking() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let (lower, upper) = ("\u{1042B}\u{308}", "\u{10403}\u{308}")
    try #require(try volumeJoins(lower, upper, in: output))
    let model = makeModel([folder(lower), file("\(lower)/a"), folder(upper), file("\(upper)/b")])
    #expect(model.extractionConflicts([lower, upper], in: output).isEmpty)

    try await model.extract([lower, upper], to: output, progress: nil)

    let landed = try snapshot(output)
    #expect(landed.count == 3)
    #expect(landed.values.sorted() == ["\(lower)/a", "\(upper)/b", "dir"].sorted())
}

/// Keep Both for a disk conflict never takes a name another item of this extraction writes: `SS 2` is
/// `ß 2` on the volume, so the kept copy of `SS` goes to `SS 3`, and `ß 2` lands too (the reserved names).
@MainActor @Test func keepBothNeverTakesANameAFullFoldTwinWillWrite() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    try write("the user's", at: "SS", in: output)
    let model = makeModel([file("SS"), file("\u{DF} 2")])
    #expect(model.extractionConflicts(nil, in: output) == ["SS"])

    try await model.extract(nil, to: output, resolutions: ["SS": .keepBoth], progress: nil)

    #expect(try snapshot(output) == ["SS": "the user's", "SS 3": "SS", "\u{DF} 2": "\u{DF} 2"])
}

@MainActor @Test func twinAlsoOnDiskTakesOneAnswer() async throws {
    // "readme" on disk is in the way of both; the twin's key is the same "Readme" the disk conflict has.
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    try write("mine", at: "readme", in: output)
    let model = makeModel([file("README"), file("Readme")])
    #expect(model.extractionConflicts(nil, in: output) == ["Readme", "README"])

    try await model.extract(nil, to: output, resolutions: ["README": .keepBoth, "Readme": .keepBoth], progress: nil)

    #expect(try snapshot(output) == ["readme": "mine", "README 2": "README", "Readme 3": "Readme"])
}

@MainActor @Test func twinUnderASkippedFolderNeedsNoAnswerInExtract() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    try write("mine", at: "docs", in: output)
    let model = makeModel([file("docs/a.txt"), file("docs/A.txt"), file("z.txt")])
    #expect(model.extractionConflicts(nil, in: output) == ["docs", "docs/A.txt"])

    try await model.extract(nil, to: output, resolutions: ["docs": .skip], progress: nil)

    #expect(try snapshot(output) == ["docs": "mine", "z.txt": "z.txt"])
}

// MARK: - Three or more twins on one name (generated tar, real engine)
// One survivor per folded name, in archive order: Replace makes the later twin the survivor, Skip leaves the
// survivor be, Keep Both puts the later twin beside under keepBothName.

@MainActor @Test func threeTwinsAllReplaceIsTheEnginesLaterWins() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let (model, engine) = try await openTar(twinFiles(["README", "Readme", "readme"]), in: root)
    #expect(engine == ["readme": "readme", "other.txt": "other.txt"])
    let output = root.appendingPathComponent("model", isDirectory: true)
    #expect(model.extractionConflicts(nil, in: output) == ["Readme", "readme"])

    let written = try await model.extract(nil, to: output, resolutions: ["Readme": .replace, "readme": .replace],
                                          progress: nil)

    #expect(try snapshot(output) == engine)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == ["other.txt", "readme"])
    #expect(written.map(\.lastPathComponent).sorted() == ["other.txt", "readme"])

    // Whatever the reader does with twins it writes onto one name (FakeReader writes into the file already
    // there), only the last twin reaches staging.
    let fake = makeModel([file("README"), file("Readme"), file("readme")])
    let viaFake = root.appendingPathComponent("fake", isDirectory: true)
    let placed = try await fake.extract(nil, to: viaFake, resolutions: ["Readme": .replace, "readme": .replace],
                                        progress: nil)
    #expect(try snapshot(viaFake) == ["readme": "readme"])
    #expect(placed.map(\.lastPathComponent) == ["readme"])
}

@MainActor @Test func threeTwinsInAFolderAllReplaceIsTheEnginesLaterWins() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let (model, engine) = try await openTar([("docs", nil), ("docs/README", "README"), ("docs/Readme", "Readme"),
                                             ("docs/readme", "readme"), ("docs/z.txt", "z.txt")], in: root)
    #expect(engine == ["docs": "dir", "docs/readme": "readme", "docs/z.txt": "z.txt"])
    let output = root.appendingPathComponent("model", isDirectory: true)
    #expect(model.extractionConflicts(["docs"], in: output) == ["docs/Readme", "docs/readme"])

    try await model.extract(["docs"], to: output, resolutions: ["docs/Readme": .replace, "docs/readme": .replace],
                            progress: nil)

    #expect(try snapshot(output) == engine)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("docs").path).sorted()
        == ["readme", "z.txt"])
}

@MainActor @Test(arguments: [
    // Replace, then Keep Both: Readme takes README's place, readme goes beside it.
    (["Readme": ExtractionConflictResolution.replace, "readme": .keepBoth], ["Readme": "Readme", "readme 2": "readme"]),
    // Keep Both, then Replace: Readme goes beside, readme takes README's place.
    (["Readme": .keepBoth, "readme": .replace], ["readme": "readme", "Readme 2": "Readme"]),
    // Skip on the middle twin: the third is answered against README, which is still there.
    (["Readme": .skip, "readme": .replace], ["readme": "readme"]),
    (["Readme": .skip, "readme": .keepBoth], ["README": "README", "readme 2": "readme"]),
    // Replace, then Skip: Readme stays.
    (["Readme": .replace, "readme": .skip], ["Readme": "Readme"]),
    (["Readme": .skip, "readme": .skip], ["README": "README"]),
    (["Readme": .keepBoth, "readme": .keepBoth], ["README": "README", "Readme 2": "Readme", "readme 3": "readme"]),
])
func threeTwinsChainTheirAnswers(_ resolutions: [String: ExtractionConflictResolution],
                                 _ expected: [String: String]) async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let (model, _) = try await openTar(twinFiles(["README", "Readme", "readme"]), in: root)
    let output = root.appendingPathComponent("model", isDirectory: true)

    let written = try await model.extract(nil, to: output, resolutions: resolutions, progress: nil)

    let all = expected.merging(["other.txt": "other.txt"]) { a, _ in a }
    #expect(try snapshot(output) == all)
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() == all.keys.sorted())
    #expect(written.map(\.lastPathComponent).sorted() == all.keys.sorted())
}

@MainActor @Test func fourTwinsReplaceAcrossAKeepBoth() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let (model, _) = try await openTar(twinFiles(["README", "Readme", "readme", "rEADME"]), in: root)
    let output = root.appendingPathComponent("model", isDirectory: true)
    #expect(model.extractionConflicts(nil, in: output) == ["Readme", "readme", "rEADME"])

    try await model.extract(nil, to: output, resolutions: ["Readme": .replace, "readme": .keepBoth, "rEADME": .replace],
                            progress: nil)

    #expect(try snapshot(output) == ["rEADME": "rEADME", "readme 2": "readme", "other.txt": "other.txt"])

    let fake = makeModel([file("README"), file("Readme"), file("readme"), file("rEADME")])
    let viaFake = root.appendingPathComponent("fake", isDirectory: true)
    try await fake.extract(nil, to: viaFake, resolutions: ["Readme": .replace, "readme": .keepBoth, "rEADME": .replace],
                           progress: nil)
    #expect(try snapshot(viaFake) == ["rEADME": "rEADME", "readme 2": "readme"])
}

// MARK: - A create that collides where the lookup missed

// The iOS 27.2 Simulator's scratch volume says it folds case, but its lookups match exact case only
// (lstat "readme" with "README" there: ENOENT) while its creates still collide (RENAME_EXCL: EEXIST).
// Keep Both must not trust a lookup to say a name is free: a collision is that name taken, and the next
// Keep Both name is tried, a bounded number of times. Only EEXIST, only on Keep Both: any other error,
// and Replace, Skip or an unanswered item, throw as before. Here a fake rename collides on a name the
// (consistent) harness volume lookup finds free.

/// Renames through the real file system unless `rule` answers for the target's name and the flags.
/// Records every exclusive move's target name.
private final class CollidingRenames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    private let rule: @Sendable (_ name: String, _ flags: UInt32) -> Int32?

    init(_ rule: @escaping @Sendable (_ name: String, _ flags: UInt32) -> Int32?) { self.rule = rule }

    /// Exclusive moves to a "Readme…" name, in order.
    var readmeTargets: [String] { lock.withLock { names.filter { $0.hasPrefix("Readme") } } }

    func fileSystem() -> ExtractionFileSystem {
        ExtractionFileSystem(deviceToken: "feedface00000001") { from, to, flags in
            let name = (to as NSString).lastPathComponent
            if flags == UInt32(RENAME_EXCL) { self.lock.withLock { self.names.append(name) } }
            return self.rule(name, flags) ?? ExtractionFileSystem.system.rename(from, to, flags)
        }
    }
}

/// "twin": both twins extracted, Readme answered for beside README. "disk": README already on disk,
/// Readme alone extracted onto it.
private let routes = ["twin", "disk"]

@MainActor
private func extractReadme(_ route: String, _ resolution: ExtractionConflictResolution, in output: URL,
                           renames: CollidingRenames) async throws -> [URL] {
    let model = try await openFixture("zip/case-twins.zip")
    model.extractionFileSystem = renames.fileSystem()
    if route == "disk" {
        try write(upper, at: "README", in: output)
        return try await model.extract(["Readme"], to: output, resolutions: ["Readme": resolution], progress: nil)
    }
    return try await model.extract(["README", "Readme"], to: output, resolutions: ["Readme": resolution],
                                   progress: nil)
}

@MainActor @Test(arguments: routes)
func keepBothTakesTheNextNameWhenTheCreateCollides(_ route: String) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    // "Readme 2" looks free, as "readme 2" would to the Simulator with "README 2" there.
    let renames = CollidingRenames { name, flags in
        name == "Readme 2" && flags == UInt32(RENAME_EXCL) ? EEXIST : nil
    }

    let written = try await extractReadme(route, .keepBoth, in: output, renames: renames)

    #expect(try snapshot(output) == ["README": upper, "Readme 3": mixed])
    #expect(written.last?.lastPathComponent == "Readme 3")
    #expect(renames.readmeTargets == ["Readme 2", "Readme 3"])
}

@MainActor @Test(arguments: routes)
func keepBothDoesNotRetryAnErrorOtherThanACollision(_ route: String) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let renames = CollidingRenames { name, flags in
        name == "Readme 2" && flags == UInt32(RENAME_EXCL) ? EACCES : nil
    }

    await #expect(throws: POSIXError(.EACCES)) {
        try await extractReadme(route, .keepBoth, in: output, renames: renames)
    }
    #expect(renames.readmeTargets == ["Readme 2"])
    #expect(try snapshot(output) == ["README": upper])
}

@MainActor @Test(arguments: routes)
func keepBothStopsAfterABoundedNumberOfCollidingNames(_ route: String) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let renames = CollidingRenames { name, flags in
        name.hasPrefix("Readme ") && flags == UInt32(RENAME_EXCL) ? EEXIST : nil
    }

    // Not a conflict: answering it again would meet the same collisions.
    await #expect(throws: POSIXError(.EEXIST)) {
        try await extractReadme(route, .keepBoth, in: output, renames: renames)
    }
    #expect(renames.readmeTargets.count == ArchiveModel.keepBothAttempts)
    #expect(renames.readmeTargets.first == "Readme 2")
    #expect(renames.readmeTargets.last == "Readme \(ArchiveModel.keepBothAttempts + 1)")
    #expect(try snapshot(output) == ["README": upper])
}

@MainActor @Test(arguments: routes)
func replaceThatCollidesStaysAConflict(_ route: String) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    // Disk route: the swap finds README gone, so Readme moves in exclusively, and collides.
    let renames = CollidingRenames { name, flags in
        if flags == UInt32(RENAME_SWAP) { return ENOENT }
        return name == "Readme" && flags == UInt32(RENAME_EXCL) ? EEXIST : nil
    }

    await #expect(throws: ExtractionConflictError(paths: ["Readme"])) {
        try await extractReadme(route, .replace, in: output, renames: renames)
    }
    #expect(renames.readmeTargets == ["Readme"])
}

@MainActor @Test func unansweredItemThatCollidesStaysAConflictBesideASkip() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let renames = CollidingRenames { name, flags in
        name == "other.txt" && flags == UInt32(RENAME_EXCL) ? EEXIST : nil
    }
    let model = try await openFixture("zip/case-twins.zip")
    model.extractionFileSystem = renames.fileSystem()

    await #expect(throws: ExtractionConflictError(paths: ["other.txt"])) {
        try await model.extract(nil, to: output, resolutions: ["Readme": .skip], progress: nil)
    }
    #expect(renames.readmeTargets.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("other 2.txt").path))
}

// MARK: - Hidden "/" (scalar split)

/// A twin behind a hidden "/" (`d/\u{301}A` beside `d/\u{301}a`) is inside `d`: kept beside a folder on disk as
/// "d 2", it follows that folder there, never into the user's own `d` (`ArchiveEntry.components(of:)`). Extract
/// All: the core's tree lists `d/\u{301}a` at the top, not in `d`, but the extraction places it by the scalar.
@MainActor @Test func aTwinBehindAHiddenSlashFollowsItsFolderKeptBeside() async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let model = makeModel([folder("d"), file("d/\u{301}a"), file("d/\u{301}A")])
    try write("mine", at: "d/mine.txt", in: root)
    let conflicts = model.extractionConflicts(nil, in: root)
    #expect(Set(conflicts.map { Array($0.unicodeScalars) }) == [Array("d".unicodeScalars),
                                                                Array("d/\u{301}A".unicodeScalars)])

    try await model.extract(nil, to: root, resolutions: ["d": .keepBoth, "d/\u{301}A": .keepBoth], progress: nil)
    #expect(try snapshot(root) == ["d": "dir", "d/mine.txt": "mine", "d 2": "dir",
                                   "d 2/\u{301}a": "d/\u{301}a", "d 2/\u{301}A 2": "d/\u{301}A"])
}

/// A file system without RENAME_EXCL answers ENOTSUP or EOPNOTSUPP (separate numbers on Darwin): Keep Both
/// checks, then renames plainly, on its own name when free and on the next Keep Both name when taken.
@Test(arguments: [ENOTSUP, EOPNOTSUPP], [false, true])
func keepBothWithoutExclusiveRenameChecksThenRenames(_ code: Int32, _ isTaken: Bool) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    if isTaken { try write("mine", at: "a.txt", in: output) } else {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }
    try write("twin", at: "staged/a.txt", in: root)
    let noExclusive = ExtractionFileSystem(deviceToken: "feedface00000000") { from, to, flags in
        if flags == UInt32(RENAME_EXCL) { return code }
        return renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/a.txt"),
                                                  to: output.appendingPathComponent("a.txt"), isDirectory: false,
                                                  path: "a.txt", in: output, reserved: &reserved, fileSystem: noExclusive)
    #expect(placed.lastPathComponent == (isTaken ? "a 2.txt" : "a.txt"))
    #expect(try snapshot(output) == (isTaken ? ["a.txt": "mine", "a 2.txt": "twin"] : ["a.txt": "twin"]))
}

/// The app's one no-RENAME_EXCL list, the same as the core's: ENOTSUP (45), EOPNOTSUPP (102) and EINVAL fall
/// back to check-then-rename; a collision (EEXIST) or a refusal (EPERM) never does.
@Test(arguments: [(Int32(45), true), (Int32(102), true), (EINVAL, true), (EEXIST, false), (EPERM, false)])
func lacksExclusiveRenameIsTheNoRenameExclList(_ code: Int32, _ lacks: Bool) {
    #expect(ArchiveModel.lacksExclusiveRename(code) == lacks, "errno \(code)")
}

/// Without RENAME_EXCL the check before the plain rename is all that keeps an item from being replaced. Here
/// one arrives at the name as the exclusive rename is refused (after every earlier look): `moveExclusively`
/// (an unanswered item) stays a conflict and leaves it alone.
@MainActor @Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL])
func withoutExclusiveRenameAnItemThatArrivesIsNeverReplaced(_ code: Int32) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let model = try await openFixture("zip/case-twins.zip")
    let folderName = output.lastPathComponent
    model.extractionFileSystem = ExtractionFileSystem(deviceToken: "feedface00000002") { from, to, flags in
        let target = URL(fileURLWithPath: to)
        if flags == UInt32(RENAME_EXCL), target.lastPathComponent == "other.txt",
           target.deletingLastPathComponent().lastPathComponent == folderName {
            try? "arrived meanwhile".write(to: target, atomically: false, encoding: .utf8)
            return code
        }
        return renamex_np(from, to, flags) == 0 ? 0 : errno
    }

    await #expect(throws: ExtractionConflictError(paths: ["other.txt"])) {
        try await model.extract(["other.txt"], to: output, progress: nil)
    }
    #expect(try snapshot(output) == ["other.txt": "arrived meanwhile"])
}

/// The same for Keep Both (`moveKeepingBoth`): the item that arrived keeps its name, and the twin takes the
/// next Keep Both name.
@Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL])
func keepBothWithoutExclusiveRenameNeverReplacesAnItemThatArrives(_ code: Int32) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try write("twin", at: "staged/a.txt", in: root)
    let noExclusive = ExtractionFileSystem(deviceToken: "feedface00000000") { from, to, flags in
        if flags == UInt32(RENAME_EXCL), URL(fileURLWithPath: to).lastPathComponent == "a.txt" {
            try? "arrived meanwhile".write(toFile: to, atomically: false, encoding: .utf8)
            return code
        }
        if flags == UInt32(RENAME_EXCL) { return code }
        return renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/a.txt"),
                                                  to: output.appendingPathComponent("a.txt"), isDirectory: false,
                                                  path: "a.txt", in: output, reserved: &reserved, fileSystem: noExclusive)
    #expect(placed.lastPathComponent == "a 2.txt")
    #expect(try snapshot(output) == ["a.txt": "arrived meanwhile", "a 2.txt": "twin"])
}

/// Without RENAME_EXCL, the plain rename itself can collide: rename(2) gives EEXIST when a folder that isn't
/// empty took the name after the check. That is the same collision RENAME_EXCL reports, so Keep Both takes the
/// next name, "a 2.txt", and the folder that arrived is left alone.
@Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL])
func keepBothWithoutExclusiveRenameTakesTheNextNameWhenThePlainRenameCollides(_ code: Int32) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try write("twin", at: "staged/a.txt", in: root)
    let noExclusive = ExtractionFileSystem(deviceToken: "feedface00000000") { from, to, flags in
        if flags == UInt32(RENAME_EXCL) { return code }
        if URL(fileURLWithPath: to).lastPathComponent == "a.txt" {
            try? FileManager.default.createDirectory(atPath: to, withIntermediateDirectories: false)
            try? "arrived meanwhile".write(toFile: to + "/inside", atomically: false, encoding: .utf8)
            return EEXIST
        }
        return renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/a.txt"),
                                                  to: output.appendingPathComponent("a.txt"), isDirectory: false,
                                                  path: "a.txt", in: output, reserved: &reserved, fileSystem: noExclusive)
    #expect(placed.lastPathComponent == "a 2.txt")
    #expect(try snapshot(output) == ["a.txt": "dir", "a.txt/inside": "arrived meanwhile", "a 2.txt": "twin"])
}

/// The same plain-rename collision for an unanswered item (`moveExclusively`) is a conflict, as RENAME_EXCL's
/// EEXIST is, never a bare POSIX error, and the folder that arrived is left alone.
@MainActor @Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL])
func withoutExclusiveRenameAPlainRenameThatCollidesIsAConflict(_ code: Int32) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let model = try await openFixture("zip/case-twins.zip")
    let folderName = output.lastPathComponent
    model.extractionFileSystem = ExtractionFileSystem(deviceToken: "feedface00000002") { from, to, flags in
        let target = URL(fileURLWithPath: to)
        let isOther = target.lastPathComponent == "other.txt"
            && target.deletingLastPathComponent().lastPathComponent == folderName
        if isOther, flags == UInt32(RENAME_EXCL) { return code }
        if isOther, flags == 0 {
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try? "arrived meanwhile".write(to: target.appendingPathComponent("inside"), atomically: false,
                                           encoding: .utf8)
            return EEXIST
        }
        return renamex_np(from, to, flags) == 0 ? 0 : errno
    }

    await #expect(throws: ExtractionConflictError(paths: ["other.txt"])) {
        try await model.extract(["other.txt"], to: output, progress: nil)
    }
    #expect(try snapshot(output) == ["other.txt": "dir", "other.txt/inside": "arrived meanwhile"])
}

// MARK: - No RENAME_EXCL: a case twin the lookup misses

// Without RENAME_EXCL the check before the plain rename is all that keeps an item from being replaced, and
// rename(2) replaces a file, or an empty folder, silently. Where the volume isn't known to keep case apart, the
// check also lists the folder for a case twin (`NameFold.key`), since a lookup can miss one: the iOS Simulator's
// scratch volume's does, and that is the lookup the fake here stands in for. The harness volume holds the twin
// for real, so a plain rename the check let through would replace it.

/// No RENAME_EXCL (`code`), a lookup that misses `missing` (lstat ENOENT) and the volume's case answer
/// `caseSensitive` (nil: unknown); renames go to the real file system. Also `UniquePlacementTests`'.
func noExclusiveRename(_ code: Int32, missing: String, caseSensitive: Bool?) -> ExtractionFileSystem {
    var fileSystem = ExtractionFileSystem(deviceToken: "feedface00000000") { from, to, flags in
        if flags == UInt32(RENAME_EXCL) { return code }
        return renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    fileSystem.exists = { path in
        var status = stat()
        return (path as NSString).lastPathComponent != missing && lstat(path, &status) == 0
    }
    fileSystem.caseSensitivity = DestinationCaseSensitivity(exists: { _ in true },
                                                            supportsCaseSensitiveNames: { _ in caseSensitive })
    return fileSystem
}

/// A file twin the lookup misses is a collision where the volume says it folds case, and where the answer is
/// unknown: Keep Both takes "readme 2" and README stays as it was.
@Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL], [Bool?.none, false])
func withoutExclusiveRenameAFileTwinTheLookupMissesIsNeverReplaced(_ code: Int32, _ caseSensitive: Bool?) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("mine", at: "README", in: output)
    try write("twin", at: "staged/readme", in: root)
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/readme"),
                                                  to: output.appendingPathComponent("readme"), isDirectory: false,
                                                  path: "readme", in: output, reserved: &reserved,
                                                  fileSystem: noExclusiveRename(code, missing: "readme",
                                                                                caseSensitive: caseSensitive))
    #expect(placed.lastPathComponent == "readme 2")
    #expect(try snapshot(output) == ["README": "mine", "readme 2": "twin"])
}

/// An empty folder is the item rename(2) replaces with a folder: one that arrives as RENAME_EXCL is refused,
/// on the name itself ("docs") or as a twin the lookup misses ("Docs"), stays, and the folder takes "docs 2".
@Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL], ["docs", "Docs"])
func withoutExclusiveRenameAnEmptyFolderIsNeverReplaced(_ code: Int32, _ arriving: String) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try write("twin", at: "staged/docs/a.txt", in: root)
    var fileSystem = noExclusiveRename(code, missing: arriving == "docs" ? "" : "docs", caseSensitive: nil)
    let rename = fileSystem.rename
    fileSystem.rename = { from, to, flags in
        if flags == UInt32(RENAME_EXCL), (to as NSString).lastPathComponent == "docs" {
            mkdir(output.appendingPathComponent(arriving).path, 0o755)
        }
        return rename(from, to, flags)
    }
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/docs"),
                                                  to: output.appendingPathComponent("docs"), isDirectory: true,
                                                  path: "docs", in: output, reserved: &reserved, fileSystem: fileSystem)
    #expect(placed.lastPathComponent == "docs 2")
    #expect(try snapshot(output) == [arriving: "dir", "docs 2": "dir", "docs 2/a.txt": "twin"])
}

/// A name without a twin there still moves on its own name.
@Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL])
func withoutExclusiveRenameANameWithoutATwinStillMoves(_ code: Int32) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("mine", at: "README", in: output)
    try write("other", at: "staged/other.txt", in: root)
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/other.txt"),
                                                  to: output.appendingPathComponent("other.txt"), isDirectory: false,
                                                  path: "other.txt", in: output, reserved: &reserved,
                                                  fileSystem: noExclusiveRename(code, missing: "other.txt",
                                                                                caseSensitive: nil))
    #expect(placed.lastPathComponent == "other.txt")
    #expect(try snapshot(output) == ["README": "mine", "other.txt": "other"])
}

/// A volume that says it keeps case apart has no case twins: "readme" beside README is free there, so it
/// isn't listed for one. (The fakes stand for such a volume. On the harness volume the plain rename then
/// does what that volume's wouldn't, so only where the item went is checked.)
@Test func withoutExclusiveRenameACaseSensitiveVolumeHasNoCaseTwins() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("mine", at: "README", in: output)
    try write("twin", at: "staged/readme", in: root)
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/readme"),
                                                  to: output.appendingPathComponent("readme"), isDirectory: false,
                                                  path: "readme", in: output, reserved: &reserved,
                                                  fileSystem: noExclusiveRename(ENOTSUP, missing: "readme",
                                                                                caseSensitive: true))
    #expect(placed.lastPathComponent == "readme")
}

/// A folder that can't be listed (a write-only drop box, 0333) shows no twin: the check fails open on purpose,
/// and the lookup still refuses the exact name. A twin the lookup misses goes ahead as without the check (on the harness
/// volume the plain rename then replaces README); the exact name keeps both.
@Test(arguments: [false, true])
func withoutExclusiveRenameAFolderThatCantBeListedChecksOnlyTheExactName(_ isTwin: Bool) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("mine", at: "README", in: output)
    let name = isTwin ? "readme" : "README"
    try write("new", at: "staged/\(name)", in: root)
    #expect(chmod(output.path, 0o333) == 0)
    defer { chmod(output.path, 0o755) }
    #expect((try? FileManager.default.contentsOfDirectory(atPath: output.path)) == nil)
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/\(name)"),
                                                  to: output.appendingPathComponent(name), isDirectory: false,
                                                  path: name, in: output, reserved: &reserved,
                                                  fileSystem: noExclusiveRename(ENOTSUP, missing: isTwin ? name : "",
                                                                                caseSensitive: nil))
    chmod(output.path, 0o755)
    #expect(placed.lastPathComponent == (isTwin ? "readme" : "README 2"))
    // The replaced twin keeps whichever spelling the volume keeps (APFS: README's), so only the contents count.
    if isTwin {
        #expect(Array(try snapshot(output).values) == ["new"])
    } else {
        #expect(try snapshot(output) == ["README": "mine", "README 2": "new"])
    }
}

/// Counts a fake's calls (folder listings, case probes). Also `UniquePlacementTests`'.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func record() { lock.withLock { calls += 1 } }
}

/// `fileSystem` whose listings all fail with `code`, counted in `listings`. Also `UniquePlacementTests`'.
func failingListings(_ code: Int32, _ fileSystem: ExtractionFileSystem,
                     counting listings: CallCounter) -> ExtractionFileSystem {
    var fileSystem = fileSystem
    fileSystem.listNames = { _ in
        listings.record()
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    return fileSystem
}

/// Only a folder that can't be listed for permission (EACCES, EPERM: a write-only drop box) fails open. Any other
/// listing error (EIO; ENOENT or ENOTDIR from a folder swapped meanwhile; EINTR) is no answer: the folder is
/// listed once more, then the error throws, nothing is renamed and the item stays where it was.
@Test(arguments: [EIO, ENOENT, ENOTDIR, EINTR])
func withoutExclusiveRenameAListingErrorOtherThanPermissionMovesNothing(_ code: Int32) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("mine", at: "README", in: output)
    try write("twin", at: "staged/readme", in: root)
    let listings = CallCounter()
    let fileSystem = failingListings(code, noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil),
                                     counting: listings)
    var reserved: Set<String> = []

    #expect(throws: POSIXError(POSIXErrorCode(rawValue: code)!)) {
        try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/readme"),
                                         to: output.appendingPathComponent("readme"), isDirectory: false,
                                         path: "readme", in: output, reserved: &reserved, fileSystem: fileSystem)
    }
    #expect(listings.count == 2)
    #expect(try snapshot(output) == ["README": "mine"])
    #expect(try snapshot(root.appendingPathComponent("staged")) == ["readme": "twin"])
}

/// EACCES or EPERM from the listing fails open: a name without a twin moves (the 0333 folder above is the real one).
@Test(arguments: [EACCES, EPERM])
func withoutExclusiveRenameAPermissionListingErrorFailsOpen(_ code: Int32) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("mine", at: "README", in: output)
    try write("other", at: "staged/other.txt", in: root)
    let listings = CallCounter()
    let fileSystem = failingListings(code, noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil),
                                     counting: listings)
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/other.txt"),
                                                  to: output.appendingPathComponent("other.txt"), isDirectory: false,
                                                  path: "other.txt", in: output, reserved: &reserved,
                                                  fileSystem: fileSystem)
    #expect(placed.lastPathComponent == "other.txt")
    #expect(listings.count == 1)
    #expect(try snapshot(output) == ["README": "mine", "other.txt": "other"])
}

/// The twin check keys names by `NameFold.key`, not `lowercased()`: "straße" beside STRASSE, which the volume
/// holds as one name, is a twin the lookup misses too, and is never replaced.
@Test func withoutExclusiveRenameAFullCaseFoldingTwinIsNeverReplaced() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(try volumeJoins("stra\u{DF}e", "STRASSE", in: root))
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("mine", at: "STRASSE", in: output)
    try write("twin", at: "staged/stra\u{DF}e", in: root)
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/stra\u{DF}e"),
                                                  to: output.appendingPathComponent("stra\u{DF}e"), isDirectory: false,
                                                  path: "stra\u{DF}e", in: output, reserved: &reserved,
                                                  fileSystem: noExclusiveRename(ENOTSUP, missing: "stra\u{DF}e",
                                                                                caseSensitive: nil))
    #expect(placed.lastPathComponent == "stra\u{DF}e 2")
    #expect(try snapshot(output) == ["STRASSE": "mine", "stra\u{DF}e 2": "twin"])
}

// MARK: - No RENAME_EXCL: each folder listed once per operation

// One merge, placement or extraction lists a folder once, at its first check, and adds the names it puts there
// (`CaseTwinListings`). The listing answers only for case twins: the lookup still runs for every item.

/// `fileSystem` with live listings, counted in `listings`; `afterListing` runs after each (another process making
/// an item right after it). Also `UniquePlacementTests`'.
func countingListings(_ fileSystem: ExtractionFileSystem, _ listings: CallCounter,
                      afterListing: @escaping @Sendable () -> Void = {}) -> ExtractionFileSystem {
    var fileSystem = fileSystem
    fileSystem.listNames = { folder in
        listings.record()
        defer { afterListing() }
        return try ExtractionFileSystem.names(in: folder)
    }
    return fileSystem
}

/// Live renames (RENAME_EXCL works), with the case probes counted in `probes`, the listings in `listings` and the
/// folder identity reads in `identities`. Also `UniquePlacementTests`'.
func exclusiveRenameCountingChecks(probes: CallCounter, listings: CallCounter,
                                   identities: CallCounter) -> ExtractionFileSystem {
    var fileSystem = ExtractionFileSystem(deviceToken: "feedface00000000") { from, to, flags in
        renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    fileSystem.caseSensitivity = DestinationCaseSensitivity(exists: { _ in true },
                                                            supportsCaseSensitiveNames: { _ in probes.record(); return nil })
    fileSystem.identity = { identities.record(); return try ExtractionFileSystem.identity(of: $0) }
    return countingListings(fileSystem, listings)
}

/// The check is the fallback's alone: where RENAME_EXCL works, nothing is probed, listed or read for its identity.
@Test func withExclusiveRenameNothingIsProbedOrListed() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("mine", at: "README", in: output)
    try write("new", at: "staged/other.txt", in: root)
    let probes = CallCounter(), listings = CallCounter(), identities = CallCounter()
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/other.txt"),
                                                  to: output.appendingPathComponent("other.txt"), isDirectory: false,
                                                  path: "other.txt", in: output, reserved: &reserved,
                                                  fileSystem: exclusiveRenameCountingChecks(probes: probes,
                                                                                            listings: listings,
                                                                                            identities: identities))
    #expect(placed.lastPathComponent == "other.txt")
    #expect(probes.count == 0)
    #expect(listings.count == 0)
    #expect(identities.count == 0)
}

/// A merge of n items into one folder lists it once, not once per item, and asks its volume once whether it
/// folds case (a round trip on SMB): the check's cost, bounded without a clock. A folder that can't be listed
/// for permission (EACCES) is kept as such: one try, then no more.
@Test(arguments: [0, EACCES])
func withoutExclusiveRenameAMergeListsTheFolderOnce(_ listingError: Int32) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let count = 300
    let source = root.appendingPathComponent("staged/D", isDirectory: true)
    let target = root.appendingPathComponent("D", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    for index in 0..<count { try write("x", at: "staged/D/file-\(index).txt", in: root) }
    let listings = CallCounter(), probes = CallCounter()
    var fileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil), listings)
    if listingError != 0 { fileSystem = failingListings(listingError, fileSystem, counting: listings) }
    fileSystem.caseSensitivity = DestinationCaseSensitivity(exists: { _ in true },
                                                            supportsCaseSensitiveNames: { _ in probes.record(); return nil })

    try ArchiveModel.moveMerging(source, to: target, path: "D", in: root, fileSystem: fileSystem)

    #expect(listings.count == 1)
    #expect(probes.count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).count == count)
}

/// A volume that keeps case apart is asked once per folder too, and never listed.
@Test func withoutExclusiveRenameACaseSensitiveFolderIsAskedOnce() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("staged/D", isDirectory: true)
    let target = root.appendingPathComponent("D", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    for index in 0..<20 { try write("x", at: "staged/D/file-\(index).txt", in: root) }
    let listings = CallCounter(), probes = CallCounter()
    var fileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil), listings)
    fileSystem.caseSensitivity = DestinationCaseSensitivity(exists: { _ in true },
                                                            supportsCaseSensitiveNames: { _ in probes.record(); return true })

    try ArchiveModel.moveMerging(source, to: target, path: "D", in: root, fileSystem: fileSystem)

    #expect(probes.count == 1)
    #expect(listings.count == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).count == 20)
}

/// On a volume that keeps case apart, the check costs one lstat per item, not three: the folder's identity is
/// read once per operation, and the lookup runs again only when something touched the disk since the first one
/// (the identity read, the case probe, a listing). So a merge of n items into one folder: the merge's own lookup of
/// the folder, then each item's, plus the first item's second one; one identity read.
@Test func withoutExclusiveRenameACaseSensitiveMergeLooksEachItemUpOnce() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let count = 20
    let source = root.appendingPathComponent("staged/D", isDirectory: true)
    let target = root.appendingPathComponent("D", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    for index in 0..<count { try write("x", at: "staged/D/file-\(index).txt", in: root) }
    let lookups = CallCounter(), identities = CallCounter()
    var fileSystem = noExclusiveRename(ENOTSUP, missing: "", caseSensitive: true)
    let exists = fileSystem.exists, identity = fileSystem.identity
    fileSystem.exists = { lookups.record(); return exists($0) }
    fileSystem.identity = { identities.record(); return try identity($0) }

    try ArchiveModel.moveMerging(source, to: target, path: "D", in: root, fileSystem: fileSystem)

    #expect(identities.count == 1)
    #expect(lookups.count == 1 + count + 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).count == count)
}

/// Two spellings of one folder (docs, Docs) are one folder to the check: its listing is kept by the folder's
/// identity (device and inode), not by how the path is spelled. So README, put through "docs" after the folder
/// was listed through "Docs", is a twin of a later "Docs/readme" that the lookup misses, which is refused.
@Test func withoutExclusiveRenameTwoSpellingsOfOneFolderShareOneListing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output.appendingPathComponent("docs"),
                                            withIntermediateDirectories: true)
    // Each in a staging folder of its own: on the harness volume README and readme are one name.
    try write("x", at: "staged/1/x.txt", in: root)
    try write("mine", at: "staged/2/README", in: root)
    try write("new", at: "staged/3/readme", in: root)
    let listings = CallCounter()
    let fileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil), listings)
    let twins = CaseTwinListings()
    let staged = root.appendingPathComponent("staged", isDirectory: true)
    try ArchiveModel.moveMerging(staged.appendingPathComponent("1/x.txt"),
                                 to: output.appendingPathComponent("Docs/x.txt"), path: "Docs/x.txt", in: root,
                                 fileSystem: fileSystem, twins: twins)
    try ArchiveModel.moveMerging(staged.appendingPathComponent("2/README"),
                                 to: output.appendingPathComponent("docs/README"), path: "docs/README", in: root,
                                 fileSystem: fileSystem, twins: twins)

    #expect(throws: ExtractionConflictError(paths: ["Docs/readme"])) {
        try ArchiveModel.moveMerging(staged.appendingPathComponent("3/readme"),
                                     to: output.appendingPathComponent("Docs/readme"), path: "Docs/readme", in: root,
                                     fileSystem: fileSystem, twins: twins)
    }
    #expect(listings.count == 1)
    #expect(try snapshot(output) == ["docs": "dir", "docs/x.txt": "x", "docs/README": "mine"])
    #expect(try snapshot(staged.appendingPathComponent("3")) == ["readme": "new"])
}

/// A folder whose identity can't be read for permission (EACCES, EPERM) is kept by its path instead: read once and
/// listed once per operation, and a twin the lookup misses is still refused.
@Test(arguments: [EACCES, EPERM])
func withoutExclusiveRenameAFolderWithoutAnIdentityIsKeptByPath(_ code: Int32) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("mine", at: "README", in: output)
    try write("a", at: "staged/a.txt", in: root)
    try write("new", at: "staged/readme", in: root)
    let listings = CallCounter(), identities = CallCounter()
    var fileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil), listings)
    fileSystem.identity = { _ in
        identities.record()
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    let twins = CaseTwinListings()
    let staged = root.appendingPathComponent("staged", isDirectory: true)
    try ArchiveModel.moveMerging(staged.appendingPathComponent("a.txt"), to: output.appendingPathComponent("a.txt"),
                                 path: "a.txt", in: root, fileSystem: fileSystem, twins: twins)

    #expect(throws: ExtractionConflictError(paths: ["readme"])) {
        try ArchiveModel.moveMerging(staged.appendingPathComponent("readme"),
                                     to: output.appendingPathComponent("readme"), path: "readme", in: root,
                                     fileSystem: fileSystem, twins: twins)
    }
    #expect(identities.count == 1)
    #expect(listings.count == 1)
    #expect(try snapshot(output) == ["README": "mine", "a.txt": "a"])
}

/// Two different folders whose identities match (a volume without RENAME_EXCL may report inode 0, or a synthesized
/// or reused one) never share a listing: a folder is kept by its identity and its folded path. So a twin already
/// in the second folder, which the lookup misses, is still refused after the first folder was listed.
@Test func withoutExclusiveRenameTwoFoldersThatShareAnIdentityAreListedApart() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output.appendingPathComponent("A"), withIntermediateDirectories: true)
    try write("mine", at: "B/README", in: output)
    try write("x", at: "staged/x.txt", in: root)
    try write("new", at: "staged/readme", in: root)
    let listings = CallCounter()
    var fileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil), listings)
    fileSystem.identity = { _ in ExtractionFileSystem.Identity(device: 1, inode: 0) }
    let twins = CaseTwinListings()
    let staged = root.appendingPathComponent("staged", isDirectory: true)
    try ArchiveModel.moveMerging(staged.appendingPathComponent("x.txt"), to: output.appendingPathComponent("A/x.txt"),
                                 path: "A/x.txt", in: root, fileSystem: fileSystem, twins: twins)

    #expect(throws: ExtractionConflictError(paths: ["B/readme"])) {
        try ArchiveModel.moveMerging(staged.appendingPathComponent("readme"),
                                     to: output.appendingPathComponent("B/readme"), path: "B/readme", in: root,
                                     fileSystem: fileSystem, twins: twins)
    }
    #expect(listings.count == 2)
    #expect(try snapshot(output) == ["A": "dir", "A/x.txt": "x", "B": "dir", "B/README": "mine"])
    #expect(try snapshot(staged) == ["readme": "new"])
}

/// The calls the check makes, in order. Also `UniquePlacementTests`'.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var events: [String] { lock.withLock { calls } }
    func record(_ call: String) { lock.withLock { calls.append(call) } }
}

/// The exact-name lookup runs again last, right before the plain rename: the folder's identity read and its first
/// listing (seconds for a big SMB folder) come before it, so they never widen the gap between lookup and rename.
@Test func withoutExclusiveRenameTheLookupRunsRightBeforeThePlainRename() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try write("new", at: "staged/other.txt", in: root)
    let log = CallLog()
    var fileSystem = noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil)
    let exists = fileSystem.exists, rename = fileSystem.rename, identity = fileSystem.identity
    fileSystem.exists = { log.record("exists"); return exists($0) }
    fileSystem.rename = { from, to, flags in
        log.record(flags == UInt32(RENAME_EXCL) ? "exclusive rename" : "rename")
        return rename(from, to, flags)
    }
    fileSystem.identity = { log.record("identity"); return try identity($0) }
    fileSystem.listNames = { log.record("listing"); return try ExtractionFileSystem.names(in: $0) }
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/other.txt"),
                                                  to: output.appendingPathComponent("other.txt"), isDirectory: false,
                                                  path: "other.txt", in: output, reserved: &reserved,
                                                  fileSystem: fileSystem)
    #expect(placed.lastPathComponent == "other.txt")
    // Keep Both's own lookup first, then the check: the lookup, identity, listing, and the lookup again last.
    #expect(log.events == ["exists", "exclusive rename", "exists", "identity", "listing", "exists", "rename"])
}

/// A folder's identity is the folder its listing lists (stat(2), which follows a symlink as opendir(3) does), so a
/// symlinked parent is keyed by the folder it leads to, not by the link: the link and its folder report one
/// identity. A missing path throws ENOENT.
@Test func aFoldersIdentityFollowsASymlinkAsItsListingDoes() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("real", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

    #expect(try ExtractionFileSystem.identity(of: link.path) == ExtractionFileSystem.identity(of: folder.path))
    #expect(try ExtractionFileSystem.names(in: link.path) == ExtractionFileSystem.names(in: folder.path))
    #expect(throws: POSIXError(.ENOENT)) {
        try ExtractionFileSystem.identity(of: root.appendingPathComponent("missing").path)
    }
}

/// Any other error reading the folder's identity is no answer, as with a listing: read once more, then it throws,
/// and nothing is listed or renamed.
@Test(arguments: [EIO, ENOENT, ENOTDIR, EINTR])
func withoutExclusiveRenameAnIdentityErrorOtherThanPermissionMovesNothing(_ code: Int32) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("mine", at: "README", in: output)
    try write("other", at: "staged/other.txt", in: root)
    let listings = CallCounter(), identities = CallCounter()
    var fileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil), listings)
    fileSystem.identity = { _ in
        identities.record()
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    #expect(throws: POSIXError(POSIXErrorCode(rawValue: code)!)) {
        try ArchiveModel.moveMerging(root.appendingPathComponent("staged/other.txt"),
                                     to: output.appendingPathComponent("other.txt"), path: "other.txt", in: root,
                                     fileSystem: fileSystem)
    }
    #expect(identities.count == 2)
    #expect(listings.count == 0)
    #expect(try snapshot(output) == ["README": "mine"])
    #expect(try snapshot(root.appendingPathComponent("staged")) == ["other.txt": "other"])
}

/// Names this operation put in a folder are never taken out: README landed, then left (moved away, or renamed in
/// place), and a later "readme" in the same operation is still refused as its twin, without a fresh listing.
/// A stale name costs a conflict or the next name, never a replace.
@Test(arguments: [false, true])
func withoutExclusiveRenameANamePutThereIsNeverTakenOut(_ renamedInPlace: Bool) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    // Each in a staging folder of its own: on the harness volume README and readme are one name.
    try write("mine", at: "staged/1/README", in: root)
    try write("new", at: "staged/2/readme", in: root)
    let listings = CallCounter()
    let fileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil), listings)
    let twins = CaseTwinListings()
    let staged = root.appendingPathComponent("staged", isDirectory: true)
    try ArchiveModel.moveMerging(staged.appendingPathComponent("1/README"),
                                 to: output.appendingPathComponent("README"), path: "README", in: root,
                                 fileSystem: fileSystem, twins: twins)
    let away = renamedInPlace ? output.appendingPathComponent("notes") : root.appendingPathComponent("away")
    try FileManager.default.moveItem(at: output.appendingPathComponent("README"), to: away)

    #expect(throws: ExtractionConflictError(paths: ["readme"])) {
        try ArchiveModel.moveMerging(staged.appendingPathComponent("2/readme"),
                                     to: output.appendingPathComponent("readme"), path: "readme", in: root,
                                     fileSystem: fileSystem, twins: twins)
    }
    #expect(listings.count == 1)
    #expect(try snapshot(output) == (renamedInPlace ? ["notes": "mine"] : [:]))
    #expect(try snapshot(staged.appendingPathComponent("2")) == ["readme": "new"])
}

/// One extraction of n items into one folder lists it once too: the extraction is one operation.
@MainActor @Test func withoutExclusiveRenameAnExtractionListsTheFolderOnce() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    let count = 200
    let model = makeModel((0..<count).map { file("file-\($0).txt") })
    let listings = CallCounter()
    model.extractionFileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil),
                                                  listings)

    try await model.extract(nil, to: output, progress: nil)

    #expect(listings.count == 1)
    #expect(try snapshot(output).count == count)
}

/// Twins in one extraction: README lands first, after the listing its check took, and the name it lands on is
/// added. So Readme, which the lookup misses, takes "Readme 2" and never replaces it; the folder was listed once.
@MainActor @Test func withoutExclusiveRenameTwinsInOneExtractionSeeEachOther() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let model = makeModel([file("README"), file("Readme")])
    let listings = CallCounter()
    model.extractionFileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "Readme", caseSensitive: nil),
                                                  listings)

    try await model.extract(nil, to: output, resolutions: ["Readme": .keepBoth], progress: nil)

    #expect(try snapshot(output) == ["README": "README", "Readme 2": "Readme"])
    #expect(listings.count == 1)
}

/// No RENAME_EXCL and no RENAME_SWAP (ENOTSUP): a Replace steps the old item aside. Renames otherwise live, the
/// lookup misses nothing and the volume's case answer is unknown.
func noExclusiveRenameOrSwap() -> ExtractionFileSystem {
    var fileSystem = noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil)
    let rename = fileSystem.rename
    fileSystem.rename = { from, to, flags in flags == UInt32(RENAME_SWAP) ? ENOTSUP : rename(from, to, flags) }
    return fileSystem
}

/// A Replace without RENAME_SWAP is part of its extraction's operation: it reuses the folder listing an earlier
/// item took, not one of its own. The archive spells the item README, the folder listed it as Readme: once the
/// old item stepped aside, that name is gone (lstat ENOENT) and no longer blocks the new one.
@MainActor @Test func withoutExclusiveRenameAReplaceReusesTheExtractionsListing() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    try write("mine", at: "Readme", in: output)
    let model = makeModel([file("other.txt"), file("README")])
    let listings = CallCounter()
    model.extractionFileSystem = countingListings(noExclusiveRenameOrSwap(), listings)

    try await model.extract(nil, to: output, resolutions: ["README": .replace], progress: nil)

    #expect(try snapshot(output) == ["README": "README", "other.txt": "other.txt"])
    #expect(listings.count == 1)
}

/// Only names lstat finds gone are dropped: a real twin (Readme, beside the README replaced, as a volume that
/// keeps case apart holds them; faked here in the listing and in lstat) stays after the step-aside and keeps
/// blocking the plain rename. The new README never lands, and the old one, whose name the twin blocks too, is
/// kept beside it as "README 2" (`ExtractionRecoveryError` `.renamed`).
@MainActor @Test func withoutExclusiveRenameARealTwinStillBlocksAReplace() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    try write("mine", at: "README", in: output)
    let model = makeModel([file("other.txt"), file("README")])
    let listings = CallCounter()
    var fileSystem = countingListings(noExclusiveRenameOrSwap(), listings)
    let isGone = fileSystem.isGone
    fileSystem.listNames = { folder in
        listings.record()
        return try ExtractionFileSystem.names(in: folder) + ["Readme"]
    }
    fileSystem.isGone = { path in (path as NSString).lastPathComponent != "Readme" && isGone(path) }
    model.extractionFileSystem = fileSystem

    let error = await #expect(throws: ExtractionRecoveryError.self) {
        try await model.extract(nil, to: output, resolutions: ["README": .replace], progress: nil)
    }

    #expect(error?.kind == .renamed)
    #expect(error?.kept.lastPathComponent == "README 2")
    let after = try snapshot(output)
    #expect(after == ["other.txt": "other.txt", "README 2": "mine"], "\(after)")
    #expect(listings.count == 1)
}

/// A Replace puts a new item at its path (swapped in, or moved in after the old one stepped aside), so what the
/// operation knew of the folders there and below is forgotten: `docs` was read and listed for `docs/x`, then
/// `Docs` replaced it, and a Keep Both twin `docs/readme`, which the lookup misses, is checked against the new
/// folder's listing (README), never the old one's. It takes "readme 2" and README stays.
@Test(arguments: [false, true])
func withoutExclusiveRenameAReplaceForgetsTheFoldersItReplaced(_ hasSwap: Bool) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output.appendingPathComponent("docs"),
                                            withIntermediateDirectories: true)
    try write("x", at: "staged1/docs/x", in: root)
    try write("new docs", at: "staged2/Docs/README", in: root)
    try write("twin", at: "staged3/docs/readme", in: root)
    var fileSystem = noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil)
    if !hasSwap {
        let rename = fileSystem.rename
        fileSystem.rename = { from, to, flags in flags == UInt32(RENAME_SWAP) ? ENOTSUP : rename(from, to, flags) }
    }
    let twins = CaseTwinListings()
    func staging(_ index: Int) -> URL { root.appendingPathComponent("staged\(index)", isDirectory: true) }
    _ = try ArchiveModel.moveStaged([("docs/x", "docs/x")], from: staging(1), to: output, resolutions: [:],
                                    fileSystem: fileSystem, twins: twins)
    _ = try ArchiveModel.moveStaged([("Docs", "Docs")], from: staging(2), to: output, resolutions: ["Docs": .replace],
                                    fileSystem: fileSystem, twins: twins)

    let placed = try ArchiveModel.moveStaged([("docs/readme", "docs/readme")], from: staging(3), to: output,
                                             resolutions: ["docs/readme": .keepBoth], fileSystem: fileSystem,
                                             twins: twins)

    #expect(placed.map(\.lastPathComponent) == ["readme 2"])
    // A swap keeps the name the folder had; a step-aside moves the new one in under the archive's.
    let name = hasSwap ? "docs" : "Docs"
    let after = try snapshot(output)
    #expect(after == [name: "dir", "\(name)/README": "new docs", "\(name)/readme 2": "twin"], "\(after)")
}

/// A volume of exact names only (case-sensitive, as a case-sensitive SMB server is), held in memory.
private final class ExactNames: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String>
    init(_ paths: Set<String>) { self.paths = paths }
    func contains(_ path: String) -> Bool { lock.withLock { paths.contains(path) } }
    func remove(_ path: String) { lock.withLock { _ = paths.remove(path) } }
    func add(_ path: String) { lock.withLock { _ = paths.insert(path) } }
    func names(in folder: String) -> [String] {
        lock.withLock {
            paths.filter { ArchiveEntry.parentPath(of: $0) == folder }.map { ArchiveEntry.name(of: $0) }
        }
    }
}

/// A Replace's `dropGone` checks each folder's names under that folder's own path. On a volume taken to fold
/// case (an unknown answer) that keeps it apart, `Docs` and `docs` are two folders whose paths fold together:
/// README stepping aside from `docs` (listed there as Readme) is gone, but `Docs/README` is still in `Docs`,
/// where it keeps blocking `Docs/readme`, which the lookup misses.
@Test func dropGoneChecksEachFolderUnderItsOwnPath() throws {
    let volume = ExactNames(["/v/Docs/README", "/v/docs/Readme"])
    var fileSystem = ExtractionFileSystem(deviceToken: "feedface00000000") { from, to, flags in
        if flags == UInt32(RENAME_EXCL) { return ENOTSUP }
        volume.remove(from)
        volume.add(to)
        return 0
    }
    // The lookup misses every readme twin, as the iOS Simulator's scratch volume's does.
    fileSystem.exists = { volume.contains($0) && ArchiveEntry.name(of: $0) != "readme" }
    fileSystem.isGone = { !volume.contains($0) }
    fileSystem.listNames = { volume.names(in: $0) }
    fileSystem.identity = { ExtractionFileSystem.Identity(device: 1, inode: $0 == "/v/Docs" ? 2 : 3) }
    fileSystem.caseSensitivity = DestinationCaseSensitivity(exists: { _ in true },
                                                            supportsCaseSensitiveNames: { _ in nil })
    func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
    let twins = CaseTwinListings()
    #expect(try twins.renamePlainly(url("/s/x"), to: url("/v/Docs/x"), fileSystem: fileSystem) == 0)
    #expect(try twins.renamePlainly(url("/s/y"), to: url("/v/docs/y"), fileSystem: fileSystem) == 0)
    // A Replace of docs/README steps the old item (Readme) aside.
    volume.remove("/v/docs/Readme")

    twins.dropGone(url("/v/docs/README"), fileSystem: fileSystem)

    #expect(try twins.renamePlainly(url("/s/readme"), to: url("/v/Docs/readme"), fileSystem: fileSystem) == EEXIST)
    #expect(try twins.renamePlainly(url("/s/README"), to: url("/v/docs/README"), fileSystem: fileSystem) == 0)
    #expect(volume.contains("/v/Docs/README") && !volume.contains("/v/Docs/readme"))
}

/// lstat failing with anything but ENOENT (EACCES here, in a folder that can't be searched; EIO on a reconnecting
/// volume) says nothing about a name (`isGone`), so `dropGone` keeps it, and it keeps blocking its twin, which the
/// lookup misses.
@Test func dropGoneKeepsANameLstatCantAnswerFor() throws {
    let root = try makeTempDirectory()
    let folder = root.appendingPathComponent("out/d", isDirectory: true)
    defer {
        chmod(folder.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }
    try write("mine", at: "out/d/README", in: root)
    try write("a", at: "staged/a.txt", in: root)
    try write("new", at: "staged/readme", in: root)
    let fileSystem = noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil)
    let twins = CaseTwinListings()
    let staged = root.appendingPathComponent("staged", isDirectory: true)
    #expect(try twins.renamePlainly(staged.appendingPathComponent("a.txt"), to: folder.appendingPathComponent("a.txt"),
                                    fileSystem: fileSystem) == 0)
    try #require(chmod(folder.path, 0o000) == 0)
    #expect(!fileSystem.isGone(folder.appendingPathComponent("README").path), "EACCES is no answer")

    twins.dropGone(folder.appendingPathComponent("readme"), fileSystem: fileSystem)

    try #require(chmod(folder.path, 0o755) == 0)
    #expect(fileSystem.isGone(folder.appendingPathComponent("nothing").path))
    #expect(try twins.renamePlainly(staged.appendingPathComponent("readme"),
                                    to: folder.appendingPathComponent("readme"), fileSystem: fileSystem) == EEXIST)
    #expect(try snapshot(folder) == ["README": "mine", "a.txt": "a"])
}

/// A step-aside that reports failure but took effect (SMB or NFS replaying the rename after a reconnect gets
/// ENOENT): the old item is aside all the same. Its name (listed as Readme) is dropped from the operation's
/// listing (`dropGone`) before it goes back (`restore`), so it gets its name back, never "README 2", and the
/// rename's error is what the user sees.
@Test func withoutExclusiveRenameAStepAsideThatFailsButTookEffectRestoresTheName() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let output = root.appendingPathComponent("out", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try write("mine", at: "Readme", in: output)
    try write("a", at: "staged/a.txt", in: root)
    try write("new", at: "staged/README", in: root)
    let target = output.appendingPathComponent("README")
    var fileSystem = noExclusiveRenameOrSwap()
    let rename = fileSystem.rename
    fileSystem.rename = { from, to, flags in
        let error = rename(from, to, flags)
        return error == 0 && flags == 0 && from == target.path ? ENOENT : error
    }
    let twins = CaseTwinListings()
    let staged = root.appendingPathComponent("staged", isDirectory: true)
    try ArchiveModel.moveMerging(staged.appendingPathComponent("a.txt"), to: output.appendingPathComponent("a.txt"),
                                 path: "a.txt", in: root, fileSystem: fileSystem, twins: twins)

    #expect(throws: POSIXError(.ENOENT)) {
        try ArchiveModel.replaceSteppingAside(target, with: staged.appendingPathComponent("README"), path: "README",
                                              staging: staging, in: output, fileSystem: fileSystem, twins: twins)
    }
    #expect(try snapshot(output) == ["README": "mine", "a.txt": "a"])
    #expect(try snapshot(staged) == ["README": "new"])
}

/// Every merge is an operation of its own, with listings of its own: a twin made between two merges is seen by
/// the second.
@Test func withoutExclusiveRenameATwinMadeBetweenTwoMergesIsSeen() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("D", isDirectory: true)
    try write("a", at: "staged1/D/a.txt", in: root)
    try write("new", at: "staged2/D/readme", in: root)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let fileSystem = noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil)
    try ArchiveModel.moveMerging(root.appendingPathComponent("staged1/D", isDirectory: true), to: target,
                                 path: "D", in: root, fileSystem: fileSystem)
    try write("mine", at: "D/README", in: root)

    #expect(throws: ExtractionConflictError(paths: ["D/readme"])) {
        try ArchiveModel.moveMerging(root.appendingPathComponent("staged2/D", isDirectory: true), to: target,
                                     path: "D", in: root, fileSystem: fileSystem)
    }
    #expect(try snapshot(target) == ["a.txt": "a", "README": "mine"])
}

/// The listing answers only for case twins: an item made on the very name after the listing is still found by
/// the lookup, which runs for every item, and is never replaced.
@Test func withoutExclusiveRenameAnItemMadeOnTheNameAfterTheListingIsStillFound() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try write("a", at: "staged/a.txt", in: root)
    try write("b", at: "staged/b.txt", in: root)
    let fileSystem = noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil)
    let twins = CaseTwinListings()
    try ArchiveModel.moveMerging(root.appendingPathComponent("staged/a.txt"), to: output.appendingPathComponent("a.txt"),
                                 path: "a.txt", in: root, fileSystem: fileSystem, twins: twins)
    try write("theirs", at: "b.txt", in: output)

    #expect(throws: ExtractionConflictError(paths: ["b.txt"])) {
        try ArchiveModel.moveMerging(root.appendingPathComponent("staged/b.txt"),
                                     to: output.appendingPathComponent("b.txt"), path: "b.txt", in: root,
                                     fileSystem: fileSystem, twins: twins)
    }
    #expect(try snapshot(output) == ["a.txt": "a", "b.txt": "theirs"])
}

/// A listing that fails with anything but EACCES or EPERM isn't kept: it throws for its item, and the next item
/// lists the folder again (here finding a twin the lookup misses).
@Test func withoutExclusiveRenameAFailedListingIsNotKept() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("mine", at: "README", in: output)
    try write("a", at: "staged/a.txt", in: root)
    try write("new", at: "staged/readme", in: root)
    let listings = CallCounter()
    var fileSystem = noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil)
    fileSystem.listNames = { folder in
        listings.record()
        if listings.count <= 2 { throw POSIXError(.EIO) }
        return try ExtractionFileSystem.names(in: folder)
    }
    let twins = CaseTwinListings()

    #expect(throws: POSIXError(.EIO)) {
        try ArchiveModel.moveMerging(root.appendingPathComponent("staged/a.txt"),
                                     to: output.appendingPathComponent("a.txt"), path: "a.txt", in: root,
                                     fileSystem: fileSystem, twins: twins)
    }
    #expect(throws: ExtractionConflictError(paths: ["readme"])) {
        try ArchiveModel.moveMerging(root.appendingPathComponent("staged/readme"),
                                     to: output.appendingPathComponent("readme"), path: "readme", in: root,
                                     fileSystem: fileSystem, twins: twins)
    }
    #expect(listings.count == 3)
    #expect(try snapshot(output) == ["README": "mine"])
    #expect(try snapshot(root.appendingPathComponent("staged")) == ["a.txt": "a", "readme": "new"])
}

/// A plain rename that meets an item after all (EEXIST, ENOTEMPTY, EISDIR, ENOTDIR; here a twin made right after
/// the listing, which the fake rename meets) drops the folder's listing and its key and decides again on a fresh
/// one (the identity read again, the folder listed again): the twin is found, and Keep Both takes the next name.
/// The rename itself is never retried blindly.
@Test(arguments: [EEXIST, ENOTEMPTY, EISDIR, ENOTDIR])
func withoutExclusiveRenameARenameThatMeetsAnItemListsTheFolderAgain(_ code: Int32) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try write("new", at: "staged/readme", in: root)
    let twin = output.appendingPathComponent("README")
    let listings = CallCounter()
    var fileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil), listings,
                                      afterListing: { try? Data("mine".utf8).write(to: twin, options: .withoutOverwriting) })
    let rename = fileSystem.rename
    fileSystem.rename = { from, to, flags in
        flags == 0 && (to as NSString).lastPathComponent == "readme" ? code : rename(from, to, flags)
    }
    let identities = CallCounter()
    fileSystem.identity = { identities.record(); return try ExtractionFileSystem.identity(of: $0) }
    var reserved: Set<String> = []

    let placed = try ArchiveModel.moveKeepingBoth(root.appendingPathComponent("staged/readme"),
                                                  to: output.appendingPathComponent("readme"), isDirectory: false,
                                                  path: "readme", in: output, reserved: &reserved,
                                                  fileSystem: fileSystem)
    #expect(placed.lastPathComponent == "readme 2")
    #expect(listings.count == 2)
    #expect(identities.count == 2)
    #expect(try snapshot(output) == ["README": "mine", "readme 2": "new"])
}

/// A case-only rename (a.txt to A.txt, docs to Docs) on a volume without RENAME_EXCL: the item leaves its old
/// name before the listing for its new one is taken, so it is never its own twin.
@MainActor @Test(arguments: [false, true])
func withoutExclusiveRenameACaseOnlyRenameIsNotItsOwnTwin(_ isFolder: Bool) async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let model = isFolder ? makeModel([folder("docs"), file("docs/a.txt")]) : makeModel([file("a.txt")])
    model.extractionFileSystem = noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil)
    let (old, new) = isFolder ? ("docs", "Docs") : ("a.txt", "A.txt")
    #expect(model.rename(old, to: new) == .success(new))

    try await model.extract(nil, to: output, progress: nil)

    #expect(try snapshot(output) == (isFolder ? ["Docs": "dir", "Docs/a.txt": "docs/a.txt"] : ["A.txt": "a.txt"]))
}

// MARK: - Containment

/// Keep Both never moves an item through a link in the destination, whether its own name is free or taken there
/// (a taken one gets a "name 2" in the same folder): each name tried is checked first (`renameExclusively`).
@Test(arguments: ["link/\u{301}pwn", "link/pwn"], [false, true])
func keepBothNeverMovesThroughALink(_ path: String, _ isTaken: Bool) throws {
    let layout = try HiddenSlashContainmentTests.Layout()
    defer { layout.remove() }
    let destination = layout.destination
    try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("link"),
                                               withDestinationURL: layout.outside)
    if isTaken { try Data("victim".utf8).write(to: layout.outside.appendingPathComponent(ArchiveEntry.name(of: path))) }
    let source = destination.appendingPathComponent(".kernir-staged")
    try Data("pwn".utf8).write(to: source)
    let before = try HiddenSlashContainmentTests.snapshot(layout.outside)
    var reserved: Set<String> = []

    #expect(throws: ExtractionContainmentError.self) {
        try ArchiveModel.moveKeepingBoth(source, to: destination.appendingPathComponent(path), isDirectory: false,
                                         path: path, in: destination, reserved: &reserved, fileSystem: .system)
    }
    #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == before, "CONTAINMENT: outside unchanged")
    #expect(FileManager.default.fileExists(atPath: source.path), "the source stays where it was")
}

/// Keep Both through a symlink in the destination is refused directly. The guard itself throws for a
/// name behind the link; Keep Both of a staged folder there throws it too, for its own name and for every
/// "name 2" it would try (the outside holds "docs" and "docs 2"), and nothing is written outside or beside.
@Test func keepBothThroughADestinationSymlinkIsRefused() throws {
    let layout = try HiddenSlashContainmentTests.Layout()
    defer { layout.remove() }
    let destination = layout.destination
    try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("link"),
                                               withDestinationURL: layout.outside)
    for taken in ["docs", "docs 2"] {
        try FileManager.default.createDirectory(at: layout.outside.appendingPathComponent(taken),
                                                withIntermediateDirectories: false)
    }
    let source = destination.appendingPathComponent(".kernir-staged/docs", isDirectory: true)
    try write("pwn", at: "x.txt", in: source)
    let target = destination.appendingPathComponent("link/docs", isDirectory: true)
    let outsideBefore = try HiddenSlashContainmentTests.snapshot(layout.outside)
    let rootBefore = try FileManager.default.contentsOfDirectory(atPath: layout.root.path).sorted()

    #expect(throws: ExtractionContainmentError.self) { try ArchiveModel.checkContained(target, in: destination) }
    var reserved: Set<String> = []
    #expect(throws: ExtractionContainmentError.self) {
        try ArchiveModel.moveKeepingBoth(source, to: target, isDirectory: true, path: "link/docs",
                                         in: destination, reserved: &reserved, fileSystem: .system)
    }
    #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == outsideBefore, "CONTAINMENT: outside unchanged")
    #expect(try FileManager.default.contentsOfDirectory(atPath: layout.root.path).sorted() == rootBefore,
            "CONTAINMENT: nothing beside the destination")
    #expect(try snapshot(source) == ["x.txt": "pwn"], "the staged folder stays where it was")
}

/// The same through `extract`: case twins inside a folder whose name is a symlink in the destination, every
/// question answered Keep Both. The link is the folder's conflict, so the folder is kept beside it as
/// "link 2" and the later twin follows it there; nothing goes through the link.
@Test @MainActor func keepBothTwinsBesideADestinationSymlinkStayInside() async throws {
    let layout = try HiddenSlashContainmentTests.Layout()
    defer { layout.remove() }
    try #require(isCaseInsensitive(layout.root))
    let destination = layout.destination
    try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("link"),
                                               withDestinationURL: layout.outside)
    try Data("victim".utf8).write(to: layout.outside.appendingPathComponent("a.txt"))
    let outsideBefore = try HiddenSlashContainmentTests.snapshot(layout.outside)
    let model = HiddenSlashContainmentTests.model([folder("link"), file("link/a.txt"), file("link/A.txt")])

    let conflicts = model.extractionConflicts(["link"], in: destination)
    #expect(conflicts == ["link", "link/A.txt"])
    let resolutions = Dictionary(uniqueKeysWithValues: conflicts.map { ($0, ExtractionConflictResolution.keepBoth) })
    try await model.extract(["link"], to: destination, resolutions: resolutions, progress: nil)

    #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == outsideBefore, "CONTAINMENT: outside unchanged")
    #expect(HiddenSlashContainmentTests.isSymlink(destination.appendingPathComponent("link")))
    #expect(try snapshot(destination.appendingPathComponent("link 2"))
        == ["a.txt": "link/a.txt", "A 2.txt": "link/A.txt"])
}

// MARK: - moveStaged trusts staging, not names

/// A staging folder in `root` as a reader left it: each relative path holds its contents, written in order.
private func makeStaging(_ files: KeyValuePairs<String, String>, in root: URL) throws -> URL {
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    for (path, contents) in files { try write(contents, at: path, in: staging) }
    return staging
}

/// Requested folders whose names differ only by case are one unit only when staging holds them in one
/// folder. Here it kept them apart (an item written under a name other than its own), so they move one
/// by one: the second meets the first as a conflict, and nothing is left behind without a word.
@Test func foldedFoldersStagingKeptApartMoveApart() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let staging = try makeStaging(["docs/x.txt": "x", "other/y.txt": "y"], in: root)
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

    #expect(throws: ExtractionConflictError(paths: ["DOCS"])) {
        try ArchiveModel.moveStaged([("docs", "docs"), ("DOCS", "other")], from: staging, to: output,
                                    resolutions: [:], foldsCase: true, fileSystem: .system)
    }
    #expect(try snapshot(output) == ["docs": "dir", "docs/x.txt": "x"])
    #expect(try snapshot(staging) == ["other": "dir", "other/y.txt": "y"])
}

/// Two requested items staging holds as one folder (folders differing only by case, merged when written)
/// but that don't fold onto one name: moving either would take the other's contents. Nothing moves.
@Test func twoUnitsOnOneStagedFolderMoveNothing() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let staging = try makeStaging(["docs/x.txt": "x", "DOCS/y.txt": "y"], in: root)
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

    #expect(throws: ExtractionConflictError(paths: ["manual"])) {
        try ArchiveModel.moveStaged([("docs", "docs"), ("manual", "DOCS")], from: staging, to: output,
                                    resolutions: [:], foldsCase: true, fileSystem: .system)
    }
    #expect(try snapshot(output).isEmpty)
    #expect(try snapshot(staging) == ["docs": "dir", "docs/x.txt": "x", "docs/y.txt": "y"])
}

/// Two files on one name but for case that staging holds as one file (hard links: one inode, two names) are
/// never one unit: only folders merge. The second meets the first as a conflict, never left out unwritten.
/// (Through `extract` they never both get here: the twin scan asks about the later one first.)
@Test func hardLinkedFileTwinsAreNeverOneUnit() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let staging = try makeStaging(["x": "both"], in: root)
    try FileManager.default.linkItem(at: staging.appendingPathComponent("x"), to: staging.appendingPathComponent("y"))
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

    #expect(throws: ExtractionConflictError(paths: ["a"])) {
        try ArchiveModel.moveStaged([("A", "x"), ("a", "y")], from: staging, to: output,
                                    resolutions: [:], foldsCase: true, fileSystem: .system)
    }
    #expect(try snapshot(output) == ["A": "both"])
    #expect(try snapshot(staging) == ["y": "both"])
}

// MARK: - moveStaged folds case only where the volume says so

/// A volume that folds case wrote `d` and `D/x.txt` into one folder: the requested `D/x.txt` is inside the
/// requested `d` there, so it moves with it, as one unit, and staging is left empty.
@Test func aFoldingVolumeMovesAnItemWithItsFolderAcrossCase() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let staging = try makeStaging(["d/a.txt": "a", "d/x.txt": "x"], in: root)
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

    let placed = try ArchiveModel.moveStaged([("d", "d"), ("D/x.txt", "D/x.txt")], from: staging, to: output,
                                             resolutions: [:], foldsCase: true, fileSystem: .system)
    #expect(placed.map(\.lastPathComponent) == ["d", "x.txt"])
    #expect(try snapshot(output) == ["d": "dir", "d/a.txt": "a", "d/x.txt": "x"])
    #expect(try snapshot(staging).isEmpty)
}

/// A volume that folds case but keeps apart two names the key joins (HFS+: `ß` and `SS`; here staging keeps
/// them apart by writing `ß/x` under another name). The requested `ß/x` is not inside the requested `SS`
/// there, so it moves on its own, under its own answer: Replace takes the user's `ß/x` and nothing else,
/// and `SS` is kept beside. Lifted to `ß` on the name alone, it met `ß` partway as a conflict nobody was
/// asked about, after `SS` was placed.
@Test func aFoldingVolumeLiftsAnItemOnlyIntoAFolderStagingShowsAsOne() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let staging = try makeStaging(["SS/a": "a", "sharp/x": "new x"], in: root)
    let output = root.appendingPathComponent("out", isDirectory: true)
    try write("keep", at: "\u{DF}/keep.txt", in: output)
    try write("old x", at: "\u{DF}/x", in: output)

    let placed = try ArchiveModel.moveStaged([("SS", "SS"), ("\u{DF}/x", "sharp/x")], from: staging, to: output,
                                             resolutions: ["SS": .keepBoth, "\u{DF}/x": .replace],
                                             foldsCase: true, fileSystem: .system)
    #expect(placed.map(\.lastPathComponent) == ["SS 2", "x"])
    #expect(try snapshot(output) == ["\u{DF}": "dir", "\u{DF}/keep.txt": "keep", "\u{DF}/x": "new x",
                                     "SS 2": "dir", "SS 2/a": "a"])
}

/// On a case-sensitive volume `d` and `D` are two folders, and staging keeps them apart (here `D` is written
/// under another name, since this disk folds case). The requested `D/x.txt` is not inside the requested `d`,
/// so it moves on its own: `D/y.txt`, which nobody asked for, never moves with it.
@Test func aCaseSensitiveVolumeNeverMovesAnUnrequestedSibling() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let staging = try makeStaging(["d/a.txt": "a", "D-apart/x.txt": "x", "D-apart/y.txt": "y"], in: root)
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

    let placed = try ArchiveModel.moveStaged([("d", "d"), ("D/x.txt", "D-apart/x.txt")], from: staging,
                                             to: output, resolutions: [:], foldsCase: false, fileSystem: .system)
    #expect(placed.map(\.lastPathComponent) == ["d", "x.txt"])
    #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("D/x.txt").path))
    #expect(try snapshot(staging) == ["D-apart": "dir", "D-apart/y.txt": "y"], "the sibling stays in staging")
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("D/y.txt").path))
}

/// With no answer from the volume (or a wrong one), staging is the proof: a folder written as `d` and `D` that
/// staging holds as one real folder (one lstat dev+ino) on the destination's device is one folder there, as
/// a whole request or with an item inside it. Staging is left empty.
@Test(arguments: [("D", "D"), ("D/b.txt", "D/b.txt")])
func anUnknownVolumeFoldsFoldersStagingHoldsAsOne(_ path: String, _ written: String) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let staging = try makeStaging(["d/a.txt": "a", "D/b.txt": "b"], in: root)
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

    _ = try ArchiveModel.moveStaged([("d", "d"), (path, written)], from: staging, to: output, resolutions: [:],
                                    foldsCase: false, fileSystem: .system)
    #expect(try snapshot(output) == ["d": "dir", "d/a.txt": "a", "d/b.txt": "b"])
    #expect(try snapshot(staging).isEmpty)
}

/// With no answer and two staged folders (two inodes), nothing folds: they move one by one, and on this disk,
/// which folds case, the second meets the first as a conflict. Its folder stays in staging.
@Test func anUnknownVolumeWithTwoStagedFoldersIsAConflict() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let staging = try makeStaging(["d/a.txt": "a", "D-apart/b.txt": "b"], in: root)
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

    #expect(throws: ExtractionConflictError(paths: ["D"])) {
        try ArchiveModel.moveStaged([("d", "d"), ("D", "D-apart")], from: staging, to: output, resolutions: [:],
                                    foldsCase: false, fileSystem: .system)
    }
    #expect(try snapshot(output) == ["d": "dir", "d/a.txt": "a"])
    #expect(try snapshot(staging) == ["D-apart": "dir", "D-apart/b.txt": "b"])
}

/// A symlink in staging to the other folder is never the proof (lstat: a link is not a folder, and has its
/// own inode): with no answer the two move one by one, and the link meets the folder as a conflict.
@Test func aStagedSymlinkToTheOtherFolderNeverFolds() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let staging = try makeStaging(["d/a.txt": "a"], in: root)
    try FileManager.default.createSymbolicLink(at: staging.appendingPathComponent("D-link"),
                                               withDestinationURL: staging.appendingPathComponent("d"))
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)

    #expect(throws: ExtractionConflictError(paths: ["D"])) {
        try ArchiveModel.moveStaged([("d", "d"), ("D", "D-link")], from: staging, to: output, resolutions: [:],
                                    foldsCase: false, fileSystem: .system)
    }
    #expect(try snapshot(output) == ["d": "dir", "d/a.txt": "a"])
    #expect(HiddenSlashContainmentTests.isSymlink(staging.appendingPathComponent("D-link")))
}

/// Staging's one folder proves a fold only on the destination's device: on another one (injected), the fold is
/// a conflict before anything moves, as a whole request or with an item inside it.
@Test(arguments: [("D", "D"), ("D/b.txt", "D/b.txt")])
func oneStagedFolderOnAnotherDeviceIsAConflict(_ path: String, _ written: String) throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let staging = try makeStaging(["d/a.txt": "a", "D/b.txt": "b"], in: root)
    let output = root.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    var status = stat()
    try #require(lstat(staging.path, &status) == 0)

    #expect(throws: ExtractionConflictError(paths: ["D"])) {
        try ArchiveModel.moveStaged([("d", "d"), (path, written)], from: staging, to: output, resolutions: [:],
                                    foldsCase: false, destinationDevice: status.st_dev &+ 1, fileSystem: .system)
    }
    #expect(try snapshot(output).isEmpty)
    #expect(try snapshot(staging) == ["d": "dir", "d/a.txt": "a", "d/b.txt": "b"])
}

/// The same through `extract`, with the volume's answer injected: says it folds case, says it doesn't, or no
/// answer. Staging on this disk holds `d` and `D` as one folder, so in every case they come out as one.
@Test(arguments: [false, true, nil] as [Bool?])
@MainActor func extractFoldsFoldersTheVolumeOrStagingShowsAsOne(_ supportsCaseSensitiveNames: Bool?) async throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(isCaseInsensitive(root))
    let model = makeModel([folder("d"), file("d/a.txt"), folder("D"), file("D/b.txt")])
    model.caseSensitivity = DestinationCaseSensitivity(exists: { _ in true },
                                                       supportsCaseSensitiveNames: { _ in supportsCaseSensitiveNames })
    let output = root.appendingPathComponent("out", isDirectory: true)

    try await model.extract(["d", "D"], to: output, resolutions: [:], progress: nil)
    #expect(try snapshot(output) == ["d": "dir", "d/a.txt": "d/a.txt", "d/b.txt": "D/b.txt"])
}

// MARK: - Never from behind a symlink in staging

/// A reader that leaves a symlink to `target` at `linked` (in place of the folder the archive has there) in
/// the stagings it writes from the `fromCall`th extraction on (1 = every one), as a crafted archive could.
private final class LinkingReader: ArchiveReading, @unchecked Sendable {
    let base: FakeReader
    let linked: String
    let target: URL
    let fromCall: Int
    private var calls = 0
    init(_ entries: [ArchiveEntry], linked: String, to target: URL, fromCall: Int = 1) {
        base = FakeReader(entries: entries)
        self.linked = linked
        self.target = target
        self.fromCall = fromCall
    }
    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { false }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        try await base.extract(paths, to: directory, progress: progress)
        calls += 1  // extractions run one after another
        guard calls >= fromCall else { return }
        let folder = directory.appendingPathComponent(linked)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: target)
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        try await base.extractToTemporaryFile(path)
    }
}

/// A requested item is never taken from behind a symlink in staging: a folder above where it was written that
/// is a symlink to a folder outside stops the extraction before anything moves (the item requested first
/// included), and the file outside stays where it is.
@Test @MainActor func aRequestedItemBehindASymlinkInStagingMovesNothing() async throws {
    let layout = try HiddenSlashContainmentTests.Layout()
    defer { layout.remove() }
    try Data("outside".utf8).write(to: layout.outside.appendingPathComponent("b.txt"))
    let outsideBefore = try HiddenSlashContainmentTests.snapshot(layout.outside)
    let reader = LinkingReader([file("c.txt"), folder("a"), file("a/b.txt")], linked: "a", to: layout.outside)
    let model = ArchiveModel(reader: reader, undoManager: nil)

    await #expect(throws: ExtractionConflictError(paths: ["a/b.txt"])) {
        try await model.extract(["c.txt", "a/b.txt"], to: layout.destination, progress: nil)
    }
    #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == outsideBefore, "outside unchanged")
    #expect(try snapshot(layout.destination).isEmpty, "nothing moved, no staging left")
}

/// The same for a Keep Both twin, moved from a staging of its own after the main items: a symlink above it
/// there throws a conflict for it before anything moves, the main items included, so the destination is
/// untouched (its own file stays, nothing comes in, no staging is left), and so is the file outside (on the
/// twin's folded name).
@Test @MainActor func aKeepBothTwinBehindASymlinkInItsStagingLeavesTheDestinationUntouched() async throws {
    let layout = try HiddenSlashContainmentTests.Layout()
    defer { layout.remove() }
    try #require(isCaseInsensitive(layout.root))
    try Data("outside".utf8).write(to: layout.outside.appendingPathComponent("A.txt"))
    try Data("mine".utf8).write(to: layout.destination.appendingPathComponent("keep.txt"))
    let outsideBefore = try HiddenSlashContainmentTests.snapshot(layout.outside)
    let destinationBefore = try HiddenSlashContainmentTests.snapshot(layout.destination)
    let reader = LinkingReader([folder("d"), file("d/a.txt"), file("d/A.txt"), file("e.txt")], linked: "d",
                               to: layout.outside, fromCall: 2)
    let model = ArchiveModel(reader: reader, undoManager: nil)
    #expect(model.extractionConflicts(["e.txt", "d"], in: layout.destination) == ["d/A.txt"])

    await #expect(throws: ExtractionConflictError(paths: ["d/A.txt"])) {
        try await model.extract(["e.txt", "d"], to: layout.destination, resolutions: ["d/A.txt": .keepBoth],
                                progress: nil)
    }
    #expect(try HiddenSlashContainmentTests.snapshot(layout.destination) == destinationBefore, "destination untouched")
    #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == outsideBefore, "outside unchanged")
}

/// A Keep Both twin goes below the item placed above it, and that place can be a symlink to a folder
/// outside by the time the twin moves (here the placed `d` is swapped for one right after its move). The
/// folders above the twin are made from the chosen folder down (`makeFolders`), never from the placed item,
/// so the link is refused: nothing is made or written outside, and nothing appears beside the destination.
/// The refusal names the twin left out (`A.txt`), never the link in its way (`d`).
@Test @MainActor func aKeepBothTwinUnderAPlacedFolderSwappedForALinkMakesNothingOutside() async throws {
    let layout = try HiddenSlashContainmentTests.Layout()
    defer { layout.remove() }
    try #require(isCaseInsensitive(layout.root))
    let outsideBefore = try HiddenSlashContainmentTests.snapshot(layout.outside)
    let model = HiddenSlashContainmentTests.model([folder("d"), folder("d/s"), file("d/s/a.txt"), file("d/s/A.txt")])
    let placed = layout.destination.appendingPathComponent("d")
    let aside = layout.destination.appendingPathComponent("d-moved")
    let outside = layout.outside
    model.extractionFileSystem = ExtractionFileSystem(deviceToken: HiddenSlashContainmentTests.deviceToken) { from, to, flags in
        guard renamex_np(from, to, flags) == 0 else { return errno }
        if to == placed.path {
            // As a local process could: the placed folder goes, a link to outside takes its name.
            _ = rename(placed.path, aside.path)
            _ = symlink(outside.path, placed.path)
        }
        return 0
    }
    #expect(model.extractionConflicts(["d"], in: layout.destination) == ["d/s/A.txt"])

    var thrown: (any Error)?
    do {
        _ = try await model.extract(["d"], to: layout.destination, resolutions: ["d/s/A.txt": .keepBoth], progress: nil)
    } catch {
        thrown = error
    }
    let refused = try #require(thrown as? ExtractionContainmentError, "\(String(describing: thrown))")
    #expect(refused.name == "A.txt", "\(refused)")
    #expect(refused.destination.path == layout.destination.path, "\(refused.destination.path)")
    #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == outsideBefore, "CONTAINMENT: nothing made outside")
    #expect(HiddenSlashContainmentTests.isSymlink(placed), "the swap happened")
    #expect(try FileManager.default.contentsOfDirectory(atPath: layout.root.path).sorted() == ["Extracted", "Extracted Outside"])
}

/// The same race on the main staging (`moveStaged`): after the first unit (`a.txt`) moves, `sub`, a folder
/// above a later unit, is replaced by a link to outside. The folders above each unit are made from the
/// chosen folder down (`makeFolders`), never through a link, so the link is refused and nothing is made
/// outside. (Making them with FileManager.createDirectory, which follows the link,
/// made `outside/deeper` and passed every other test.)
@Test @MainActor func aFolderAboveALaterUnitSwappedForALinkMakesNothingOutside() async throws {
    let layout = try HiddenSlashContainmentTests.Layout()
    defer { layout.remove() }
    let destination = layout.destination
    let outsideBefore = try HiddenSlashContainmentTests.snapshot(layout.outside)
    let model = HiddenSlashContainmentTests.model([file("a.txt"), folder("sub"), folder("sub/deeper"), file("sub/deeper/x")])
    let outside = layout.outside
    model.extractionFileSystem = ExtractionFileSystem(deviceToken: HiddenSlashContainmentTests.deviceToken) { from, to, flags in
        guard renamex_np(from, to, flags) == 0 else { return errno }
        if URL(fileURLWithPath: to).lastPathComponent == "a.txt" {
            // As a local process could: a link to outside takes the name of a folder still to be made.
            _ = symlink(outside.path, destination.appendingPathComponent("sub").path)
        }
        return 0
    }

    await #expect(throws: ExtractionContainmentError.self) {
        try await model.extract(["a.txt", "sub/deeper/x"], to: destination, progress: nil)
    }
    #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == outsideBefore, "CONTAINMENT: nothing made outside")
    #expect(HiddenSlashContainmentTests.isSymlink(destination.appendingPathComponent("sub")), "the swap happened")
    #expect(try FileManager.default.contentsOfDirectory(atPath: layout.root.path).sorted() == ["Extracted", "Extracted Outside"])
}

/// A refusal in a Keep Both twin's own staging names the folder the user chose, as one in the main staging
/// does, never the hidden staging folder: the twin `D` is a folder whose metadata-only `m` the plan makes
/// (`perform`), and its staging holds a link to outside on `D/m`. Nothing moves, nothing goes outside.
@Test @MainActor func aRefusalInATwinsStagingNamesTheChosenFolder() async throws {
    let layout = try HiddenSlashContainmentTests.Layout()
    defer { layout.remove() }
    try #require(isCaseInsensitive(layout.root))
    let outsideBefore = try HiddenSlashContainmentTests.snapshot(layout.outside)
    let reader = LinkingReader([file("d"), folder("D"), file("D/x"), folder("D/m"), file("D/m/._m")], linked: "D/m",
                               to: layout.outside, fromCall: 2)
    let model = ArchiveModel(reader: reader, undoManager: nil)
    #expect(model.extractionConflicts(nil, in: layout.destination) == ["D"])

    var thrown: (any Error)?
    do {
        _ = try await model.extract(nil, to: layout.destination, resolutions: ["D": .keepBoth], progress: nil)
    } catch {
        thrown = error
    }
    let refused = try #require(thrown as? ExtractionContainmentError, "\(String(describing: thrown))")
    #expect(refused.destination.path == layout.destination.path, "\(refused.destination.path)")
    #expect(!refused.destination.path.contains(".kernir-"))
    #expect(!refused.name.contains(".kernir-") && !"\(refused)".contains(".kernir-"), "\(refused)")
    #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == outsideBefore, "CONTAINMENT")
    #expect(try snapshot(layout.destination).isEmpty, "nothing moved, no staging left")
}

/// A Keep Both twin finds the item above it across case (`NameFold.key`, not NFC-exact): `DOCS/Readme` is below
/// `docs`, which went to "docs 2" beside the user's own docs, so the twin follows it there and takes Keep Both's
/// name beside README, never landing in the user's folder.
@Test @MainActor func aKeepBothTwinFollowsItsFolderAcrossCase() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    try write("mine", at: "docs/mine.txt", in: output)
    let model = makeModel([folder("docs"), file("docs/README"), file("DOCS/Readme")])
    let paths = ["docs", "DOCS/Readme"]
    #expect(model.extractionConflicts(paths, in: output) == ["docs", "DOCS/Readme"])

    try await model.extract(paths, to: output, resolutions: ["docs": .keepBoth, "DOCS/Readme": .keepBoth],
                            progress: nil)

    let after = try snapshot(output)
    #expect(after == [
        "docs": "dir", "docs/mine.txt": "mine",
        "docs 2": "dir", "docs 2/README": "docs/README", "docs 2/Readme 2": "DOCS/Readme",
    ], "\(after)")
}

/// A Keep Both twin follows a folder across case only where that folder was kept under another name ("docs 2"
/// above). Placed at its own path, it is not the twin's parent by a fold: on HFS+ `straße` and `STRASSE` are two
/// folders that `NameFold.key` joins, so `STRASSE/Readme` goes to its own path, never under `straße`. APFS joins
/// them, so here both land in one folder, and the URL the twin went to keeps its own spelling.
@Test @MainActor func aKeepBothTwinUnderAFolderAtItsOwnPathKeepsItsOwnPath() async throws {
    let output = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: output) }
    try #require(isCaseInsensitive(output))
    let model = makeModel([folder("stra\u{DF}e"), file("stra\u{DF}e/README"), file("STRASSE/Readme")])
    let paths = ["stra\u{DF}e", "STRASSE/Readme"]
    #expect(model.extractionConflicts(paths, in: output) == ["STRASSE/Readme"])

    let written = try await model.extract(paths, to: output, resolutions: ["STRASSE/Readme": .keepBoth],
                                          progress: nil)

    let twin = try #require(written.first { $0.lastPathComponent == "Readme 2" }, "\(written)")
    #expect(twin.deletingLastPathComponent().lastPathComponent == "STRASSE", "\(twin.path)")
    let after = try snapshot(output)
    #expect(after == [
        "stra\u{DF}e": "dir", "stra\u{DF}e/README": "stra\u{DF}e/README", "stra\u{DF}e/Readme 2": "STRASSE/Readme",
    ], "\(after)")
}

/// `docs` in the chosen folder is a link to a folder outside, and the user extracts `docs/README`
/// and its case twin `docs/Readme`, Keep Both to both. `docs` is the conflict, not a requested item, so README's unit
/// goes to "docs 2", and the twin follows that unit there (not to `docs/Readme`, behind the link), taking Keep Both's
/// name beside README: `docs 2/Readme 2`. No error, the link untouched, nothing goes outside, and no staging is left.
@Test @MainActor func aKeepBothTwinBelowAConflictingDestinationLinkFollowsItsFolder() async throws {
    let layout = try HiddenSlashContainmentTests.Layout()
    defer { layout.remove() }
    try #require(isCaseInsensitive(layout.root))
    let destination = layout.destination
    try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("docs"),
                                               withDestinationURL: layout.outside)
    let outsideBefore = try HiddenSlashContainmentTests.snapshot(layout.outside)
    let model = HiddenSlashContainmentTests.model([folder("docs"), file("docs/README"), file("docs/Readme")])
    let paths = ["docs/README", "docs/Readme"]
    #expect(model.extractionConflicts(paths, in: destination) == ["docs", "docs/Readme"])

    let written = try await model.extract(paths, to: destination,
                                          resolutions: ["docs": .keepBoth, "docs/Readme": .keepBoth], progress: nil)

    #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == outsideBefore, "CONTAINMENT")
    #expect(try FileManager.default.contentsOfDirectory(atPath: layout.root.path).sorted() == ["Extracted", "Extracted Outside"])
    // Both under Keep Both's name for `docs`, the twin beside README under its own Keep Both name, the link
    // untouched, and nothing else: no staging folder.
    let s = HiddenSlashContainmentTests.scalars
    #expect(try HiddenSlashContainmentTests.snapshot(destination) == [
        s("docs"): "-> " + layout.outside.path,
        s("docs 2"): "dir",
        s("docs 2/README"): "docs/README",
        s("docs 2/Readme 2"): "docs/Readme",
    ])
    #expect(written.map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent }
                == ["docs 2/README", "docs 2/Readme 2"], "\(written)")
}

/// The same link at `docs`, with the twin's folder spelled by case (`DOCS/Readme`): it finds its unit only across
/// case (`moveBeside`'s folded branch), so it follows `docs` to "docs 2" as Keep Both for `docs` placed it. Its own
/// conflict `DOCS` is the same link on this volume, and the answer to it (Replace here) isn't used: the link stays.
/// (Only Skip on `DOCS` counts: `extract` leaves the twin out before anything is written.)
@Test @MainActor func aKeepBothTwinBelowAConflictingLinkAcrossCaseFollowsItsFolder() async throws {
    let layout = try HiddenSlashContainmentTests.Layout()
    defer { layout.remove() }
    try #require(isCaseInsensitive(layout.root))
    let destination = layout.destination
    try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("docs"),
                                               withDestinationURL: layout.outside)
    let outsideBefore = try HiddenSlashContainmentTests.snapshot(layout.outside)
    let model = HiddenSlashContainmentTests.model([folder("docs"), file("docs/README"), file("DOCS/Readme")])
    let paths = ["docs/README", "DOCS/Readme"]
    #expect(model.extractionConflicts(paths, in: destination) == ["docs", "DOCS", "DOCS/Readme"])

    let written = try await model.extract(paths, to: destination,
                                          resolutions: ["docs": .keepBoth, "DOCS": .replace, "DOCS/Readme": .keepBoth],
                                          progress: nil)

    #expect(try HiddenSlashContainmentTests.snapshot(layout.outside) == outsideBefore, "CONTAINMENT")
    #expect(try FileManager.default.contentsOfDirectory(atPath: layout.root.path).sorted() == ["Extracted", "Extracted Outside"])
    let s = HiddenSlashContainmentTests.scalars
    #expect(try HiddenSlashContainmentTests.snapshot(destination) == [
        s("docs"): "-> " + layout.outside.path,
        s("docs 2"): "dir",
        s("docs 2/README"): "docs/README",
        s("docs 2/Readme 2"): "DOCS/Readme",
    ])
    #expect(written.map { $0.deletingLastPathComponent().lastPathComponent + "/" + $0.lastPathComponent }
                == ["docs 2/README", "docs 2/Readme 2"], "\(written)")
}

/// Each folder above a staged path is checked in turn with lstat, split on the "/" scalar: a symlink (also
/// behind a hidden "/", "l/\u{301}x"), a file, or an empty, "." or ".." component fails; a missing folder only
/// passes when `missingIsFine`.
@Test func hasRealFoldersChecksEveryFolderAboveAStagedPath() throws {
    let layout = try HiddenSlashContainmentTests.Layout()
    defer { layout.remove() }
    let staging = layout.destination
    try write("c", at: "a/b/c", in: staging)
    try FileManager.default.createSymbolicLink(at: staging.appendingPathComponent("l"), withDestinationURL: layout.outside)
    try FileManager.default.createSymbolicLink(at: staging.appendingPathComponent("a/lb"),
                                               withDestinationURL: staging.appendingPathComponent("a/b"))

    #expect(ArchiveModel.hasRealFolders(above: "a/b/c", in: staging, missingIsFine: false))
    #expect(ArchiveModel.hasRealFolders(above: "top", in: staging, missingIsFine: false))
    #expect(ArchiveModel.hasRealFolders(above: "l", in: staging, missingIsFine: false), "the item itself may be a link")
    #expect(ArchiveModel.hasRealFolders(above: "a/new/c", in: staging, missingIsFine: true))
    #expect(!ArchiveModel.hasRealFolders(above: "a/new/c", in: staging, missingIsFine: false))
    for path in ["l/secret", "l/\u{301}secret", "a/lb/c", "a/b/c/d", "a//c", "./a/b", "a/../a/b", "/a/b", ""] {
        #expect(!ArchiveModel.hasRealFolders(above: path, in: staging, missingIsFine: true), "\(path)")
    }
}
