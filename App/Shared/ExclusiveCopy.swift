import Foundation
import os

/// Copies an item to a path this call makes itself, never over or into anything already there:
/// drag-out's move to another volume (`ArchiveDragOut.place`). The tree is walked through folder
/// descriptors opened O_NOFOLLOW, never by path below the top, so a symlink swapped in at the target
/// or anywhere in the copy is never written through, and a symlink is copied as a link, never
/// followed. The top folder is the copy's own only if, by its open descriptor, it is this user's,
/// 0700 (where the volume keeps modes) and empty, so a folder a racer swaps in after the mkdir is
/// refused, never filled. Each folder is made 0700 and gets its own modes, flags, dates, extended
/// attributes and ACL only once everything in it is copied, so a read-only folder (an archive's
/// 0555) fills too. The setuid, setgid and sticky bits are never copied (`specialBits`): each
/// item made keeps `mode & 0o777`.
/// A failure or a cancel removes what the copy made, and only that: each item it made while it is
/// still that item (device and inode), never anything else put in its folders. When that removal
/// fails too, the error is `PartialCopyError`.
/// Descriptors: two per folder level (the source's and the copy's) stay open while the copy works
/// below that level, so a tree deeper than about 120 folders fails with EMFILE under a GUI app's
/// soft limit of 256 (the limit is never raised); the removal needs one per level, so it still
/// leaves nothing.
/// Across volumes some items fail that an exclusive rename on one volume would place: a FIFO
/// (ENOTSUP; the engine stages one from an archive's FIFO entry, never a device node, which needs
/// root), and a symlink on a volume without symlinks (FAT, exFAT: symlinkat fails).
enum ExclusiveCopy {
    typealias Identity = ExtractionFileSystem.Identity
    private static let logger = Logger(subsystem: "com.kernir.app", category: "dragOut")

    /// Test seams; the app never sets them.
    struct Seams {
        /// Runs right after the copy made `target` (the top folder's mkdir, or the top file's
        /// O_EXCL open), before it opens or checks what it made.
        var afterMakingTarget: (URL) -> Void = { _ in }
    }

    /// A copy that failed (`underlying`) and whose removal failed too: part of it is left at `url`.
    struct PartialCopyError: LocalizedError {
        let url: URL
        let underlying: any Error

        var errorDescription: String? {
            let name = url.lastPathComponent
            // The folder as Finder names it (localized, extension hidden as the user set).
            let folder = FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
            return String(localized: "A partial copy of “\(name)” was left in “\(folder)”.", table: "Shared")
        }

        /// The real cause (a full disk, say): what `NSAlert(error:)` shows under the title. None for
        /// a cancel, which is no cause to show.
        var recoverySuggestion: String? {
            ArchiveDragOut.isCancellation(underlying) ? nil : underlying.localizedDescription
        }
    }

