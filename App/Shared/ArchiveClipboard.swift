import Foundation
import KernirCore
import os

/// What Copy or Cut put on the pasteboard besides any files: which archive, which items. Pasteboard-free:
/// the platform code (Mac `ArchiveActions`, iOS `ScreenState`) writes `encoded()` under `typeIdentifier` and
/// reads it back with `decoded(_:)`. Not `Codable` itself: only `decoded(_:)` reads it, so the version check
/// and the ancestor-wins trim always apply.
struct ArchiveClipboard: Equatable, Sendable {
    enum Operation: String, Codable, Sendable { case copy, cut }

    nonisolated static let typeIdentifier = "com.kernir.app.archive-items"
    /// The name start of every folder `export` makes; a UUID follows.
    nonisolated static let exportPrefix = "Kernir-Clipboard-"
    /// The progress sheet's title while `export` runs (Copy).
    static var progressTitle: String {
        String(localized: "Copying…", table: "Shared",
               comment: "Progress sheet title while the copied archive items are extracted for the clipboard (Edit > Copy).")
    }

    private nonisolated static let version = 1
    private nonisolated static let logger = Logger(subsystem: "com.kernir.app", category: "clipboard")

    /// The document the items were copied or cut in: the platform's per-document ID (Mac
    /// `ArchiveActions.clipboardSource`, iOS `ScreenState.dragSourceID`), which outlives a model a Revert or
    /// Text Encoding replaces.
    var source: UUID
    var operation: Operation
    /// Visible paths, ancestor wins (as `MovePlanning.roots`), order kept.
    var paths: [String]

    init(source: UUID, operation: Operation, paths: [String]) {
        self.source = source
        self.operation = operation
        self.paths = MovePlanning.topLevel(paths)
    }

    /// What `encoded()` writes: the fields with a version, so a later format reads as nothing.
    private struct Payload: Codable {
        var version: Int
        var source: UUID
        var operation: Operation
        var paths: [String]
    }

