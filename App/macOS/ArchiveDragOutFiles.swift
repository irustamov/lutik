import AppKit
import KernirCore

// The caps of a drag out's plain files (`ArchiveDragOutFiles`), in one place, so they are easy to change.
extension ArchiveDragOut {
    /// The most bytes, all its files together, a drag out offers as plain files beside its promises; a drag
    /// over it stays promises only, every row.
    static let maxBytes: Int64 = 32 * 1024 * 1024
    /// The most rows a drag out may have to offer plain files; a drag with more stays promises only.
    static let maxEntries = 16
    /// How long the start of a drag out may hold the main thread for its extraction; a drag whose files
    /// aren't ready by then stays promises only.
    static let fileURLWait: TimeInterval = 1
    /// How old a drag's folder of plain files is before a later drag deletes it: a slow upload (Slack, Mail)
    /// may still read a recent one. Quit deletes them all, launch those a crash left.
    static let dragOutFolderMaxAge: TimeInterval = 10 * 60
    /// The name prefix of a drag's folder of plain files in the temporary folder. A `Kernir-` prefix, so a drop
    /// of them back on an archive window adds nothing (`ArchiveActions.isOwnTemporaryFile`).
    static let dragOutFolderPrefix = "Kernir-DragOut-"
    /// The record, in a drag's folder, of its files as extracted (`ArchiveDragOutManifest`).
    static let dragOutManifestName = ".Kernir-DragOut-manifest.json"
}

/// The plain files one drag out of an archive window offers beside its file promises, for receivers that
/// don't take promises (Slack and other Electron apps, browser uploads, Terminal, Mail). All or nothing: when
/// the drag is written (the first `offersFileURL`, after AppKit asked for every row's writer), every row must
/// be a file of the archive as it was read (`Row`; not a folder, an addition, a renamed file, a size unknown),
/// at most `ArchiveDragOut.maxEntries` rows and `maxBytes` in all; then one detached task extracts them into a
/// fresh `Kernir-DragOut-<UUID>` folder of the temporary folder, each at `<folder>/<i>/<offered name>`, while the
/// main thread waits at most `ArchiveDragOut.fileURLWait`. Each row then declares `.fileURL`, written at once
/// (not promised: a lazily served URL gets no sandbox extension, and receivers read nothing). Anything else (a
/// row that may not, a cap, a failure, an extracted item that is not a regular file such as a symlink, the
/// wait running out, the files as extracted over `maxBytes`) leaves the whole drag promises only, and its folder
/// is deleted by whichever side ends last. The files are made u+rw whatever the archive stored (a receiver that
/// copies the URL keeps the mode), and the folder records them as extracted (`ArchiveDragOutManifest`). The
/// folders stay for slow receivers: `ArchiveDragOutFolders` deletes them later, unless their files changed
/// (edited in place, say).
/// All state is guarded by `condition`.
final class ArchiveDragOutFiles: @unchecked Sendable {
    /// A row that may come out as a plain file.
    struct Row: Sendable, Equatable {
        /// The row's archive path as shown (its key here).
        let path: String
        /// The path the reader knows the entry by.
        let readerPath: String
        /// The name the file must have (`ArchiveDragOut.offeredName(forPath:)`).
        let name: String
        let size: Int64
    }

    /// Extracts the entry at `readerPath` into the existing empty `directory`, its archive path recreated
    /// there (`ArchiveReading.extract`).
    typealias Extract = @Sendable (_ readerPath: String, _ directory: URL) async throws -> Void

    private enum Phase { case collecting, extracting, ready, refused }

    private let condition = NSCondition()
    private var phase = Phase.collecting
    /// The paths of every row counted, eligible or not: a row asked for twice counts once.
    private var paths: Set<String> = []
    private var rows: [Row] = []
    private var hasIneligibleRow = false
    private var urls: [String: URL] = [:]
    private var task: Task<Void, Never>?

    private let extract: Extract
    private let maxBytes: Int64
    private let maxEntries: Int
    private let wait: TimeInterval
    private let temporaryDirectory: URL
    private let folders: ArchiveDragOutFolders

