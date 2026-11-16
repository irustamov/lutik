import Foundation

/// The files one archive window's preview shows in place of extracted files (`PreviewStrategy`):
/// a root folder of the window's own (`Kernir-Preview-<UUID>`), a folder per render
/// (a batch) in it, and a UUID folder per stand-in in that, since two entries in different archive
/// folders can share a name. Share's copies (`shareCopy`) live in the same root, under `share/`.
///
/// A batch is live from `beginBatch()` until a newer one is installed, it is discarded, or
/// `removeAll()` runs. Only a live batch gets new files, so a render that ends late (superseded,
/// or after the panel closed) neither writes into a folder already deleted nor re-creates the
/// root. The installed batch is the one the preview shows; it stays until the next one is
/// installed or `removeAll()`. `close()` (the window closed) deletes the whole root, Share's
/// copies too. Thread-safe: stand-ins are made off the main actor.
///
/// While the root exists the store holds a `PreviewRootLock` on it, so the launch sweep of a
/// second Lutik (`open -n`) leaves it alone; the lock goes when the root is deleted, and is taken
/// again when the root is made again.
final class PreviewStandInStore: @unchecked Sendable {
    /// The start of every root folder's name: the one the launch sweep looks for.
    static let prefix = PreviewLeftoverSweeper.prefix
    /// The root's folder for Share's copies. Never a batch's name (those are UUIDs).
    static let shareFolderName = "share"

    /// One render's stand-ins.
    struct Batch: Hashable, Sendable {
        let id = UUID()
    }

    /// This window's folder; created with the first stand-in.
    let root: URL
    private let lock = NSLock()
    /// Batches that may still get files.
    private var live: Set<UUID> = []
    /// The batch the preview shows.
    private var installed: UUID?
    /// The window closed (`close()`): nothing is written any more.
    private var isClosed = false
    /// Held while the root exists (`makeRoot()`), so no other instance's launch sweep takes it.
    private var rootLock: PreviewRootLock?
    #if DEBUG
    /// Tests only: runs after a stand-in's file (or a Share copy) is written and before the batch
    /// (or `close()`) is checked again, so a test can end the batch, or close, at exactly that point.
    private let afterWrite: (@Sendable (URL) -> Void)?
    /// Tests only: runs after the root is made and before it is locked, so a test can take it away
    /// (as another instance's launch sweep might) at exactly that point. Runs with the lock held.
    private let beforeRootLock: (@Sendable (URL) -> Void)?

    init(parent: URL = FileManager.default.temporaryDirectory, afterWrite: (@Sendable (URL) -> Void)? = nil,
         beforeRootLock: (@Sendable (URL) -> Void)? = nil) {
        root = parent.appendingPathComponent(Self.prefix + UUID().uuidString, isDirectory: true)
        self.afterWrite = afterWrite
        self.beforeRootLock = beforeRootLock
    }
    #else
    init(parent: URL = FileManager.default.temporaryDirectory) {
        root = parent.appendingPathComponent(Self.prefix + UUID().uuidString, isDirectory: true)
    }
    #endif

    /// The folder `batch`'s stand-ins go in.
    func folder(of batch: Batch) -> URL {
        root.appendingPathComponent(batch.id.uuidString, isDirectory: true)
    }

    /// Whether the store holds the lock on its root now; for tests.
    var holdsRootLock: Bool {
        lock.withLock { rootLock?.isHolding(root) == true }
    }

    /// How many times `makeRoot` makes and locks the root before it gives up.
    private static let rootLockAttempts = 3

    /// Makes the root if it isn't there, and locks it unless the lock already holds this very
    /// folder (one deleted and made again is a new folder). Called with the lock held, before
    /// anything is made inside the root. Returns only with the root locked: if the lock can't be
    /// taken (another instance's launch sweep took the new, empty root before it was locked, say),
    /// it makes the root again and retries, then throws `CocoaError(.fileLocking)`, so nothing is
    /// ever written into a root a sweep could take.
    private func makeRoot() throws {
        for _ in 0..<Self.rootLockAttempts {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if rootLock?.isHolding(root) == true { return }
            dropRootLock()
            #if DEBUG
            beforeRootLock?(root)
            #endif
            rootLock = PreviewRootLock(holding: root)
            if rootLock?.isHolding(root) == true { return }
        }
        dropRootLock()
        // An empty root made here goes; anything else is the launch sweep's.
        _ = rmdir(root.path)
        throw CocoaError(.fileLocking)
    }

    /// The root is gone (or about to be): its lock goes too. Called with the lock held.
    private func dropRootLock() {
        rootLock?.unlock()
        rootLock = nil
    }

    /// Starts a batch for a new render; after `close()` one that gets no files.
    func beginBatch() -> Batch {
        let batch = Batch()
        lock.withLock {
            if !isClosed { live.insert(batch.id) }
        }
        return batch
    }

    /// A new path for a stand-in named `name`, in a folder of its own in `batch`. Throws
    /// `CancellationError` when the calling task is cancelled or `batch` is no longer live: then
    /// nothing is created, not even the root.
    func newFile(named name: String, in batch: Batch) throws -> URL {
        try Task.checkCancellation()
        return try lock.withLock {
            guard live.contains(batch.id) else { throw CancellationError() }
            try makeRoot()
            let folder = folder(of: batch).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent(name, isDirectory: false)
        }
    }

    /// A `.txt` copy of the file at `url` (a clone on APFS; never read into memory), named after
    /// it (`PreviewStrategy.standInName`).
    func textCopy(of url: URL, in batch: Batch) throws -> URL {
        let name = PreviewStrategy.standInName(for: url.lastPathComponent, pathExtension: "txt")
        let target = try newFile(named: name, in: batch)
        return try finish(target, in: batch) {
            // Fails, rather than re-creating the folder, if the batch was removed meanwhile.
            try FileManager.default.copyItem(at: url, to: target)
        }
    }

