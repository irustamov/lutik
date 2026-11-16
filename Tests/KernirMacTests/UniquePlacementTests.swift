import Testing
import Foundation
@testable import Kernir

// MARK: - Helpers

/// Fresh empty directory; the caller removes it.
private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("UniquePlacementTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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

private func names(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

/// Renames that go through `rule` first: nil means the real renamex_np(2), a number fails with it.
/// Records each rename's target and flags.
private final class FakeRenames: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(to: String, flags: UInt32)] = []
    private let rule: @Sendable (_ from: String, _ to: String, _ flags: UInt32) -> Int32?

    init(rule: @escaping @Sendable (_ from: String, _ to: String, _ flags: UInt32) -> Int32?) {
        self.rule = rule
    }

    var targets: [String] { lock.withLock { log.map { ($0.to as NSString).lastPathComponent } } }
    var flags: [UInt32] { lock.withLock { log.map(\.flags) } }

    func fileSystem() -> ExtractionFileSystem {
        ExtractionFileSystem(deviceToken: "feedface00000000") { from, to, flags in
            self.lock.withLock { self.log.append((to, flags)) }
            return self.rule(from, to, flags) ?? ExtractionFileSystem.system.rename(from, to, flags)
        }
    }
}

/// A source item outside `directory`, so placing it is a move between two folders.
private func makeSource(_ name: String, isDirectory: Bool, contents: String) throws -> URL {
    let holder = try makeTempDirectory()
    if isDirectory {
        try makeFile("\(name)/inner.txt", in: holder, contents: contents)
        return holder.appendingPathComponent(name, isDirectory: true)
    }
    return try makeFile(name, in: holder, contents: contents)
}

// MARK: - Tests

@Test func aFreeNameIsUsedAsItIs() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("report.pdf", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }

    let placed = try UniquePlacement.place(source, named: "report.pdf", in: directory, isDirectory: false)

    #expect(placed == directory.appendingPathComponent("report.pdf"))
    #expect(try contents(of: placed) == "new")
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test func aTakenFileGetsFindersNextName() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("staged", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("report.pdf", in: directory, contents: "mine")

    let placed = try UniquePlacement.place(source, named: "report.pdf", in: directory, isDirectory: false)

    #expect(placed.lastPathComponent == "report 2.pdf")
    #expect(try contents(of: directory.appendingPathComponent("report.pdf")) == "mine")
    #expect(try contents(of: placed) == "new")
}

@Test func aTakenFolderGetsFindersNextName() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("project", isDirectory: true, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("project/mine.txt", in: directory, contents: "mine")
    try makeFile("project 2", in: directory, contents: "a file named like the next folder")

    let placed = try UniquePlacement.place(source, named: "project", in: directory, isDirectory: true)

    #expect(placed.lastPathComponent == "project 3")
    #expect(placed.hasDirectoryPath)
    #expect(try contents(of: placed.appendingPathComponent("inner.txt")) == "new")
    #expect(try names(in: directory.appendingPathComponent("project")) == ["mine.txt"])
}

@Test func aNameTakenAfterTheCheckIsNeverReplaced() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("staged", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    let newcomer = directory.appendingPathComponent("report.pdf").path
    // Something else writes "report.pdf" between the check and the rename.
    let renames = FakeRenames { _, to, _ in
        guard to == newcomer, !FileManager.default.fileExists(atPath: newcomer) else { return nil }
        FileManager.default.createFile(atPath: newcomer, contents: Data("newcomer".utf8))
        return EEXIST
    }

    let placed = try UniquePlacement.place(source, named: "report.pdf", in: directory, isDirectory: false,
                                           fileSystem: renames.fileSystem())

    #expect(placed.lastPathComponent == "report 2.pdf")
    #expect(try contents(of: directory.appendingPathComponent("report.pdf")) == "newcomer")
    #expect(try contents(of: placed) == "new")
    #expect(renames.targets == ["report.pdf", "report 2.pdf"])
    #expect(renames.flags == [UInt32(RENAME_EXCL), UInt32(RENAME_EXCL)])
}