    /// A binary property list carrying a version field.
    func encoded() -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let payload = Payload(version: Self.version, source: source, operation: operation, paths: paths)
        // Only UUIDs, strings and an integer: encoding can't fail.
        return (try? encoder.encode(payload)) ?? Data()
    }

    /// nil for garbage or another version.
    static func decoded(_ data: Data) -> ArchiveClipboard? {
        guard let payload = try? PropertyListDecoder().decode(Payload.self, from: data),
              payload.version == version else { return nil }
        return ArchiveClipboard(source: payload.source, operation: payload.operation, paths: payload.paths)
    }

    /// Copy's file side: extracts `paths` into a fresh `<temporary>/Kernir-Clipboard-<process>/<UUID>/`
    /// (through `ArchiveModel.extract`, so Finder metadata is left out as by Extract). The parent is this
    /// process's (`exportParent(in:)`), made and locked once and held until the process ends: another instance's
    /// sweep (`removeExports`) leaves it, and every export in it, alone. A parent that can't be made or locked
    /// fails the export, nothing left. Ancestor wins (`MovePlanning.topLevel`): an item inside another given
    /// one goes with it, not again beside it. Case-only twins keep both without asking (the folder is fresh,
    /// so they are its only conflicts), and folder twins that extract as one folder go once, as iOS Share's
    /// copies (`ScreenState.shareURLs`). Cancel or failure removes the folder (a cancel throws
    /// `ArchiveError.cancelled` or `CancellationError`: the platform parts treat both as a silent cancel).
    /// The copies are `ExportLinkSweep`ed before they are returned: an item that is a symlink is left out, and
    /// links inside that lead out of their item are removed; when every item was a symlink, the export throws
    /// `ExportedLinksError` and no folder is left. A sweep that can't finish fails the export the same way.
    /// Returns the folder and the copies, in order; no paths, or only hidden metadata: no copies, and no
    /// folder is left.
    @MainActor static func export(_ paths: [String], from model: ArchiveModel,
                                  in temporary: URL = FileManager.default.temporaryDirectory,
                                  progress: ArchiveProgressHandler?) async throws -> (folder: URL, urls: [URL]) {
        let paths = MovePlanning.topLevel(paths)
        let name = UUID().uuidString
        let folder = exportParent(in: temporary).appendingPathComponent(name, isDirectory: true)
        guard !paths.isEmpty else { return (folder, []) }
        let parent = try holdParent(in: temporary)
        // Relative to the held parent: nothing on the way is followed.
        guard mkdirat(parent, name, 0o755) == 0 else { throw posixError(errno) }
        do {
            let keepBoth = model.extractionConflicts(paths, in: folder).map { ($0, ExtractionConflictResolution.keepBoth) }
            let urls = try await model.extract(paths, to: folder, resolutions: Dictionary(keepBoth) { $1 },
                                               progress: progress)
            var seen = Set<String>()
            let unique = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
            // Before any app gets a URL: no link out of an item (`ExportLinkSweep`), off the main actor.
            let kept = try await Task.detached(priority: Task.currentPriority) {
                try ExportLinkSweep.sanitize(unique)
            }.value
            if kept.isEmpty, !unique.isEmpty { throw ExportedLinksError(names: unique.map(\.lastPathComponent)) }
            if kept.isEmpty { removeExport(folder) }
            return (folder, kept)
        } catch {
            removeExport(folder)
            throw error
        }
    }

    /// This process's parent of its export folders in `temporary`: `Kernir-Clipboard-<process UUID>`.
    nonisolated static func exportParent(in temporary: URL) -> URL {
        temporary.appendingPathComponent("\(exportPrefix)\(processID.uuidString)", isDirectory: true)
    }

    /// Sweeps `temporary`'s `Kernir-Clipboard-<UUID>` folders. This process's held parent stays, emptied of
    /// its export folders except `keeping` (by name). Any other (another instance's parent, or a flat export
    /// folder of an older Lutik) goes only when no one holds its flock(2), and is locked while it goes so it
    /// can't be claimed: the sweep of a second instance (`open -n`) or of a test host never breaks the copies
    /// a running Lutik's pending additions read at save. lstat only: a symlink or a file with such a name is
    /// left alone, and nothing is followed. A running export of this process goes too: the platform parts run
    /// one Copy export at a time (CB-iOS gates it in `perform`, CB-Mac with a copy-in-flight flag) and call this
    /// only after the new export has returned.
    nonisolated static func removeExports(in temporary: URL, keeping: URL?) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: temporary.path) else { return }
        for name in names where name.hasPrefix(exportPrefix) {
            guard UUID(uuidString: String(name.dropFirst(exportPrefix.count))) != nil else { continue }
            let url = temporary.appendingPathComponent(name, isDirectory: true)
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else { continue }
            if heldParent(matching: status) != nil {
                let exports = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                for export in exports where export != keeping?.lastPathComponent {
                    removeExport(url.appendingPathComponent(export, isDirectory: true))
                }
                continue
            }
            // Someone else's: only when no one holds it, and locked while deleting so it can't be claimed.
            let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_dev == status.st_dev, opened.st_ino == status.st_ino,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
            removeExport(url)
        }
    }

    /// `removeExports(in:keeping: nil)`, then this process's parent too, its lock released (Mac quit). A later
    /// export makes and locks a new one.
    nonisolated static func removeAllExports(in temporary: URL) {
        removeExports(in: temporary, keeping: nil)
        removeExportParent(in: temporary)
    }

    /// Removes this process's parent in `temporary`, exports and all, and releases its lock; nothing when this
    /// process holds none there. Nothing else in `temporary` is touched.
    nonisolated static func removeExportParent(in temporary: URL) {
        let parent = exportParent(in: temporary)
        var status = stat()
        guard lstat(parent.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              let fd = heldParent(matching: status) else { return }
        removeExport(parent)
        parentLocks.withLock { $0.removeAll { $0 == fd } }
        close(fd)
    }

    /// The Mac quit sweep: `removeExportParent(in:)` that stops at `deadline`, so a huge tree never holds up
    /// quit. Only this process's parent: another instance's, held or left by a crash, stays (its exports may be
    /// pasted, read at that instance's save; the next launch's `removeExports` takes an unheld one). Depth
    /// first, nothing followed; a read-only folder from the archive is made writable to empty it. True once the
    /// parent is gone (its lock released) or this process holds none there; false when time ran out or an
    /// entry can't go: what is left stays, still locked until the process ends, then the next launch sweeps it.
    @discardableResult
    nonisolated static func removeExportParent(in temporary: URL, before deadline: ContinuousClock.Instant) -> Bool {
        let parent = exportParent(in: temporary)
        var status = stat()
        guard lstat(parent.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              let fd = heldParent(matching: status) else { return true }
        let directory = open(temporary.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { return false }
        defer { close(directory) }
        guard removeTree(parent.lastPathComponent, in: directory, before: deadline) else { return false }
        parentLocks.withLock { $0.removeAll { $0 == fd } }
        close(fd)
        return true
    }

    /// Removes `name` in the folder `directory`, depth first, relative to its parent's descriptor so nothing on
    /// the way is followed (a symlink goes as a link). False when `deadline` passed or an entry can't go.
    private nonisolated static func removeTree(_ name: String, in directory: Int32,
                                               before deadline: ContinuousClock.Instant) -> Bool {
        guard ContinuousClock.now < deadline else { return false }
        if unlinkat(directory, name, 0) == 0 || errno == ENOENT { return true }
        // A folder (unlink says EPERM on macOS): empty it first.
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = openat(directory, name, flags)
        if fd < 0, errno == EACCES {
            // A folder its owner can't read or search (an archive's 0o000 or 0o300): made 0o700 to be emptied
            // (it can't be opened first: O_SEARCH needs the search right it lacks). Only what was a folder when
            // looked at, no link followed. Stat and chmod aren't atomic: an entry swapped in between (only
            // something with write access to this process's own export folder could) is caught right after the
            // chmod, as it is no longer that folder or no folder at all: it gets the folder's old mode back and
            // nothing more is done with it, the removal fails. Not guaranteed: that a swapped-in file's own mode
            // is never changed for that moment.
            var before = stat()
            if fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0, before.st_mode & S_IFMT == S_IFDIR,
               fchmodat(directory, name, S_IRWXU, AT_SYMLINK_NOFOLLOW) == 0 {
                var after = stat()
                guard fstatat(directory, name, &after, AT_SYMLINK_NOFOLLOW) == 0, after.st_mode & S_IFMT == S_IFDIR,
                      after.st_dev == before.st_dev, after.st_ino == before.st_ino else {
                    _ = fchmodat(directory, name, before.st_mode & ~S_IFMT, AT_SYMLINK_NOFOLLOW)
                    return false
                }
                fd = openat(directory, name, flags)
            }
        }
        guard fd >= 0 else { return false }
        var status = stat()
        if fstat(fd, &status) == 0, status.st_mode & S_IRWXU != S_IRWXU {
            _ = fchmod(fd, status.st_mode | S_IRWXU)
        }
        guard let folder = fdopendir(fd) else {
            close(fd)
            return false
        }
        // Closes `fd` too.
        defer { closedir(folder) }
        var names: [String] = []
        while let entry = readdir(folder) {
            // A huge folder's listing stops at the deadline too.
            guard ContinuousClock.now < deadline else { return false }
            let child = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if child != ".", child != ".." { names.append(child) }
        }
        for child in names {
            guard removeTree(child, in: fd, before: deadline) else { return false }
        }
        return unlinkat(directory, name, AT_REMOVEDIR) == 0 || errno == ENOENT
    }

    /// Removes one export folder (or a whole parent); a missing one is no error.
    nonisolated static func removeExport(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            logger.error("Cannot remove clipboard copies: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
    }

    // MARK: - The export parent's lock

    /// Names this process's export parent (`exportParent(in:)`).
    private nonisolated static let processID = UUID()

    /// This process's flock(2)s on its export parents (one per temporary folder exported to): a descriptor on
    /// the folder itself (no lock file), held until `removeAllExports` or the process ends. One descriptor per
    /// parent, however many exports.
    private nonisolated static let parentLocks = OSAllocatedUnfairLock<[Int32]>(initialState: [])

    /// The held descriptor of `temporary`'s export parent: made and locked on first use, then reused.
    private nonisolated static func holdParent(in temporary: URL) throws -> Int32 {
        let parent = exportParent(in: temporary)
        var status = stat()
        if lstat(parent.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
           let fd = heldParent(matching: status) {
            return fd
        }
        let created = mkdir(parent.path, 0o755) == 0
        guard created || errno == EEXIST else { throw posixError(errno) }
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var opened = stat()
        var now = stat()
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0, fstat(fd, &opened) == 0,
              lstat(parent.path, &now) == 0, opened.st_dev == now.st_dev, opened.st_ino == now.st_ino else {
            let code = errno
            if fd >= 0 { close(fd) }
            // Only an empty folder this call made: never what another holder or a sweep has there.
            if created { rmdir(parent.path) }
            logger.error("Cannot lock clipboard copies: errno \(code)")
            throw posixError(code)
        }
        parentLocks.withLock { $0.append(fd) }
        return fd
    }

    /// The held descriptor on the directory `status` describes (an lstat), if this process holds one.
    private nonisolated static func heldParent(matching status: stat) -> Int32? {
        parentLocks.withLock { fds in
            fds.first { fd in
                var held = stat()
                return fstat(fd, &held) == 0 && held.st_dev == status.st_dev && held.st_ino == status.st_ino
            }
        }
    }

    private nonisolated static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}

/// Why a paste is refused.
enum PasteRefusal: Error, Equatable, Sendable {
    /// Items cut in another archive (or in a previous run): never a silent copy.
    case cutElsewhere
    /// Every cut item is gone from this archive.
    case gone
    /// Copied items of this archive already in the target folder (their paths): no Keep Both in Add.
    case sameFolder([String])
    case move(MoveProblem)
}

/// What a paste does: add the pasteboard's files to a folder, move the cut items there, or refuse.
enum PastePlan: Equatable, Sendable {
    case add(into: String)
    /// [] = every item is there already: nothing to do.
    case move([String], into: String)
    case refuse(PasteRefusal)
}

/// The paste rules, pure.
enum ArchivePaste {
    /// The alert title for a `PasteRefusal`.
    static var refusalTitle: String {
        String(localized: "Couldn't Paste", table: "Shared",
               comment: "Alert title when pasting into the archive is refused (Edit > Paste).")
    }

    /// nil = nothing to paste. `here` is the pasting document's clipboard ID. A Lutik Cut moves within the
    /// archive it was cut in and is refused anywhere else; cut paths missing from `exists` are dropped (some
    /// left: move those). A Lutik Copy (with its files) adds the files, refused when a copied item of this
    /// archive is already in `folder`. Files alone add. Paths NFC-compared.
    static func plan(_ clipboard: ArchiveClipboard?, hasFiles: Bool, here: UUID, into folder: String,
                     exists: (String) -> Bool) -> PastePlan? {
        guard let clipboard, !clipboard.paths.isEmpty else { return hasFiles ? .add(into: folder) : nil }
        switch clipboard.operation {
        case .cut:
            guard clipboard.source == here else { return .refuse(.cutElsewhere) }
            let present = clipboard.paths.filter(exists)
            guard !present.isEmpty else { return .refuse(.gone) }
            switch MovePlanning.roots(present, into: folder) {
            case .success(let roots): return .move(roots, into: folder)
            case .failure(let problem): return .refuse(.move(problem))
            }
        case .copy:
            guard hasFiles else { return nil }
            if clipboard.source == here {
                let target = nfc(folder)
                let inFolder = clipboard.paths.filter { exists($0) && ArchiveEntry.parentPath(of: nfc($0)) == target }
                if !inFolder.isEmpty { return .refuse(.sameFolder(inFolder)) }
            }
            return .add(into: folder)
        }
    }

    /// Mac target: the one selected folder (`destinationForAdd`), or its parent when that very folder is on
    /// the clipboard from this document (`here`, the pasting document's clipboard ID). A folder of the same
    /// name copied or cut in another archive is no reason to go up. A Copy of the selected folder pasted with
    /// it still selected so goes up into the folder it came from and `plan` refuses it as `.sameFolder`.
    static func destination(selectedFolder: String, clipboard: ArchiveClipboard?, here: UUID) -> String {
        let selected = nfc(selectedFolder)
        guard !selected.isEmpty, let clipboard, clipboard.source == here,
              clipboard.paths.contains(where: { nfc($0) == selected }) else {
            return selectedFolder
        }
        return ArchiveEntry.parentPath(of: selectedFolder)
    }

    /// The alert message for a refused paste (title `refusalTitle`).
    static func message(for refusal: PasteRefusal) -> String {
        switch refusal {
        case .cutElsewhere:
            String(localized: "Items cut in another archive can’t be pasted here. Copy them instead.", table: "Shared",
                   comment: "Alert message when items cut (Edit > Cut) in another archive, or before Lutik was last quit, are pasted into this one.")
        case .gone:
            String(localized: "The cut items are no longer in this archive.", table: "Shared",
                   comment: "Alert message when every item cut (Edit > Cut) was deleted or renamed before the paste.")
        case .sameFolder(let paths) where paths.count == 1:
            String(localized: "“\(ArchiveEntry.name(of: paths[0]))” is already in this folder.", table: "Shared",
                   comment: "Alert message when a copied archive item is pasted into the folder it is already in. %@ = the item's name.")
        case .sameFolder(let paths):
            String(localized: "\(paths.count) of the copied items are already in this folder.", table: "Shared",
                   comment: "Alert message when several copied archive items are pasted into the folder they are already in. %lld = how many (always 2 or more).")
        case .move(let problem):
            MovePlanning.message(for: problem)
        }
    }

    private static func nfc(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
    }
}
