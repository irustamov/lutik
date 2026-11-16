import Testing
import Foundation
@testable import Kernir

// ExclusiveCopy, drag-out's copy to another volume: the top folder is the
// copy's own only by its open descriptor (this user's, 0700, empty), a failure removes only what
// the copy made (and says so when something is left), an open failing right after the mkdir
// leaves nothing, the caller's own unreadable staging is copied with its modes, and a cancel stops
// a file midway. Slot-free.
// Not covered: the descriptor limit of a tree deeper than about 120 folders (only a lowered
// RLIMIT_NOFILE would reach it in a test, and that limit is the whole process's, tests beside it
// included).

// MARK: - Helpers

/// A fresh empty folder; the caller removes it with `ExclusiveCopy.removeItem`, which empties
/// read-only and unlistable folders too.
private func ecRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExclusiveCopyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func ecFile(_ name: String, in directory: URL, contents: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
}

/// Everything under `directory`: "dir" for folders, "link" for symlinks, else the contents (lstat).
private func ecSnapshot(_ directory: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for relative in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
        let url = directory.appendingPathComponent(relative)
        var status = stat()
        guard lstat(url.path, &status) == 0 else { continue }
        switch status.st_mode & S_IFMT {
        case S_IFDIR: result[relative] = "dir"
        case S_IFLNK: result[relative] = "link"
        default: result[relative] = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
    }
    return result
}

/// Something is at `url` (lstat).
private func ecExists(_ url: URL) -> Bool {
    var status = stat()
    return lstat(url.path, &status) == 0
}

/// The mode bits of the item at `url` (lstat), 0 when nothing is there.
private func ecMode(_ url: URL) -> mode_t {
    var status = stat()
    return lstat(url.path, &status) == 0 ? status.st_mode & 0o7777 : 0
}

/// A folder "source" in `root`: "a.txt", a read-only (0555) "b" with "inner.txt", "c.txt".
private func ecSource(in root: URL) throws -> URL {
    let source = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("b"), withIntermediateDirectories: true)
    try ecFile("a.txt", in: source, contents: "a")
    try ecFile("inner.txt", in: source.appendingPathComponent("b"), contents: "inner")
    try ecFile("c.txt", in: source, contents: "c")
    try #require(chmod(source.appendingPathComponent("b").path, 0o555) == 0)
    return source
}

private func expectFileExistsError(_ error: any Error, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect((error as NSError).domain == NSCocoaErrorDomain
                && (error as NSError).code == CocoaError.fileWriteFileExists.rawValue, "\(error)",
            sourceLocation: sourceLocation)
}

// MARK: - A: the top folder must be the copy's own

/// What a racer in the drop folder does right after the copy's mkdir of the promised folder.
enum ExclusiveCopyRacer: String, CaseIterable, Sendable {
    /// Moves the copy's folder away and puts an empty folder of its own there, opened up (0755).
    case swapsInAnOpenFolder
    /// Moves the copy's folder away and puts a 0700 folder of its own there, holding its item.
    case swapsInAFilledFolder
    /// Puts its item in the copy's own folder.
    case fillsTheCopysFolder
}

/// A top folder that isn't, by its open descriptor, this user's empty 0700 folder (a racer's
/// swapped in after the mkdir, or the copy's with a racer's item in it) is refused as the file-exists
/// error; nothing is copied into it and the racer's item stays.
@Test(arguments: ExclusiveCopyRacer.allCases)
func aTopFolderThatIsntTheCopysOwnIsRefusedAndLeftAlone(_ racer: ExclusiveCopyRacer) throws {
    let root = try ecRoot()
    defer { try? ExclusiveCopy.removeItem(at: root) }
    let source = try ecSource(in: root)
    let target = root.appendingPathComponent("copy", isDirectory: true)
    let aside = root.appendingPathComponent("aside", isDirectory: true)
    var seams = ExclusiveCopy.Seams()
    seams.afterMakingTarget = { made in
        if racer != .fillsTheCopysFolder {
            _ = rename(made.path, aside.path)
            _ = mkdir(made.path, 0o700)
            _ = chmod(made.path, racer == .swapsInAnOpenFolder ? 0o755 : 0o700)
        }
        if racer != .swapsInAnOpenFolder {
            _ = try? ecFile("racer.txt", in: made, contents: "racer")
        }
    }

    do {
        try ExclusiveCopy.copy(source, to: target, seams: seams)
        Issue.record("must throw")
    } catch {
        expectFileExistsError(error)
    }

    let racersItems: [String: String] = racer == .swapsInAnOpenFolder ? [:] : ["racer.txt": "racer"]
    let racersMode: mode_t = racer == .swapsInAnOpenFolder ? 0o755 : 0o700
    #expect(try ecSnapshot(target) == racersItems)
    #expect(ecMode(target) == racersMode)
}