/// ENOTSUP, or EOPNOTSUPP: a separate number on Darwin, which some volumes (SMB, FAT/exFAT, a File
/// Provider) may give instead.
@Test(arguments: [ENOTSUP, EOPNOTSUPP])
func withoutExclusiveRenameItChecksThenRenames(_ code: Int32) throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("staged", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("report.pdf", in: directory, contents: "mine")
    let renames = FakeRenames { _, _, flags in flags == UInt32(RENAME_EXCL) ? code : nil }

    let placed = try UniquePlacement.place(source, named: "report.pdf", in: directory, isDirectory: false,
                                           fileSystem: renames.fileSystem())

    #expect(placed.lastPathComponent == "report 2.pdf")
    #expect(try contents(of: directory.appendingPathComponent("report.pdf")) == "mine")
    #expect(try contents(of: placed) == "new")
    #expect(renames.flags == [UInt32(RENAME_EXCL), 0])
}

@Test func withoutExclusiveRenameANameTakenAfterTheCheckMovesOn() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("staged", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    let newcomer = directory.appendingPathComponent("report.pdf").path
    // EINVAL: no RENAME_EXCL here; the newcomer shows up as the exclusive rename is refused.
    let renames = FakeRenames { _, to, flags in
        guard flags == UInt32(RENAME_EXCL) else { return nil }
        if to == newcomer { FileManager.default.createFile(atPath: newcomer, contents: Data("newcomer".utf8)) }
        return EINVAL
    }

    let placed = try UniquePlacement.place(source, named: "report.pdf", in: directory, isDirectory: false,
                                           fileSystem: renames.fileSystem())

    #expect(placed.lastPathComponent == "report 2.pdf")
    #expect(try contents(of: directory.appendingPathComponent("report.pdf")) == "newcomer")
    #expect(try contents(of: placed) == "new")
}

@Test func anyOtherErrorThrowsAndLeavesTheSourceWhereItWas() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("report.pdf", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    let renames = FakeRenames { _, _, _ in EIO }

    #expect(throws: POSIXError(.EIO)) {
        try UniquePlacement.place(source, named: "report.pdf", in: directory, isDirectory: false,
                                  fileSystem: renames.fileSystem())
    }
    #expect(try contents(of: source) == "new")
    #expect(try names(in: directory).isEmpty)
}

@Test(.timeLimit(.minutes(1))) func aNameThatIsNeverFreeEndsInsteadOfLoopingForever() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("report.pdf", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    let renames = FakeRenames { _, _, _ in EEXIST }

    #expect(throws: POSIXError(.EEXIST)) {
        try UniquePlacement.place(source, named: "report.pdf", in: directory, isDirectory: false,
                                  fileSystem: renames.fileSystem())
    }
    #expect(renames.targets.count == UniquePlacement.maxAttempts)
    #expect(Set(renames.targets).count == UniquePlacement.maxAttempts)
    #expect(try contents(of: source) == "new")
    #expect(try names(in: directory).isEmpty)
}

/// The Finder services pass their own naming (CompressPlan's); it picks both the first free name and the one after
/// a name taken at the rename.
@Test func aCallersNamingRulePicksTheNames() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("staged", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("Archive.zip", in: directory, contents: "mine")
    let newcomer = directory.appendingPathComponent("+Archive.zip").path
    let renames = FakeRenames { _, to, _ in
        guard to == newcomer, !FileManager.default.fileExists(atPath: newcomer) else { return nil }
        FileManager.default.createFile(atPath: newcomer, contents: Data("newcomer".utf8))
        return EEXIST
    }
    let prefixPlus = { (name: String, _: Bool, isTaken: (String) -> Bool) -> String in
        var candidate = name
        repeat { candidate = "+" + candidate } while isTaken(candidate)
        return candidate
    }

    let placed = try UniquePlacement.place(source, named: "Archive.zip", in: directory, isDirectory: false,
                                           fileSystem: renames.fileSystem(), nextName: prefixPlus)

    #expect(placed.lastPathComponent == "++Archive.zip")
    #expect(renames.targets == ["+Archive.zip", "++Archive.zip"])
    #expect(try contents(of: directory.appendingPathComponent("Archive.zip")) == "mine")
    #expect(try contents(of: directory.appendingPathComponent("+Archive.zip")) == "newcomer")
    #expect(try contents(of: placed) == "new")
}

