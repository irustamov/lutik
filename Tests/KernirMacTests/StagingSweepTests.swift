import Testing
import Foundation
@testable import Kernir

// StagingSweep: a crashed run's hidden staging in a drop folder (or beside an archive) goes, and
// nothing else does: a live run's (another window's extract), a young one, another device's, a
// symlink named like staging, a foreign ".kernir-" name, one holding a user's item. Slot-free.

// MARK: - Helpers (internal: ArchiveDragOutTests uses them too)

private let token = "5eed5eed5eed5eed"

/// A pid no process has: a child that ran and was reaped (kill says ESRCH).
func reapedPid() throws -> pid_t {
    for _ in 0..<5 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        let pid = process.processIdentifier
        if kill(pid, 0) == -1, errno == ESRCH { return pid }
    }
    throw POSIXError(.ESRCH)
}

/// A staging folder `.kernir-<token>-<pid>-<uuid>` in `directory` holding one file, last modified at
/// `modified`.
@discardableResult
func makeTestStaging(in directory: URL, token: String, pid: pid_t, modified: Date,
                     contents: [String] = ["partial.bin"]) throws -> URL {
    let url = directory.appendingPathComponent("\(ArchiveModel.stagingPrefix)\(token)-\(pid)-\(UUID().uuidString)",
                                               isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    for name in contents {
        let item = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: item.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: item)
    }
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
}

private func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("StagingSweepTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func names(in directory: URL) throws -> Set<String> {
    Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
}

private let old = Date(timeIntervalSinceNow: -3600)

// MARK: - Tests

@Test func aStaleStagingOfOursIsRemoved() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try makeTestStaging(in: folder, token: token, pid: try reapedPid(), modified: old, contents: ["a/b/c.txt", "d.txt"])
    try Data("mine".utf8).write(to: folder.appendingPathComponent("mine.txt"))

    StagingSweep.sweep(in: folder, deviceToken: token)

    #expect(try names(in: folder) == ["mine.txt"])
}

/// A crashed drag-out's staging holding read-only (0555) folders, as an archive's can be, goes
/// whole: FileManager's removal stopped at their items, so it failed on every sweep.
@Test func aStaleStagingWithAReadOnlyFolderIsRemoved() throws {
    let folder = try makeFolder()
    defer { try? ExclusiveCopy.removeItem(at: folder) }
    let staging = try makeTestStaging(in: folder, token: token, pid: try reapedPid(), modified: old,
                                      contents: ["src/lib/util.swift", "src/main.swift"])
    for path in ["src/lib", "src"] {
        try #require(chmod(staging.appendingPathComponent(path).path, 0o555) == 0)
    }
    try Data("mine".utf8).write(to: folder.appendingPathComponent("mine.txt"))

    StagingSweep.sweep(in: folder, deviceToken: token)

    #expect(try names(in: folder) == ["mine.txt"])
}

/// A live process's staging stays, however old: another window's extract is still using it. pid 1
/// (EPERM for kill) counts as alive too.
@Test func aLiveRunsStagingIsKept() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let parent = try makeTestStaging(in: folder, token: token, pid: getppid(), modified: old)
    let launchd = try makeTestStaging(in: folder, token: token, pid: 1, modified: old)
    let own = try makeTestStaging(in: folder, token: token, pid: getpid(), modified: old)

    StagingSweep.sweep(in: folder, deviceToken: token)

    #expect(try names(in: folder) == [parent.lastPathComponent, launchd.lastPathComponent, own.lastPathComponent])
}

/// Younger than 10 minutes: kept, its process gone or not (a pid can be reused, a slow volume lags).
@Test func aYoungStagingIsKept() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let young = try makeTestStaging(in: folder, token: token, pid: try reapedPid(),
                                    modified: Date(timeIntervalSinceNow: -StagingSweep.minimumAge + 60))

    StagingSweep.sweep(in: folder, deviceToken: token)
    #expect(try names(in: folder) == [young.lastPathComponent])

    StagingSweep.sweep(in: folder, deviceToken: token, now: Date(timeIntervalSinceNow: 120))
    #expect(try names(in: folder).isEmpty)
}

/// Another device's staging (a shared folder): its pid means nothing here, so it stays.
@Test func anotherDevicesStagingIsKept() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let other = try makeTestStaging(in: folder, token: "0123456789abcdef", pid: try reapedPid(), modified: old)

    StagingSweep.sweep(in: folder, deviceToken: token)

    #expect(try names(in: folder) == [other.lastPathComponent])
}

