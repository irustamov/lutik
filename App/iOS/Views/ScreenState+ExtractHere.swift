import Foundation
import KernirCore

/// Extract Here's file work: `plan` from `model` into a folder, returning the result's URL
/// (`ExtractHereService.extract(_:from:in:progress:)`).
typealias ExtractHereRun = @MainActor @Sendable (ExtractHerePlan, ArchiveModel, URL, ArchiveProgressHandler?) async throws -> URL

/// Extract Here on iPhone and iPad: writes the items next to the archive, never
/// replacing anything (`ExtractHereService`, `UniquePlacement`), and asks for the archive's folder in
/// the Files picker until `folderAccessStore` holds a grant that covers it. Off for an archive in
/// the app's tmp/ or Documents/Inbox (`ExtractHereLocation`): Extract To… stays.
extension ScreenState {
    /// Extract Here can run on `extractTargets()`: an open archive, not saving or reading again, no
    /// picker, alert, question (Extract's conflict, Add's Replace, Save's Mac metadata) or progress up,
    /// nothing running, something
    /// to extract, and the archive not in an excluded folder (`extractHereExcludedFolders`). The URL
    /// is read now: UIDocument updates it on a move, and `fileURLChanges` tells views reading this.
    var canExtractHere: Bool { canExtractHere(extractTargets()) }

    /// The document's URL now, read through `fileURLChanges` so a view reading it updates on a move.
    private var archiveURL: URL {
        _ = fileURLChanges
        return document.fileURL
    }

    /// `canExtractHere` for `paths` (nil: everything): a row's context menu asks for its item.
    func canExtractHere(_ paths: [String]?) -> Bool {
        extractHereRequest == nil && isReadyForExtractHere(paths)
    }

    /// `canExtractHere` without the request: also checked after a pick, before extracting.
    private func isReadyForExtractHere(_ paths: [String]?) -> Bool {
        guard let model, !isBusy, pendingExtraction == nil, extractionQuestion == nil, pendingReplacement == nil,
              !macMetadataQuestion, presentedAlert == nil, progress == nil, runningOperations == 0,
              extractHereLocation.allowsExtractHere(at: archiveURL, excluding: extractHereExcludedFolders)
        else { return false }
        return ExtractHerePlan.make(paths, in: model, archiveURL: archiveURL) != nil
    }

    /// Extracts `paths` (nil: everything) next to the archive, under the progress sheet. Without a
    /// grant covering the archive's folder, raises the `.grant` picker instead and extracts once a
    /// folder is picked (`extractHereFolderPicked`). Does nothing when `canExtractHere` is off for
    /// `paths`, so ⌥⌘E or a stray call can't get around the gate.
    func extractHere(_ paths: [String]?) async {
        guard canExtractHere(paths) else { return }
        let folder = document.fileURL.deletingLastPathComponent()
        guard let access = folderAccessStore.access(for: folder) else {
            extractHereRequest = ExtractHereRequest(step: .grant, paths: paths, folder: folder)
            return
        }
        defer { access.stop() }
        await runExtractHere(paths, in: folder, isArchiveFolder: true)
    }

    /// The Files picker of `.grant` or `.otherFolder` returned `picked` (nil: cancelled). For
    /// `.grant`, the pick is checked against the folder the archive is in now, not the request's
    /// (it may have moved while the picker was up): that folder or one above it is granted and the
    /// extraction runs there (if access to it won't start, an alert says so); another folder
    /// brings the `.notContaining` alert for it. For
    /// `.otherFolder`, the result goes there, and no grant is kept. A save or Text Encoding's reopen
    /// that started meanwhile gets the alert (`refuseExtractHereIfBusy`).
    func extractHereFolderPicked(_ picked: URL?) async {
        guard let request = extractHereRequest, request.step == .grant || request.step == .otherFolder else { return }
        guard let picked else {
            extractHereRequest = nil
            return
        }
        let accessing = picked.startAccessingSecurityScopedResource()
        defer { if accessing { picked.stopAccessingSecurityScopedResource() } }
        if request.step == .otherFolder {
            extractHereRequest = nil
            guard isReadyForExtractHere(request.paths) else { return refuseExtractHereIfBusy(request.paths) }
            await runExtractHere(request.paths, in: picked, isArchiveFolder: false)
            return
        }
        let folder = document.fileURL.deletingLastPathComponent()
        guard FolderAccessStore.covers(picked, folder) else {
            extractHereRequest = ExtractHereRequest(step: .notContaining, paths: request.paths, folder: folder)
            return
        }
        extractHereRequest = nil
        do {
            try folderAccessStore.grant(picked)
        } catch {
            alert = AlertContent(title: Self.extractHereFailureTitle(request.paths, in: model, archiveURL: document.fileURL),
                                 message: error.localizedDescription)
            return
        }
        guard isReadyForExtractHere(request.paths) else { return refuseExtractHereIfBusy(request.paths) }
        // Just granted and covering the archive, so access didn't start: the bookmark didn't
        // resolve or the security scope didn't open. The picker again would loop without a reason.
        guard let access = folderAccessStore.access(for: folder) else {
            alert = AlertContent(title: Self.extractHereFailureTitle(request.paths, in: model, archiveURL: document.fileURL),
                                 message: String(localized: "The folder you chose couldn't be opened. Try again.",
                                                 comment: "Extract Here alert message: Files gave a folder, but the app couldn't get access to it"))
            return
        }
        defer { access.stop() }
        await runExtractHere(request.paths, in: folder, isArchiveFolder: true)
    }