/// A racer's item put in the copy's folder while it copies: a failure then (here a cancel, once the
/// read-only "b" is copied whole) removes every item the copy made, read-only folder included, and
/// leaves the racer's item, so the folder stays: `PartialCopyError`, which says a partial copy was
/// left there.
@Test func aFailedCopyRemovesOnlyWhatItMadeAndSaysWhatIsLeft() throws {
    let root = try ecRoot()
    defer { try? ExclusiveCopy.removeItem(at: root) }
    let source = try ecSource(in: root)
    let target = root.appendingPathComponent("copy", isDirectory: true)

    do {
        try ExclusiveCopy.copy(source, to: target) {
            guard ecMode(target.appendingPathComponent("b")) == 0o555 else { return false }
            _ = try? ecFile("racer.txt", in: target, contents: "racer")
            return true
        }
        Issue.record("must throw")
    } catch let error as ExclusiveCopy.PartialCopyError {
        #expect(error.url == target)
        #expect(error.underlying is CancellationError, "\(error.underlying)")
        #expect(error.localizedDescription.contains("partial copy"), "\(error.localizedDescription)")
    } catch {
        Issue.record("\(error)")
    }

    #expect(try ecSnapshot(target) == ["racer.txt": "racer"])
}

/// The alert names the folder as Finder does and gives the real cause (a full disk, say) as its
/// suggestion, none for a cancel; no failure reason repeating the title (`NSAlert(error:)` shows the suggestion).
@Test func aPartialCopyErrorNamesTheFolderAsFinderDoesAndGivesTheCause() throws {
    let root = try ecRoot()
    defer { try? ExclusiveCopy.removeItem(at: root) }
    let target = root.appendingPathComponent("copy", isDirectory: true)
    let underlying = POSIXError(.ENOSPC)
    let error = ExclusiveCopy.PartialCopyError(url: target, underlying: underlying)

    let folder = FileManager.default.displayName(atPath: root.path)
    #expect(error.errorDescription
        == String(localized: "A partial copy of “copy” was left in “\(folder)”.", table: "Shared"))
    #expect(error.failureReason == nil)
    #expect(error.recoverySuggestion == underlying.localizedDescription)
    // A cancel is no cause to show: the title alone.
    #expect(ExclusiveCopy.PartialCopyError(url: target, underlying: CancellationError()).recoverySuggestion == nil)
    #expect(ExclusiveCopy.PartialCopyError(url: target, underlying: CocoaError(.userCancelled)).recoverySuggestion == nil)
}

// MARK: - B: an open failing after the mkdir

/// The promised folder made, then its open failing (here: made unreadable right after the mkdir):
/// its error, and the empty folder the mkdir made is removed again, so the next drop on that URL
/// isn't refused.
@Test func anOpenFailingRightAfterTheMkdirLeavesNothing() throws {
    try #require(geteuid() != 0, "running as root: a 0000 folder still opens")
    let root = try ecRoot()
    defer { try? ExclusiveCopy.removeItem(at: root) }
    let source = try ecSource(in: root)
    let target = root.appendingPathComponent("copy", isDirectory: true)
    var seams = ExclusiveCopy.Seams()
    seams.afterMakingTarget = { _ = chmod($0.path, 0) }

    #expect(throws: POSIXError(.EACCES)) {
        try ExclusiveCopy.copy(source, to: target, seams: seams)
    }
    #expect(!ecExists(target))

    try ExclusiveCopy.copy(source, to: target)
    #expect(try ecSnapshot(target) == ["a.txt": "a", "b": "dir", "b/inner.txt": "inner", "c.txt": "c"])
}

