import Foundation
import os
import KernirCore

/// Extract Here's file work: extracts an `ExtractHerePlan` next to the archive, out of sight until
/// it is done, then moves the one result into place under a free Finder name. The caller has
/// access to the archive's folder (`FolderAccessStore`) and shows progress.
enum ExtractHereService {
    private static let logger = Logger(subsystem: "com.kernir.app", category: "extractHere")

    /// Extracts `plan` from `model` into a hidden folder `.kernir-<device token>-<pid>-<uuid>`
    /// beside `archiveURL` (named as the model's staging, so a sweep of that folder can remove a
    /// crash's remnant), with `model.extract`: a `.wrapped` plan into a folder named
    /// `folderName` inside it. Then moves the result next to the archive under its name, or the
    /// next free Finder name ("report 2.pdf", "project 2"), never replacing anything
    /// (`UniquePlacement`). The hidden folder goes in every case, so a cancel or a failure leaves
    /// the archive's folder as it was, and the result appears whole, at once. It goes off the main
    /// thread (a big tree takes a while) through `removeItem` (tests pass their own), awaited, so
    /// it is gone when this returns or throws. Renames go through `model.extractionFileSystem`.
    /// Stale staging a crashed run left in the destination folder is swept first (`StagingSweep`).
    /// Returns the result's URL, a folder's as a directory URL.
    @MainActor
    static func extract(_ plan: ExtractHerePlan, from model: ArchiveModel, nextTo archiveURL: URL,
                        progress: ArchiveProgressHandler?,
                        removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) })
        async throws -> URL {
        try await extract(plan, from: model, in: archiveURL.deletingLastPathComponent(), progress: progress,
                          removeItem: removeItem)
    }

    /// `extract(_:from:nextTo:)` into `directory` instead of the archive's folder: the same result
    /// (its name, the wrap), placed the same way. For the folder the user picks when the archive's
    /// volume is read-only (the error offers another folder).
    @MainActor
    static func extract(_ plan: ExtractHerePlan, from model: ArchiveModel, in directory: URL,
                        progress: ArchiveProgressHandler?,
                        removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) })
        async throws -> URL {
        let fileSystem = model.extractionFileSystem
        // A crashed run's staging here (this device's, its process gone, 10 minutes old) goes first,
        // off the main thread; best effort (`StagingSweep`). Drag-out sweeps the temporary folder itself
        // (`ArchiveDragOut.write`; its `extract(_:from:stagingIn:for:)` never sweeps). Bounded:
        // at most once per folder per `StagingSweep.interval`, each sweep capped.
        let deviceToken = fileSystem.deviceToken
        await Task.detached(priority: .userInitiated) {
            _ = StagingSweep.sweepIfDue(in: directory, deviceToken: deviceToken)
        }.value
        // A Cancel that landed while the sweep ran (awaiting it never throws) stops here, before
        // any staging exists.
        try Task.checkCancellation()
        return try await extract(plan, from: model, stagingIn: directory, for: directory, progress: progress,
                                 removeItem: removeItem) { result, name, isDirectory in
            try UniquePlacement.place(result, named: name, in: directory, isDirectory: isDirectory,
                                      fileSystem: model.extractionFileSystem)
        }
    }

    /// The staged extraction under both: extracts `plan` into a fresh hidden folder
    /// `.kernir-<device token>-<pid>-<uuid>` in `parent` (made 0700; `parent` is not swept here),
    /// then, unless cancelled, hands the result, its name and whether it is a folder to `place`,
    /// which moves it out and returns where it went. Nothing in it has a setuid, setgid or sticky bit:
    /// the engine never writes one, and a pending addition's copy has them cleared
    /// (`ExclusiveCopy.dropSpecialBits(inTreeAt:)`). The hidden folder goes in every case, awaited, through
    /// `removeItem`. A containment refusal is rethrown naming `folder`, the one the user sees. Drag-out stages
    /// in the temporary folder and places at Finder's URL (`ArchiveDragOut`).
    @MainActor
    static func extract(_ plan: ExtractHerePlan, from model: ArchiveModel, stagingIn parent: URL, for folder: URL,
                        progress: ArchiveProgressHandler?,
                        removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                        place: (_ result: URL, _ name: String, _ isDirectory: Bool) async throws -> URL)
        async throws -> URL {
        let outer = parent.appendingPathComponent(
            "\(ArchiveModel.stagingPrefix)\(model.extractionFileSystem.deviceToken)-\(getpid())-\(UUID().uuidString)",
            isDirectory: true)
        // Only this process can look inside while it fills (a shared folder, /Users/Shared, SMB):
        // made 0700 by mkdir itself, never a chmod after. What `place` moves out keeps its own modes.
        try makeStagingFolder(outer)
        let placed: URL
        do {
            let (result, name, isDirectory) = try await stage(plan, from: model, into: outer, progress: progress)
            // A reader that ignored the cancellation, or a cancel during the model's own moves, must
            // not put anything in place.
            try Task.checkCancellation()
            placed = try await place(result, name, isDirectory)
            // The move out of the hidden folder drops the placed item's quarantine in the sandbox
            // (not that of what is inside it, which `model.extract` marked): mark it again.
            QuarantinePropagation.propagate(from: model.quarantineSources, to: [placed], recursive: false)
        } catch let refused as ExtractionContainmentError {
            await remove(outer, with: removeItem)
            // Named for the folder the result goes in, not the hidden one.
            throw ExtractionContainmentError(name: refused.name, destination: folder)
        } catch {
            await remove(outer, with: removeItem)
            throw error
        }
        await remove(outer, with: removeItem)
        return placed
    }

    /// mkdir(2) of `outer` with mode 0700 (less the umask): fails on anything already there, a
    /// symlink included. A failure throws the Cocoa error `createDirectory` would (the POSIX error
    /// underneath, the path), so callers tell a missing grant or a read-only volume apart as before.
    /// Internal for tests.
    nonisolated static func makeStagingFolder(_ outer: URL) throws {
        guard mkdir(outer.path, 0o700) != 0 else { return }
        let code = errno
        let cocoa: CocoaError.Code = switch code {
        case ENOENT, ENOTDIR: .fileNoSuchFile
        case EPERM, EACCES: .fileWriteNoPermission
        case ENAMETOOLONG: .fileWriteInvalidFileName
        case ENOSPC, EDQUOT: .fileWriteOutOfSpace
        case EROFS: .fileWriteVolumeReadOnly
        case EEXIST: .fileWriteFileExists
        default: .fileWriteUnknown
        }
        throw CocoaError(cocoa, userInfo: [NSFilePathErrorKey: outer.path,
                                           NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
    }

    /// The destination is on a read-only volume (a disk image, a locked card): no grant helps, so
    /// the caller offers another folder instead of the Allow panel. Cocoa's code or EROFS, on the
    /// error or anywhere down its `NSUnderlyingErrorKey` chain (followed for at most 16 links, so
    /// a chain that loops ends). Permission errors (EPERM, EACCES, no permission) and a full disk
    /// or quota (ENOSPC, EDQUOT) are not this.
    nonisolated static func isReadOnlyVolume(_ error: any Error) -> Bool {
        var next: NSError? = error as NSError
        var links = 0
        while let error = next, links < 16 {
            if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileWriteVolumeReadOnly.rawValue { return true }
            if error.domain == NSPOSIXErrorDomain, error.code == Int(EROFS) { return true }
            next = error.userInfo[NSUnderlyingErrorKey] as? NSError
            links += 1
        }
        return false
    }

    /// `extract`'s work inside `outer`: the result, its name and whether it is a folder. The caller
    /// places it and removes `outer`.
    @MainActor
    private static func stage(_ plan: ExtractHerePlan, from model: ArchiveModel, into outer: URL,
                              progress: ArchiveProgressHandler?) async throws -> (URL, String, Bool) {
        switch plan {
        case let .single(path, itemName, itemIsDirectory):
            // The outer folder is fresh and empty: nothing is in the way, so nothing is asked.
            let written = try await model.extract([path], to: outer,
                                                  resolutions: keepBothTwins([path], of: model, in: outer,
                                                                             staging: outer),
                                                  progress: progress)
            guard let first = written.first else { throw ArchiveError.entryNotFound(path) }
            return (first, itemName, itemIsDirectory)
        case let .wrapped(folderName, paths):
            let folder = outer.appendingPathComponent(folderName, isDirectory: true)
            try await model.extract(paths, to: folder,
                                    resolutions: keepBothTwins(paths, of: model, in: folder, staging: outer),
                                    progress: progress)
            return (folder, folderName, true)
        }
    }

    /// Keep Both for every conflict extracting `paths` into `destination`, a fresh folder (or one not
    /// made yet) inside the hidden one: nothing is on disk there, so the only conflicts are case-only
    /// twins on a case-insensitive volume. Extract Here never asks: the later twin takes
    /// the dialog's Keep Both name ("Readme 2"), so both are kept. `outer` is the hidden folder.
    /// Only when `destination` is it or a child of it, missing or empty, in every build: anywhere else this answers
    /// nothing, so a conflict there stays a conflict (`ExtractionConflictError`), never a blanket Keep Both. Internal
    /// for tests.
    @MainActor
    static func keepBothTwins(_ paths: [String], of model: ArchiveModel, in destination: URL,
                              staging outer: URL) -> [String: ExtractionConflictResolution] {
        let outerPath = outer.standardizedFileURL.path
        guard ArchiveModel.stagingNameFields(outer.lastPathComponent) != nil,
              destination.standardizedFileURL.path == outerPath
                || destination.deletingLastPathComponent().standardizedFileURL.path == outerPath,
              isMissingOrEmptyFolder(destination) else {
            logger.fault("Keep Both for every conflict asked outside a fresh staging folder: none given")
            return [:]
        }
        return Dictionary(model.extractionConflicts(paths, in: destination).map { ($0, .keepBoth) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// Nothing at `url` (not even a dangling symlink), or a real folder with nothing in it. By lstat:
    /// a symlink (to a folder too), a file, or a folder that can't be listed is neither.
    private static func isMissingOrEmptyFolder(_ url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return errno == ENOENT }
        return status.st_mode & S_IFMT == S_IFDIR
            && ((try? FileManager.default.contentsOfDirectory(atPath: url.path))?.isEmpty ?? false)
    }

    /// Best effort, on a detached task (a cancel of the caller doesn't stop it): a remnant is
    /// hidden, and only a sweep that can delete it removes it.
    private nonisolated static func remove(_ outer: URL,
                                           with removeItem: @escaping @Sendable (URL) throws -> Void) async {
        await Task.detached(priority: .userInitiated) {
            do {
                try removeItem(outer)
            } catch {
                logger.error("Cannot remove \(outer.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            }
        }.value
    }
}