    init(extract: @escaping Extract, maxBytes: Int64 = ArchiveDragOut.maxBytes,
         maxEntries: Int = ArchiveDragOut.maxEntries, wait: TimeInterval = ArchiveDragOut.fileURLWait,
         temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         folders: ArchiveDragOutFolders = .shared) {
        self.extract = extract
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
        self.wait = wait
        self.temporaryDirectory = temporaryDirectory
        self.folders = folders
    }

    /// Extractions through `reader`, captured now (an `ArchiveReading` is `Sendable`).
    convenience init(reader: any ArchiveReading, wait: TimeInterval = ArchiveDragOut.fileURLWait,
                     temporaryDirectory: URL = FileManager.default.temporaryDirectory,
                     folders: ArchiveDragOutFolders = .shared) {
        self.init(extract: { path, directory in try await reader.extract([path], to: directory, progress: nil) },
                  wait: wait, temporaryDirectory: temporaryDirectory, folders: folders)
    }

    /// Counts a row of the drag: `row` when it may come out as a file, nil for one that may not (the whole
    /// drag then stays promises only). Rows added after the drag was written stay promises only.
    func add(_ row: Row?) {
        condition.lock()
        defer { condition.unlock() }
        guard phase == .collecting else { return }
        guard let row, row.size >= 0 else {
            hasIneligibleRow = true
            return
        }
        if paths.insert(row.path).inserted { rows.append(row) }
    }

    /// Whether the row at `path` declares a file URL. The first call ends the drag's rows: within the caps
    /// the files are extracted, the main thread waiting at most the drag's wait.
    func offersFileURL(for path: String) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        if phase == .collecting { prepare() }
        return urls[path] != nil
    }

    /// The file of the row at `path`, ready since the drag was written; nil when the drag offers none. Never
    /// waits.
    func fileURL(for path: String) -> URL? {
        condition.lock()
        defer { condition.unlock() }
        return urls[path]
    }

    /// Test seam: returns once the extraction task (if one ran) has ended, its folder deleted if unused.
    func extractionEnded() async {
        await currentTask()?.value
    }

    /// The extraction task, read under the lock (synchronous: `NSCondition.lock` is unavailable in async code).
    private func currentTask() -> Task<Void, Never>? {
        condition.lock()
        defer { condition.unlock() }
        return task
    }

    /// With the lock held; returns with it held.
    private func prepare() {
        let total = rows.reduce(Int64(0)) { $0 + $1.size }
        guard !hasIneligibleRow, !rows.isEmpty, paths.count <= maxEntries, total <= maxBytes else {
            phase = .refused
            return
        }
        let folder = temporaryDirectory.appendingPathComponent(ArchiveDragOut.dragOutFolderPrefix + UUID().uuidString,
                                                               isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            phase = .refused
            return
        }
        folders.register(folder)
        phase = .extracting
        let rows = rows
        let extract = extract
        let maxBytes = maxBytes
        task = Task.detached(priority: .userInitiated) {
            let urls = await Self.extractAll(rows, into: folder, maxBytes: maxBytes, extract)
            self.finish(urls, folder: folder)
        }
        let deadline = Date(timeIntervalSinceNow: wait)
        while phase == .extracting {
            if !condition.wait(until: deadline) { break }
        }
        if phase == .extracting {
            // Out of time: promises only. The task deletes the folder when it ends (`finish`).
            phase = .refused
            task?.cancel()
        }
    }

    /// The task's end: its files when the wait is still on, else (too late, or failed) its folder goes.
    private func finish(_ result: [String: URL]?, folder: URL) {
        condition.lock()
        let isLate = phase != .extracting
        if !isLate {
            if let result {
                urls = result
                phase = .ready
            } else {
                phase = .refused
            }
            condition.broadcast()
        }
        condition.unlock()
        if isLate || result == nil { folders.remove(folder) }
    }

    /// Extracts each row into `<folder>/x<i>/`, then moves its one file to `<folder>/<i>/<name>`, made u+rw;
    /// at the end records the folder's files (`ArchiveDragOutManifest`). Nil when cancelled, when an extraction
    /// fails, when it gives anything but one regular file with one link (lstat: a symlink is not one), when
    /// the files' real sizes (not the entries' stated ones) come to more than `maxBytes`, or when the record
    /// can't be written.
    static func extractAll(_ rows: [Row], into folder: URL, maxBytes: Int64 = .max,
                           _ extract: Extract) async -> [String: URL]? {
        let fileManager = FileManager.default
        var urls: [String: URL] = [:]
        var total: Int64 = 0
        for (index, row) in rows.enumerated() {
            guard !Task.isCancelled else { return nil }
            let staging = folder.appendingPathComponent("x\(index)", isDirectory: true)
            let final = folder.appendingPathComponent("\(index)", isDirectory: true)
            do {
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
                try await extract(row.readerPath, staging)
                guard let file = singleRegularFile(in: staging) else { return nil }
                var info = stat()
                // One link only (as `ExportLinkSweep`): a hard link's other names could change the offered file.
                guard lstat(file.path, &info) == 0, info.st_nlink == 1 else { return nil }
                total += Int64(info.st_size)
                guard total <= maxBytes else { return nil }
                try fileManager.createDirectory(at: final, withIntermediateDirectories: false)
                let target = final.appendingPathComponent(row.name, isDirectory: false)
                try fileManager.moveItem(at: file, to: target)
                try fileManager.removeItem(at: staging)
                // Readable and user-writable whatever mode the archive stored (0444, 0000): receivers read it,
                // and their copies keep the mode.
                guard chmod(target.path, (info.st_mode & 0o777) | 0o600) == 0 else { return nil }
                urls[row.path] = target
            } catch {
                return nil
            }
        }
        guard !Task.isCancelled, (try? ArchiveDragOutManifest.write(into: folder)) != nil else { return nil }
        return urls
    }

    /// The one item under `directory` that is not a folder, when it is a regular file; nil otherwise.
    static func singleRegularFile(in directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        var found: [URL] = []
        for case let url as URL in enumerator {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            if (info.st_mode & S_IFMT) == S_IFDIR { continue }
            guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            found.append(url)
        }
        return found.count == 1 ? found[0] : nil
    }
}

