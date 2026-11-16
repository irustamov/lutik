import AppKit
import KernirCore
import os

// Finder Services' windowless jobs: `ServicesJobRunner` runs one `ServicesJob` with
// `ExtractHereService` or `CompressService` under the destination folder's grant
// (`FolderAccessStore`), asking for it once when the folder can't be written. The live AppKit
// pieces (the Allow panel, alerts, the progress panel) are in ServicesJobs+AppKit.swift.

extension ServicesJob {
    /// The folder the job writes in: the archive's for Extract Here, the one `CompressPlan` picks
    /// for Compress (the items' common folder).
    var destination: URL? {
        switch self {
        case let .extractHere(archive):
            archive.deletingLastPathComponent()
        case let .compress(items, format):
            CompressPlan.destination(for: items, format: format, existingNames: [])?.directory
        }
    }

    /// What the job works on: one item by its Finder name ("x.zip", "a.txt"), or several by
    /// number. Each sentence has a key that quotes a name and a plural key for a number, so a
    /// language can inflect both its own way. Extract Here is always one archive.
    enum Subject: Equatable, Sendable {
        case named(String)
        case items(Int)
    }

    var subject: Subject {
        switch self {
        case let .extractHere(archive):
            .named(ServicesJobRunner.displayName(of: archive))
        case let .compress(items, _) where items.count == 1:
            .named(ServicesJobRunner.displayName(of: items[0]))
        case let .compress(items, _):
            .items(items.count)
        }
    }

    /// The first line of the alert when the job fails.
    var failureTitle: String {
        switch (self, subject) {
        case let (.extractHere(archive), _):
            String(localized: "Couldn't extract “\(ServicesJobRunner.displayName(of: archive))”.",
                   comment: "Alert title when Finder's “Extract Here with Lutik” fails. %@ = the archive's name, as Finder shows it. The reason follows below it.")
        case let (.compress, .named(name)):
            String(localized: "Couldn't compress “\(name)”.",
                   comment: "Alert title when Finder's “Compress with Lutik” fails for one file or folder. %@ = its name, as Finder shows it. The reason follows below it.")
        case let (.compress, .items(count)):
            String(localized: "Couldn't compress \(count) items.",
                   comment: "Alert title when Finder's “Compress with Lutik” fails for several files and folders. %lld = number of those items (two or more). Never shown for a single item; in languages whose ‘one’ form also covers 21, 31…, it still means several items.")
        }
    }
}

/// How one Services job ended.
enum ServicesJobOutcome: Equatable, Sendable {
    /// The result is in place: shown in Finder.
    case done(URL)
    /// The archive needs a password: opened as a document, which asks for it.
    case needsPassword(URL)
    /// Stopped by the user, or the Allow panel was cancelled: nothing to say.
    case cancelled
    case failed(ServicesJobFailure)
}

/// A failed job, for the alert: what failed, and why, never naming the hidden staging folder.
struct ServicesJobFailure: Equatable, Sendable {
    var title: String
    var reason: String
}

/// What Extract Here made: the result, and whether the archive was one part of a split set (which
/// the Trash rule keeps: its other parts would stay behind).
struct ServicesExtraction: Equatable, Sendable {
    var result: URL
    var isVolumeSet = false
}

/// Whether a Lutik document window has an archive open, and with unsaved changes.
enum ServicesOpenArchive: Equatable, Sendable {
    case notOpen, open, openWithUnsavedChanges
}

/// A file's identity: its volume and its file on it (`fileResourceIdentifierKey`), the same
/// whatever path reaches it (a hard link, a symbolic link, another case, a firmlink like
/// /System/Volumes/Data).
struct ServicesFileIdentity: Equatable {
    var file: any NSObjectProtocol
    var volume: any NSObjectProtocol

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.file.isEqual(rhs.file) && lhs.volume.isEqual(rhs.volume)
    }

    /// The identity of the file at `url`, symbolic links resolved; nil when either part can't be
    /// read (no such file).
    static func of(_ url: URL) -> ServicesFileIdentity? {
        guard let values = ServicesFileStamp.freshValues(of: url, [.fileResourceIdentifierKey, .volumeIdentifierKey]),
              let file = values.fileResourceIdentifier, let volume = values.volumeIdentifier else { return nil }
        return ServicesFileIdentity(file: file, volume: volume)
    }
}

/// What the Trash checks has not changed since the job began: the archive's identity, size and
/// modification date. Another app that replaced or rewrote the file changes one of them.
/// Where the file's identity can't be read (a volume with no file IDs), the stamp is the size and
/// the date only, so a replacement copied with its date (`cp -p`) matches: accepted.
struct ServicesFileStamp: Equatable {
    var identity: ServicesFileIdentity?
    var size: Int?
    var modified: Date?

