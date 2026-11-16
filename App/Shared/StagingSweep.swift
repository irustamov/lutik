import Foundation
import os

/// Removes the hidden staging folders (`.kernir-<device token>-<pid>-<uuid>`) a crashed or killed
/// run left directly in a folder Lutik extracts into: a drop folder (drag-out) or the archive's
/// folder (Extract Here). Those runs make their staging there, and `ArchiveModel`'s own sweep only
/// covers the folder it stages in, which for them is inside that staging. Mirrors that sweep's
/// rules, stricter: only a direct child named exactly as staging is (`ArchiveModel
/// .stagingNameFields`, the parser of the name `ExtractHereService` makes), this device's token, a
/// real folder (lstat: a symlink is never followed or removed) owned by this user, its process gone
/// (`kill` says ESRCH; alive or EPERM keeps it), untouched for `minimumAge`, holding no user's item
/// (`ArchiveModel`'s keep marker, or a non-empty recovered folder, in it or in a staging folder
/// directly inside it). Best effort: a failure is logged, never thrown, so it never blocks the
/// extraction that runs it. Bounded, since every write awaits it: a write sweeps its
/// folder at most once per `interval` (`sweepIfDue`), and one sweep looks at no more than
/// `candidateLimit` staging folders of ours and stops at `timeLimit`; what it leaves waits for a later one.
enum StagingSweep {
    private static let logger = Logger(subsystem: "com.kernir.app", category: "stagingSweep")

    /// `ArchiveModel`'s rule: untouched for 10 minutes.
    static let minimumAge: TimeInterval = 600
    /// A folder is swept at most once in this long (`sweepIfDue`).
    static let interval: TimeInterval = 60
    /// One sweep looks at no more than this many staging folders of ours (this device's, another pid's).
    static let candidateLimit = 64
    /// One sweep looks at no further staging folder after this long. Best effort: it is checked
    /// between staging folders only, so listing the folder, listing a candidate and the staging
    /// folders directly in it for a user's item (`holdsUsersItem`), and removing one stale staging
    /// folder (however big) run to their end and may take the sweep past it.
    static let timeLimit: TimeInterval = 2

    /// When each folder (and device token) was last swept, by `sweepIfDue`, as the system's uptime;
    /// older than `interval` pruned.
    private static let lastSweeps = OSAllocatedUnfairLock(initialState: [String: TimeInterval]())

    /// `sweep`, unless `directory` was swept (or a sweep of it started) for `deviceToken` less than
    /// `interval` before. The interval runs on `uptime`, the system's (monotonic), not the wall
    /// clock: a clock set back doesn't hold a folder's next sweep, one set forward doesn't
    /// bring it early. `now` (the wall clock) is only the staging folders' age. True when it swept.
    /// `now` and `uptime` are for tests.
    @discardableResult
    static func sweepIfDue(in directory: URL, deviceToken: String, now: Date = Date(),
                           uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let key = "\(deviceToken)/\(directory.resolvingSymlinksInPath().path)"
        let isDue = lastSweeps.withLock { last in
            last = last.filter { uptime - $0.value < interval }
            guard last[key] == nil else { return false }
            last[key] = uptime
            return true
        }
        if isDue { sweep(in: directory, deviceToken: deviceToken, now: now) }
        return isDue
    }

    /// Sweeps `directory` for `deviceToken`'s stale staging: at most `limit` staging folders of ours,
    /// none after `timeLimit` by `clock`. `now`, `limit`, `timeLimit`, `clock` and `isProcessGone`
    /// are for tests.
    static func sweep(in directory: URL, deviceToken: String, now: Date = Date(),
                      limit: Int = candidateLimit, timeLimit: TimeInterval = timeLimit,
                      clock: () -> Date = { Date() }, isProcessGone: (pid_t) -> Bool = isProcessGone) {
        let deadline = clock().addingTimeInterval(timeLimit)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        var looked = 0
        // In no fixed order, so folders a sweep keeps (a live run's, a user's item) can't take the
        // limit from the stale ones every time.
        for name in names.shuffled() {
            guard let fields = ArchiveModel.stagingNameFields(name), fields.deviceToken == deviceToken,
                  fields.pid != getpid() else { continue }
            // Best effort: the time limit is checked here, between candidates; neither the listing
            // above, nor `holdsUsersItem`'s listings of a candidate, nor one removal below is interrupted.
            guard looked < limit, clock() < deadline else {
                logger.info("Sweep stopped after \(looked, privacy: .public) staging folders, the rest waits")
                return
            }
            looked += 1
            guard isProcessGone(fields.pid) else { continue }
            let url = directory.appendingPathComponent(name, isDirectory: true)
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid()
            else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
                                + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000)
            guard now.timeIntervalSince(modified) >= minimumAge, !holdsUsersItem(url) else { continue }
            do {
                // A symlink inside is unlinked, never followed; a read-only folder inside (an archive's
                // 0555, in a crashed drag-out's staging) empties too, where FileManager's removal stops.
                try ExclusiveCopy.removeItem(at: url)
                logger.info("Swept stale staging \(name, privacy: .private)")
            } catch {
                logger.error("Cannot sweep \(url.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public)")
            }
        }
    }

    /// No process has `pid`: kill(2) says ESRCH. A live one, or one we may not signal (EPERM), isn't gone.
    static func isProcessGone(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    /// `staging`, or a staging folder directly in it, has the keep marker or a recovered folder that
    /// isn't empty; or can't be listed (then nothing says it holds nothing).
    private static func holdsUsersItem(_ staging: URL) -> Bool {
        if holdsUsersItemItself(staging) { return true }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: staging.path) else { return true }
        return names.contains { name in
            guard ArchiveModel.stagingNameFields(name) != nil else { return false }
            let inner = staging.appendingPathComponent(name, isDirectory: true)
            var status = stat()
            return lstat(inner.path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR && holdsUsersItemItself(inner)
        }
    }

    private static func holdsUsersItemItself(_ staging: URL) -> Bool {
        var status = stat()
        if lstat(staging.appendingPathComponent(ArchiveModel.keepMarker).path, &status) == 0 { return true }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: staging.path) else { return true }
        return names.contains { name in
            guard ArchiveModel.isRecoveredFolderName(name) else { return false }
            let folder = staging.appendingPathComponent(name).path
            return (try? FileManager.default.contentsOfDirectory(atPath: folder).isEmpty) != true
        }
    }
}