// MARK: - D: the caller's own unreadable staging

/// With `unlocksSource` (drag-out's own staging), a file of this user's without u+r and a folder
/// without u+rx are copied, their modes kept on the copy and given back to the source; at the top
/// too.
@Test func anUnreadableSourceOfOursIsCopiedWithItsModesWhenUnlocked() throws {
    try #require(geteuid() != 0, "running as root: nothing is unreadable")
    let root = try ecRoot()
    defer { try? ExclusiveCopy.removeItem(at: root) }
    let source = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("closed"), withIntermediateDirectories: true)
    try ecFile("x.txt", in: source.appendingPathComponent("closed"), contents: "x")
    let locked = try ecFile("locked", in: source, contents: "secret")
    let top = try ecFile("top", in: root, contents: "top")
    for (url, mode) in [(locked, 0o000), (source.appendingPathComponent("closed"), 0o300), (top, 0o000)] {
        try #require(chmod(url.path, mode_t(mode)) == 0)
    }
    let target = root.appendingPathComponent("copy", isDirectory: true)
    let topCopy = root.appendingPathComponent("top copy")

    try ExclusiveCopy.copy(source, to: target, unlocksSource: true)
    try ExclusiveCopy.copy(top, to: topCopy, unlocksSource: true)

    #expect(ecMode(target.appendingPathComponent("locked")) == 0)
    #expect(ecMode(target.appendingPathComponent("closed")) == 0o300)
    #expect(ecMode(topCopy) == 0)
    #expect(ecMode(locked) == 0)
    #expect(ecMode(source.appendingPathComponent("closed")) == 0o300)
    #expect(ecMode(top) == 0)
    for (url, mode) in [(target.appendingPathComponent("locked"), 0o600), (target.appendingPathComponent("closed"), 0o700),
                        (topCopy, 0o600)] {
        try #require(chmod(url.path, mode_t(mode)) == 0)
    }
    #expect(try ecSnapshot(target) == ["locked": "secret", "closed": "dir", "closed/x.txt": "x"])
    #expect(String(decoding: try Data(contentsOf: topCopy), as: UTF8.self) == "top")
}

// MARK: - F: a cancel within one file

/// A cancel while one file copies stops it midway, not at its end: the copy asks after each chunk
/// it writes (copyfile's status callback; 1 MiB chunks on APFS, so 8 MiB is eight), then removes
/// what it made. Alone and in a folder.
@Test(arguments: [false, true])
func aCancelStopsAFileMidway(_ inAFolder: Bool) throws {
    let root = try ecRoot()
    defer { try? ExclusiveCopy.removeItem(at: root) }
    let size = 8 << 20
    let folder = root.appendingPathComponent("source", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let big = folder.appendingPathComponent("big.bin")
    try Data(repeating: 0x61, count: size).write(to: big)
    let target = root.appendingPathComponent("copy", isDirectory: inAFolder)
    let copied = inAFolder ? target.appendingPathComponent("big.bin") : target
    // Asked at the start, and in a folder before "big.bin": the asks after those are the file's own.
    let asksBeforeTheFile = inAFolder ? 2 : 1
    var asked = 0
    var largestWhenCancelled: off_t = -1

    #expect(throws: CancellationError.self) {
        try ExclusiveCopy.copy(inAFolder ? folder : big, to: target) {
            asked += 1
            guard asked > asksBeforeTheFile else { return false }
            var status = stat()
            if lstat(copied.path, &status) == 0 { largestWhenCancelled = max(largestWhenCancelled, status.st_size) }
            return true
        }
    }

    #expect(asked > asksBeforeTheFile, "never asked within the file")
    #expect(largestWhenCancelled >= 0 && largestWhenCancelled < off_t(size), "\(largestWhenCancelled)")
    #expect(!ecExists(target))
}