// MARK: - No RENAME_EXCL: a case twin the lookup misses (extraction's check, here too)

// Without RENAME_EXCL, place checks, then renames plainly, and rename(2) replaces a file or an empty folder
// silently. As in `ArchiveModel.renameExclusively`, the check also lists the folder for a case twin
// (`CaseTwinListings`) where the volume isn't known to keep case apart. The fake lookup
// (`noExclusiveRename`) misses the twin the harness volume holds for real.

/// A file twin the lookup misses takes the next name where the volume folds case or the answer is unknown.
@Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL], [Bool?.none, false])
func placeWithoutExclusiveRenameNeverReplacesAFileTwinTheLookupMisses(_ code: Int32, _ caseSensitive: Bool?) throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("readme", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("README", in: directory, contents: "mine")

    let placed = try UniquePlacement.place(source, named: "readme", in: directory, isDirectory: false,
                                           fileSystem: noExclusiveRename(code, missing: "readme",
                                                                         caseSensitive: caseSensitive))

    #expect(placed.lastPathComponent == "readme 2")
    #expect(try names(in: directory) == ["README", "readme 2"])
    #expect(try contents(of: directory.appendingPathComponent("README")) == "mine")
    #expect(try contents(of: placed) == "new")
}

/// An empty folder that arrives as RENAME_EXCL is refused, on the name itself ("docs") or as a twin the
/// lookup misses ("Docs"): it stays, and the folder takes "docs 2".
@Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL], ["docs", "Docs"])
func placeWithoutExclusiveRenameNeverReplacesAnEmptyFolder(_ code: Int32, _ arriving: String) throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("docs", isDirectory: true, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    var fileSystem = noExclusiveRename(code, missing: arriving == "docs" ? "" : "docs", caseSensitive: nil)
    let rename = fileSystem.rename
    fileSystem.rename = { from, to, flags in
        if flags == UInt32(RENAME_EXCL), (to as NSString).lastPathComponent == "docs" {
            mkdir(directory.appendingPathComponent(arriving).path, 0o755)
        }
        return rename(from, to, flags)
    }

    let placed = try UniquePlacement.place(source, named: "docs", in: directory, isDirectory: true,
                                           fileSystem: fileSystem)

    #expect(placed.lastPathComponent == "docs 2")
    #expect(try names(in: directory) == [arriving, "docs 2"])
    #expect(try names(in: directory.appendingPathComponent(arriving)).isEmpty)
    #expect(try contents(of: placed.appendingPathComponent("inner.txt")) == "new")
}

/// A name without a twin there still goes on its own name.
@Test(arguments: [ENOTSUP, EOPNOTSUPP, EINVAL])
func placeWithoutExclusiveRenameANameWithoutATwinStillGoesOnItsName(_ code: Int32) throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("other.txt", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("README", in: directory, contents: "mine")

    let placed = try UniquePlacement.place(source, named: "other.txt", in: directory, isDirectory: false,
                                           fileSystem: noExclusiveRename(code, missing: "other.txt",
                                                                         caseSensitive: nil))

    #expect(placed.lastPathComponent == "other.txt")
    #expect(try names(in: directory) == ["README", "other.txt"])
}