    /// Copies `source` (a folder, a file or a symlink; anything else is ENOTSUP) to `target`.
    /// Something already at `target` is Cocoa's file-exists error, as is a top folder that isn't
    /// the copy's own once made (swapped, filled or opened up by someone else: left as it is).
    /// `isCancelled` is asked before each item and, within a file, after each chunk written; a yes
    /// stops the copy with `CancellationError`. With `unlocksSource` (the source is the caller's
    /// own staging, which it may change), an item of this user's that can't be read (a file
    /// without u+r, a folder without u+rx) gets those bits for the copy, and its own mode back
    /// after, on both sides. Any other failure throws its `POSIXError`; `PartialCopyError` when
    /// the copy's removal failed as well.
    static func copy(_ source: URL, to target: URL, unlocksSource: Bool = false, seams: Seams = Seams(),
                     isCancelled: () -> Bool = { false }) throws {
        if isCancelled() { throw CancellationError() }
        var status = stat()
        guard lstat(source.path, &status) == 0 else { throw posixError(errno) }
        switch status.st_mode & S_IFMT {
        case S_IFDIR:
            let (input, restore) = try openSource(source.path, in: AT_FDCWD, mode: status.st_mode,
                                                  owner: status.st_uid, unlocking: unlocksSource)
            defer {
                if let restore { _ = fchmod(input, restore) }
                close(input)
            }
            let (output, own) = try makeTopFolder(target, seams: seams)
            defer { close(output) }
            let made = MadeFolder()
            do {
                try copyContents(of: input, into: output, made: made, unlocking: unlocksSource,
                                 isCancelled: isCancelled)
                try check(fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_METADATA)))
                if let restore { try check(fchmod(output, restore)) }
                try dropSpecialBits(output)
            } catch {
                _ = fchmod(output, S_IRWXU)
                let removed = remove(made, in: output) && removeFolder(target, ifStill: own)
                throw failure(error, removed: removed, at: target)
            }
        case S_IFREG:
            let (input, restore) = try openSource(source.path, in: AT_FDCWD, mode: status.st_mode,
                                                  owner: status.st_uid, unlocking: unlocksSource)
            defer {
                if let restore { _ = fchmod(input, restore) }
                close(input)
            }
            let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw creationError(errno, target) }
            defer { close(output) }
            // The file O_EXCL made, by its own descriptor (the path could be a racer's by now).
            let own = identity(of: output)
            seams.afterMakingTarget(target)
            do {
                try copyFile(input, to: output, isCancelled: isCancelled)
                if let restore { try check(fchmod(output, restore)) }
                try dropSpecialBits(output)
            } catch {
                let removed = own.map { removeFile(target, ifStill: $0) } ?? false
                throw failure(error, removed: removed, at: target)
            }
        case S_IFLNK:
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            guard symlink(destination, target.path) == 0 else { throw creationError(errno, target) }
        default:
            throw POSIXError(.ENOTSUP)
        }
    }

    /// Makes the folder `target` (0700) and opens it O_NOFOLLOW; returns the descriptor and the
    /// folder's identity, both from that descriptor (fstat), never from the path. It is the copy's
    /// own only if it is this user's, 0700 and empty: anything else (a folder swapped in after the
    /// mkdir, or something put in it) is Cocoa's file-exists error, left as it is. The mode counts
    /// only on a volume that keeps it (`keepsModes`): FAT, exFAT and SMB show one they make up,
    /// the same for every folder, so there it tells nothing and would refuse every drop. When the
    /// open or its fstat fails, the folder mkdir made is removed again while lstat still finds it
    /// there, this user's, so a failed drop never leaves an empty folder in the way of the next.
    private static func makeTopFolder(_ target: URL, seams: Seams) throws -> (descriptor: Int32, identity: Identity) {
        guard mkdir(target.path, 0o700) == 0 else { throw creationError(errno, target) }
        let made = ownedIdentity(at: target.path)  // only to take back a folder the open can't use
        seams.afterMakingTarget(target)
        let output = open(target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard output >= 0 else {
            let error = creationError(errno, target)
            throw failure(error, removed: made.map { removeFolder(target, ifStill: $0) } ?? false, at: target)
        }
        var status = stat()
        guard fstat(output, &status) == 0 else {
            let error = posixError(errno)
            close(output)
            throw failure(error, removed: made.map { removeFolder(target, ifStill: $0) } ?? false, at: target)
        }
        let entries = try? names(in: output)
        guard status.st_uid == geteuid(), status.st_mode & 0o7777 == 0o700 || !keepsModes(output),
              entries?.isEmpty == true else {
            close(output)
            throw fileExists(target)
        }
        return (output, Identity(device: status.st_dev, inode: status.st_ino))
    }

    /// The volume of `descriptor` keeps the modes it is given (APFS, HFS+), so a folder's mode says
    /// who made it; FAT, exFAT, SMB and other volumes show modes they make up.
    private static func keepsModes(_ descriptor: Int32) -> Bool {
        var volume = statfs()
        guard fstatfs(descriptor, &volume) == 0 else { return true }
        let type = withUnsafeBytes(of: volume.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return type == "apfs" || type == "hfs"
    }

    /// What the copy made in one folder, oldest first: each item's name and identity, and for a
    /// folder what the copy made in it. A failed copy removes exactly these (`remove(_:in:)`).
    private final class MadeFolder {
        var entries: [(name: String, identity: Identity, folder: MadeFolder?)] = []
    }

    /// Copies everything in the folder open at `input` into the empty one open at `output`, by name
    /// relative to both, never following a symlink, noting each item it makes in `made`; each
    /// subfolder gets its metadata after its items.
    private static func copyContents(of input: Int32, into output: Int32, made: MadeFolder, unlocking: Bool,
                                     isCancelled: () -> Bool) throws {
        for name in try names(in: input) {
            if isCancelled() { throw CancellationError() }
            var status = stat()
            guard fstatat(input, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(errno) }
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                let (from, restore) = try openSource(name, in: input, mode: status.st_mode, owner: status.st_uid,
                                                     unlocking: unlocking)
                defer {
                    if let restore { _ = fchmod(from, restore) }
                    close(from)
                }
                guard mkdirat(output, name, 0o700) == 0 else { throw posixError(errno) }
                let inner = MadeFolder()
                try note(name, in: output, inner: inner, to: made)
                let to = openat(output, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard to >= 0 else { throw posixError(errno) }
                defer { close(to) }
                try copyContents(of: from, into: to, made: inner, unlocking: unlocking, isCancelled: isCancelled)
                try check(fcopyfile(from, to, nil, copyfile_flags_t(COPYFILE_METADATA)))
                if let restore { try check(fchmod(to, restore)) }
                try dropSpecialBits(to)
            case S_IFREG:
                let (from, restore) = try openSource(name, in: input, mode: status.st_mode, owner: status.st_uid,
                                                     unlocking: unlocking)
                defer {
                    if let restore { _ = fchmod(from, restore) }
                    close(from)
                }
                let to = openat(output, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard to >= 0 else { throw posixError(errno) }
                defer { close(to) }
                try note(name, in: output, inner: nil, to: made)
                try copyFile(from, to: to, isCancelled: isCancelled)
                if let restore { try check(fchmod(to, restore)) }
                try dropSpecialBits(to)
            case S_IFLNK:
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let length = readlinkat(input, name, &buffer, buffer.count - 1)
                guard length >= 0 else { throw posixError(errno) }
                buffer[length] = 0
                guard symlinkat(buffer, output, name) == 0 else { throw posixError(errno) }
                try note(name, in: output, inner: nil, to: made)
            default:
                throw POSIXError(.ENOTSUP)
            }
        }
    }

    /// Notes in `made` the item the copy just made at `name` in the folder open at `folder` (by
    /// lstat), with `inner`, what it will make in it when it is a folder.
    private static func note(_ name: String, in folder: Int32, inner: MadeFolder?, to made: MadeFolder) throws {
        var status = stat()
        guard fstatat(folder, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(errno) }
        made.entries.append((name: name, identity: Identity(device: status.st_dev, inode: status.st_ino),
                             folder: inner))
    }

    /// Opens the source item `name` (a path when `folder` is AT_FDCWD) whose lstat mode and owner are
    /// `mode` and `owner`, read-only, O_NOFOLLOW: a folder to list, a file to read. With `unlocking`,
    /// an item of this user's lacking u+r (a file) or u+rx (a folder) gets them first; `restore` is
    /// then its own mode, which the caller puts back on the source when done and gives the copy
    /// after its metadata copy (fcopyfile reads extended attributes through the descriptor, which
    /// the item's own mode would refuse: EACCES).
    private static func openSource(_ name: String, in folder: Int32, mode: mode_t, owner: uid_t,
                                   unlocking: Bool) throws -> (descriptor: Int32, restore: mode_t?) {
        let isFolder = mode & S_IFMT == S_IFDIR
        let needed: mode_t = isFolder ? S_IRUSR | S_IXUSR : S_IRUSR
        let own: mode_t = mode & 0o7777
        var restore: mode_t?
        if unlocking, own & needed != needed, owner == geteuid() {
            guard fchmodat(folder, name, own | needed, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixError(errno) }
            restore = own
        }
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (isFolder ? O_DIRECTORY : 0))
        guard descriptor >= 0 else {
            let code = errno
            if let restore { _ = fchmodat(folder, name, restore, AT_SYMLINK_NOFOLLOW) }
            throw posixError(code)
        }
        return (descriptor, restore)
    }

    /// What fcopyfile's status callback reaches through its context: the cancel question, and what
    /// the copy saw.
    private final class CopyStatus {
        let isCancelled: () -> Bool
        var cancelled = false
        var errorCode: Int32 = 0

        init(_ isCancelled: @escaping () -> Bool) {
            self.isCancelled = isCancelled
        }

        /// The callback's answer at `stage`: quit on an error, keeping its errno (continue would
        /// retry a failed write for ever, or skip the failure), and once cancelled; else continue.
        func answer(stage: Int32) -> Int32 {
            if stage == COPYFILE_ERR {
                if errorCode == 0 { errorCode = errno }
                return COPYFILE_QUIT
            }
            guard isCancelled() else { return COPYFILE_CONTINUE }
            cancelled = true
            return COPYFILE_QUIT
        }
    }

    /// fcopyfile(3) of everything (COPYFILE_ALL) from the file open at `input` to the one open at
    /// `output`, its status callback asking `isCancelled` after each chunk written and around each
    /// extended attribute: a yes stops it mid-file with `CancellationError`. A failure throws its
    /// `POSIXError`.
    private static func copyFile(_ input: Int32, to output: Int32, isCancelled: () -> Bool) throws {
        guard let state = copyfile_state_alloc() else { throw posixError(ENOMEM) }
        defer { copyfile_state_free(state) }
        try withoutActuallyEscaping(isCancelled) { isCancelled in
            let status = CopyStatus(isCancelled)
            try withExtendedLifetime(status) {
                let callback: copyfile_callback_t = { _, stage, _, _, _, context in
                    let pointer: UnsafeMutableRawPointer? = context
                    guard let pointer else { return COPYFILE_QUIT }
                    return Unmanaged<CopyStatus>.fromOpaque(pointer).takeUnretainedValue().answer(stage: stage)
                }
                guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
                                         unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0,
                      copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX),
                                         UnsafeRawPointer(Unmanaged.passUnretained(status).toOpaque())) == 0
                else { throw posixError(errno) }
                let result = fcopyfile(input, output, state, copyfile_flags_t(COPYFILE_ALL))
                let code = errno
                // A quit at an extended attribute's start can still end in success: a cancel all the same.
                if status.cancelled { throw CancellationError() }
                if result != 0 { throw posixError(status.errorCode != 0 ? status.errorCode : code) }
            }
        }
    }

    /// Removes what the copy made in the folder open at `folder` (`made`, newest first), each item
    /// only while it is still the one the copy made (same device and inode, lstat), never following
    /// a symlink and never touching anything else; a folder of the copy's is made u+rwx first (it
    /// may have its read-only mode already). One gone already counts as removed. By name in a
    /// folder held open: something swapped in between the check and the unlink is removed in its
    /// place, a window only someone writing into the copy's own folders has. Whether all went.
    private static func remove(_ made: MadeFolder, in folder: Int32) -> Bool {
        var removedAll = true
        for entry in made.entries.reversed() {
            var status = stat()
            guard fstatat(folder, entry.name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno != ENOENT { removedAll = false }
                continue
            }
            guard Identity(device: status.st_dev, inode: status.st_ino) == entry.identity else {
                removedAll = false
                continue
            }
            if let inner = entry.folder {
                _ = fchmodat(folder, entry.name, S_IRWXU, AT_SYMLINK_NOFOLLOW)
                let child = openat(folder, entry.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else {
                    removedAll = false
                    continue
                }
                let emptied = identity(of: child) == entry.identity && remove(inner, in: child)
                close(child)
                if !emptied || unlinkat(folder, entry.name, AT_REMOVEDIR) != 0 { removedAll = false }
            } else if unlinkat(folder, entry.name, 0) != 0 {
                removedAll = false
            }
        }
        return removedAll
    }

    /// rmdir(2) of the folder at `url` while lstat finds `own` there, this user's; true when it is
    /// gone or what is there isn't the copy's. By path, so a racer could swap the folder between the
    /// lstat and the rmdir: acceptable, as only the promised name is exposed and rmdir removes
    /// nothing but an empty folder.
    private static func removeFolder(_ url: URL, ifStill own: Identity) -> Bool {
        guard ownedIdentity(at: url.path) == own else { return !isStill(own, at: url.path) }
        return rmdir(url.path) == 0
    }

    /// unlink(2) of the file at `url` while lstat finds `own` there, this user's; true when it is
    /// gone or what is there isn't the copy's. By path, so a racer could swap the item between the
    /// lstat and the unlink: acceptable, as only the promised name is exposed, and a racer would
    /// first have to move the copy's own file away.
    private static func removeFile(_ url: URL, ifStill own: Identity) -> Bool {
        guard ownedIdentity(at: url.path) == own else { return !isStill(own, at: url.path) }
        return unlink(url.path) == 0
    }

    /// The item at `path` is `own` (lstat), whoever owns it now.
    private static func isStill(_ own: Identity, at path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && Identity(device: status.st_dev, inode: status.st_ino) == own
    }

    /// `error`, or `PartialCopyError` (logged) when what the copy made at `target` couldn't all be removed.
    private static func failure(_ error: any Error, removed: Bool, at target: URL) -> any Error {
        guard !removed else { return error }
        let nsError = error as NSError
        logger.error("Drag out: a partial copy was left at \(target.path, privacy: .private) after \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
        return PartialCopyError(url: target, underlying: error)
    }

    /// Removes the item at `url`, a folder with everything in it even where a folder in it is read-only
    /// or can't be listed (FileManager's removal stops there), never following a symlink: drag-out's
    /// staging, which holds what was copied from it, and stale staging (`StagingSweep`). Throws the
    /// `POSIXError` of the item's own removal.
    static func removeItem(at url: URL) throws {
        let folder = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if folder >= 0 {
            removeContents(of: folder)
            close(folder)
            guard rmdir(url.path) == 0 else { throw posixError(errno) }
        } else {
            guard unlink(url.path) == 0 else { throw posixError(errno) }
        }
    }

    /// Best effort: empties the folder open at `folder` (made u+rwx first, as is each folder in it,
    /// so a read-only one empties too), by name relative to it, never following a symlink.
    private static func removeContents(of folder: Int32) {
        _ = fchmod(folder, S_IRWXU)
        for name in (try? names(in: folder)) ?? [] {
            var status = stat()
            guard fstatat(folder, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            if status.st_mode & S_IFMT == S_IFDIR {
                _ = fchmodat(folder, name, S_IRWXU, AT_SYMLINK_NOFOLLOW)  // one that can't be listed, too
                let child = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child >= 0 {
                    removeContents(of: child)
                    close(child)
                }
                _ = unlinkat(folder, name, AT_REMOVEDIR)
            } else {
                _ = unlinkat(folder, name, 0)
            }
        }
    }

    /// The names in the folder open at `folder`, "." and ".." left out, sorted (one order every time),
    /// read through a descriptor of its own (so its offset is not `folder`'s).
    static func names(in folder: Int32) throws -> [String] {
        let own = openat(folder, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard own >= 0 else { throw posixError(errno) }
        guard let stream = fdopendir(own) else {
            let code = errno
            close(own)
            throw posixError(code)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw posixError(errno) }
                return names.sorted()
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    /// lstat(2)'s device and inode at `path`, when the item there is this user's.
    private static func ownedIdentity(at path: String) -> Identity? {
        var status = stat()
        guard lstat(path, &status) == 0, status.st_uid == geteuid() else { return nil }
        return Identity(device: status.st_dev, inode: status.st_ino)
    }

    /// fstat(2)'s device and inode of `descriptor`.
    private static func identity(of descriptor: Int32) -> Identity? {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return nil }
        return Identity(device: status.st_dev, inode: status.st_ino)
    }

    /// Clears the setuid, setgid and sticky bits on the item the copy made, open at `descriptor`,
    /// where its metadata copy or its own mode put them back (`specialBits`).
    private static func dropSpecialBits(_ descriptor: Int32) throws {
        var status = stat()
        try check(fstat(descriptor, &status))
        guard status.st_mode & specialBits != 0 else { return }
        try check(fchmod(descriptor, status.st_mode & 0o777))
    }

    /// setuid, setgid and sticky.
    static let specialBits: mode_t = S_ISUID | S_ISGID | S_ISVTX

    /// Clears the setuid, setgid and sticky bits (`specialBits`, keeping `mode & 0o777`) on the item at
    /// `url` and, for a folder, on everything in it; never through a symlink: one is left as it is, and
    /// nothing it leads to is visited. For items neither the engine nor this copy wrote: a pending
    /// addition `FileManager` copies into an extraction. It works by path (`lstat`, then `fchmodat` with
    /// `AT_SYMLINK_NOFOLLOW`; intermediate path components are followed), so it is safe only inside a folder
    /// only this user can write, e.g. the app's 0700 staging folder.
    static func dropSpecialBits(inTreeAt url: URL) throws {
        var status = stat()
        try check(lstat(url.path, &status))
        let type = status.st_mode & S_IFMT
        guard type != S_IFLNK else { return }
        if status.st_mode & specialBits != 0 {
            try check(fchmodat(AT_FDCWD, url.path, status.st_mode & 0o777, AT_SYMLINK_NOFOLLOW))
        }
        guard type == S_IFDIR else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
            try dropSpecialBits(inTreeAt: url.appendingPathComponent(name))
        }
    }

    private static func check(_ result: Int32) throws {
        if result != 0 { throw posixError(errno) }
    }

    /// Making `target` failed with `code`: Cocoa's file-exists error for EEXIST, else its `POSIXError`.
    private static func creationError(_ code: Int32, _ target: URL) -> any Error {
        code == EEXIST ? fileExists(target) : posixError(code)
    }

    static func fileExists(_ url: URL) -> CocoaError {
        CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path])
    }

    static func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
