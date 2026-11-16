import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KernirCore
import os

/// The save options of one save panel: what `SaveOptionsView` edits, and the panel's delegate,
/// which refuses Save while the settings have problems. With Split on the panel
/// saves a folder that will hold the set, and refuses a folder a split save must not replace.
@MainActor @Observable
final class SavePanelOptions: NSObject, NSOpenSavePanelDelegate {
    var settings: ArchiveSaveSettings
    /// The parts of the split archive being saved; empty for one file. Save never lands on one.
    let volumeURLs: [URL]
    /// What a split save must never replace (`isUnsafeSplitDestination`): the open archive's files
    /// (the document and every part of its set) and every pending addition's URL.
    let sourceURLs: [URL]
    /// The archive's comment as the Info popover shows it (`ArchiveModel.commentText`): the typed one, else the
    /// source's; "" for none or a removed one. One file keeps it where the format has comments; a split set never
    /// does (`droppedCommentNote`).
    let comment: String

    @ObservationIgnored private weak var panel: NSSavePanel?
    /// Whether the panel is set up for a split save's folder rather than an archive file.
    @ObservationIgnored private var panelShowsFolder = false
    /// The archive name the panel had before it turned to a folder, given back when Split goes off.
    @ObservationIgnored private var archiveName: String?
    /// The folder name before any number was added ("Photos"), proposed again in another folder.
    @ObservationIgnored private var folderBaseName: String?
    /// The folder name last put in the name field; a name the user typed is never replaced.
    @ObservationIgnored private var proposedFolderName: String?

    init(settings: ArchiveSaveSettings, volumeURLs: [URL] = [], sourceURLs: [URL] = [], comment: String = "") {
        self.settings = settings
        self.volumeURLs = volumeURLs
        self.sourceURLs = sourceURLs
        self.comment = comment
    }

    /// Says that the save won't write `comment`: the chosen format has none (7z, TAR…), or Split is on, as a
    /// split set holds no comment. The format drops it without asking; a split save drops the
    /// source's and refuses a typed one (`ArchiveModel.splitSaveProblem`). nil when there is no comment or
    /// the save keeps it.
    var droppedCommentNote: String? {
        guard !comment.isEmpty else { return nil }
        if !ArchiveCommentText.supportsComments(format) {
            return String(localized: "\(format.displayName) archives can’t have a comment.",
                          comment: "Save panel note: the chosen format (%@: 7z, TAR…) has no archive comment; it is left out.")
        }
        return isSplitting ? String(localized: "A split archive can’t have a comment.", table: "Shared") : nil
    }

    /// The format, keeping the options and the panel's file type and extension in step with it.
    var format: ArchiveFormat {
        get { settings.format }
        set {
            settings.format = newValue
            settings.formatDidChange()
            updatePanel()
        }
    }

    /// The split choice, keeping the panel's type and name in step with it: a folder while splitting.
    var split: VolumeSplit {
        get { settings.split }
        set {
            settings.split = newValue
            updatePanel()
        }
    }

    /// Whether this save writes a split set into a folder: Split is on, for a format that can split.
    var isSplitting: Bool { settings.format.supportsVolumes && settings.split != .none }

    /// Shows the options in `panel`. The panel keeps them only while this object lives.
    /// `fileName` is the document's own ("s2-plain.tar.gz"), which the proposal starts from.
    func attach(to panel: NSSavePanel, fileName: String?) {
        self.panel = panel
        // NSDocument sets no delegate on its save panel; never replace one that is there.
        if panel.delegate == nil {
            panel.delegate = self
        } else {
            Self.logger.fault("Save panel already has a delegate; save options are not validated")
        }
        panel.isExtensionHidden = false
        let hostingView = SaveOptionsHostingView(rootView: SaveOptionsView(options: self))
        hostingView.frame.size = hostingView.fittedSize
        panel.accessoryView = hostingView
        updatePanel(name: fileName)
    }

    /// Allowed types first, then the name, once: the panel takes its current type from the
    /// name's last extension, and a name set while that type wasn't allowed yet got it appended
    /// ("x.tar.gz.gz"). The proposal's "tgz" makes the format's own type current, so a bare
    /// name gets "tgz"; "gz" stays allowed, so a typed "x.tar.gz" is kept.
    ///
    /// Splitting, the panel saves a folder (`[.folder]` adds no extension, q2), named when the panel
    /// turns to one: "Photos.zip" → "Photos", or "Photos 2" when that is taken. Changing the size,
    /// or between 7z and ZIP, keeps the name. Split off gives the archive name back, unless the
    /// user typed another one meanwhile.
    private func updatePanel(name: String? = nil) {
        guard let panel else { return }
        // A set proposes its own name, not its part's ("s7.7z.001" → "s7.7z", or "s7" for a folder);
        // later calls start from the name field, which no longer has the part suffix.
        let isVolumeSet = name != nil && volumeURLs.count > 1
        if isSplitting {
            panel.allowedContentTypes = [.folder]
            if name != nil || !panelShowsFolder {
                let current = name ?? panel.nameFieldStringValue
                archiveName = ArchiveSaveSettings.savePanelProposal(
                    current, for: settings.format, isVolumeSet: isVolumeSet)
                folderBaseName = ArchiveSaveSettings.splitFolderProposal(current, isVolumeSet: isVolumeSet)
                proposeFolderName(in: panel.directoryURL)
            }
        } else {
            panel.allowedContentTypes = KernirDocumentTypes.savePanelTypes(for: settings.format)
            var current = name ?? panel.nameFieldStringValue
            if name == nil, panelShowsFolder, current == proposedFolderName, let archiveName {
                current = archiveName
            }
            panel.nameFieldStringValue = ArchiveSaveSettings.savePanelProposal(
                current, for: settings.format, isVolumeSet: isVolumeSet)
            proposedFolderName = nil
        }
        panelShowsFolder = isSplitting
    }