/// A volume that says it keeps case apart has no case twins, so "readme" beside README isn't listed for one.
/// (On the harness volume the plain rename then does what that volume's wouldn't: only the name is checked.)
@Test func placeWithoutExclusiveRenameOnACaseSensitiveVolumeHasNoCaseTwins() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("readme", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("README", in: directory, contents: "mine")

    let placed = try UniquePlacement.place(source, named: "readme", in: directory, isDirectory: false,
                                           fileSystem: noExclusiveRename(ENOTSUP, missing: "readme",
                                                                         caseSensitive: true))

    #expect(placed.lastPathComponent == "readme")
}

/// A folder that can't be listed (a write-only drop box, 0333) shows no twin: the check fails open on purpose,
/// and the lookup still refuses the exact name. A twin the lookup misses goes ahead as before (on the harness
/// volume the plain rename then replaces README); the exact name takes "README 2".
@Test(arguments: [false, true])
func placeIntoAFolderThatCantBeListedChecksOnlyTheExactName(_ isTwin: Bool) throws {
    let directory = try makeTempDirectory()
    let name = isTwin ? "readme" : "README"
    let source = try makeSource(name, isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("README", in: directory, contents: "mine")
    #expect(chmod(directory.path, 0o333) == 0)
    defer { chmod(directory.path, 0o755) }
    #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) == nil)

    let placed = try UniquePlacement.place(source, named: name, in: directory, isDirectory: false,
                                           fileSystem: noExclusiveRename(ENOTSUP, missing: isTwin ? name : "",
                                                                         caseSensitive: nil))
    chmod(directory.path, 0o755)

    #expect(placed.lastPathComponent == (isTwin ? "readme" : "README 2"))
    // The replaced twin keeps whichever spelling the volume keeps (APFS: README's), so it's matched folded.
    #expect(try names(in: directory).map { $0.lowercased() } == (isTwin ? ["readme"] : ["readme", "readme 2"]))
    #expect(try contents(of: placed) == "new")
    if !isTwin { #expect(try contents(of: directory.appendingPathComponent("README")) == "mine") }
}

/// Only EACCES or EPERM from the listing fails open. Any other listing error is listed once more, then
/// throws: nothing is renamed, and the source stays where it was.
@Test(arguments: [EIO, ENOENT, ENOTDIR, EINTR])
func placeWithoutExclusiveRenameThrowsOnAListingErrorOtherThanPermission(_ code: Int32) throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("readme", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("README", in: directory, contents: "mine")
    let listings = CallCounter()
    let fileSystem = failingListings(code, noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil),
                                     counting: listings)

    #expect(throws: POSIXError(POSIXErrorCode(rawValue: code)!)) {
        try UniquePlacement.place(source, named: "readme", in: directory, isDirectory: false, fileSystem: fileSystem)
    }

    #expect(listings.count == 2)
    #expect(try names(in: directory) == ["README"])
    #expect(try contents(of: directory.appendingPathComponent("README")) == "mine")
    #expect(try contents(of: source) == "new")
}

/// EACCES or EPERM from the listing fails open: a name without a twin goes on its own name.
@Test(arguments: [EACCES, EPERM])
func placeWithoutExclusiveRenameFailsOpenOnAPermissionListingError(_ code: Int32) throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("other.txt", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("README", in: directory, contents: "mine")
    let listings = CallCounter()
    let fileSystem = failingListings(code, noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil),
                                     counting: listings)

    let placed = try UniquePlacement.place(source, named: "other.txt", in: directory, isDirectory: false,
                                           fileSystem: fileSystem)

    #expect(placed.lastPathComponent == "other.txt")
    #expect(listings.count == 1)
    #expect(try names(in: directory) == ["README", "other.txt"])
}