/// A symlink named exactly like stale staging: neither removed nor followed (its target and what's
/// in it stay).
@Test func aSymlinkNamedLikeStagingIsLeftAlone() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("target", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
    let link = folder.appendingPathComponent("\(ArchiveModel.stagingPrefix)\(token)-\(try reapedPid())-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: target.path)
    // The link's own times (lutimes, not the target's) are old too, and "now" is a day on: age, token
    // and pid all say "stale", so only the symlink rule keeps it.
    var times = [timeval(tv_sec: Int(old.timeIntervalSince1970), tv_usec: 0),
                 timeval(tv_sec: Int(old.timeIntervalSince1970), tv_usec: 0)]
    try #require(lutimes(link.path, &times) == 0)
    var status = stat()
    try #require(lstat(link.path, &status) == 0 && status.st_mode & S_IFMT == S_IFLNK)
    try #require(Date().timeIntervalSince1970 - Double(status.st_mtimespec.tv_sec) >= StagingSweep.minimumAge)

    StagingSweep.sweep(in: folder, deviceToken: token, now: Date(timeIntervalSinceNow: 86_400))

    #expect(try names(in: folder) == ["target", link.lastPathComponent])
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("keep.txt").path))
}

/// A regular file (or a symlink-free non-folder) named exactly like stale staging: not a folder, so
/// it is not ours to remove.
@Test func aRegularFileNamedLikeStagingIsLeftAlone() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("\(ArchiveModel.stagingPrefix)\(token)-\(try reapedPid())-\(UUID().uuidString)")
    try Data("mine".utf8).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)

    StagingSweep.sweep(in: folder, deviceToken: token, now: Date(timeIntervalSinceNow: 86_400))

    #expect(try names(in: folder) == [file.lastPathComponent])
    #expect(try String(contentsOf: file, encoding: .utf8) == "mine")
}

/// Names that only look like staging: kept (the parser is exact, not a prefix match).
@Test func namesThatAreNotStagingAreKept() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let pid = try reapedPid()
    let uuid = UUID().uuidString
    let lookalikes = [".kernir-foo", ".kernir-\(token)", ".kernir-\(token)-\(pid)", ".kernir-\(token)-0\(pid)-\(uuid)",
                      ".kernir-\(token)--\(pid)-\(uuid)", ".kernir-\(token.uppercased())-\(pid)-\(uuid)",
                      ".kernir-\(token)-\(pid)-\(uuid)x", "kernir-\(token)-\(pid)-\(uuid)", ".kernir-keep"]
    for name in lookalikes {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }

    StagingSweep.sweep(in: folder, deviceToken: token)

    #expect(try names(in: folder) == Set(lookalikes))
}

/// A stale staging holding a user's item (Replace's keep marker, or a non-empty recovered folder,
/// in it or in a staging folder inside it) stays.
@Test(arguments: [
    [ArchiveModel.keepMarker],
    ["\(ArchiveModel.recoveredName) \(UUID().uuidString)/report.pdf"],
    [".kernir-5eed5eed5eed5eed-1-\(UUID().uuidString)/\(ArchiveModel.keepMarker)"],
    [".kernir-5eed5eed5eed5eed-1-\(UUID().uuidString)/\(ArchiveModel.recoveredName) \(UUID().uuidString)/x"],
])
func aStagingHoldingAUsersItemIsKept(_ contents: [String]) throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let kept = try makeTestStaging(in: folder, token: token, pid: try reapedPid(), modified: old, contents: contents)

    StagingSweep.sweep(in: folder, deviceToken: token)

    #expect(try names(in: folder) == [kept.lastPathComponent])
}

/// A staging a build from before the rename left, its "Kernir Recovered <uuid>" folder holding
/// the user's item and no keep marker (its lstat failed): kept, under the old name as under the new.
@Test func aLegacyKernirRecoveredFolderKeepsItsStaging() throws {
    #expect(ArchiveModel.legacyRecoveredName == "Kernir Recovered")
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let kept = try makeTestStaging(in: folder, token: token, pid: try reapedPid(), modified: old,
                                   contents: ["Kernir Recovered \(UUID().uuidString)/report.pdf"])
    let inner = ".kernir-\(token)-1-\(UUID().uuidString)/Kernir Recovered \(UUID().uuidString)/x"
    let keptToo = try makeTestStaging(in: folder, token: token, pid: try reapedPid(), modified: old, contents: [inner])
    let empty = try makeTestStaging(in: folder, token: token, pid: try reapedPid(), modified: Date(), contents: [])
    try FileManager.default.createDirectory(at: empty.appendingPathComponent("Kernir Recovered \(UUID().uuidString)"),
                                            withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: empty.path)

    StagingSweep.sweep(in: folder, deviceToken: token)

    #expect(try names(in: folder) == [kept.lastPathComponent, keptToo.lastPathComponent])
}

/// An empty recovered folder holds nothing: that staging goes.
@Test func anEmptyRecoveredFolderDoesNotKeepIt() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let staging = try makeTestStaging(in: folder, token: token, pid: try reapedPid(), modified: Date(), contents: [])
    try FileManager.default.createDirectory(at: staging.appendingPathComponent("\(ArchiveModel.recoveredName) \(UUID().uuidString)"),
                                            withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: staging.path)

    StagingSweep.sweep(in: folder, deviceToken: token)

    #expect(try names(in: folder).isEmpty)
}