/// What a drag's folder held when its files were extracted, written in it as `ArchiveDragOut.dragOutManifestName`:
/// each item's relative path, type, and for a file its size, modification date and inode. A file offered to
/// other apps may be edited there (dropped on TextEdit's Dock icon, saved, or autosaved): then the folder no
/// longer matches its record, and no sweep deletes it (`ArchiveDragOutFolders.mayRemove`).
struct ArchiveDragOutManifest: Codable, Equatable {
    struct Item: Codable, Equatable {
        /// `st_mode & S_IFMT`.
        let type: UInt16
        /// Zero for a folder, as are the others (a folder's own dates change with the files'; its items count).
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let inode: UInt64
    }

    /// By path relative to the folder, the record itself left out.
    let items: [String: Item]

    /// The folder's items now, `.DS_Store` files left out; nil when it can't be read.
    static func scan(_ folder: URL) -> Self? {
        guard let enumerator = FileManager.default.enumerator(atPath: folder.path) else { return nil }
        var items: [String: Item] = [:]
        // Finder's `.DS_Store` (the folder opened in Finder) is no change to the files.
        for case let path as String in enumerator
        where path != ArchiveDragOut.dragOutManifestName && (path as NSString).lastPathComponent != ".DS_Store" {
            var info = stat()
            guard lstat(folder.appendingPathComponent(path).path, &info) == 0 else { return nil }
            let type = UInt16(info.st_mode & S_IFMT)
            items[path] = type == UInt16(S_IFDIR)
                ? Item(type: type, size: 0, modifiedSeconds: 0, modifiedNanoseconds: 0, inode: 0)
                : Item(type: type, size: Int64(info.st_size), modifiedSeconds: Int(info.st_mtimespec.tv_sec),
                       modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec), inode: UInt64(info.st_ino))
        }
        return Self(items: items)
    }

    /// Records `folder`'s items now in it, read-only.
    static func write(into folder: URL) throws {
        guard let manifest = scan(folder) else { throw CocoaError(.fileReadUnknown) }
        let url = folder.appendingPathComponent(ArchiveDragOut.dragOutManifestName, isDirectory: false)
        try JSONEncoder().encode(manifest).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    }
}

