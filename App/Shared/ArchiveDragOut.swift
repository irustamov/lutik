import Foundation
import KernirCore
import os
import UniformTypeIdentifiers

/// A row dragged out of an archive window as a file promise: the type the promise announces, and
/// the file work when the drop lands. A sandboxed app may write only the exact URL the receiver
/// gives (the promise's grant covers nothing else in the drop folder), so the work is Extract Here's
/// staging in a hidden `.kernir-` folder of the temporary folder (the app container's), then one
/// exclusive move to that URL, or an exclusive copy (`ExclusiveCopy`) when it is on another volume.
/// Nothing in the drop folder is listed, swept or made but the promised item, and nothing is ever
/// replaced.
enum ArchiveDragOut {
    /// The type a dragged item announces. AppKit accepts only a promise type that conforms to
    /// public.data or public.directory (anything else raises an exception Swift can't catch), so:
    /// .folder for a folder; for a file, its extension's type when that conforms to public.data
    /// (a dynamic one when the system has none; "x.app" as a file gives com.apple.application-file,
    /// never the bundle type), else .data, as without an extension.
    static func contentType(name: String, isDirectory: Bool) -> UTType {
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), type.conforms(to: .data) else { return .data }
        return type
    }

    /// A name the receiver's URL may end in: not empty, not "." or "..", no "/" and no NUL, at most
    /// 255 bytes of UTF-8 (a file name's limit).
    static func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.unicodeScalars.contains { $0 == "/" || $0 == "\0" }
    }

    /// The name Finder shows for the promise of the item at archive `path`: the item's own (its last
    /// "/" scalar component), made one `isValidFileName` accepts when the archive's isn't. A "/" left
    /// in it (a path with no component, "/") becomes ":", which a file name can hold; NUL becomes "_";
    /// "." and ".." become "_" and "__"; a name over 255 UTF-8 bytes is cut by whole characters, a
    /// short extension kept.
    static func offeredName(forPath path: String) -> String {
        let scalars = ArchiveEntry.name(of: path).unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar {
            case "/": ":"
            case "\0": "_"
            default: scalar
            }
        }
        var name = String(String.UnicodeScalarView(scalars))
        if name == "." || name == ".." { name = String(repeating: "_", count: name.count) }
        if name.utf8.count > 255 {
            let ext = (name as NSString).pathExtension
            let suffix = !ext.isEmpty && ext.utf8.count < 32 ? ".\(ext)" : ""
            var stem = Substring(name.dropLast(suffix.count))
            while stem.utf8.count + suffix.utf8.count > 255 { stem = stem.dropLast() }
            name = String(stem) + suffix
        }
        return name.isEmpty ? "_" : name
    }

    /// Writes the item at `path` to exactly `url`, the URL the drop's receiver gives the promise
    /// ("Always use the supplied URL", NSFilePromiseProvider.h); a folder's whole tree lands there in
    /// one move. First removes stale staging a crashed run left in the temporary folder (the app's
    /// own; `StagingSweep`), off the main thread. Stages there (`ExtractHereService.extract(_:from:
    /// stagingIn:for:)`), then `place`s it. Holds `url`'s security scope until every file operation,
    /// the staging's removal included, is done. Throws `CocoaError(.fileWriteInvalidFileName)` for a
    /// name `isValidFileName` refuses, `ArchiveError.entryNotFound` for a row the model no longer has
    /// and `CocoaError(.fileWriteFileExists)` when something is at `url` already (never replaced,
    /// never another name), before anything is extracted; any other failure as the extraction or the
    /// placement throws it (a cancel as `CancellationError`). `progress` gets the extraction's
    /// progress. Returns `url`, a folder's as a directory URL. The staged item always goes through the link
    /// sweep (`ExportLinkSweep.sanitize`) off the main actor.
    @MainActor
    static func write(_ path: String, from model: ArchiveModel, toPromised url: URL,
                      progress: ArchiveProgressHandler? = nil) async throws -> URL {
        try await write(path, from: model, toPromised: url, progress: progress, sweep: ExportLinkSweep.sanitize)
    }

    #if DEBUG
    /// Tests only: `write(_:from:toPromised:progress:)` with `sanitize` in place of the link sweep. Never in a
    /// release build, so no production caller can skip `ExportLinkSweep`.
    @MainActor
    static func write(_ path: String, from model: ArchiveModel, toPromised url: URL,
                      progress: ArchiveProgressHandler? = nil,
                      sanitize: @escaping @Sendable ([URL]) throws -> [URL]) async throws -> URL {
        try await write(path, from: model, toPromised: url, progress: progress, sweep: sanitize)
    }
    #endif

    @MainActor
    private static func write(_ path: String, from model: ArchiveModel, toPromised url: URL,
                              progress: ArchiveProgressHandler?,
                              sweep sanitize: @escaping @Sendable ([URL]) throws -> [URL]) async throws -> URL {
        let name = url.lastPathComponent
        guard isValidFileName(name) else { throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSURLErrorKey: url]) }
        guard let item = model.item(at: path) else { throw ArchiveError.entryNotFound(path) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileSystem = model.extractionFileSystem
        guard !fileSystem.exists(url.path) else { throw ExclusiveCopy.fileExists(url) }
        let temporary = FileManager.default.temporaryDirectory
        let deviceToken = fileSystem.deviceToken
        await Task.detached(priority: .userInitiated) {
            _ = StagingSweep.sweepIfDue(in: temporary, deviceToken: deviceToken)
        }.value
        try Task.checkCancellation()
        let plan = ExtractHerePlan.single(path: item.path, name: name, isDirectory: item.isDirectory)
        // The staging may hold a read-only folder after a copy (an archive's 0555).
        return try await ExtractHereService.extract(plan, from: model, stagingIn: temporary,
                                                    for: url.deletingLastPathComponent(), progress: progress,
                                                    removeItem: { try ExclusiveCopy.removeItem(at: $0) }) { staged, _, isDirectory in
            let target = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: isDirectory)
            // No link out of the item reaches the receiver (`ExportLinkSweep`); a link item itself fails.
            let kept = try await Task.detached(priority: .userInitiated) { try sanitize([staged]) }.value
            guard !kept.isEmpty else { throw ExportedLinksError(names: [name]) }
            // A cancel during the sweep places nothing.
            try Task.checkCancellation()
            if try await place(staged, at: target, fileSystem: fileSystem) {
                // Copied across volumes: in the sandbox the copy can't carry a quarantine over, so what is
                // inside is marked again too, off the main actor (`QuarantinePropagation`). Never stopped by a
                // cancel: it is in place already.
                let sources = model.quarantineSources
                await Task.detached(priority: .userInitiated) {
                    QuarantinePropagation.propagate(from: sources, to: [target])
                }.value
            }
            return target
        }
    }

    /// Moves `staged` to `target` with an exclusive rename (renamex_np RENAME_EXCL, through
    /// `fileSystem`): never over anything there (Cocoa's file-exists error). Across volumes (EXDEV),
    /// or where the volume has no exclusive rename, `ExclusiveCopy` instead, off the main actor; a
    /// cancel stops it, mid-file too (`CancellationError`, nothing left at `target`). `staged` is
    /// the app's own staging, so the copy may unlock what the archive made unreadable there (a 0000
    /// file, a 0300 folder), as a rename would move it all the same; the copy keeps its modes, never
    /// a setuid, setgid or sticky bit (`ExclusiveCopy.specialBits`). A
    /// FIFO, or a symlink onto FAT or exFAT, still fails across volumes (`ExclusiveCopy`). Any other
    /// failure throws its `POSIXError`; a failed rename leaves nothing at `target`. Returns whether it copied.
    @discardableResult
    nonisolated static func place(_ staged: URL, at target: URL, fileSystem: ExtractionFileSystem) async throws -> Bool {
        switch fileSystem.rename(staged.path, target.path, UInt32(RENAME_EXCL)) {
        case 0:
            return false
        case EEXIST:
            throw ExclusiveCopy.fileExists(target)
        case let code where code == EXDEV || ArchiveModel.lacksExclusiveRename(code):
            let cancelled = OSAllocatedUnfairLock(initialState: false)
            try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try ExclusiveCopy.copy(staged, to: target, unlocksSource: true) { cancelled.withLock { $0 } }
                }.value
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
            return true
        case let code:
            throw ExclusiveCopy.posixError(code)
        }
    }

    /// The error a failed promise reports: any kind of cancel as Cocoa's user-cancelled error (no
    /// alert, and what Finder expects of a cancelled promise), anything else as it is.
    static func promiseError(for error: any Error) -> any Error {
        isCancellation(error) ? CocoaError(.userCancelled) : error
    }

    /// The error the window shows for a promise that ended with `error`: nil for a success or any
    /// kind of cancel (the user asked for it), else the error as it is.
    static func alertError(for error: (any Error)?) -> (any Error)? {
        guard let error, !isCancellation(error) else { return nil }
        return error
    }

    /// A cancel: Swift's `CancellationError`, the engine's `ArchiveError.cancelled` (what a reader
    /// throws when Cancel stops it midway), or Cocoa's user-cancelled error.
    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case ArchiveError.cancelled = error { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.userCancelled.rawValue
    }
}