/// The check is the fallback's alone: where RENAME_EXCL works, nothing is probed, listed or read for its identity.
@Test func placeWithExclusiveRenameProbesAndListsNothing() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("other.txt", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("README", in: directory, contents: "mine")
    let probes = CallCounter(), listings = CallCounter(), identities = CallCounter()

    let placed = try UniquePlacement.place(source, named: "other.txt", in: directory, isDirectory: false,
                                           fileSystem: exclusiveRenameCountingChecks(probes: probes,
                                                                                     listings: listings,
                                                                                     identities: identities))

    #expect(placed.lastPathComponent == "other.txt")
    #expect(probes.count == 0)
    #expect(listings.count == 0)
    #expect(identities.count == 0)
}

/// One placement lists the folder once, however many names it tries (here three twins, then a free name).
@Test func placeWithoutExclusiveRenameListsTheFolderOnce() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("readme", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    for name in ["README", "README 2", "README 3"] { try makeFile(name, in: directory, contents: "mine") }
    let listings = CallCounter()
    // A lookup that misses all three, so only the folder's listing finds them.
    var fileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil), listings)
    fileSystem.exists = { _ in false }

    let placed = try UniquePlacement.place(source, named: "readme", in: directory, isDirectory: false,
                                           fileSystem: fileSystem, nextName: { name, _, _ in
                                               ["readme": "Readme 2", "Readme 2": "readme 3"][name] ?? "readme 4"
                                           })

    #expect(placed.lastPathComponent == "readme 4")
    #expect(listings.count == 1)
}

/// Two different folders whose identities match (inode 0, or a synthesized or reused one) never share a listing:
/// names that reach two folders (A/readme, then B/notes) list each, and NOTES in B, which the lookup misses, is
/// never replaced; the placement takes "B/notes 2".
@Test func placeWithoutExclusiveRenameTwoFoldersThatShareAnIdentityAreListedApart() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("notes", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    try makeFile("A/Readme", in: directory, contents: "theirs")
    try makeFile("B/NOTES", in: directory, contents: "mine")
    let listings = CallCounter()
    // A lookup that misses everything, so only the folders' listings find the twins.
    var fileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "", caseSensitive: nil), listings)
    fileSystem.exists = { _ in false }
    fileSystem.identity = { _ in ExtractionFileSystem.Identity(device: 1, inode: 0) }

    let placed = try UniquePlacement.place(source, named: "A/readme", in: directory, isDirectory: false,
                                           fileSystem: fileSystem, nextName: { name, _, _ in
                                               ["A/readme": "B/notes"][name] ?? "B/notes 2"
                                           })

    #expect(placed == directory.appendingPathComponent("B/notes 2"))
    #expect(listings.count == 2)
    #expect(try names(in: directory.appendingPathComponent("A")) == ["Readme"])
    #expect(try names(in: directory.appendingPathComponent("B")) == ["NOTES", "notes 2"])
    #expect(try contents(of: directory.appendingPathComponent("B/NOTES")) == "mine")
}

/// A plain rename that meets an item after all (here a twin made right after the listing) lists the folder
/// again and takes the next name: never a blind retry, never a replace.
@Test func placeWithoutExclusiveRenameListsAgainWhenTheRenameMeetsAnItem() throws {
    let directory = try makeTempDirectory()
    let source = try makeSource("readme", isDirectory: false, contents: "new")
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
    }
    let twin = directory.appendingPathComponent("README")
    let listings = CallCounter()
    var fileSystem = countingListings(noExclusiveRename(ENOTSUP, missing: "readme", caseSensitive: nil), listings,
                                      afterListing: { try? Data("mine".utf8).write(to: twin, options: .withoutOverwriting) })
    let rename = fileSystem.rename
    fileSystem.rename = { from, to, flags in
        flags == 0 && (to as NSString).lastPathComponent == "readme" ? EEXIST : rename(from, to, flags)
    }

    let placed = try UniquePlacement.place(source, named: "readme", in: directory, isDirectory: false,
                                           fileSystem: fileSystem)

    #expect(placed.lastPathComponent == "readme 2")
    #expect(listings.count == 2)
    #expect(try names(in: directory) == ["README", "readme 2"])
    #expect(try contents(of: twin) == "mine")
}