    /// Puts the split folder's name in the name field: the base name, numbered past any name taken
    /// in `directory` (q3 rule (b)). No directory known: the base name, unchecked; `validate`
    /// still refuses what may not be replaced.
    private func proposeFolderName(in directory: URL?) {
        guard let panel, let folderBaseName else { return }
        let name = ArchiveSaveSettings.freeSplitFolderName(folderBaseName, in: directory)
        panel.nameFieldStringValue = name
        proposedFolderName = name
    }

    // MARK: - NSOpenSavePanelDelegate

    /// Called when the user clicks Save: an error keeps the panel open and shows its message.
    /// For a folder that exists it runs only after the system "Replace?" sheet (q3), so a split
    /// save refuses here what it must not replace, and nothing has been touched yet.
    func panel(_ sender: Any, validate url: URL) throws {
        if ArchiveSaveSettings.isVolumePart(url, of: volumeURLs) {
            throw SaveOntoVolumePartError(name: url.lastPathComponent)
        }
        if isSplitting, let error = SplitSetPlacement.splitDestinationError(url, sources: sourceURLs) {
            throw error
        }
        if let problem = settings.problems.first { throw Self.error(for: problem) }
    }

    /// The error that refuses a save for `problem`: its message, as the panel shows it.
    nonisolated static func error(for problem: ArchiveSaveSettings.Problem) -> NSError {
        NSError(domain: "com.kernir.app.save-options", code: 1, userInfo: [NSLocalizedDescriptionKey: problem.message])
    }

    /// The user moved to another folder: a split folder name this proposed is proposed again there,
    /// numbered past the names taken in it. A name the user typed stays.
    func panel(_ sender: Any, didChangeToDirectoryURL url: URL?) {
        guard panelShowsFolder, let panel, panel.nameFieldStringValue == proposedFolderName else { return }
        proposeFolderName(in: url)
    }

    private static let logger = Logger(subsystem: "com.kernir.app", category: "document")
}

/// The save options as the panel's accessory, its frame kept at the content's fitting size: the panel lays out the
/// accessory by its frame, which an `NSHostingView` never changes itself, so a note or the password fields that came
/// later were cut off and the form slid up under the panel's header. SwiftUI lays the view out again on each change;
/// the fit runs on the next turn of the run loop, out of that layout pass. The size is rounded up per side: a
/// fractional one (363.5) that the panel rounds would set off another fit on every layout.
final class SaveOptionsHostingView: NSHostingView<SaveOptionsView> {
    var fittedSize: NSSize {
        let size = fittingSize
        return NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }

    override func layout() {
        super.layout()
        guard frame.size != fittedSize else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(fitFrame), object: nil)
        perform(#selector(fitFrame), with: nil, afterDelay: 0, inModes: [.common])
    }

    @objc private func fitFrame() {
        let size = fittedSize
        if frame.size != size { setFrameSize(size) }
    }
}

/// Save As chose a part of the split archive being saved: a set is read-only, so it is refused.
struct SaveOntoVolumePartError: LocalizedError {
    let name: String

    var errorDescription: String? {
        String(localized: "“\(name)” is a part of this archive. Choose another name.")
    }
}

/// A split save chose a folder that is, holds, or lies inside the archive being saved or a file
/// being added: replacing it would delete what the set is made from.
struct SplitOntoSourceError: LocalizedError {
    let name: String

    var errorDescription: String? {
        String(localized: "Saving to “\(name)” would replace this archive or files being added to it. Choose another name.")
    }
}

/// A split save chose an existing item that is not an earlier set's folder
/// (`ArchiveSaveSettings.isReplaceableSetFolder`): replacing it would lose other files.
/// Its text is in the Shared table, for iOS too.
struct NotASplitSetFolderError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Only a folder holding an earlier split archive can be replaced.", table: "Shared")
    }
}

/// A split save put its set in a temporary folder but couldn't replace the earlier set folder with it,
/// after the Trash had failed too, or couldn't move it in after the Trash had taken the earlier set
/// folder. The new set is kept (`setFolder`), so nothing is lost.
struct SplitSetNotPlacedError: LocalizedError {
    let name: String
    /// The folder holding the new set, kept: where it was written, or where `replaceItemAt` says it
    /// moved it (`SplitSetPlacement.newItemLocationKey`) when something is there.
    let setFolder: URL
    /// Where the earlier folder is when `replaceItemAt` says it moved it
    /// (`SplitSetPlacement.originalItemLocationKey`) and it didn't go back: its name was taken by then,
    /// or the move back failed. Nil when there is no key (it stayed in place), when it went back, and
    /// when nothing is at the place the key names, so the error never names a place that isn't there.
    let originalLocation: URL?
    /// The earlier set folder went to the Trash, and then the new set couldn't be moved in.
    /// `originalLocation` is nil then: the folder is where the Trash put it.
    let earlierFolderInTrash: Bool
    /// The Trash threw, but the earlier set folder was gone by then, and then the new set couldn't be
    /// moved in. The Trash may have moved it before it threw, so it may be there.
    let earlierFolderMayBeInTrash: Bool
    let underlying: any Error

    init(name: String, setFolder: URL, originalLocation: URL?, underlying: any Error) {
        self.init(name: name, setFolder: setFolder, originalLocation: originalLocation, earlierFolderInTrash: false,
                  earlierFolderMayBeInTrash: false, underlying: underlying)
    }

    /// The Trash took the earlier set folder, then the new set couldn't be moved in.
    static func earlierFolderInTrash(name: String, setFolder: URL, underlying: any Error) -> Self {
        Self(name: name, setFolder: setFolder, originalLocation: nil, earlierFolderInTrash: true,
             earlierFolderMayBeInTrash: false, underlying: underlying)
    }

    /// The Trash threw once the earlier set folder was gone, then the new set couldn't be moved in.
    static func earlierFolderMayBeInTrash(name: String, setFolder: URL, underlying: any Error) -> Self {
        Self(name: name, setFolder: setFolder, originalLocation: nil, earlierFolderInTrash: false,
             earlierFolderMayBeInTrash: true, underlying: underlying)
    }