    /// The file at `url` now; nil when none of it can be read.
    static func of(_ url: URL) -> ServicesFileStamp? {
        let values = freshValues(of: url, [.fileSizeKey, .contentModificationDateKey])
        let stamp = ServicesFileStamp(identity: ServicesFileIdentity.of(url), size: values?.fileSize,
                                      modified: values?.contentModificationDate)
        return stamp == ServicesFileStamp() ? nil : stamp
    }

    /// `keys` of the file at `url`, symbolic links resolved, read anew (a URL keeps what it read).
    fileprivate static func freshValues(of url: URL, _ keys: Set<URLResourceKey>) -> URLResourceValues? {
        let resolved = URL(fileURLWithPath: url.standardizedFileURL.resolvingSymlinksInPath().path)
        return try? resolved.resourceValues(forKeys: keys)
    }
}

/// Tells the queue that the running job shows a panel or an alert of its own (`begin`) and that it
/// has gone (`end`), so the progress panel keeps out of its way.
struct ServicesPrompting {
    var begin: @MainActor () -> Void
    var end: @MainActor () -> Void

    static let none = ServicesPrompting(begin: {}, end: {})

    /// `body` between `begin` and `end`.
    @MainActor
    func around<T>(_ body: () async -> T) async -> T {
        begin()
        defer { end() }
        return await body()
    }
}

/// Runs one Services job. Each piece of work is a seam: tests pass fakes, and the Allow panel is
/// app-modal in the app (a Services job has no window to attach a sheet to).
@MainActor
struct ServicesJobRunner {
    /// Extract Here of a whole archive next to it, or in `folder` when one is given; returns the
    /// result and whether the archive was part of a split set.
    var extract: @MainActor (_ archive: URL, _ folder: URL?,
                             _ progress: ArchiveProgressHandler?) async throws -> ServicesExtraction = Self.extractHere
    /// Compress into a new archive beside the items, or in `folder` when one is given; returns it.
    var compress: @MainActor (_ items: [URL], _ format: ArchiveFormat, _ folder: URL?,
                              _ progress: ArchiveProgressHandler?) async throws -> URL = {
        try await CompressService().compress($0, format: $1, in: $2, progress: $3)
    }
    /// The grant covering a folder, started; nil when none does.
    var access: @MainActor (URL) -> ScopedFolder?
    /// Keeps the folder the user picked in the Allow panel.
    var grant: @MainActor (URL) throws -> Void
    /// Asks the user to allow writing in the destination folder (the job says what for); the
    /// folder picked, or nil for Cancel.
    var askForAccess: @MainActor (_ destination: URL, _ job: ServicesJob) async -> URL?
    /// The destination refuses writes (a read-only volume, or a folder that still
    /// refuses with a grant), so the user may put the result elsewhere. Says why (`failure`) and
    /// offers another folder; the folder picked, or nil for Cancel. With none, the job fails.
    var offerAnotherFolder: (@MainActor (_ failure: ServicesJobFailure, _ job: ServicesJob) async -> URL?)?
    /// Extract Here's "Move archive to Trash" setting (`ExtractHereSettings`). The app's runner
    /// reads it; any other never moves an archive to the Trash.
    var movesArchiveToTrash: @MainActor () -> Bool = { false }
    /// Whether a Lutik document window has the archive open (an open one is never trashed), and
    /// with unsaved changes (which the Trash would lose).
    var openInKernir: @MainActor (_ archive: URL) -> ServicesOpenArchive = { _ in .notOpen }
    /// Moves the archive to the Trash (`ExtractHereEffects.moveToTrash`: a folder of the UI tests'
    /// own under their launch arguments).
    var moveToTrash: @MainActor (_ archive: URL) throws -> Void = { _ = try ExtractHereEffects.moveToTrash($0) }
    /// The archive's stamp (`ServicesFileStamp.of`), taken under the folder's grant when the job
    /// begins and again before the Trash. Tests pass one that sees when it is taken.
    var fileStamp: @MainActor (_ archive: URL) -> ServicesFileStamp? = { ServicesFileStamp.of($0) }

    private static let logger = Logger(subsystem: "com.kernir.app", category: "services")

    /// The archive has no items to extract.
    struct EmptyArchive: Error, Equatable {}