    /// `data` as a new stand-in named `name`.
    func write(_ data: Data, named name: String, in batch: Batch) throws -> URL {
        let target = try newFile(named: name, in: batch)
        return try finish(target, in: batch) {
            // Fails, rather than re-creating the folder, if the batch was removed meanwhile.
            try data.write(to: target, options: .withoutOverwriting)
        }
    }

    /// Writes `target` (with `make`, outside the lock: a copy or a page can take a while), then
    /// checks that `batch` is still live. If it ended meanwhile, the sweep that ended it may have
    /// run while the file was being written and failed on a folder that wasn't empty yet: what
    /// it left is deleted here and the stand-in is `CancellationError`, whether or not the write
    /// itself failed.
    private func finish(_ target: URL, in batch: Batch, _ make: () throws -> Void) throws -> URL {
        var failure: (any Error)?
        do { try make() } catch { failure = error }
        #if DEBUG
        afterWrite?(target)
        #endif
        try lock.withLock {
            guard live.contains(batch.id) else {
                sweep(batch)
                throw CancellationError()
            }
        }
        if let failure { throw failure }
        return target
    }

    /// Deletes what an ended `batch` may have left. With no batch live (the preview closed) that
    /// is every stand-in, as `removeAll()` or `close()` meant; else `batch`'s folder, as `install`
    /// or `discard` meant. Called with the lock held.
    private func sweep(_ batch: Batch) {
        if live.isEmpty {
            removeStandIns()
        } else {
            try? FileManager.default.removeItem(at: folder(of: batch))
        }
    }

    /// Deletes every batch's folder, then the root if nothing else is in it: Share's copies stay
    /// until `close()`. Called with the lock held.
    private func removeStandIns() {
        let manager = FileManager.default
        let children = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for child in children where child.lastPathComponent != Self.shareFolderName {
            try? manager.removeItem(at: child)
        }
        // Only an empty folder: never Share's copies. With the root gone, so is its lock.
        if rmdir(root.path) == 0 || errno == ENOENT { dropRootLock() }
    }

    /// The preview now shows `batch`: every other batch is deleted and gets no more files. False
    /// (and nothing deleted) if `batch` is no longer live.
    @discardableResult
    func install(_ batch: Batch) -> Bool {
        lock.withLock {
            guard live.contains(batch.id) else { return false }
            for other in live where other != batch.id {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(other.uuidString, isDirectory: true))
            }
            live = [batch.id]
            installed = batch.id
            return true
        }
    }

    /// A render that never reached the preview: `batch` is deleted and gets no more files. The
    /// installed batch stays, since the preview still shows it.
    func discard(_ batch: Batch) {
        lock.withLock {
            guard batch.id != installed else { return }
            live.remove(batch.id)
            try? FileManager.default.removeItem(at: folder(of: batch))
        }
    }

    /// The preview closed: every stand-in is deleted, and the root unless Share's copies are in
    /// it; no batch begun before this gets another file.
    func removeAll() {
        lock.withLock {
            live = []
            installed = nil
            removeStandIns()
        }
    }

    /// The archive window closed: the whole root is deleted, Share's copies too, and nothing is
    /// written into it any more. A crash leaves the root to the launch sweep.
    func close() {
        lock.withLock {
            live = []
            installed = nil
            isClosed = true
            try? FileManager.default.removeItem(at: root)
            dropRootLock()
        }
    }

    // MARK: - Share

    /// A copy of the file (or folder) at `url` to hand to a share service, named `name`, the
    /// entry's real name: `<root>/share/<UUID>/<name>`, a clone on APFS. The reader's cache file
    /// goes on a save, while AirDrop may still be reading, so Share never hands that out. The copy
    /// stays until `close()`, after the preview closes too. Throws `CancellationError` once the
    /// window closed; a failed copy leaves nothing.
    func shareCopy(of url: URL, named name: String) throws -> URL {
        let manager = FileManager.default
        let folder = try lock.withLock {
            guard !isClosed else { throw CancellationError() }
            try makeRoot()
            let folder = root.appendingPathComponent(Self.shareFolderName, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            // With the lock held: `removeStandIns` can't take the root away half-way.
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }
        let target = folder.appendingPathComponent(Self.shareName(name, fallback: url.lastPathComponent))
        do {
            // Fails, rather than re-creating the folder, if the window closed meanwhile.
            try manager.copyItem(at: url, to: target)
            #if DEBUG
            afterWrite?(target)
            #endif
        } catch {
            try? manager.removeItem(at: folder)
            _ = removeRootIfClosed()
            throw error
        }
        if removeRootIfClosed() { throw CancellationError() }
        return target
    }

    /// After `close()`: deletes the whole root again, as `close()` meant, since a Share copy that
    /// raced it may have left its folder (and so `share/` and the root) behind, unlocked. True if the store is closed.
    private func removeRootIfClosed() -> Bool {
        lock.withLock {
            guard isClosed else { return false }
            try? FileManager.default.removeItem(at: root)
            return true
        }
    }

    /// `name` as a file name in a share folder: one path component, never "." or "..".
    /// Otherwise `fallback`, or "Shared Item" if that isn't one either.
    static func shareName(_ name: String, fallback: String) -> String {
        func isFileName(_ name: String) -> Bool {
            !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
        }
        if isFileName(name) { return name }
        return isFileName(fallback) ? fallback : "Shared Item"
    }
}