/// A folder we can't change (or can't read), or one that's gone: nothing thrown, nothing removed.
@Test func anUnwritableFolderIsLeftAsItIs() throws {
    let folder = try makeFolder()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }
    let stale = try makeTestStaging(in: folder, token: token, pid: try reapedPid(), modified: old)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)

    StagingSweep.sweep(in: folder, deviceToken: token)
    #expect(FileManager.default.fileExists(atPath: stale.path))

    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
    StagingSweep.sweep(in: folder, deviceToken: token)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
    #expect(FileManager.default.fileExists(atPath: stale.path))

    StagingSweep.sweep(in: folder.appendingPathComponent("gone", isDirectory: true), deviceToken: token)
}

/// Only direct children: stale staging deeper down (inside a user's folder) stays.
@Test func onlyDirectChildrenAreSwept() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let nested = folder.appendingPathComponent("Projects", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    let deep = try makeTestStaging(in: nested, token: token, pid: try reapedPid(), modified: old)

    StagingSweep.sweep(in: folder, deviceToken: token)

    #expect(FileManager.default.fileExists(atPath: deep.path))
}

/// The name ExtractHereService makes for its staging is one the sweep's parser accepts, with its
/// fields: seen while an Extract Here runs (the same name as a drag-out's, ArchiveDragOutTests
/// aWriteInFlightKeepsItsStagingThroughASweep).
@Test func theParserReadsTheMadeName() throws {
    let made = "\(ArchiveModel.stagingPrefix)\(token)-\(getpid())-\(UUID().uuidString)"
    let fields = try #require(ArchiveModel.stagingNameFields(made))
    #expect(fields.deviceToken == token && fields.pid == getpid())
}

// MARK: - Bounds: a write awaits the sweep, so it never takes long

/// One sweep looks at no more than `limit` staging folders of ours: N+1 stale ones lose N, the next
/// sweep takes the last.
@Test func aSweepLooksAtNoMoreThanItsLimit() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let gone = try reapedPid()
    for _ in 0..<3 { try makeTestStaging(in: folder, token: token, pid: gone, modified: old) }
    try Data("mine".utf8).write(to: folder.appendingPathComponent("mine.txt"))

    StagingSweep.sweep(in: folder, deviceToken: token, limit: 2)
    #expect(try names(in: folder).count == 2)

    StagingSweep.sweep(in: folder, deviceToken: token, limit: 2)
    #expect(try names(in: folder) == ["mine.txt"])
}

/// A sweep stops at its time limit: with a clock one second on per look and a limit of 1.5 s, it
/// takes one stale staging folder of three and leaves the others for later.
@Test func aSweepStopsAtItsTimeLimit() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let gone = try reapedPid()
    for _ in 0..<3 { try makeTestStaging(in: folder, token: token, pid: gone, modified: old) }
    var ticks: TimeInterval = 0
    let start = Date()

    StagingSweep.sweep(in: folder, deviceToken: token, timeLimit: 1.5,
                       clock: { defer { ticks += 1 }; return start.addingTimeInterval(ticks) })

    #expect(try names(in: folder).count == 2)
}

/// A folder is swept at most once per `StagingSweep.interval` (a drop of many rows, Extract Here
/// again and again): a stale staging folder that shows up in between waits for the next one.
/// The interval runs on the system's uptime, not the wall clock: a clock set forward an hour doesn't
/// let the folder be swept again early, and one set back five minutes doesn't hold its next sweep
/// for five minutes more. (One test: a call with a later uptime prunes every folder's earlier sweeps.)
@Test func aFolderIsSweptAtMostOncePerInterval() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let gone = try reapedPid()
    let first = try makeTestStaging(in: folder, token: token, pid: gone, modified: old)
    let uptime = ProcessInfo.processInfo.systemUptime

    #expect(StagingSweep.sweepIfDue(in: folder, deviceToken: token, now: Date(), uptime: uptime))
    #expect(!FileManager.default.fileExists(atPath: first.path))

    let second = try makeTestStaging(in: folder, token: token, pid: gone, modified: old)
    #expect(!StagingSweep.sweepIfDue(in: folder, deviceToken: token, now: Date(timeIntervalSinceNow: 3_600),
                                     uptime: uptime + StagingSweep.interval / 2))
    #expect(FileManager.default.fileExists(atPath: second.path))

    #expect(StagingSweep.sweepIfDue(in: folder, deviceToken: token, now: Date(timeIntervalSinceNow: -300),
                                    uptime: uptime + StagingSweep.interval))
    #expect(!FileManager.default.fileExists(atPath: second.path))
}

/// A folder reached through a symlink is the same folder: the folder and a symlink to it are swept
/// once per interval together, not once each.
@Test func aFolderAndItsSymlinkedPathShareOneSweepInterval() throws {
    let folder = try makeFolder()
    let link = FileManager.default.temporaryDirectory
        .appendingPathComponent("StagingSweepTests-link-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    defer {
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.removeItem(at: folder)
    }
    let uptime = ProcessInfo.processInfo.systemUptime

    #expect(StagingSweep.sweepIfDue(in: link, deviceToken: token, now: Date(), uptime: uptime))
    #expect(!StagingSweep.sweepIfDue(in: folder, deviceToken: token, now: Date(), uptime: uptime + 1))
}