    /// Runs `job` under the grant that covers its folder. A permission error with no grant asks
    /// once (`askForAccess`), keeps the pick and runs the job again; Cancel there ends it quietly.
    /// A folder that refuses writes all the same (a read-only volume, or one that refuses with a
    /// grant) offers another (`offerAnotherFolder`) and runs the job again there,
    /// as often as the user picks one; Cancel there ends it, the user having seen why. The panels
    /// and alerts go between `prompting`'s calls. A whole Extract Here done in the archive's own
    /// folder may then move the archive to the Trash (`trashIfAsked`), under the same grant.
    func run(_ job: ServicesJob, progress: ArchiveProgressHandler?,
             prompting: ServicesPrompting = .none) async -> ServicesJobOutcome {
        guard let destination = job.destination else { return .cancelled }
        /// Where the job writes: nil for its own folder (`destination`), else the one picked instead.
        var elsewhere: URL?
        var scoped = access(destination)
        defer { scoped?.stop() }
        /// The archive as the job found it, so a file another app put in its place isn't trashed.
        /// Taken under the folder's grant, as the Trash's check is: without one, a sandboxed app
        /// may not read it (nil), and the check would then keep every archive.
        var stamp = archiveStamp(job)
        var asked = false
        while true {
            do {
                let (result, isVolumeSet) = try await work(job, in: elsewhere, progress: progress)
                if case let .extractHere(archive) = job {
                    trashIfAsked(archive, isVolumeSet: isVolumeSet, ranElsewhere: elsewhere != nil, stamp: stamp)
                }
                return .done(result)
            } catch {
                if Self.isCancellation(error) { return .cancelled }
                if case ArchiveError.passwordRequired = error, case let .extractHere(archive) = job {
                    return .needsPassword(archive)
                }
                let folder = elsewhere ?? destination
                // A read-only volume first: Cocoa's 513 can wrap EROFS, and a grant can't help there.
                if Self.needsFolderAccess(error), !Self.isReadOnlyVolume(error), scoped == nil, !asked {
                    // Asked once per job: a grant that can't be kept still leaves the pick's access
                    // for this launch, so a second panel couldn't help.
                    asked = true
                    guard let picked = await prompting.around({ await askForAccess(folder, job) }) else { return .cancelled }
                    do {
                        try grant(picked)
                    } catch {
                        // The panel's pick still carries access for this launch; only the next one asks again.
                        Self.logger.error("Cannot keep a folder grant: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                    }
                    scoped = access(folder)
                    // The archive couldn't be read before the grant: read it now, before the work.
                    if stamp == nil { stamp = archiveStamp(job) }
                    continue
                }
                let failure = Self.failure(for: error, job: job, in: folder)
                guard Self.refusesWrites(error), let offerAnotherFolder else { return .failed(failure) }
                guard let other = await prompting.around({ await offerAnotherFolder(failure, job) }) else { return .cancelled }
                // The pick carries access for this launch: no Allow panel for it.
                elsewhere = other
                asked = true
            }
        }
    }

    /// Extract Here's archive as it is now (`fileStamp`); nil for Compress, which trashes nothing.
    private func archiveStamp(_ job: ServicesJob) -> ServicesFileStamp? {
        guard case let .extractHere(archive) = job else { return nil }
        return fileStamp(archive)
    }

    /// The job's result, and whether it extracted a split set.
    private func work(_ job: ServicesJob, in folder: URL?,
                      progress: ArchiveProgressHandler?) async throws -> (result: URL, isVolumeSet: Bool) {
        switch job {
        case let .extractHere(archive):
            let extraction = try await extract(archive, folder, progress)
            return (extraction.result, extraction.isVolumeSet)
        case let .compress(items, format):
            return (try await compress(items, format, folder, progress), false)
        }
    }

    /// Extract Here's "Move archive to Trash" applies to Services jobs, by the same rule
    /// (`ExtractHereTrashDecision`): only after a whole, completed extraction of an archive that
    /// isn't one part of a split set and has no unsaved changes in an open document. Called with
    /// the grant still held. Two rules of the Services' own: not after the job ran in another
    /// folder (the archive's own folder refused writes, so the Trash, which takes the archive out
    /// of it, would fail as well, and the result isn't beside the archive), and not while any
    /// Lutik window has the archive open, edited or not (unlike 01, a Services job never closes
    /// a window the user didn't act from). Nor after a Stop that came as the work returned (the
    /// user asked for nothing more), nor when the archive's file changed since the job began
    /// (`stamp`: another app replaced it), nor when that can't be told (no stamp: the file was
    /// unreadable when the job began and again after the Allow panel). The job is done whatever
    /// happens here: an archive kept, or a Trash that fails, is only logged, never an alert.
    private func trashIfAsked(_ archive: URL, isVolumeSet: Bool, ranElsewhere: Bool, stamp: ServicesFileStamp?) {
        guard !ranElsewhere, !Task.isCancelled else { return }
        let open = openInKernir(archive)
        switch Self.trashDecision(enabled: movesArchiveToTrash(), open: open, isVolumeSet: isVolumeSet) {
        case .moveToTrash:
            guard open == .notOpen else {
                Self.logger.info("An archive open in a Kernir window was kept out of the Trash")
                return
            }
            guard let stamp else {
                Self.logger.info("An archive unreadable since the job began was kept out of the Trash")
                return
            }
            guard fileStamp(archive) == stamp else {
                Self.logger.info("An archive changed during the job, or unreadable, was kept out of the Trash")
                return
            }
            do {
                try moveToTrash(archive)
            } catch {
                Self.logger.error("Cannot move an archive to the Trash: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            }
        case .keep(.unsavedChanges?):
            Self.logger.info("An archive with unsaved changes was kept out of the Trash")
        case .keep(nil):
            break
        }
    }

    /// The rule (`ExtractHereTrashDecision`) for a whole, completed Extract Here of `archive`, as
    /// a Lutik window has it open (`open`): unsaved changes keep it. The caller keeps an archive
    /// open in a clean window as well.
    nonisolated static func trashDecision(enabled: Bool, open: ServicesOpenArchive,
                                          isVolumeSet: Bool) -> ExtractHereTrashDecision {
        ExtractHereTrashDecision.decide(enabled: enabled, outcome: .completed, extractedAll: true,
                                        hasUnsavedChanges: open == .openWithUnsavedChanges,
                                        isVolumeSet: isVolumeSet, hasFileURL: true)
    }

    /// Whether one of `documents` (each its file and whether it is edited) has `archive` open,
    /// and with unsaved changes. The same file by its identity (`ServicesFileIdentity`), whatever
    /// path reaches it; by path, symbolic links resolved, when either identity can't be read.
    nonisolated static func openState(of archive: URL, in documents: [(fileURL: URL?, isEdited: Bool)],
                                      identity: (URL) -> ServicesFileIdentity? = ServicesFileIdentity.of)
        -> ServicesOpenArchive {
        let archiveIdentity = identity(archive)
        let path = archive.standardizedFileURL.resolvingSymlinksInPath().path
        let matches = documents.filter { document in
            guard let url = document.fileURL else { return false }
            if let archiveIdentity, let other = identity(url) { return archiveIdentity == other }
            return url.standardizedFileURL.resolvingSymlinksInPath().path == path
        }
        if matches.contains(where: { $0.isEdited }) { return .openWithUnsavedChanges }
        return matches.isEmpty ? .notOpen : .open
    }

    /// Opens `archive` and extracts all of it next to it, or in `folder` (`ExtractHerePlan`,
    /// `ExtractHereService`). An encrypted ZIP or 7z throws `.passwordRequired` before anything is
    /// written, as `ArchiveDocument` asks for its password on open.
    static func extractHere(_ archive: URL, in folder: URL?, progress: ArchiveProgressHandler?) async throws -> ServicesExtraction {
        let reader = try await Archive.open(at: archive, password: nil)
        if reader.isEncrypted, reader.format == .zip || reader.format == .sevenZip {
            throw ArchiveError.passwordRequired
        }
        let model = ArchiveModel(reader: reader, undoManager: nil)
        guard let plan = ExtractHerePlan.make(nil, in: model, archiveURL: archive) else { throw EmptyArchive() }
        let result = if let folder {
            try await ExtractHereService.extract(plan, from: model, in: folder, progress: progress)
        } else {
            try await ExtractHereService.extract(plan, from: model, nextTo: archive, progress: progress)
        }
        return ServicesExtraction(result: result, isVolumeSet: reader.volumeURLs.count > 1)
    }

    // MARK: Errors

    /// The alert's text for `error`. The reason names the destination folder where that helps and
    /// never the hidden staging folder (`.kernir-…`) the services write in first: a system message
    /// that names it is replaced by a plain one.
    /// `destination` is the folder the job wrote in, when not its own.
    static func failure(for error: any Error, job: ServicesJob, in destination: URL? = nil) -> ServicesJobFailure {
        ServicesJobFailure(title: job.failureTitle, reason: reason(for: error, job: job, in: destination ?? job.destination))
    }

    private static func reason(for error: any Error, job: ServicesJob, in destination: URL?) -> String {
        let folder = destination.map(displayName(of:)) ?? ""
        if error is EmptyArchive {
            return String(localized: "The archive is empty.",
                          comment: "Alert text under “Couldn't extract “…”.” when Finder's “Extract Here with Lutik” gets an archive with nothing in it.")
        }
        // The same text (and key, so its comment is the alert's) as the read-only alert
        // (`FolderAccessPanel.readOnlyAlert`).
        if isReadOnlyVolume(error) { return String(localized: "“\(folder)” is on a read-only volume.") }
        if isFolderPermission(error) {
            return String(localized: "Lutik doesn't have permission to write in “\(folder)”.",
                          comment: "Alert text under a failed Finder Service (“Extract Here with Lutik”, “Compress with Lutik”): the folder's permissions don't let Lutik write there. %@ = that folder's name, as Finder shows it.")
        }
        if posixCode(of: error) == EEXIST {
            switch job {
            case .compress:
                return String(localized: "Couldn't find a free name for the archive in “\(folder)”.",
                              comment: "Alert text under “Couldn't compress …”: every name Lutik tried for the new archive (“Archive.zip”, “Archive 2.zip”, …) was taken. %@ = the folder's name, as Finder shows it.")
            case .extractHere:
                return String(localized: "Couldn't find a free name for the extracted items in “\(folder)”.",
                              comment: "Alert text under “Couldn't extract …”: every name Lutik tried for the extracted items was taken. %@ = the folder's name, as Finder shows it.")
            }
        }
        let description = error.localizedDescription
        return namesStaging(description)
            ? String(localized: "The files couldn't be written in “\(folder)”.",
                     comment: "Alert text under a failed Finder Service when the system's own message names a hidden working folder. %@ = the destination folder's name, as Finder shows it.")
            : description
    }

    /// Whether `text` names a staging folder: `.kernir-<device token>-<pid>-<uuid>`.
    private static func namesStaging(_ text: String) -> Bool {
        text.range(of: ".kernir-", options: .caseInsensitive) != nil
    }

    /// The user can't write there (the sandbox or the folder's permissions), so a grant may help;
    /// so may one for a split set whose other parts are out of reach. A read-only volume is not one.
    static func needsFolderAccess(_ error: any Error) -> Bool {
        if let volume = error as? ArchiveVolumeError { return volume.reason == .noAccess }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileWriteNoPermission.rawValue { return true }
        return posixCode(of: error).map { [EPERM, EACCES].contains($0) } ?? false
    }

    /// The destination folder itself refuses the write, so another folder may take the job: a
    /// read-only volume, or the folder's permissions. A split set out of reach is not one: the
    /// parts can't be read wherever the result goes.
    static func refusesWrites(_ error: any Error) -> Bool {
        isReadOnlyVolume(error) || isFolderPermission(error)
    }

    /// A permission error of the folder written in, not a split set's (`ArchiveVolumeError`).
    /// TODO: this and `needsFolderAccess` merge with `ArchiveActions.isPermissionError`
    /// Settle one depth for the underlying errors when they do: `posixCode` reads
    /// one level down, `isReadOnlyVolume` sixteen, `needsFolderAccess` the top error's
    /// Cocoa code and `posixCode`'s one level, as `isPermissionError` does (which also counts
    /// read-only as a permission error).
    private static func isFolderPermission(_ error: any Error) -> Bool {
        needsFolderAccess(error) && !(error is ArchiveVolumeError)
    }

    /// Cocoa's read-only code or EROFS anywhere down the underlying errors.
    private static func isReadOnlyVolume(_ error: any Error) -> Bool {
        ExtractHereService.isReadOnlyVolume(error)
    }

    /// The POSIX code of `error`, or of the error under it.
    private static func posixCode(of error: any Error) -> Int32? {
        let error = error as NSError
        let posix = error.domain == NSPOSIXErrorDomain ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
        guard let posix, posix.domain == NSPOSIXErrorDomain else { return nil }
        return Int32(posix.code)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case ArchiveError.cancelled = error { return true }
        return (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == CocoaError.userCancelled.rawValue
    }

    /// The item's name as Finder shows it.
    nonisolated static func displayName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
    }
}

// MARK: - The queue

extension ServicesJob {
    /// The progress panel's title: "Extracting “x.zip”…", "Compressing 3 items…".
    var progressTitle: String {
        switch (self, subject) {
        case let (.extractHere(archive), _):
            // The same key as the Allow panel's, which has the comment.
            String(localized: "Extracting “\(ServicesJobRunner.displayName(of: archive))”…")
        case let (.compress, .named(name)):
            String(localized: "Compressing “\(name)”…",
                   comment: "Title of the progress panel while Finder's “Compress with Lutik” runs on one file or folder. %@ = its name, as Finder shows it.")
        case let (.compress, .items(count)):
            String(localized: "Compressing \(count) items…",
                   comment: "Title of the progress panel while Finder's “Compress with Lutik” runs on several files and folders. %lld = number of those items (two or more). Never shown for a single item; in languages whose ‘one’ form also covers 21, 31…, it still means several items.")
        }
    }
}

/// The alert after the queue drains: one failure is its own title and reason; several are listed.
struct ServicesAlertText: Equatable, Sendable {
    var message: String
    var information: String

    init(failures: [ServicesJobFailure]) {
        if failures.count == 1 {
            message = failures[0].title
            information = failures[0].reason
        } else {
            message = String(localized: "Some jobs couldn't be finished.",
                             comment: "Alert title after several Finder Service jobs (“Extract Here with Lutik”, “Compress with Lutik”) failed. The text lists each failure: its title and reason.")
            information = failures.map {
                String(localized: "\($0.title) \($0.reason)",
                       comment: "One failure in the list under “Some jobs couldn't be finished.”: %1$@ = its title (e.g. “Couldn't extract “a.zip”.”), %2$@ = its reason. Only the space between them may change.")
            }.joined(separator: "\n\n")
        }
    }
}

/// The offer of another folder, in words that fit the job. The app's alert is the
/// failure's title and reason, with a button that goes on to a folder panel; the button and the
/// panel say what the folder is for: extracting the archive, or saving the new archive. Not the
/// read-only alert: the offer comes for a folder's permissions too, so the reason says which.
struct ServicesOtherFolderText: Equatable, Sendable {
    var message: String
    var information: String
    /// The alert's first button, which opens the panel.
    var choose: String
    var cancel: String
    var panelMessage: String
    var panelPrompt: String

    init(failure: ServicesJobFailure, job: ServicesJob) {
        message = failure.title
        information = failure.reason
        cancel = String(localized: "Cancel",
                    comment: "Cancel button of the password sheet, the progress sheet (stops the operation), the read-only volume alert, and the alert after a Finder service (“Extract Here with Lutik”, “Compress with Lutik”) couldn't write in its folder.")
        switch (job, job.subject) {
        case let (.extractHere(archive), _):
            choose = String(localized: "Extract to Another Folder…",
                            comment: "Button in the alert after Finder's “Extract Here with Lutik” couldn't write in the archive's folder: opens a folder panel to pick another one.")
            panelMessage = String(localized: "Choose where to extract “\(ServicesJobRunner.displayName(of: archive))”.",
                                  comment: "Message at the top of the folder panel that “Extract to Another Folder…” opens. %@ = the archive's name, as Finder shows it.")
            panelPrompt = String(localized: "Extract",
                    comment: "Extract (a verb): the label and VoiceOver label of the toolbar's Extract button, and the default button of the folder panels that pick where to extract (also the panel opened by “Extract to Another Folder…” after Finder's “Extract Here with Lutik” couldn't write in the archive's folder).")
        case let (.compress, subject):
            choose = String(localized: "Save to Another Folder…",
                            comment: "Button in the alert after Finder's “Compress with Lutik” couldn't write the new archive in its folder: opens a folder panel to pick another one.")
            switch subject {
            case let .named(name):
                panelMessage = String(localized: "Choose where to save the archive of “\(name)”.",
                                      comment: "Message at the top of the folder panel that “Save to Another Folder…” opens. %@ = the name of the one file or folder being compressed, as Finder shows it.")
            case let .items(count):
                panelMessage = String(localized: "Choose where to save the archive of \(count) items.",
                                      comment: "Message at the top of the folder panel that “Save to Another Folder…” opens. %lld = number of files and folders being compressed (two or more). Never shown for a single item; in languages whose ‘one’ form also covers 21, 31…, it still means several items.")
            }
            panelPrompt = String(localized: "Save",
                    comment: "Save (a verb), in two places: the File menu command (⌘S) that saves the archive, and the default button of the folder panel opened by “Save to Another Folder…” after Finder's “Compress with Lutik” couldn't save the new archive in its folder.")
        }
    }
}

/// The progress panel, as the queue drives it. The app's is a small floating panel hosting
/// `ProgressSheet` (ServicesJobs+AppKit.swift).
struct ServicesProgressDisplay {
    /// Shows the panel with `title`; its Stop button calls `stop`.
    var show: @MainActor (_ title: String, _ stop: @escaping @MainActor () -> Void) -> Void
    /// The running job's fraction, 0...1.
    var update: @MainActor (Double) -> Void
    var hide: @MainActor () -> Void
}

/// What the queue does outside itself. The app's are in ServicesJobs+AppKit.swift; tests record.
struct ServicesJobEffects {
    /// Shows the results in Finder (`ExtractHereEffects.reveal`, which the UI tests silence).
    var reveal: @MainActor ([URL]) -> Void
    /// Opens an archive as a document: its window asks for the password.
    var openDocument: @MainActor (URL) -> Void
    /// Returns once the alert is dismissed. The app's is modal, so other main-actor work (another
    /// job sent meanwhile) runs before it returns.
    var showAlert: @MainActor (ServicesAlertText) async -> Void
    /// The app's side of the quit rule, read when the queue drains: the launch (`AppDelegate`'s
    /// `ServicesLaunchFlag`) and what is open. The queue fills in its own jobs and documents.
    var appState: @MainActor () -> ServicesQuitState
    var terminate: @MainActor () -> Void
    var progress: ServicesProgressDisplay
}

/// Runs Finder Services' jobs one at a time, with no window: a progress panel only for a job that
/// takes longer than `panelDelay`, so a fast one shows nothing. When the queue drains: the
/// results are shown in one Finder selection, the failures in one alert, archives that need a
/// password are opened as documents, and then the app quits when it was launched only for the
/// Services and nothing is open (`shouldQuit`). Stop cancels the running job and drops the queued
/// ones.
@MainActor
final class ServicesJobQueue {
    typealias Run = @MainActor (ServicesJob, ArchiveProgressHandler?, ServicesPrompting) async -> ServicesJobOutcome

    /// How long a job runs before the progress panel shows.
    static let panelDelay: Duration = .seconds(1)

    private let run: Run
    private let effects: ServicesJobEffects
    private let sleep: @Sendable (Duration) async throws -> Void
    private var pending: [ServicesJob] = []
    private var worker: Task<Void, Never>?
    private var running: Task<ServicesJobOutcome, Never>?
    /// The running job's progress: updates for an earlier job are dropped.
    private var progressID: UUID?
    /// How many of the queue's own prompts are up (`isPrompting`): a count, so prompts may nest.
    private var promptDepth = 0

    /// Whether one of the queue's own prompts is up: a job's (the Allow panel, the other-folder
    /// alert and panel, between `ServicesPrompting`'s calls) or the failures alert (`finish`).
    /// All are app-modal, and a menu bar action under them (⌘V or ⌘A in the Allow panel's Go to
    /// Folder) isn't the user using the app (`ServicesMenuActivity`), so it can't keep a launch
    /// only for the Services. A password archive's document isn't a prompt: its opening counts.
    var isPrompting: Bool { promptDepth > 0 }

    /// `sleep` waits out the panel's delay (tests pass their own clock).
    init(run: @escaping Run, effects: ServicesJobEffects,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.run = run
        self.effects = effects
        self.sleep = sleep
    }

    /// Queues `job`; it starts once those before it end. One sent while the queue's ending runs
    /// (its alert is up, say) runs right after, in the same drain.
    func submit(_ job: ServicesJob) {
        pending.append(job)
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    /// Cancels the running job and drops the queued ones.
    func stop() {
        pending.removeAll()
        running?.cancel()
    }

    /// Returns once no job is queued or running and the queue's ending is done.
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    /// Whether to quit after the queue drained: only after a launch just for the Services (which
    /// state restoration also gives) that the user hasn't used since, with no job left, no
    /// document or window open, no panel up (an Open panel, About), no modal session, and no
    /// document about to open for a password. Every guard on its own keeps the app.
    nonisolated static func shouldQuit(_ state: ServicesQuitState) -> Bool {
        state.launchedForServicesOnly && !state.userActivated && !state.hasJobs && !state.hasDocumentWindows
            && !state.hasVisiblePanels && !state.hasModal && !state.opensDocuments
    }

    /// Runs the jobs, then reports them (`finish`), and again for those sent meanwhile: the app's
    /// alert is modal and main-actor work goes on under it, so `worker` stays set until the end,
    /// and only this drain's last check can quit, once, with no alert up.
    private func drain() async {
        var opensDocuments = false
        while !pending.isEmpty {
            var outcomes: [ServicesJobOutcome] = []
            while !pending.isEmpty {
                outcomes.append(await runOne(pending.removeFirst()))
            }
            opensDocuments = await finish(outcomes) || opensDocuments
        }
        // No suspension from here on: a job sent from now on starts a drain of its own.
        worker = nil
        var state = effects.appState()
        state.hasJobs = !pending.isEmpty || running != nil
        state.opensDocuments = opensDocuments
        if Self.shouldQuit(state) {
            effects.terminate()
        }
    }

    private func runOne(_ job: ServicesJob) async -> ServicesJobOutcome {
        let id = UUID()
        progressID = id
        let handler = ProgressForwarding.handler { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.progressID == id else { return }
                self.effects.progress.update(fraction)
            }
        }
        let panel = ProgressPanel(title: job.progressTitle, effects: effects, sleep: sleep) { [weak self] in self?.stop() }
        panel.start()
        let run = run
        // The job's own panels and alerts (the Allow panel) hide the progress panel; its delay
        // starts again after them. Meanwhile they are the queue's prompts (`isPrompting`).
        let prompting = ServicesPrompting(
            begin: { [weak self] in
                self?.promptDepth += 1
                panel.end()
            },
            end: { [weak self] in
                self?.promptDepth -= 1
                panel.start()
            })
        let task = Task { await run(job, handler, prompting) }
        running = task
        let outcome = await task.value
        panel.end()
        running = nil
        progressID = nil
        return outcome
    }

    /// The running job's progress panel: shown once `panelDelay` has passed since `start`.
    @MainActor
    private final class ProgressPanel {
        private let title: String
        private let effects: ServicesJobEffects
        private let sleep: @Sendable (Duration) async throws -> Void
        private let stop: @MainActor () -> Void
        private var delay: Task<Void, Never>?
        private var isShown = false

        init(title: String, effects: ServicesJobEffects, sleep: @escaping @Sendable (Duration) async throws -> Void,
             stop: @escaping @MainActor () -> Void) {
            self.title = title
            self.effects = effects
            self.sleep = sleep
            self.stop = stop
        }

        /// Starts the delay; the panel shows when it is out, unless `end` comes first.
        func start() {
            delay?.cancel()
            delay = Task { [sleep] in
                guard (try? await sleep(ServicesJobQueue.panelDelay)) != nil, !Task.isCancelled else { return }
                self.isShown = true
                self.effects.progress.show(self.title, self.stop)
            }
        }

        /// Stops the delay and hides the panel if it shows.
        func end() {
            delay?.cancel()
            delay = nil
            guard isShown else { return }
            isShown = false
            effects.progress.hide()
        }
    }

    /// The jobs ran: reveal, open, then alert. Returns whether a document is opening.
    private func finish(_ outcomes: [ServicesJobOutcome]) async -> Bool {
        var reveal: [URL] = []
        var open: [URL] = []
        var failures: [ServicesJobFailure] = []
        for outcome in outcomes {
            switch outcome {
            case let .done(url): reveal.append(url)
            case let .needsPassword(url): open.append(url)
            case let .failed(failure): failures.append(failure)
            case .cancelled: break
            }
        }
        if !reveal.isEmpty { effects.reveal(reveal) }
        open.forEach(effects.openDocument)
        if !failures.isEmpty {
            // The alert is the queue's prompt as well (`isPrompting`).
            promptDepth += 1
            defer { promptDepth -= 1 }
            await effects.showAlert(ServicesAlertText(failures: failures))
        }
        return !open.isEmpty
    }
}


/// What the quit rule after the Services' jobs looks at (`ServicesJobQueue.shouldQuit`). The
/// default is the one state that quits; each field set otherwise keeps the app.
struct ServicesQuitState: Equatable, Sendable {
    /// AppKit's launch flag was false: launched only to run a Service, open a file or restore
    /// windows (`ServicesLaunchFlag`).
    var launchedForServicesOnly = true
    /// The user has used the app since: a document or a window of its own opened, an open request
    /// came, an action from the menu bar (not one under the queue's own prompts,
    /// `ServicesJobQueue.isPrompting`), or a Dock click (`ServicesLaunchFlag.noteOpened`). The
    /// queue's own open of an archive for its password goes through `KernirDocumentController`'s
    /// open hook as well, and counts as use, as it did through `windowDidOpen` before.
    var userActivated = false
    /// A job is queued or running.
    var hasJobs = false
    /// A document, or a window that isn't a panel, is open (`ServicesJobEffects.countsAsOpen`).
    var hasDocumentWindows = false
    /// A panel is on screen: an Open panel, About. The queue's own panels are gone by then.
    var hasVisiblePanels = false
    /// A modal session runs (`NSApp.modalWindow`).
    var hasModal = false
    /// A document is about to open for its password.
    var opensDocuments = false
}

/// AppKit's launch flag as the quit rule reads it: false after a launch only to run a
/// Service, open a file or restore windows; and whether the user has used the app since (a
/// document or a window of the app's own opened, an open request, a menu bar action not under the
/// queue's own prompts, or a Dock click), which counts for good, so a later queue doesn't quit an
/// app the user has been using.
struct ServicesLaunchFlag {
    private var launchedAsUsual = true
    private var hasOpened = false

    var launchedForServicesOnly: Bool { !launchedAsUsual }
    var userActivated: Bool { hasOpened }

    /// AppKit's flag, when launch finishes (`ServicesProvider.isDefaultLaunch`).
    mutating func finishLaunching(isDefault: Bool) { launchedAsUsual = isDefault }

    /// A document or a window (not a panel) opened, a document was asked to open, the user sent
    /// an action from the menu bar (not under the queue's own prompts: `ServicesMenuActivity`
    /// doesn't call it then) or clicked the Dock icon: before launch finishes too.
    mutating func noteOpened() { hasOpened = true }
}

extension ServicesJobEffects {
    /// Whether a window counts as open for the quit rule: visible, or minimized in the Dock;
    /// never a panel (the progress panel, an alert, the Allow panel).
    nonisolated static func countsAsOpen(isVisible: Bool, isMiniaturized: Bool, isPanel: Bool) -> Bool {
        (isVisible || isMiniaturized) && !isPanel
    }
}

extension ServicesQuitState {
    /// The app's side of the state from `flag` and its windows. Jobs and documents opening are
    /// the queue's to fill in.
    init(flag: ServicesLaunchFlag, hasDocumentWindows: Bool, hasVisiblePanels: Bool, hasModal: Bool) {
        self.init(launchedForServicesOnly: flag.launchedForServicesOnly, userActivated: flag.userActivated,
                  hasDocumentWindows: hasDocumentWindows, hasVisiblePanels: hasVisiblePanels, hasModal: hasModal)
    }
}