    /// A pick came back while a save or Text Encoding's reopen runs: nothing is extracted, and the
    /// alert says why, as Add's does (`refuseAddingWhileBusy`). The gate's other reasons stay
    /// silent: the archive closed, or another question or sheet is up and speaks for itself.
    private func refuseExtractHereIfBusy(_ paths: [String]?) {
        guard isBusy else { return }
        alert = AlertContent(title: Self.extractHereFailureTitle(paths, in: model, archiveURL: document.fileURL),
                             message: busyMessage)
    }

    /// The alert of `extractHereRequest`, if it asks a question not yet answered: the pick that
    /// doesn't hold the archive, or the read-only volume. The folder's name is read only then.
    var extractHereAlert: AlertContent? {
        guard let request = extractHereRequest, request.asksQuestion else { return nil }
        func folderName() -> String {
            (try? request.folder.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
                ?? request.folder.lastPathComponent
        }
        switch request.step {
        case .notContaining:
            let name = folderName()
            let message = String(localized: "Choose “\(name)” or a folder that contains it.",
                                 comment: "Extract Here alert message: %@ is the archive's folder as Files names it")
            let title = String(localized: "That folder doesn't contain “\(name)”.")
            return AlertContent(title: title, message: message)
        case .readOnly:
            return AlertContent(title: String(localized: "“\(folderName())” is on a read-only volume."),
                                message: String(localized: "Choose another folder to extract into."))
        case .grant, .otherFolder:
            return nil
        }
    }

    /// OK on the `.notContaining` alert: the alert goes, and the picker comes back once it has
    /// (`extractHereAlertDidGo`).
    func pickAgainForExtractHere() {
        if extractHereRequest?.step == .notContaining { answerExtractHere() }
    }

    /// Choose Another Folder… on the read-only alert: the alert goes, and the picker for any
    /// folder comes once it has (`extractHereAlertDidGo`).
    func chooseAnotherFolderForExtractHere() {
        if extractHereRequest?.step == .readOnly { answerExtractHere() }
    }

    /// The answer: the question goes at once, and its picker comes after `extractHereAlertDidGo` and
    /// `extractHereAlertSettle`, or `extractHereAlertFallback` after now without it.
    private func answerExtractHere() {
        guard extractHereRequest?.asksQuestion == true else { return }
        extractHereRequest?.answer()
        scheduleExtractHereHandOff(settling: false)
    }

    /// Extract Here's alert condition has gone false (`FolderScreen`'s `onChange`, not the alert
    /// binding's setter, which UIKit calls while still dismissing or not at all): after an answer,
    /// the picker once `extractHereAlertSettle` has passed. Nothing without an answer (something
    /// else took the screen; the alert comes back), or when the hand-off already settles.
    func extractHereAlertDidGo() {
        guard extractHereRequest?.isAnswered == true, !extractHereHandOffSettles else { return }
        scheduleExtractHereHandOff(settling: true)
    }

    /// Schedules `extractHereAlertDidDismiss` after the settle or the fallback, in place of the one
    /// scheduled before. It does nothing if the request has changed meanwhile.
    private func scheduleExtractHereHandOff(settling: Bool) {
        extractHereHandOff?.cancel()
        extractHereHandOffSettles = settling
        guard let request = extractHereRequest,
              let delay = settling ? extractHereAlertSettle : extractHereAlertFallback else {
            extractHereHandOff = nil
            return
        }
        extractHereHandOff = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, self.extractHereRequest == request else { return }
            self.extractHereAlertDidDismiss()
        }
    }