    private init(name: String, setFolder: URL, originalLocation: URL?, earlierFolderInTrash: Bool,
                 earlierFolderMayBeInTrash: Bool, underlying: any Error) {
        self.name = name
        self.setFolder = setFolder
        self.originalLocation = originalLocation
        self.earlierFolderInTrash = earlierFolderInTrash
        self.earlierFolderMayBeInTrash = earlierFolderMayBeInTrash
        self.underlying = underlying
    }

    var errorDescription: String? {
        String(localized: "Lutik couldn't replace “\(name)”.")
    }

    var recoverySuggestion: String? {
        var lines = [underlying.localizedDescription]
        if let originalLocation {
            lines.append(String(localized: "The earlier folder is now at “\(originalLocation.path)”."))
        } else if earlierFolderInTrash {
            lines.append(String(localized: "The earlier folder is in the Trash."))
        } else if earlierFolderMayBeInTrash {
            lines.append(String(localized: "The earlier folder may be in the Trash."))
        }
        lines.append(String(localized: "The new volumes are in “\(setFolder.path)”."))
        // `setFolder` is a temporary folder, which can be cleared; so is `originalLocation` when set, and
        // the Trash can be emptied.
        if originalLocation != nil || earlierFolderInTrash || earlierFolderMayBeInTrash {
            lines.append(String(localized:
                "Move the earlier folder and the new volumes to another folder to keep them. Temporary folders can be cleared at any time."))
        } else {
            lines.append(String(localized:
                "Move them to another folder to keep them. Temporary folders can be cleared at any time."))
        }
        return lines.joined(separator: " ")
    }
}

/// A split save replacing an earlier set in place (on SMB, where the item-replacement
/// directory was refused) found the set's folder changed while the new set was written: an item came in
/// or went. Nothing was replaced, and the new volumes were removed again.
struct SplitSetChangedError: LocalizedError {
    /// The set's folder name.
    let name: String

    var errorDescription: String? {
        String(localized: "“\(name)” changed while saving.",
               comment: "Split save alert title: replacing an earlier split archive in its own folder (a network share) stopped because the folder changed while the new volumes were written. %@ = the folder's name.")
    }

    var recoverySuggestion: String? {
        String(localized: "Nothing was replaced.",
               comment: "Split save alert text, after the title “%@ changed while saving.”: the earlier split archive is as it was, and the new volumes were removed.")
    }
}

/// A split save replacing an earlier set in place (on SMB) removed some or all of the earlier volumes,
/// then couldn't finish: the new volumes not moved in yet are in `recoveredFolder` inside the set's
/// folder, "Lutik Recovered" (or "Lutik Recovered 2", … when that name was taken). The alert offers
/// Show in Finder: a `RecoverableError`, which Foundation bridges to the `NSError` recovery options and
/// attempter that NSDocument's error alert shows as buttons.
struct SplitSetPartlyReplacedError: LocalizedError, RecoverableError {
    /// The set's folder name.
    let name: String
    /// What Show in Finder selects: the folder holding the new volumes not moved in, "Lutik Recovered"
    /// (or the first free "Lutik Recovered 2", …); the set's folder when every rename failed and they
    /// stayed in the hidden staging folder, which Finder doesn't show.
    let recoveredFolder: URL

    var errorDescription: String? {
        String(localized: "“\(name)” was only partly replaced.",
               comment: "Split save alert title: replacing an earlier split archive in its own folder (a network share) removed earlier volumes, then stopped. %@ = the folder's name.")
    }

    var recoverySuggestion: String? {
        String(localized: "The new volumes are in the folder “Lutik Recovered” inside it. Some earlier volumes may have been moved to the Trash or deleted.",
               comment: "Split save alert text, after the title “%@ was only partly replaced.”. “Lutik Recovered” is the name of the folder Lutik made inside the split archive's folder (not translated: it is the folder's name on disk); “it” = that split archive's folder.")
    }

    var recoveryOptions: [String] {
        [String(localized: "OK", comment: "Alert button that only closes the alert."),
         String(localized: "Show in Finder",
                comment: "Alert button that opens a Finder window with the item selected.")]
    }

    /// Show in Finder (option 1) selects `recoveredFolder`; OK does nothing. False either way: nothing
    /// was recovered, so the save stays failed.
    func attemptRecovery(optionIndex recoveryOptionIndex: Int) -> Bool {
        if recoveryOptionIndex == 1 {
            let folder = recoveredFolder
            Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        }
        return false
    }
}