/// The folders of the drags out's plain files (`ArchiveDragOutFiles`) this process made. A new drag deletes
/// those older than `ArchiveDragOut.dragOutFolderMaxAge` (`ArchiveActions.dragOutFiles`), quit deletes them all
/// (`AppDelegate.applicationWillTerminate`), and launch deletes old ones a crash left (`removeLeftovers`). None
/// of these deletes a folder whose files changed since they were extracted (`mayRemove`): it stays.
final class ArchiveDragOutFolders: @unchecked Sendable {
    static let shared = ArchiveDragOutFolders()

    private let lock = NSLock()
    private var folders: [URL: Date] = [:]

    func register(_ folder: URL, at date: Date = Date()) {
        lock.withLock { folders[folder] = date }
    }

    /// Whether a sweep may delete `folder`: its files are as extracted (`ArchiveDragOutManifest`), or it has no
    /// record (its extraction never ended, so nothing was offered from it). A record that can't be read keeps it.
    static func mayRemove(_ folder: URL) -> Bool {
        let record = folder.appendingPathComponent(ArchiveDragOut.dragOutManifestName, isDirectory: false)
        var info = stat()
        guard lstat(record.path, &info) == 0 else { return errno == ENOENT }
        guard (info.st_mode & S_IFMT) == S_IFREG, let data = try? Data(contentsOf: record),
              let recorded = try? JSONDecoder().decode(ArchiveDragOutManifest.self, from: data)
        else { return false }
        return ArchiveDragOutManifest.scan(folder) == recorded
    }

    /// Deletes `folder` when `mayRemove` allows it.
    private static func sweep(_ folder: URL) {
        guard mayRemove(folder) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes `folder` and forgets it, whatever it holds: for a drag that offered no files.
    func remove(_ folder: URL) {
        lock.withLock { folders[folder] = nil }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Deletes the folders registered more than `age` before `now` (unless changed: those are forgotten, kept).
    func removeOlder(than age: TimeInterval = ArchiveDragOut.dragOutFolderMaxAge, now: Date = Date()) {
        let old = lock.withLock {
            let old = folders.filter { now.timeIntervalSince($0.value) > age }.map(\.key)
            for folder in old { folders[folder] = nil }
            return old
        }
        for folder in old { Self.sweep(folder) }
    }

    /// Deletes every registered folder (unless changed: those are kept).
    func removeAll() {
        let all = lock.withLock {
            defer { folders = [:] }
            return Array(folders.keys)
        }
        for folder in all { Self.sweep(folder) }
    }

    /// The registered folders (a test seam).
    var registered: Set<URL> { lock.withLock { Set(folders.keys) } }

    /// At launch: deletes the `Kernir-DragOut-*` folders of `temporary` last modified more than `age` before
    /// `now` (a crashed run's; another instance's recent ones stay), unless changed (`mayRemove`). None while
    /// tests host the app in the real temporary folder (`PreviewLeftoverSweeper.refuses(parent:)`).
    static func removeLeftovers(in temporary: URL = FileManager.default.temporaryDirectory,
                                olderThan age: TimeInterval = ArchiveDragOut.dragOutFolderMaxAge,
                                now: Date = Date()) {
        guard !PreviewLeftoverSweeper.refuses(parent: temporary) else { return }
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: temporary.path) else { return }
        for name in names where name.hasPrefix(ArchiveDragOut.dragOutFolderPrefix) {
            let url = temporary.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(modified) > age else { continue }
            sweep(url)
        }
    }
}