    /// Extract Here's alert has gone: after OK or Choose Another Folder…, the request moves on to
    /// its picker (`FolderScreen` brings it up on the change), once: a second call, or a hand-off
    /// still waiting, does nothing. Without an answer the question stays, and its alert comes back.
    func extractHereAlertDidDismiss() {
        guard extractHereRequest?.isAnswered == true else { return }
        cancelExtractHereHandOff()
        extractHereRequest?.alertDidDismiss()
    }

    /// The hand-off waiting for the alert's going stops.
    private func cancelExtractHereHandOff() {
        extractHereHandOff?.cancel()
        extractHereHandOff = nil
        extractHereHandOffSettles = false
    }

    /// The Files picker has gone, or the level came on screen with none up. A request still waiting
    /// on a picker got no pick and no cancel back from it (it never came up, or went without a
    /// word): it is cancelled, so Extract Here and ⌥⌘E don't stay off until the archive is opened
    /// again. Called a turn after the picker's own callbacks (`FolderScreen`), so a pick or cancel
    /// they report is handled first; a question or a request already handled is left alone.
    func extractHerePickerDidClose() {
        if extractHereRequest?.waitsOnPicker == true { extractHereRequest = nil }
    }

    /// Cancel on Extract Here's alert or picker: nothing is extracted.
    func cancelExtractHere() {
        cancelExtractHereHandOff()
        extractHereRequest = nil
    }

    /// Extracts under the progress sheet into `directory`. A read-only volume there, when it is the
    /// archive's folder, brings the `.readOnly` question; any other failure the alert, with Extract's
    /// title; a cancel nothing.
    private func runExtractHere(_ paths: [String]?, in directory: URL, isArchiveFolder: Bool) async {
        guard let model, let plan = ExtractHerePlan.make(paths, in: model, archiveURL: document.fileURL) else { return }
        var run = extractHereRun
        #if DEBUG
        if isArchiveFolder, ExtractHereTestHooks.takeReadOnly() {
            run = { _, _, _, _ in throw CocoaError(.fileWriteVolumeReadOnly) }
        }
        #endif
        do {
            _ = try await perform(Self.extractHereTitle(plan)) { progress in
                try await run(plan, model, directory, progress)
            }
        } catch let error where isArchiveFolder && ExtractHereService.isReadOnlyVolume(error) {
            extractHereRequest = ExtractHereRequest(step: .readOnly, paths: paths, folder: directory)
        } catch {
            report(error, title: Self.extractHereFailureTitle(plan))
        }
    }

    private static func extractHereTitle(_ plan: ExtractHerePlan) -> String {
        switch plan {
        case .single(_, let name, _): String(localized: "Extracting “\(name)”…")
        case .wrapped(_, let paths): String(localized: "Extracting \(paths.count) items…")
        }
    }

    private static func extractHereFailureTitle(_ plan: ExtractHerePlan) -> String {
        switch plan {
        case .single(_, let name, _): String(localized: "Couldn't extract “\(name)”")
        case .wrapped(_, let paths): String(localized: "Couldn't extract \(paths.count) items")
        }
    }

    private static func extractHereFailureTitle(_ paths: [String]?, in model: ArchiveModel?, archiveURL: URL) -> String {
        guard let model, let plan = ExtractHerePlan.make(paths, in: model, archiveURL: archiveURL) else {
            return String(localized: "Couldn't extract")
        }
        return extractHereFailureTitle(plan)
    }
}

#if DEBUG
/// The iOS UI tests' stand-ins (`ExtractHereLaunchArguments`), each taken once per launch: the
/// folder `-KernirExtractHereGrant` names, as if picked in the `.grant` picker, so the picker comes up
/// as usual after it; and `-KernirExtractHereReadOnly`'s read-only failure.
@MainActor
enum ExtractHereTestHooks {
    private static var isGrantTaken = false
    private static var isReadOnlyTaken = false

    /// The hook's folder the first time; nil after that, or without the argument.
    static func takeGrant() -> URL? {
        guard !isGrantTaken, let folder = ExtractHereLaunchArguments.current.extractHereGrant else { return nil }
        isGrantTaken = true
        return folder
    }

    /// True the first time with the argument.
    static func takeReadOnly() -> Bool {
        guard !isReadOnlyTaken, ExtractHereLaunchArguments.current.failsExtractHereAsReadOnly else { return false }
        isReadOnlyTaken = true
        return true
    }
}
#endif