/// Where a split save may put its set, and how the finished set gets there. The engine
/// writes the volumes into an empty folder of their own (`makeFolder(for:)`); `place(_:at:sources:)` then
/// moves that folder to the save panel's URL. Nothing at the URL: a plain move. An earlier set folder
/// there: it goes to the Trash first by design, so it can be recovered.
///
/// When the item-replacement directory is refused (an SMB share under the sandbox: smbfs
/// has no .TemporaryItems, and the panel's grant doesn't cover the folder Foundation then tries beside the
/// destination), a save to a free name writes the set in place, into a folder made at the panel's URL;
/// a save over an earlier set writes it into a staging folder inside the set's folder, then swaps the
/// volumes (`replaceInPlace`); see `makeFolder(for:replacing:)`.
struct SplitSetPlacement: Sendable {
    /// Moves an item to the Trash: `FileManager.trashItem` except in tests, which never use the real Trash.
    var trashItem: @Sendable (URL) throws -> Void
    /// Replaces the item at the first URL with the one at the second, with no backup item:
    /// `FileManager.replaceItemAt` except in tests. Used only when the Trash fails.
    var replaceItem: @Sendable (_ original: URL, _ replacement: URL) throws -> Void
    /// Makes an item-replacement directory for items going into the given folder:
    /// `FileManager.url(for: .itemReplacementDirectory, …)` except in tests, which make it throw.
    var replacementDirectory: @Sendable (_ appropriateFor: URL) throws -> URL = { directory in
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory,
                                    create: true)
    }
    /// Removes one file when the Trash fails in a replace in place: `unlink`, which never removes a
    /// folder (so never recursively), except in tests.
    var removeFile: @Sendable (URL) throws -> Void = { url in
        guard unlink(url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    /// renamex_np(2): 0, or the error number; `moveExclusively` uses it. Tests swap it (smbfs: ENOTSUP).
    var renameFile: @Sendable (_ from: String, _ to: String, _ flags: UInt32) -> Int32 = { from, to, flags in
        renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    /// Runs right before each earlier entry's recheck in a replace in place (step 3): nothing, except
    /// in tests, which change the set's folder there (the window after the step 2 check).
    var beforeRemoval: @Sendable (URL) -> Void = { _ in }

    static let live = SplitSetPlacement(
        trashItem: { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) },
        replaceItem: { original, replacement in
            _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement, backupItemName: nil,
                                                      options: [])
        }
    )

    /// The user-info key under which a failed `replaceItemAt` gives the URL the original item was moved
    /// to. Documented for `FileManager.replaceItemAt`, but the SDK declares no constant for it.
    static let originalItemLocationKey = "NSFileOriginalItemLocationKey"
    /// The same for the URL the replacement item was moved to.
    static let newItemLocationKey = "NSFileNewItemLocationKey"

    /// Why a split save may not put its set at `url`, nil when it may. The panel's `validate` and the
    /// recheck right before the move into place both ask here, so they refuse alike:
    /// `url` is, holds or lies inside one of `sources` (`isUnsafeSplitDestination`), or something is
    /// there that isn't an earlier set's folder (`isReplaceableSetFolder`, rule (a)).
    static func splitDestinationError(_ url: URL, sources: [URL]) -> (any Error)? {
        if ArchiveSaveSettings.isUnsafeSplitDestination(url, sources: sources) {
            return SplitOntoSourceError(name: url.lastPathComponent)
        }
        if ArchiveSaveSettings.isNameTaken(url), !ArchiveSaveSettings.isReplaceableSetFolder(url) {
            return NotASplitSetFolderError()
        }
        return nil
    }

    /// Where a split save writes its set: the folder `makeFolder(for:replacing:)` made, and whether it is
    /// the destination itself (`inPlace`, the item-replacement directory was refused) rather than alone in a
    /// temporary folder of its own.
    struct Folder: Sendable {
        let url: URL
        let inPlace: Bool
        /// Set when `url` is a staging folder inside an earlier set's folder: what is replaced.
        var replacement: Replacement? = nil
    }

    /// The earlier set's folder and its entries as `isReplaceableSetFolder` approved them, recorded
    /// before the staging folder was made: what the replace may remove, and what the folder must still
    /// hold (with the staging folder) right before.
    struct Replacement: Sendable {
        let destination: URL
        let entries: [ArchiveSaveSettings.FolderEntry]
        /// `destination` itself (named ".") and the staging folder as made, by `lstat` (no follow): type,
        /// device and inode, rechecked before anything is removed, like each entry's.
        let folder: ArchiveSaveSettings.FolderEntry
        let staging: ArchiveSaveSettings.FolderEntry
        /// The item-replacement directory's refusal: thrown again when the first removal fails.
        let denied: any Error
    }

    /// The staging folder's name prefix, then a UUID: `.kernir-replace-<uuid>`.
    static let stagingPrefix = ".kernir-replace-"
    /// The visible folder a failed replace in place leaves the new volumes in, inside the set's folder.
    static let recoveredFolderName = "Lutik Recovered"

    /// A new empty folder named like `destination`, alone in a temporary folder of its own on the same
    /// volume (the item-replacement directory), for the engine to write the set into.
    ///
    /// When `replacementDirectory` throws (any error), the error is logged, and with nothing at
    /// `destination` the folder is made there, in place: an exclusive create, no check first, so it fails
    /// when anything (also a case-variant twin) is there, and only a folder this create made is marked
    /// `inPlace`. When the create fails for any reason, the replacement directory's own error is thrown.
    /// A crash mid-write leaves a partial set at `destination`; nothing is lost.
    ///
    /// `replacing` (the panel's Replace) with the replacement directory refused: when the folder at
    /// `destination` is an earlier set's (`isReplaceableSetFolder`), its entries are recorded and an
    /// empty staging folder `.kernir-replace-<uuid>` is made inside it, exclusively, for the engine to
    /// write into (`Folder.replacement`). When it isn't, or the create fails, the replacement directory's
    /// own error is thrown. A crash mid-write leaves the staging folder, and the earlier set as it was.
    func makeFolder(for destination: URL, replacing: Bool = false) throws -> Folder {
        let target = Self.plain(destination)
        let container: URL
        do {
            container = try replacementDirectory(target.deletingLastPathComponent())
        } catch {
            return try makeFolderInPlace(at: target, replacing: replacing, denied: error)
        }
        let folder = container.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            try? FileManager.default.removeItem(at: container)
            throw error
        }
        return Folder(url: folder, inPlace: false)
    }

    /// The fallback of `makeFolder(for:replacing:)` once `replacementDirectory` threw `denied`.
    private func makeFolderInPlace(at target: URL, replacing: Bool, denied: any Error) throws -> Folder {
        Self.logger.error("""
            The item-replacement directory for a split save was refused (\(Self.codes(of: denied), privacy: .public))
            """)
        if replacing { return try makeStagingFolder(in: target, denied: denied) }
        let folder = URL(fileURLWithPath: target.path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            Self.logger.error("""
                Making the split set's folder in place failed (\(Self.codes(of: error), privacy: .public))
                """)
            throw denied
        }
        Self.logger.notice("""
            Writing the split set in place: a crash mid-write leaves a partial set at the destination \
            (nothing is lost)
            """)
        return Folder(url: folder, inPlace: true)
    }

    /// Records the earlier set's entries, then makes the staging folder inside its folder.
    private func makeStagingFolder(in target: URL, denied: any Error) throws -> Folder {
        // The folder's identity before and after its entries are listed: one folder, not one swapped meanwhile.
        guard let folder = Self.entry(at: target, name: "."), folder.type == S_IFDIR,
              let entries = ArchiveSaveSettings.replaceableSetFolderEntries(target),
              Self.entry(at: target, name: ".") == folder else {
            Self.logger.error("The split save's destination isn't an earlier set's folder: not replacing in place")
            throw denied
        }
        let staging = URL(fileURLWithPath: target.path, isDirectory: true)
            .appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            Self.logger.error("""
                Making the split set's staging folder failed (\(Self.codes(of: error), privacy: .public))
                """)
            throw denied
        }
        guard let stagingEntry = Self.entry(at: staging, name: staging.lastPathComponent),
              stagingEntry.type == S_IFDIR else {
            Self.logger.error("The split set's staging folder can't be checked: not replacing in place")
            rmdir(Self.plain(staging).path)
            throw denied
        }
        Self.logger.notice("Replacing the earlier split set in place, through a staging folder inside it")
        return Folder(url: staging, inPlace: false,
                      replacement: Replacement(destination: target, entries: entries, folder: folder,
                                               staging: stagingEntry, denied: denied))
    }

    /// What is at `url` by `lstat` (no follow), as an entry named `name`: type, device and inode; nil when
    /// it can't be `lstat`ed.
    private static func entry(at url: URL, name: String) -> ArchiveSaveSettings.FolderEntry? {
        var info = stat()
        guard lstat(plain(url).path, &info) == 0 else { return nil }
        return ArchiveSaveSettings.FolderEntry(name: name, type: info.st_mode & S_IFMT, device: info.st_dev,
                                               inode: info.st_ino)
    }

    /// Removes a folder in a temporary folder of its own (`makeFolder(for:replacing:)` not `inPlace`),
    /// with the temporary folder around it.
    func discard(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    /// Removes a folder `makeFolder(for:replacing:)` made. Not `inPlace`: with its temporary folder
    /// (`discard(_:)`). `inPlace`: only `volumes`, the files the engine reported it wrote (none when the
    /// engine failed or was cancelled, as it removes its own), each with its AppleDouble "._" companion
    /// when one is there, then the folder by a plain `rmdir`. Never a recursive delete and never by name:
    /// anything else in the folder (a file dropped in meanwhile, even one named like a volume) stays, and
    /// so does the folder then. Never the folder above it, which is the user's. A staging folder
    /// `replacement`) goes the same way, and the earlier set's folder around it is never touched.
    func discard(_ folder: Folder, volumes: [URL] = []) {
        guard folder.inPlace || folder.replacement != nil else { return discard(folder.url) }
        Self.removeWritten(volumes, andFolder: folder.url, isStaging: folder.replacement != nil)
    }

    /// Unlinks `volumes` that are files right in `folder`, each with its AppleDouble "._" companion when
    /// one is there (by `lstat`, never following a link), then `rmdir`s `folder` (a staging folder:
    /// `removeStaging(_:)`): never recursive, never by name. Logs, and leaves the folder, when anything else
    /// is in it.
    private static func removeWritten(_ volumes: [URL], andFolder folder: URL, isStaging: Bool = false) {
        let path = plain(folder).path
        for volume in volumes where plain(volume).deletingLastPathComponent().path == path {
            let name = volume.lastPathComponent
            for entry in [name, "._" + name] {
                let entryPath = (path as NSString).appendingPathComponent(entry)
                var info = stat()
                if lstat(entryPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG { unlink(entryPath) }
            }
        }
        if isStaging { return removeStaging(folder) }
        if rmdir(path) != 0 {
            let code = errno
            logger.error("The split save's own folder stays, it holds other items (errno \(code, privacy: .public))")
        }
    }

    /// Removes a staging folder the new volumes left: a lone Finder `.DS_Store` in it first (a
    /// regular file by `lstat`), then a plain `rmdir`, then the AppleDouble "._" file beside it
    /// when it is a regular file (FAT, exFAT and a share without streams keep one). Logs, and
    /// leaves the folder, when anything else is in it.
    private static func removeStaging(_ staging: URL) {
        let folder = plain(staging)
        if let entries = ArchiveSaveSettings.folderEntries(folder), entries.count == 1,
           entries[0].name == ".DS_Store", entries[0].type == S_IFREG {
            unlink(folder.appendingPathComponent(".DS_Store", isDirectory: false).path)
        }
        guard rmdir(folder.path) == 0 else {
            let code = errno
            logger.error("""
                The split save's staging folder stays, it holds other items (errno \(code, privacy: .public))
                """)
            return
        }
        let companion = folder.deletingLastPathComponent()
            .appendingPathComponent("._" + folder.lastPathComponent, isDirectory: false).path
        var info = stat()
        if lstat(companion, &info) == 0, info.st_mode & S_IFMT == S_IFREG { unlink(companion) }
    }

    /// An error's domain and code, and its underlying error's: never a path or a description, which may hold one.
    static func codes(of error: any Error) -> String {
        let error = error as NSError
        var text = "\(error.domain) \(error.code)"
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += ", underlying \(underlying.domain) \(underlying.code)"
        }
        return text
    }

    /// Puts the finished set in `folder` at `destination`. Not `inPlace`: `place(_:at:sources:replacing:)`.
    /// `inPlace`, the folder is the destination already: no Trash and no move, only the Cancel check and
    /// the rules; when either stops it, `discard(_:volumes:)` removes `volumes` (what the engine wrote)
    /// and the folder if nothing else is in it.
    func place(_ folder: Folder, at destination: URL, sources: [URL], replacing: Bool, volumes: [URL]) throws {
        if let replacement = folder.replacement {
            return try replaceInPlace(replacement, staging: folder.url, sources: sources, volumes: volumes)
        }
        guard folder.inPlace else {
            return try place(folder.url, at: destination, sources: sources, replacing: replacing)
        }
        let target = Self.plain(destination)
        do {
            try Task.checkCancellation()
            guard Self.plain(folder.url).path == target.path else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: target])
            }
            if let error = Self.splitDestinationError(target, sources: sources) { throw error }
        } catch {
            discard(folder, volumes: volumes)
            throw error
        }
    }

    /// Swaps the earlier set in `replacement.destination` for the new one in `staging`, inside that
    /// folder, with no item-replacement directory:
    /// 1. A Cancel that came after the engine finished: `volumes` and `staging` go, nothing else.
    /// 2. Verify, before anything is removed: `volumes` are files in `staging`; the folder is no source
    ///    (`isUnsafeSplitDestination`); it holds exactly the recorded entries plus `staging`, by exact
    ///    name, type, device and inode, never by prefix (a Finder `.DS_Store`, which is never removed, may
    ///    come or go, and so may the staging folder's own AppleDouble "._" file); and it is still the
    ///    recorded folder (`lstat`, device and inode). Anything else (a file dropped in, a leftover staging
    ///    folder, an earlier volume gone or rewritten, the folder swapped): the new volumes and
    ///    `staging` go and `SplitSetChangedError` is thrown; nothing was replaced.
    /// 3. Each recorded volume, then each "._" file, rechecked right before (`lstat`: type, device, inode),
    ///    goes to the Trash; when the Trash fails, `removeFile` unlinks it (permanent: the user chose
    ///    Replace and the new set is complete). A "._" file already gone is no change (it goes with its
    ///    volume on FAT); a volume already gone was not removed by us, and, like another item at its name
    ///    (left alone), stops the replace: `SplitSetChangedError` when nothing was removed yet, else the
    ///    partly replaced case below. A removal that fails: the partly replaced case; the first one (nothing
    ///    removed): the new volumes and `staging` go and the item-replacement directory's own error is
    ///    thrown, with no recovered folder.
    /// 4. Each new volume moves up into the folder, never replacing anything (`moveExclusively`); any
    ///    failure: the partly replaced case. Then `staging` goes (`removeStaging`): a lone `.DS_Store` in it
    ///    first, then a plain `rmdir`; when anything else is left in it, it stays (logged).
    /// Partly replaced: `staging` is renamed to "Lutik Recovered", or the first free "Lutik Recovered 2", …, without
    /// replacing anything (kept hidden when that fails, and Show in Finder then selects the set's folder)
    /// and `SplitSetPartlyReplacedError` is thrown. Never a recursive delete; never the folder above.
    private func replaceInPlace(_ replacement: Replacement, staging: URL, sources: [URL], volumes: [URL]) throws {
        let target = replacement.destination
        do {
            try Task.checkCancellation()
        } catch {
            Self.removeWritten(volumes, andFolder: staging, isStaging: true)
            throw error
        }
        func nothingReplaced(_ problem: String) -> SplitSetChangedError {
            Self.logger.error("The earlier split set's folder changed while saving (\(problem, privacy: .public)): nothing replaced")
            Self.removeWritten(volumes, andFolder: staging, isStaging: true)
            return SplitSetChangedError(name: target.lastPathComponent)
        }
        if let problem = Self.replacementProblem(replacement, staging: staging, sources: sources, volumes: volumes) {
            throw nothingReplaced(problem)
        }
        // Volumes first, then their "._" files, each in name order.
        let removals = replacement.entries.filter { $0.name != ".DS_Store" }
            .sorted { ($0.name.hasPrefix("._") ? 1 : 0, $0.name) < ($1.name.hasPrefix("._") ? 1 : 0, $1.name) }
        var removed = 0
        for entry in removals {
            let outcome: EarlierRemoval
            do {
                outcome = try removeEarlier(target.appendingPathComponent(entry.name, isDirectory: false),
                                            recorded: entry)
            } catch {
                Self.logger.error("Removing an earlier split volume failed (\(Self.codes(of: error), privacy: .public))")
                guard removed > 0 else {
                    // Stopped before touching anything: no recovered folder.
                    Self.logger.error("Nothing earlier was removed: the new split volumes go, nothing replaced")
                    Self.removeWritten(volumes, andFolder: staging, isStaging: true)
                    throw replacement.denied
                }
                throw partlyReplaced(target, staging: staging)
            }
            switch outcome {
            case .removed:
                removed += 1
            case .gone where entry.name.hasPrefix("._"):
                // FAT, exFAT and a share without streams drop a volume's "._" file along with it.
                continue
            case .gone where removed == 0:
                throw nothingReplaced("an earlier volume was gone before its removal")
            case .gone:
                Self.logger.error("An earlier split volume was gone before its removal: stopping")
                throw partlyReplaced(target, staging: staging)
            case .changed where removed == 0:
                throw nothingReplaced("an earlier volume was replaced before its removal")
            case .changed, .changedAfterTrash:
                Self.logger.error("An earlier split volume was replaced before its removal: left alone, stopping")
                throw partlyReplaced(target, staging: staging)
            }
        }
        for volume in volumes {
            let code = moveExclusively(volume.path,
                                       to: target.appendingPathComponent(volume.lastPathComponent, isDirectory: false).path)
            if code != 0 {
                Self.logger.error("Moving a new split volume in failed (errno \(code, privacy: .public))")
                throw partlyReplaced(target, staging: staging)
            }
        }
        Self.removeStaging(staging)
    }

    /// Why the replace in place must stop before removing anything (step 2), nil when it may go on: a
    /// short reason for the log, never a path.
    private static func replacementProblem(_ replacement: Replacement, staging: URL, sources: [URL],
                                           volumes: [URL]) -> String? {
        // No new volume, nothing to put in place: removing the earlier set would leave an empty folder.
        if volumes.isEmpty { return "no new volumes" }
        let stagingPath = plain(staging).path
        for volume in volumes {
            var info = stat()
            guard plain(volume).deletingLastPathComponent().path == stagingPath,
                  lstat(volume.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                return "a new volume is missing"
            }
        }
        let target = replacement.destination
        if ArchiveSaveSettings.isUnsafeSplitDestination(target, sources: sources) { return "it holds a source" }
        guard let listed = ArchiveSaveSettings.folderEntries(target) else { return "it can't be listed" }
        // The staging folder's AppleDouble file (FAT, exFAT, a share without streams) is no change.
        let companion = "._" + staging.lastPathComponent
        let entries = listed.filter { !($0.name == companion && $0.type == S_IFREG) }
        let expected = replacement.entries + [replacement.staging]
        // Exact bytes: `String` equality would take an NFD twin of a name for the name itself.
        func ordered(_ entries: [ArchiveSaveSettings.FolderEntry]) -> [ArchiveSaveSettings.FolderEntry] {
            entries.filter { $0.name != ".DS_Store" }.sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        }
        let (have, want) = (ordered(entries), ordered(expected))
        let pairs = zip(have, want)
        guard have.count == want.count,
              pairs.allSatisfy({ $0.name.utf8.elementsEqual($1.name.utf8) && $0.type == $1.type }) else {
            return "its entries differ"
        }
        // Same names, other files: one rewritten under its name (a sync client, another save).
        // st_ino can follow the name on smbfs (servers without file IDs; otherwise it is the server's file
        // ID): a same-name rewrite then keeps its inode and this can't see it; the check falls back to the
        // name and type compare above (so does `isStill`).
        guard pairs.allSatisfy({ $0.device == $1.device && $0.inode == $1.inode }) else {
            return "an entry was replaced"
        }
        // Last, right before the removals: still the recorded folder, not another one (or a link) put there.
        return entry(at: target, name: ".") == replacement.folder ? nil : "the folder was replaced"
    }

    /// How step 3 went for one earlier entry.
    private enum EarlierRemoval {
        /// Removed by us: by the Trash or `removeFile`, or gone once either threw.
        case removed
        /// Gone before we touched it (removed by someone else after the step 2 check): not removed by us.
        case gone
        /// Another item is at its name (another type, device or inode): left alone, nothing removed.
        case changed
        /// The same, found once the Trash threw: it may have taken the recorded entry first.
        case changedAfterTrash
    }

    /// Step 3 for one earlier entry, rechecked against `entry` right before the Trash and again before
    /// `removeFile` (`isStill`): the Trash, else `removeFile`. Gone already: `gone`; gone once either
    /// threw: removed. Throws only when it is still there.
    private func removeEarlier(_ url: URL, recorded entry: ArchiveSaveSettings.FolderEntry) throws -> EarlierRemoval {
        beforeRemoval(url)
        switch Self.isStill(entry, at: url) {
        case nil: return .gone
        case false?: return .changed
        case true?: break
        }
        do {
            try trashItem(url)
            return .removed
        } catch {
            Self.logger.error("""
                Moving an earlier split volume to the Trash failed, deleting it (\(Self.codes(of: error), privacy: .public))
                """)
        }
        switch Self.isStill(entry, at: url) {
        case nil: return .removed
        case false?: return .changedAfterTrash
        case true?: break
        }
        do {
            try removeFile(url)
        } catch where !ArchiveSaveSettings.isNameTaken(url) {
            return .removed
        }
        return .removed
    }

    /// Whether the item at `url` is still the recorded `entry`, by `lstat` (no follow): type, device and
    /// inode. Nil when nothing is there; false when another item is, or it can't be checked. On smbfs the
    /// inode can follow the name (servers without file IDs; otherwise it is the server's file ID), so
    /// there only the type may tell a same-name rewrite (see `replacementProblem`).
    private static func isStill(_ entry: ArchiveSaveSettings.FolderEntry, at url: URL) -> Bool? {
        var info = stat()
        guard lstat(plain(url).path, &info) == 0 else { return errno == ENOENT ? nil : false }
        return info.st_mode & S_IFMT == entry.type && info.st_dev == entry.device && info.st_ino == entry.inode
    }

    /// `staging` renamed to "Lutik Recovered" in `target` without replacing anything; when that name
    /// is taken (EEXIST), to "Lutik Recovered 2", "3", … up to `maximumSplitFolderNumber`; kept as it is
    /// when no rename succeeds. The error names where the new volumes are; with the staging folder kept
    /// hidden, the set's folder, which Finder shows.
    private func partlyReplaced(_ target: URL, staging: URL) -> SplitSetPartlyReplacedError {
        var folder = staging
        var code = EEXIST
        var number = 1
        while code == EEXIST, number <= ArchiveSaveSettings.maximumSplitFolderNumber {
            let name = number == 1 ? Self.recoveredFolderName : "\(Self.recoveredFolderName) \(number)"
            let recovered = target.appendingPathComponent(name, isDirectory: true)
            code = moveExclusively(Self.plain(staging).path, to: recovered.path)
            if code == 0 { folder = recovered }
            number += 1
        }
        if code != 0 {
            Self.logger.error("The split save's staging folder keeps its hidden name (errno \(code, privacy: .public))")
            folder = target
        }
        return SplitSetPartlyReplacedError(name: target.lastPathComponent, recoveredFolder: folder)
    }

    /// Renames `source` to `target` without ever replacing what is there: RENAME_EXCL, which fails with
    /// EEXIST atomically; a volume without it (smbfs: ENOTSUP, `ArchiveModel.lacksExclusiveRename`) gets
    /// a check right before a plain rename, as KernirCore's `moveIntoPlace` and `UniquePlacement` do.
    /// 0, or the error number.
    private func moveExclusively(_ source: String, to target: String) -> Int32 {
        let code = renameFile(source, target, UInt32(RENAME_EXCL))
        guard ArchiveModel.lacksExclusiveRename(code) else { return code }
        if ArchiveSaveSettings.isNameTaken(URL(fileURLWithPath: target)) { return EEXIST }
        return renameFile(source, target, 0)
    }

    /// Moves the finished set in `folder` (from `makeFolder(for:replacing:)`, not `inPlace`) to
    /// `destination`. First checks `destination` again (TOCTOU): it may have changed
    /// since `validate`. An earlier
    /// set folder there goes to the Trash; if the Trash fails (no Trash on the volume, or no access),
    /// `replaceItemAt` replaces it instead, after one more check, or, when the earlier folder is
    /// gone by then, the set is moved in (a failed move then keeps the new set, as listed below, unless
    /// the new set is gone too).
    ///
    /// `replacing` says whether something was at `destination` when the save started (the panel's
    /// Replace). When it wasn't, anything there now came in while the set was written (another window
    /// saving to the same name), so it is refused with `fileWriteFileExists`, never trashed or replaced.
    ///
    /// A Cancel that came after the engine's last check still stops here, before anything is trashed.
    /// Any failure leaves `destination` as it was and discards `folder`, except:
    /// - the replace fails: the new set stays in `folder`, or where `replaceItemAt` moved it, and
    ///   `SplitSetNotPlacedError` says where;
    /// - the move fails after the Trash took the earlier set: the new set stays in
    ///   `folder`, and `SplitSetNotPlacedError` says so and that the earlier set is in the Trash;
    /// - the move fails after the Trash threw once the earlier set was gone: the same, but the
    ///   earlier set may be in the Trash;
    /// - either move fails with the new set gone too: the raw move error, as nothing is
    ///   left to keep; the earlier set is (or may be) in the Trash.
    func place(_ folder: URL, at destination: URL, sources: [URL], replacing: Bool) throws {
        let target = Self.plain(destination)
        var trashed = false
        var mayBeTrashed = false
        do {
            try Task.checkCancellation()
            // Before the rules: an item that came in is a taken name, whatever it is.
            if !replacing, ArchiveSaveSettings.isNameTaken(target) {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path,
                                                                  NSURLErrorKey: target])
            }
            if let error = Self.splitDestinationError(target, sources: sources) { throw error }
            // The check passed, so whatever is here is an earlier set's folder (or an empty one), and the
            // panel's Replace covers it.
            if ArchiveSaveSettings.isNameTaken(target) {
                do {
                    try trashItem(target)
                    trashed = true
                } catch where ArchiveSaveSettings.isNameTaken(target) {
                    Self.logger.error("""
                        Moving the earlier split folder to the Trash failed, replacing it instead: \
                        \(error.localizedDescription, privacy: .public)
                        """)
                    try replace(target, with: folder, sources: sources)
                    discard(folder)
                    return
                } catch {
                    // The earlier folder is gone: nothing to replace, so a plain move. `trashItem` may have
                    // moved it before it threw, so a failed move keeps the new set too.
                    mayBeTrashed = true
                    Self.logger.error("""
                        Moving the earlier split folder to the Trash failed and it is gone, moving the set in: \
                        \(error.localizedDescription, privacy: .public)
                        """)
                }
            }
            do {
                try FileManager.default.moveItem(at: folder, to: target)
            } catch where (trashed || mayBeTrashed) && ArchiveSaveSettings.isNameTaken(folder) {
                Self.logger.error("""
                    Moving the split set in failed after the earlier folder went (or may have gone) to the \
                    Trash; the new set stays in \(folder.path, privacy: .private): \
                    \(error.localizedDescription, privacy: .public)
                    """)
                let name = target.lastPathComponent
                throw trashed
                    ? SplitSetNotPlacedError.earlierFolderInTrash(name: name, setFolder: folder, underlying: error)
                    : SplitSetNotPlacedError.earlierFolderMayBeInTrash(name: name, setFolder: folder, underlying: error)
            }
        } catch let error as SplitSetNotPlacedError {
            throw error
        } catch {
            discard(folder)
            throw error
        }
        discard(folder)
    }

    /// `replaceItemAt` with no backup item, right after both rules pass once more. When it fails
    /// after moving the earlier folder away, the folder goes back to its name if that is still free.
    /// Only a place the keys name where something is counts, and the new set's only when it
    /// left `folder`.
    private func replace(_ destination: URL, with folder: URL, sources: [URL]) throws {
        if let error = Self.splitDestinationError(destination, sources: sources) { throw error }
        do {
            try replaceItem(destination, folder)
        } catch {
            let userInfo = (error as NSError).userInfo
            var setFolder = folder
            if let movedSet = userInfo[Self.newItemLocationKey] as? URL, ArchiveSaveSettings.isNameTaken(movedSet),
               !ArchiveSaveSettings.isNameTaken(folder),
               movedSet.standardizedFileURL.path != folder.standardizedFileURL.path {
                setFolder = movedSet
                // The temporary folder `makeFolder(for:)` made, if the move left it empty.
                rmdir(folder.deletingLastPathComponent().path)
            }
            var originalLocation = (userInfo[Self.originalItemLocationKey] as? URL)
                .flatMap { ArchiveSaveSettings.isNameTaken($0) ? $0 : nil }
            if let moved = originalLocation, !ArchiveSaveSettings.isNameTaken(destination) {
                do {
                    try FileManager.default.moveItem(at: moved, to: destination)
                    originalLocation = nil
                    Self.removeIfEmptyReplacementFolder(moved.deletingLastPathComponent())
                } catch let putBackError {
                    Self.logger.error("""
                        Putting the earlier split folder back failed, it stays in \
                        \(moved.path, privacy: .private): \(putBackError.localizedDescription, privacy: .public)
                        """)
                }
            }
            Self.logger.error("""
                Replacing the earlier split folder failed; the new set stays in \
                \(setFolder.path, privacy: .private): \(error.localizedDescription, privacy: .public)
                """)
            throw SplitSetNotPlacedError(name: destination.lastPathComponent, setFolder: setFolder,
                                         originalLocation: originalLocation, underlying: error)
        }
    }

    /// Removes `directory` when it is a temporary folder of `replaceItemAt`'s own (an item-replacement
    /// folder, `TemporaryItems/NSIRD_…`) and empty: `rmdir` leaves a folder with anything in it.
    private static func removeIfEmptyReplacementFolder(_ directory: URL) {
        guard directory.lastPathComponent.hasPrefix("NSIRD_"),
              directory.deletingLastPathComponent().lastPathComponent == "TemporaryItems" else { return }
        rmdir(directory.path)
    }

    /// `url` standardized, without the trailing slash an existing folder's panel URL has (q2).
    private static func plain(_ url: URL) -> URL {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private static let logger = Logger(subsystem: "com.kernir.app", category: "document")
}
