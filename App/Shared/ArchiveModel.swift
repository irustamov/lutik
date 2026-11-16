import Foundation
import Observation
import os
import KernirCore

/// The user's answer for an item that extraction would write where something already exists.
enum ExtractionConflictResolution: Sendable {
    /// The existing item stays; the extracted one takes the next free Finder-style name ("name 2.ext").
    case keepBoth
    /// The existing item goes, a whole folder included, as in Finder.
    case replace
    /// The existing item stays and this one isn't extracted.
    case skip
}

/// What an extraction has to ask about before it writes anything (`ArchiveModel.extractionConflictScan`):
/// the conflicts in the order they are asked, and the case-only twins among them, so a twin's question
/// can name the item whose name it would take.
struct ExtractionConflictScan: Equatable, Sendable {
    /// The paths in the way, as `ArchiveModel.extractionConflicts` returns them.
    var conflicts: [String] = []
    /// Every later case-only twin among the requested items and their descendants, in write order
    /// (`CaseTwinScan.laterTwins`), those whose name is taken on disk too: their answers move the name as well.
    var laterTwins: [CaseTwinScan.Twin] = []
    /// The later twins asked about as twins: nothing on disk is in their way, so neither item is there yet.
    var askedAsTwins: Set<String> = []

    /// The conflicts asked about as case-only twins: each later twin's path -> the first twin on its name.
    var twins: [String: String] {
        var twins: [String: String] = [:]
        for twin in laterTwins where askedAsTwins.contains(twin.path) { twins[twin.path] = twin.earlierPath }
        return twins
    }

    /// The item a question about conflict `path` names as the one it would replace, given the `answers`
    /// so far (keyed by conflict path, as `ArchiveModel.extract` takes them): the twin that holds the name
    /// then (`CaseTwinScan.holders`, extract's own rule). Nil when `path` is not asked about as a twin.
    func earlierTwin(of path: String, answers: [String: ExtractionConflictResolution]) -> String? {
        guard askedAsTwins.contains(path) else { return nil }
        return CaseTwinScan.holders(of: laterTwins, answers: answers)[path]
    }
}

/// The user's answer when Update would put a new item in place of a different archive item of
/// the same name (`ArchiveModel.wouldReplace(_:)`).
enum UpdateConflictResolution: Sendable {
    /// The archive's item stays; the new one goes in under the next free Finder-style name.
    case keepBoth
    /// The archive's item goes, a whole folder included.
    case replace
}

/// Replace couldn't finish, and the existing item it was replacing had to be kept somewhere other
/// than its own name. Nothing is lost, but the user needs to know where to look: reveal `kept`.
struct ExtractionRecoveryError: Error {
    enum Kind: Sendable, Equatable {
        /// The original took the next free name beside it ("Report 2.docx"); `kept` is the item.
        case renamed
        /// The original is in a folder of its own, under its own name; `kept` is the folder (inside the
        /// hidden staging folder when even that couldn't move out, and the text says so).
        case inFolder
    }

    /// The name of the item that couldn't be replaced.
    let name: String
    /// Where the original is now: the renamed item, or the folder holding it.
    let kept: URL
    let kind: Kind
    /// Why the replace failed.
    let underlying: any Error
}

/// A symlink was where a folder was expected: a move into the folder the user chose would have left it (the
/// folder that would hold the item resolves somewhere else, `ArchiveModel.checkContained(_:in:)`), or a folder
/// the extraction makes is a link, wherever it leads (`ArchiveModel.makeFolders(_:in:readOnlyOpens:)`).
/// Nothing was moved or made through it.
struct ExtractionContainmentError: Error {
    /// The name the item (or the folder in the way) would have had.
    let name: String
    /// The folder the user sees: the one they chose, or the item dragged out. Never a hidden one of ours.
    let destination: URL
}

/// The file operations staged extraction depends on. Tests swap in their own.
struct ExtractionFileSystem: Sendable {
    /// This device's token in staging folder names, `.kernir-<token>-<pid>-<uuid>`.
    var deviceToken: String
    /// renamex_np(2): 0, or the error number.
    var rename: @Sendable (_ from: String, _ to: String, _ flags: UInt32) -> Int32
    /// lstat(2) finds an item at the path: the lookup an exclusive move checks before a plain rename.
    var exists: @Sendable (_ path: String) -> Bool = { path in
        var status = stat()
        return lstat(path, &status) == 0
    }
    /// lstat(2) reports nothing at the path (ENOENT; any other failure is no answer): a name a Replace stepped
    /// aside, which the check's listing may still hold (`CaseTwinListings.dropGone`).
    var isGone: @Sendable (_ path: String) -> Bool = { path in
        var status = stat()
        return lstat(path, &status) != 0 && errno == ENOENT
    }
    /// Whether a folder's volume may fold case: where it isn't known not to, that check also looks for a
    /// case twin (`ArchiveModel.renameExclusively`, `UniquePlacement.place`).
    /// Not the model's own `caseSensitivity` (the dialog's twins): the extraction's check reads this one,
    /// which Extract Here passes in as `extractionFileSystem`.
    var caseSensitivity = DestinationCaseSensitivity.live
    /// The names in a folder, "." and ".." left out (readdir(3)); throws the `POSIXError` it fails with. That
    /// check's listing (`CaseTwinListings`).
    var listNames: @Sendable (_ folder: String) throws -> [String] = { try ExtractionFileSystem.names(in: $0) }
    /// The item a path leads to (stat(2): a symlink is followed, as `listNames`' opendir(3) follows it, so a
    /// symlinked folder is the folder it lists); throws the `POSIXError` it fails with. That check keeps a folder's
    /// listing by it, so two spellings of one folder share one (`CaseTwinListings`).
    var identity: @Sendable (_ path: String) throws -> Identity = { try ExtractionFileSystem.identity(of: $0) }

    /// An item's device and inode.
    struct Identity: Hashable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    static let system = ExtractionFileSystem(deviceToken: storedDeviceToken) { from, to, flags in
        renamex_np(from, to, flags) == 0 ? 0 : errno
    }

    /// `listNames`' live listing.
    static func names(in folder: String) throws -> [String] {
        guard let stream = opendir(folder) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return names
            }
            let name = withUnsafeBytes(of: entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    /// `identity`'s live stat.
    static func identity(of path: String) throws -> Identity {
        var status = stat()
        guard stat(path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return Identity(device: status.st_dev, inode: status.st_ino)
    }

    private static let deviceTokenKey = "KernirStagingDeviceToken"

    /// A random token made once per install and kept in the app's defaults (which don't sync), the
    /// same way on macOS and iOS. A pid only means something on the device that ran it, so a sweep
    /// deletes only staging with this token, never staging another device is still using in the
    /// same folder (iCloud Drive, a shared volume). A device restored from another's backup can
    /// carry the same token; then a pid there could match a live run here, which the sweep's other
    /// checks (process gone, no keep marker, untouched for 10 minutes) still guard.
    private static let storedDeviceToken = deviceToken(in: .standard)

    /// The token kept in `defaults`, made and kept there first if it has none (or not a valid one).
    /// Internal for tests, which pass defaults of their own.
    static func deviceToken(in defaults: UserDefaults = .standard) -> String {
        if let token = defaults.string(forKey: deviceTokenKey), isDeviceToken(token) { return token }
        let token = String(UUID().uuidString.lowercased().filter(\.isHexDigit).prefix(16))
        defaults.set(token, forKey: deviceTokenKey)
        return token
    }

    /// 16 lowercase hex digits: no "-", so the staging name splits unambiguously.
    static func isDeviceToken(_ token: some StringProtocol) -> Bool {
        token.count == 16 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// The check before a plain rename where a volume has no RENAME_EXCL (`ArchiveModel.renameExclusively`,
/// `UniquePlacement.place`), for one operation: one merge, one placement or one extraction makes its own and
/// drops it when it ends; never shared with another operation, document or thread. A folder is listed once, at
/// its first check, and each name this operation puts there is added once it lands, so n items moved into one
/// folder list it once, not n times; its volume is asked once whether it folds case. A folder is kept by its
/// identity (`ExtractionFileSystem.identity`) and its folded path, so two spellings of it (docs, Docs) share one
/// listing and two folders that report one identity never do; each folder path's identity is read once. It answers
/// only whether a case twin is there: the exact-name lookup (`exists`) still runs for every item, first, and again
/// last, right before the rename, whenever the check touched the disk in between (an identity read, the volume's
/// case answer, a listing). Names are taken out only where a Replace stepped the old item aside and lstat finds
/// its name gone (`dropGone`), so a stale one costs a conflict or the next name, never a replace. TOCTOU: a twin
/// another process makes after the listing goes unseen for the rest of the operation, not only the µs between
/// check and rename; accepted, as main has no twin check at all. A folder deleted and made again mid-operation,
/// whose inode a volume reuses (or whose path's identity was read earlier), inherits the old one's listing: the
/// same accepted window (a path key would be just as stale).
final class CaseTwinListings {
    /// A folder: by its identity and its folded path (`NameFold.key`), or by its path where the identity can't be
    /// read for permission (EACCES, EPERM). The folded path keeps two folders apart whose identities match (a volume
    /// without RENAME_EXCL may report inode 0, or a synthesized or reused one); two spellings of one folder still
    /// share.
    private enum FolderKey: Hashable {
        case identity(ExtractionFileSystem.Identity, folded: String)
        case path(String)
    }

    /// What this operation knows of one folder.
    private struct Folder {
        /// It can't be listed for permission (EACCES, EPERM): it shows no twin.
        var isUnlistable = false
        /// Its volume's answer to `isCaseInsensitive`, once asked.
        var foldsCase: Bool?
        /// Every name in its listing and every name this operation put there, exactly as spelled, under its
        /// `NameFold.key`; nil until listed.
        var names: [String: [String]]?
    }

    private var folders: [FolderKey: Folder] = [:]
    /// Each folder path's key, read once per operation (its identity, inside the accepted TOCTOU window above),
    /// until a rename there meets an item after all.
    private var folderKeys: [String: FolderKey] = [:]

    /// Renames `source` to `target` plainly unless the name is taken: 0, EEXIST when the lookup finds `target`
    /// or the folder holds a case twin of it, or the rename's error. A rename that meets an item after all
    /// (EEXIST, ENOTEMPTY, EISDIR, ENOTDIR: a twin made after the listing, say) drops what is known of the folder
    /// and decides again on a fresh listing: EEXIST if that finds the item, else the rename's error. Never a blind
    /// retry.
    func renamePlainly(_ source: URL, to target: URL, fileSystem: ExtractionFileSystem) throws -> Int32 {
        guard let folder = try freeFolder(of: target, fileSystem: fileSystem) else { return EEXIST }
        let error = fileSystem.rename(source.path, target.path, 0)
        switch error {
        case 0:
            folders[folder]?.names?[Self.key(of: target), default: []].append(ArchiveEntry.name(of: target.path))
        case EEXIST, ENOTEMPTY, EISDIR, ENOTDIR:
            folders[folder] = nil
            folderKeys[Self.folder(of: target)] = nil
            if try freeFolder(of: target, fileSystem: fileSystem) == nil { return EEXIST }
        default:
            break
        }
        return error
    }

    /// `target`'s folder when the name is free there, else nil: the lookup (`exists`) finds `target`, or the
    /// folder holds a case twin of it.
    private func freeFolder(of target: URL, fileSystem: ExtractionFileSystem) throws -> FolderKey? {
        // A name plainly taken (a merge's existing folder) is refused before its folder is read or listed.
        if fileSystem.exists(target.path) { return nil }
        let path = Self.folder(of: target)
        var touchedDisk = false
        let folder: FolderKey
        if let known = folderKeys[path] {
            folder = known
        } else {
            touchedDisk = true
            let identity = try Self.permissionTolerant { try fileSystem.identity(path) }
            folder = identity.map { FolderKey.identity($0, folded: NameFold.key(path)) } ?? .path(path)
            folderKeys[path] = folder
        }
        if try hasCaseTwin(target, in: folder, path: path, fileSystem: fileSystem, touchedDisk: &touchedDisk) {
            return nil
        }
        // The lookup again, last, right before the rename: the identity read, the case probe and a first listing
        // never widen the gap between them. Where none of them ran, the first lookup is already the last.
        guard touchedDisk else { return folder }
        return fileSystem.exists(target.path) ? nil : folder
    }

    /// An item in `target`'s folder whose name folds to `target`'s (`NameFold.key`, names as listed and as
    /// spelled), unless the volume is known to keep case apart (`isCaseInsensitive`: unknown counts as folding).
    /// A folder that can't be listed for permission (EACCES, EPERM) shows none, and the plain rename is as
    /// unchecked as before. Any other listing error is no answer: listed once more, then it throws.
    /// Sets `touchedDisk` when it asks the volume or lists the folder.
    private func hasCaseTwin(_ target: URL, in folder: FolderKey, path: String,
                             fileSystem: ExtractionFileSystem, touchedDisk: inout Bool) throws -> Bool {
        var known = folders[folder] ?? Folder()
        defer { folders[folder] = known }
        if known.isUnlistable { return false }
        if known.foldsCase == nil {
            touchedDisk = true
            let url = URL(fileURLWithPath: path, isDirectory: true)
            known.foldsCase = fileSystem.caseSensitivity.isCaseInsensitive(url)
        }
        guard known.foldsCase == true else { return false }
        if known.names == nil {
            touchedDisk = true
            // Only EACCES and EPERM are kept (as unlistable); any other error throws and is listed again next time.
            guard let names = try Self.permissionTolerant({ try fileSystem.listNames(path) }) else {
                known.isUnlistable = true
                return false
            }
            known.names = Dictionary(grouping: names, by: NameFold.key)
        }
        return known.names?[Self.key(of: target)]?.isEmpty == false
    }

    /// After a Replace stepped the old item at `target` aside: drops the names in `target`'s folder that fold to
    /// its name and that lstat now reports gone (`isGone`, ENOENT). The archive spells `target` its own way, so the
    /// old item may be listed under another case (Readme for README); a real twin is still there and keeps
    /// blocking. Folders are found by the folder paths read whose folded path is `target`'s (never by a new
    /// identity read), and each one's names are checked under its own path: on a volume taken to fold case that
    /// keeps it apart, `Docs` and `docs` are two folders, and `Docs`' names are not gone because `docs` lacks them.
    func dropGone(_ target: URL, fileSystem: ExtractionFileSystem) {
        let key = Self.key(of: target), folded = NameFold.key(Self.folder(of: target))
        var checked: Set<FolderKey> = []
        for (path, folder) in folderKeys where NameFold.key(path) == folded && checked.insert(folder).inserted {
            guard var known = folders[folder], let names = known.names?[key] else { continue }
            let folderURL = URL(fileURLWithPath: path, isDirectory: true)
            known.names?[key] = names.filter { !fileSystem.isGone(folderURL.appendingPathComponent($0).path) }
            folders[folder] = known
        }
    }

    /// After a Replace put a new item at `target` (swapped in, or moved in once the old one stepped aside or
    /// went): forgets every folder at `target` or below it, by folded path (`NameFold.key`), so its identity is
    /// read and it is listed again. Those keys and listings were the old item's.
    func forget(below target: URL) {
        let root = NameFold.key(target.path)
        func isBelow(_ path: String) -> Bool {
            let path = NameFold.key(path)
            return path == root || root.isAncestor(of: path)
        }
        folderKeys = folderKeys.filter { !isBelow($0.key) }
        folders = folders.filter { folder, _ in
            switch folder {
            case .identity(_, folded: let folded): !(folded == root || root.isAncestor(of: folded))
            case .path(let path): !isBelow(path)
            }
        }
    }

    /// The folder holding `target`: its parent path, "/" for an item at the root (whose parent path is "").
    private static func folder(of target: URL) -> String {
        let parent = ArchiveEntry.parentPath(of: target.path)
        return parent.isEmpty ? "/" : parent
    }

    private static func key(of target: URL) -> String {
        NameFold.key(ArchiveEntry.name(of: target.path))
    }

    /// `body`'s answer about a folder (its listing, its identity); nil when it fails for permission (EACCES, EPERM).
    /// Any other error asks once more, then throws.
    private static func permissionTolerant<Answer>(_ body: () throws -> Answer) throws -> Answer? {
        var retried = false
        while true {
            do {
                return try body()
            } catch let error as POSIXError where error.code == .EACCES || error.code == .EPERM {
                return nil
            } catch {
                if retried { throw error }
                retried = true
            }
        }
    }
}

/// Edit model shared by the macOS NSDocument and the iOS UIDocument.
///
/// Holds an immutable source snapshot (`reader`) plus pending edits: an `ArchiveChangeSet`
/// for the writer and the on-disk files waiting to be added. `items` is the merged tree the
/// user sees. Every edit is undoable; `didSave(reader:)` starts over from the new snapshot.
@MainActor @Observable
final class ArchiveModel {
    /// A copy `copyForOpening(_:checking:)` handed to another app.
    typealias OpenedFile = OpenedFiles.File

    /// A file or folder on disk waiting to be added, as it will appear in the archive.
    private struct PendingEntry: Equatable, Sendable {
        let entry: ArchiveEntry
        /// The added file itself, or a file inside an added folder.
        let url: URL
    }

    /// Everything one undo step restores. Renames live in `changes.renamedPaths` (source path -> final path,
    /// read through `RenameMap`) for source items, and in `pending` keys plus `Addition.archiveName` /
    /// `destinationDirectory` for pending ones.
    private struct EditState: Equatable, Sendable {
        var changes: ArchiveChangeSet
        /// Keyed by NFC archive path (the final path, renames applied).
        var pending: [String: PendingEntry]
    }

    private nonisolated static let logger = Logger(subsystem: "com.kernir.app", category: "model")

    private struct Totals {
        var itemCount = 0
        var totalSize: Int64? = 0
        var compressedSize: Int64?
    }

    var undoManager: UndoManager?
    private(set) var reader: (any ArchiveReading)?
    private(set) var format: ArchiveFormat
    private(set) var changes = ArchiveChangeSet() {
        // A model that replaces this one (Revert to Saved) maps opened copies back through these.
        didSet { openedFiles.noteUnsavedRenames(changes.renamedPaths, by: ObjectIdentifier(self)) }
    }
    /// Merged tree in Finder order (folders first, then by name).
    private(set) var items: [ArchiveItem] = []
    /// Counts the times `items` was rebuilt, so a view can keep what it derived from them (a sorted level)
    /// until they change, without comparing them.
    private(set) var itemsRevision = 0
    /// In memory for this document only; used for reading and to prefill the save options.
    var password: String?
    /// Options chosen in the save panel or sheet, or on iOS a new archive's creation settings (the
    /// document applies them to each model it opens); nil when none has set them (a split save never
    /// does). A plain save writes with `ArchiveSaveSettings.writeOptions(for:)`, which follows the
    /// app's default then; on iOS, `PlainSaveChoice` puts the file's Mac metadata choice (remembered,
    /// answered at Save, or keep on a save that can't ask while the archive holds Mac metadata) in place
    /// of both the saved options' flag and the app's default.
    private(set) var saveOptions: ArchiveWriteOptions?

    @ObservationIgnored private var pending: [String: PendingEntry] = [:]
    /// The `Kernir-<UUID>` folders `localFileURL(for:)` extracted folders into, until
    /// `removeTemporaryFiles()`.
    @ObservationIgnored private var temporaryDirectories: [URL] = []
    /// Renamed files `localFileURL(for:)` extracted into `temporaryDirectories`, so a second preview of one
    /// reuses it.
    @ObservationIgnored private var renamedExtractions: [RenamedExtraction: URL] = [:]
    /// The copies `copyForOpening(_:checking:)` handed out. The document's: a model that replaces this one
    /// gets the same, and only the document's close deletes them.
    let openedFiles: OpenedFiles
    /// NFC path -> path as spelled in the source archive (the first spelling seen).
    @ObservationIgnored private var sourcePaths: [String: String] = [:]
    /// NFC path -> path as the tree spells it, where that differs from `sourcePaths`: below a
    /// folder the archive spells more than one way (NFC and NFD), every folder keeps its first spelling.
    @ObservationIgnored private var displayPaths: [String: String] = [:]
    /// NFC paths of source folders spelled more than one way. Each spelling is its own path to
    /// the reader, so these are extracted child by child.
    @ObservationIgnored private var mixedFolders = Set<String>()
    /// Every source entry's exact path and every folder above one (implicit folders included): the paths
    /// `renamedPaths` may use as keys.
    @ObservationIgnored private var sourceEntryPaths = Set<String>()
    /// NFC final path -> path as the tree spells it, for source items and the folders above them, renames
    /// applied. Rebuilt with `items`; `archiveSpelling(of:)` reads it.
    @ObservationIgnored private var finalSpellings: [String: String] = [:]
    /// The visible NFC paths the running `edit` removes (Delete, Replace), collected by `remove(_:from:)`.
    @ObservationIgnored private var removalTargets = Set<String>()
    /// The `Kernir-NewFolders-<UUID>` folder holding the empty folders New Folder stages; one of
    /// `temporaryDirectories`, so only the document's close removes it, never a save.
    @ObservationIgnored private var newFoldersDirectory: URL?
    /// Every visible item by NFC path, rebuilt with `items`.
    private var index: [String: ArchiveItem] = [:]
    private var totals = Totals()
    /// What `extract` renames with and names its staging by. Tests swap it.
    @ObservationIgnored var extractionFileSystem = ExtractionFileSystem.system
    /// Where `reopen(nameEncoding:)` and `openSaved(_:open:)` keep the chosen name encoding. Tests swap it.
    @ObservationIgnored var nameEncodingStore = ArchiveNameEncodingStore.shared
    /// Counts the snapshots adopted (`didSave`), so `reopen(nameEncoding:)` sees one adopted while it read. Observed:
    /// the Info popover keys its file-size load on it, so a save landing while the size loads still loads it again.
    private(set) var snapshotGeneration = 0
    /// The archive's size on disk for `infoSummary`, set by `loadInfoFileSize()`; nil until then and after a save.
    private(set) var infoFileSize: Int64?
    /// The edit state before the open "Edit Comment" typing step, which `setComment` joins while the user types
    /// (see `endCommentTyping()`); nil when no typing step is open.
    @ObservationIgnored private var commentTypingBase: EditState?
    /// `setComment` is undoing its own typing step, typed back to where it began: no redo step for it.
    @ObservationIgnored private var isDroppingTypingStep = false
    /// Whether an extraction destination folds case, so case-only twins would land on one name
    /// (`CaseTwinScan`). Tests swap it.
    @ObservationIgnored var caseSensitivity = DestinationCaseSensitivity.live

    init(reader: any ArchiveReading, undoManager: UndoManager?, openedFiles: OpenedFiles = OpenedFiles()) {
        self.reader = reader
        self.format = reader.format
        self.undoManager = undoManager
        self.openedFiles = openedFiles
        indexSource()
        rebuild()
        openedFiles.adopt(by: ObjectIdentifier(self))
    }

    init(newArchiveFormat: ArchiveFormat, undoManager: UndoManager?, openedFiles: OpenedFiles = OpenedFiles()) {
        self.reader = nil
        self.format = newArchiveFormat
        self.undoManager = undoManager
        self.openedFiles = openedFiles
        rebuild()
        openedFiles.adopt(by: ObjectIdentifier(self))
    }

    /// A multi-volume set is read-only even when its format is writable: Save As writes one archive.
    var isEditable: Bool { format.isWritable && (reader?.volumeURLs.count ?? 1) == 1 }
    var hasChanges: Bool { !changes.isEmpty }
    /// All visible entries, files and folders.
    var itemCount: Int { totals.itemCount }
    /// Sum of visible file sizes; nil when any of them is unknown (single-stream .gz, .xz…).
    var totalSize: Int64? { totals.totalSize }
    /// nil while anything is pending or when a kept file has no compressed size.
    var compressedSize: Int64? { totals.compressedSize }

    func item(at path: String) -> ArchiveItem? {
        index[Self.nfc(path)]
    }

    /// Children of a folder ("" = top level), filtered like the search field.
    func children(of directoryPath: String, matching query: String = "") -> [ArchiveItem] {
        let level = directoryPath.isEmpty ? items : (item(at: directoryPath)?.children ?? [])
        return level.filtered(matching: query)
    }

    /// Visible archive paths that adding `urls` to `directory` would replace.
    func conflicts(adding urls: [URL], to directory: String) -> [String] {
        let directory = Self.normalizedDirectory(directory)
        var result: [String] = []
        for url in urls where !Self.isIgnored(url) {
            let path = Self.join(directory, Self.nfc(url.lastPathComponent))
            if let existing = item(at: path), !result.contains(existing.path) {
                result.append(existing.path)
            }
        }
        return result
    }

    /// Adds files and folders from disk, replacing whatever is at the same paths.
    func add(_ urls: [URL], to directory: String) {
        add(urls, to: directory, actionName: String(localized: "Add", table: "Shared",
                                comment: "Undo action name after adding files to the archive (Edit > Undo Add)."))
    }

    private func add(_ urls: [URL], to directory: String, actionName: String) {
        guard isEditable else { return }
        let directory = Self.normalizedDirectory(directory)
        guard !hasFileAtOrAbove(directory) else { return }
        let destination = archiveSpelling(of: directory)
        edit(actionName: actionName) { state in
            for url in urls where !Self.isIgnored(url) {
                let path = Self.join(directory, Self.nfc(url.lastPathComponent))
                let entries = Self.pendingEntries(for: url, at: path)
                guard !entries.isEmpty else { continue }
                remove(path, from: &state)
                state.changes.additions.append(.init(sourceURL: url, destinationDirectory: destination))
                for entry in entries { state.pending[entry.entry.path] = entry }
            }
        }
    }

    /// Removes visible items: source entries become `removedPaths` (items moved into a removed folder go with it,
    /// items moved out of it stay: `RemovalRule`), pending ones are dropped. Refused, nothing changed and no undo
    /// step, when the writer would drop an item moved out of a deleted folder that this does not remove
    /// (`.holdsMovedOutItems`, `edit`); nil otherwise.
    @discardableResult func remove(_ paths: Set<String>) -> MoveProblem? {
        guard isEditable else { return nil }
        // Visible paths only; a path inside another removed path is already covered.
        let visible = Set(paths.compactMap { item(at: $0).map { Self.nfc($0.path) } })
        let roots = visible.filter { !Self.isCovered(Self.parentPath(of: $0), by: visible) }
            .sorted()
        guard !roots.isEmpty else { return nil }
        return edit(actionName: String(localized: "Delete", table: "Shared",
                                       comment: "Undo action name after deleting items from the archive (Edit > Undo Delete).")) { state in
            remove(roots, from: &state)
        }
    }

    /// A disk URL for dragging out or previewing: the file itself for pending additions (a clone
    /// under its new name for a renamed one), otherwise an extracted copy in a temporary location, with no
    /// symlink in it that leads out of the item (`ExportLinkSweep`).
    func localFileURL(for path: String) async throws -> URL {
        guard let item = item(at: path) else { throw ArchiveError.entryNotFound(path) }
        let name = ArchiveEntry.name(of: item.path)
        if let entry = pending[item.path], !item.isDirectory || !hasAdditions(inside: item.path) {
            // A renamed addition is shown under its new name, never as the user's file under its own.
            // Pending paths name added files by their NFC names (`add`), whatever spelling they have on disk.
            if Self.isSameSpelling(Self.nfc(entry.url.lastPathComponent), name) { return entry.url }
            let directory = try makeTemporaryDirectory()
            let clone = directory.appendingPathComponent(name, isDirectory: item.isDirectory)
            try await Task.detached(priority: Task.currentPriority) { [source = entry.url] in
                try FileManager.default.copyItem(at: source, to: clone)
            }.value
            return clone
        }
        // A renamed file comes out under its new name below, never as the reader's file under its old one.
        let source = readerPath(of: item)
        if !item.isDirectory, !item.isPendingAddition, let reader,
           Self.isSameSpelling(ArchiveEntry.name(of: source), name) {
            return try await reader.extractToTemporaryFile(source)
        }
        // A renamed file extracted before, from the same archive, is still the same file.
        let key = RenamedExtraction(generation: snapshotGeneration, source: Array(source.unicodeScalars),
                                    path: Array(item.path.unicodeScalars))
        let isRenamedFile = !item.isDirectory && !item.isPendingAddition && reader != nil
        if isRenamedFile, let cached = renamedExtractions[key], FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        let directory = try makeTemporaryDirectory()
        // A fresh folder of our own: nothing to collide with, so no staging.
        let local = directory.appendingPathComponent(item.path, isDirectory: item.isDirectory)
        do {
            try await Self.run(plan(for: [item]), reader: reader, in: directory, fileSystem: extractionFileSystem,
                               progress: nil)
        } catch let refused as ExtractionContainmentError {
            // Named for the item dragged out or previewed, not the hidden temporary folder.
            throw ExtractionContainmentError(name: refused.name, destination: local)
        }
        // Before any app gets the URL: no link out of the item (`ExportLinkSweep`), off the main actor. A
        // renamed link entry is removed, then comes back as the reader's file it leads to inside the archive,
        // as an unrenamed one does (`extractToTemporaryFile`), copied under its new name. One the reader can't
        // serve (it leads out, or to no entry) fails as a link, as an unrenamed folder's link item does.
        do {
            let kept = try await Task.detached(priority: Task.currentPriority) {
                try ExportLinkSweep.sanitize([local])
            }.value
            if kept.isEmpty {
                guard isRenamedFile, let reader else { throw ExportedLinksError(names: [name]) }
                let file: URL
                do {
                    file = try await reader.extractToTemporaryFile(source)
                } catch ArchiveError.entryNotFound {
                    throw ExportedLinksError(names: [name])
                }
                try await Task.detached(priority: Task.currentPriority) {
                    try FileManager.default.copyItem(at: file, to: local)
                }.value
            }
        } catch {
            // An archive's 0555 or 0000 folder in it goes too.
            try? ExclusiveCopy.removeItem(at: directory)
            throw error
        }
        if isRenamedFile { renamedExtractions[key] = local }
        return local
    }

    /// A renamed file `localFileURL(for:)` extracted: from the reader of `generation`'s entry `source` to
    /// `path`, spelled as they are (String's `==` takes NFC and NFD for one).
    private struct RenamedExtraction: Hashable {
        let generation: Int
        let source: [Unicode.Scalar]
        let path: [Unicode.Scalar]
    }

    /// A fresh `Kernir-<UUID>` folder of `temporaryDirectories`.
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kernir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    /// Deletes the temporary folders `localFileURL(for:)` extracted folders into. Call when the
    /// document closes; files from `reader.extractToTemporaryFile` are the reader's own, and the
    /// copies `copyForOpening(_:checking:)` made are `openedFiles`'.
    func removeTemporaryFiles() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories = []
        renamedExtractions = [:]
        newFoldersDirectory = nil
    }

    // MARK: - Opened files

    /// A copy of a file to open in another app, in a fresh `Kernir-<UUID>` folder that
    /// `openedFiles` tracks: unlike the reader's cache, a save doesn't delete it; the document's
    /// close does. A pending addition is copied too, so the user's own file is never edited "in the
    /// archive". Files only: a folder throws. Copies off the main actor; a cancelled open or the
    /// document's close meanwhile throws `CancellationError` and leaves no copy. `check` sees the item's
    /// extracted file (`localFileURL(for:)`) before the copy is made; what it throws ends there, with no copy
    /// made or tracked. That file can be the reader's cache: a caller that uses it after the throw keeps
    /// `reader`, as it was at the call, alive until then.
    func copyForOpening(_ path: String, checking check: (URL) throws -> Void = { _ in }) async throws -> URL {
        // The item copied, as it is now: a different item that later takes its path is asked about.
        guard let item = item(at: path), !item.isDirectory, let identity = identity(at: item.path)
        else { throw ArchiveError.entryNotFound(path) }
        // A save before the copy is tracked may save a different item over this one.
        let saves = openedFiles.saves
        // A save meanwhile adopts a new reader, and the old one's cache (the source) goes with it.
        let reader = reader
        let name = ArchiveEntry.name(of: item.path)
        // Tracked before the extraction: a rename, or its undo or redo, meanwhile moves the copy too.
        let url = try await openedFiles.copy(named: name, path: item.path, item: identity, asOf: saves) {
            let local = try await self.localFileURL(for: item.path)
            try check(local)
            return local
        }
        withExtendedLifetime(reader) {}
        return url
    }

    /// The opened copies that still exist and whose size or modification date differs from when
    /// they were last seen, in opening order, then the new items other apps left next to them
    /// (`OpenedFiles.changed()`).
    func changedOpenedFiles() -> [OpenedFile] {
        openedFiles.changed()
    }

    /// True when Update would put `file` in place of a different archive item: a new item named
    /// like one in the archive, such as an export or a renamed copy, or a
    /// copy or updated item whose own item has since gone and another taken its path: the user's
    /// own file added after an Undo, a saved item a Revert brought back, a folder added under the
    /// copy's name. The user chooses then, and `update(from:ifNameIsTaken:)`
    /// without a choice refuses. A copy going back over its own item, or an item an Update
    /// already put in, replaces nothing else; with its item gone and the path free, it goes in. Asks about
    /// where `file` goes back in now (`OpenedFiles.current(_:)`), not where it was reported: a rename since,
    /// such as one during an earlier item's Update, may have moved it.
    func wouldReplace(_ file: OpenedFile) -> Bool {
        let file = openedFiles.current(file)
        return item(at: file.path) != nil && !isItsItem(file, at: file.path)
    }

    /// Puts a changed copy back at its item's archive path, replacing what is there (as `add`
    /// does), as one undo step "Update"; a new item next to a copy goes in beside the copy's item.
    /// When that would replace a different item (`wouldReplace(_:)`), `resolution` says what to
    /// do: Keep Both puts it in under the next free Finder-style name, Replace replaces the item,
    /// and no answer puts nothing in. Once in, the item is one of its archive items (`itsItems`:
    /// the snapshot added), so a later change updates it without asking, also after the Update is
    /// undone, while a different item that later takes the path is asked about. What goes in is a snapshot of the
    /// file (`OpenedFiles.snapshot(of:named:)`), never the file the other app may still be writing,
    /// and what the snapshot holds is then seen. False when nothing went in, and
    /// the file is still reported: an archive Lutik can't write, a file where the item's folder
    /// was, a name taken without an answer (also while the snapshot was made), a copy gone or
    /// changing too fast to snapshot, the document closed or the task cancelled.
    @discardableResult
    func update(from reported: OpenedFile, ifNameIsTaken resolution: UpdateConflictResolution? = nil) async -> Bool {
        // Where the file goes back in now: a rename since it was reported, or while its snapshot is made, moved it.
        // After a rename during the snapshot, it is made again under the name the file has
        // then; a second such rename puts nothing in.
        for _ in 1...2 {
            var file = openedFiles.current(reported)
            let directory = Self.parentPath(of: file.path)
            var path = file.path
            if resolution == .keepBoth, wouldReplace(file) {
                let isFolder = (try? file.url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]))
                    .map { $0.isDirectory == true && $0.isPackage != true } ?? false
                let name = Self.keepBothName(Self.nfc(file.url.lastPathComponent), isDirectory: isFolder) {
                    self.item(at: Self.join(Self.normalizedDirectory(directory), $0)) != nil
                }
                path = Self.join(Self.normalizedDirectory(directory), name)
            }
            // Nothing replaced unasked: the path holds the file's own item, is free, or Replace was chosen.
            func mayGoIn() -> Bool {
                resolution == .replace || item(at: path) == nil
                    || (path == file.path && isItsItem(file, at: path))
            }
            let name = ArchiveEntry.name(of: path)
            guard isEditable, !hasFileAtOrAbove(Self.normalizedDirectory(directory)), mayGoIn(),
                  let snapshot = try? await openedFiles.snapshot(of: file, named: name) else { return false }
            let now = openedFiles.current(reported)
            guard now.path.unicodeScalars.elementsEqual(file.path.unicodeScalars) else {
                openedFiles.discardSnapshot(snapshot.url)
                continue
            }
            // A save while the snapshot was made gave the file its items anew (`rebaseItems`): those count.
            file.itsItems = now.itsItems
            // The archive can change while the snapshot is made; `add` checks the folder again.
            guard mayGoIn() else {
                openedFiles.discardSnapshot(snapshot.url)
                return false
            }
            let before = editState
            add([snapshot.url], to: directory, actionName: String(localized: "Update", table: "Shared",
                                comment: "Undo action name after a file opened from the archive and changed in another app was put back into the archive (Edit > Undo Update)."))
            // Only once it went in: a refused add leaves the copy to be asked about again, without its snapshot.
            guard editState != before else {
                openedFiles.discardSnapshot(snapshot.url)
                return false
            }
            var seen = snapshot.seen
            seen.path = path
            // In place, the items it stood for stay its own, so an undone Update goes back in unasked.
            seen.itsItems = (path == file.path ? file.itsItems : []) + [identity(at: path)].compactMap { $0 }
            openedFiles.markUpdated(seen)
            return true
        }
        return false
    }

    /// Takes the size and modification date `file` was reported with as seen, so it is reported
    /// again only if it changes again (`OpenedFiles.markSeen`: its path and items stay as they are
    /// now, also after a rename since); a new item next to a copy is tracked from then on.
    func markSeen(_ file: OpenedFile) {
        openedFiles.markSeen(file)
    }

    /// The archive item at `path` as an opened file keeps it (`OpenedFile.itsItems`): `.saved` with
    /// its size, date and kind for an item of the archive as last read or saved, `.added` with the file on disk for
    /// a pending addition. Nil when nothing is there, or only a folder made to hold additions, which no opened file
    /// stands for.
    private func identity(at path: String) -> OpenedItemIdentity? {
        guard let item = item(at: path) else { return nil }
        // Keyed like `pending`: the tree may spell a pending path with a source folder's NFD spelling.
        if let entry = pending[Self.nfc(item.path)] { return .added(entry.url) }
        guard !item.isPendingAddition else { return nil }
        return .saved(size: item.size, modified: item.modificationDate, isDirectory: item.isDirectory)
    }

    /// True when the archive item at `path` is one `file` stands for (`OpenedFile.itsItems`).
    private func isItsItem(_ file: OpenedFile, at path: String) -> Bool {
        identity(at: path).map(file.itsItems.contains) ?? false
    }

    /// The paths in the way of the requested items (`nil` = every top-level item), each once, in
    /// extraction order: an item's own path when something is there, or, for a nested item, the
    /// first folder above it that is something other than a real folder (a file, a symlink, never
    /// followed). A dangling symlink counts; real folders above a nested item merge, so they never
    /// conflict. Then, when `directory` folds case (`caseSensitivity`), the case-only twins among the
    /// requested items and their descendants: each later twin in archive order, by its own path
    /// (`CaseTwinScan`), since it would land on its earlier twin's name. Read-only.
    func extractionConflicts(_ paths: [String]?, in directory: URL) -> [String] {
        extractionConflictScan(paths, in: directory).conflicts
    }

    /// The names a twin question shows for the later twin at `path` and its earlier twin at `earlier`:
    /// their last components, or their whole archive paths when those read the same (`D/x` and `d/x`).
    nonisolated static func twinNames(of path: String, earlier: String) -> (name: String, earlier: String) {
        let names = (ArchiveEntry.name(of: path), ArchiveEntry.name(of: earlier))
        return names.0 == names.1 ? (path, earlier) : names
    }

    /// `extractionConflicts` with the case-only twins behind it, in one scan of the archive and the
    /// folder: what the extract questions ask (`ExtractionConflictScan`). A later twin whose name is taken
    /// on disk too is asked about as an item that exists, not as a twin. Read-only.
    func extractionConflictScan(_ paths: [String]?, in directory: URL) -> ExtractionConflictScan {
        var scan = ExtractionConflictScan()
        var requested: [ArchiveItem] = []
        for path in paths ?? items.map(\.path) {
            guard let item = item(at: path) else { continue }
            requested.append(item)
            guard let conflict = Self.conflictPath(of: item.path, in: directory),
                  !scan.conflicts.contains(conflict) else { continue }
            scan.conflicts.append(conflict)
        }
        let foldsCase = !requested.isEmpty && caseSensitivity.isCaseInsensitive(directory)
        scan.laterTwins = caseTwins(of: requested, foldsCase: foldsCase)
        for twin in scan.laterTwins where !scan.conflicts.contains(twin.path) {
            scan.conflicts.append(twin.path)
            scan.askedAsTwins.insert(twin.path)
        }
        return scan
    }

    /// The later case-only twins among `items` and their descendants, in write order, when the
    /// destination folds case (`foldsCase`, read once per call from `caseSensitivity`); none otherwise.
    /// Write order is the archive's entry order, each entry at its path in the tree: a renamed item keeps
    /// its source entry's place, as the engine writes it there.
    private func caseTwins(of items: [ArchiveItem], foldsCase: Bool) -> [CaseTwinScan.Twin] {
        guard !items.isEmpty, foldsCase else { return [] }
        let renames = RenameMap(changes.renamedPaths)
        let writeOrder = (reader?.entries ?? []).map { entry in
            renames.sourceToFinal.isEmpty ? entry.path
                : shownPath(ofSource: entry.path, key: Self.nfc(entry.path), renames: renames)
        }
        return CaseTwinScan.laterTwins(in: CaseTwinScan.entries(of: items, writeOrder: writeOrder), requested: nil)
    }

    /// Extracts visible items as the user sees them, recreating their archive paths under
    /// `directory`. `nil` extracts every top-level item. Never replaces anything without an answer
    /// in `resolutions` (keyed by the paths `extractionConflicts` returns): an unanswered conflict
    /// throws `ExtractionConflictError` before anything is written. Everything is extracted into a
    /// hidden staging folder in `directory` first, so a failure or cancellation before the items
    /// move into place leaves `directory` as it was. The moves come one by one: a failure on item k
    /// leaves items 1 to k-1 placed (and what they replaced gone), the folders made above them, and
    /// `directory` itself if it had to be created. A Replace that fails never loses the original:
    /// it stays under its own name, or `ExtractionRecoveryError` says where it is. Returns where the
    /// items went, in order.
    ///
    /// Case-only twins (`extractionConflicts`, keyed by the later twin's path) need an answer too:
    /// The twins on one name are answered in archive order against a survivor, at first the earliest
    /// twin: Skip leaves the later twin out; Replace leaves the survivor out and makes the later twin
    /// the survivor, so all Replace lands the last twin under its own name with its own bytes, as the
    /// engine itself leaves twins; Keep Both leaves the later one out of the main staging, extracts it
    /// on its own into a staging of its own, and moves it in after the rest under `keepBothName`, as
    /// the dialog's Keep Both names an item on disk. At most one twin per name is left in the main staging.
    @discardableResult
    func extract(_ paths: [String]?, to directory: URL,
                 resolutions: [String: ExtractionConflictResolution] = [:],
                 progress: ArchiveProgressHandler?) async throws -> [URL] {
        var requested: [ArchiveItem] = []
        for path in paths ?? items.map(\.path) {
            // Hidden metadata is never written, so asking for it directly does nothing.
            if Self.isHidden(path: path), item(at: path) == nil { continue }
            guard let item = item(at: path) else { throw ArchiveError.entryNotFound(path) }
            requested.append(item)
        }
        let conflicts = requested.map { Self.conflictPath(of: $0.path, in: directory) }
        var unanswered: [String] = []
        for case let conflict? in conflicts where resolutions[conflict] == nil && !unanswered.contains(conflict) {
            unanswered.append(conflict)
        }
        let wanted = zip(requested, conflicts).filter { resolutions[$1 ?? $0.path] != .skip }.map(\.0)
        // Twins below an item skipped for a conflict on disk are never written, so they need no answer.
        let foldsCase = !wanted.isEmpty && caseSensitivity.isCaseInsensitive(directory)
        let twins = caseTwins(of: wanted, foldsCase: foldsCase)
        for twin in twins where resolutions[twin.path] == nil && !unanswered.contains(twin.path) {
            unanswered.append(twin.path)
        }
        guard unanswered.isEmpty else { throw ExtractionConflictError(paths: unanswered) }
        guard !wanted.isEmpty else {
            progress?(1, nil)
            return []
        }
        // Left out: a skipped later twin, or the survivor a later one replaces. Kept beside: a later twin
        // answered Keep Both, unless something above it is left out. One survivor per folded name, the
        // earliest twin until a later one replaces it (`CaseTwinScan.holders`, the rule the questions name
        // it by), so the main staging holds at most one per name.
        var dropped: [String] = []
        var besidePaths: [String] = []
        let survivors = CaseTwinScan.holders(of: twins, answers: resolutions)
        for twin in twins {
            let survivor = survivors[twin.path] ?? twin.earlierPath
            switch resolutions[twin.path] {
            case .skip?:
                dropped.append(twin.path)
            case .replace?:
                if !dropped.contains(survivor) { dropped.append(survivor) }
            case .keepBoth?, nil:
                besidePaths.append(twin.path)  // nil: answered above
            }
        }
        besidePaths.removeAll { path in dropped.contains { Self.isPath(path, atOrBelow: $0) } }
        let excluded = dropped + besidePaths
        let main = wanted.filter { item in !excluded.contains { Self.isPath(item.path, atOrBelow: $0) } }
        var beside: [TwinPass] = []
        for path in besidePaths {
            // The twin itself when it is requested or inside a requested item, else (a folder above
            // requested items) the requested items inside it.
            let items: [ArchiveItem]
            if wanted.contains(where: { Self.isPath(path, atOrBelow: $0.path) }) {
                guard let item = item(at: path) else { continue }
                items = [item]
            } else {
                items = wanted.filter { item in
                    Self.isPath(item.path, atOrBelow: path)
                        && !excluded.contains { $0 != path && Self.isPath(item.path, atOrBelow: $0) }
                }
            }
            guard !items.isEmpty else { continue }
            beside.append(TwinPass(path: path, items: items.map(\.path),
                                   plan: plan(for: items, excluding: excluded.filter { $0 != path })))
        }
        let placed = try await Self.extractStaged(plan(for: main, excluding: excluded), reader: reader,
                                                  items: main.map(\.path), beside: beside, to: directory,
                                                  resolutions: resolutions,
                                                  foldsCase: caseSensitivity.isKnownCaseInsensitive(directory),
                                                  fileSystem: extractionFileSystem,
                                                  quarantine: QuarantinePropagation.Mark(of: quarantineSources),
                                                  progress: progress)
        var result: [URL] = []
        for item in wanted {
            if let url = placed[Self.nfc(item.path)] { result.append(url) }
        }
        return result
    }

    /// The archive file and its other volumes: what a quarantine is carried over from.
    var quarantineSources: [URL] { reader.map { [$0.url] + $0.volumeURLs } ?? [] }

    /// Adopts the freshly saved archive: clears pending edits and the undo history,
    /// since both refer to the old snapshot. Opened files whose item was saved stand for the
    /// saved item from then on; the others stand for none, so Update asks. `renamed` maps old NFC
    /// paths to the paths the new archive lists the same entries at (`reopen(nameEncoding:)`): an
    /// opened file follows its item, or its folder, to the new name.
    func didSave(reader: any ArchiveReading, renamed: [String: String] = [:]) {
        snapshotGeneration += 1
        infoFileSize = nil
        commentTypingBase = nil
        // Before `pending` goes: an opened file whose item was saved stands for the saved item now,
        // as the new archive has it, and one whose item had gone or been replaced stands for none.
        let saved = Set(openedFiles.files.filter { isItsItem($0, at: $0.path) }.map(\.url))
        self.reader = reader
        format = reader.format
        changes = ArchiveChangeSet()
        openedFiles.noteArchiveSaved(by: ObjectIdentifier(self))
        pending = [:]
        indexSource()
        rebuild()
        if !renamed.isEmpty {
            openedFiles.renamePaths { self.path(of: $0, renamed: renamed) }
        }
        openedFiles.rebaseItems { saved.contains($0.url) ? [identity(at: $0.path)].compactMap { $0 } : [] }
        undoManager?.removeAllActions()
    }

    /// `path` as `renamed` renames it: an entry's own new path, else its folder's (recursively)
    /// with its own name, spelled as the tree spells it; unchanged when nothing above it was renamed.
    private func path(of path: String, renamed: [String: String]) -> String {
        if let new = renamed[Self.nfc(path)] { return item(at: new)?.path ?? new }
        let parent = Self.parentPath(of: path)
        guard !parent.isEmpty else { return path }
        let newParent = self.path(of: parent, renamed: renamed)
        guard newParent != parent else { return path }
        return newParent + "/" + Self.scalarSuffix(of: path, after: parent + "/")
    }

    /// The old NFC path to new path of each entry, pairing two listings of the same archive bytes
    /// entry by entry (KernirCore lists entries in archive order, whatever the name encoding). Empty
    /// unless they pair up entry by entry: the same count, each pair the same kind, size and date,
    /// each pair's folders paired too, and no path paired twice. An encoding that merges two names
    /// into one path, or splits one at a "/", lists differently, and then no copy can be followed.
    nonisolated static func renamedPaths(from old: [ArchiveEntry], to new: [ArchiveEntry]) -> [String: String] {
        guard old.count == new.count else { return [:] }
        var renamed: [String: String] = [:]
        var targets = Set<String>()
        for (o, n) in zip(old, new) {
            let from = nfc(o.path), to = nfc(n.path)
            guard o.isDirectory == n.isDirectory, o.size == n.size, o.modificationDate == n.modificationDate,
                  renamed.updateValue(to, forKey: from) == nil, targets.insert(to).inserted else { return [:] }
        }
        // A real folder entry may come after its children, so folders are checked once all are paired.
        for (from, to) in renamed {
            let (fromParent, toParent) = (parentPath(of: from), parentPath(of: to))
            guard fromParent.isEmpty ? toParent.isEmpty : renamed[fromParent] == toParent else { return [:] }
        }
        return renamed.filter { $0.key != $0.value }
    }

    /// Lists the archive again with its names decoded as `nameEncoding` asks (View > Text Encoding), and
    /// remembers the choice for the file (`.automatic` forgets it). Only for an archive without unsaved
    /// changes: like `didSave`, it starts over from the new snapshot, so pending edits and the undo history
    /// go. Selection and expanded folders belong to the window: clear the selection, and keep only the
    /// expanded folders `listedFolders(among:)` still finds. Throws what opening throws; the model and the
    /// remembered choice are unchanged then. Does nothing for a new archive (no file to read).
    ///
    /// The windows keep the archive from changing while this reads it (the Mac's progress sheet). If it
    /// changes anyway (an edit, undo or redo, or a save adopted), or the task is cancelled, this throws
    /// `CancellationError` and applies and remembers nothing: adopting the new listing would drop the change.
    /// `open` reads the file; tests hold it to act while it runs.
    func reopen(nameEncoding: ArchiveNameEncoding,
                open: (_ url: URL, _ password: String?, _ nameEncoding: ArchiveNameEncoding) async throws
                    -> any ArchiveReading = { try await Archive.open(at: $0, password: $1, nameEncoding: $2) })
        async throws {
        guard let url = reader?.url else { return }
        let changesBefore = changes
        let snapshotBefore = snapshotGeneration
        let reopened = try await open(url, password, nameEncoding)
        guard changes == changesBefore, snapshotGeneration == snapshotBefore, !Task.isCancelled else {
            throw CancellationError()
        }
        nameEncodingStore.remember(nameEncoding, for: url)
        // Copies opened in other apps follow their items to the new names.
        didSave(reader: reopened, renamed: Self.renamedPaths(from: reader?.entries ?? [], to: reopened.entries))
    }

    /// The folders among `paths` that the archive still lists, e.g. after `reopen(nameEncoding:)` renamed
    /// some of them.
    func listedFolders(among paths: Set<String>) -> Set<String> {
        paths.filter { item(at: $0)?.isDirectory == true }
    }

    /// Opens `url`, the file a save just wrote, for `didSave(reader:)`, and records the name encoding for
    /// it. `open` opens a file the way the app does, its names decoded as the encoding passed says (not as
    /// a store says: the engine needn't share `nameEncodingStore`). Both apps' reopen after a save goes
    /// through here.
    ///
    /// A manual choice follows the archive to the written file (the file that replaced it, or a Save As
    /// copy) only while names stored in a legacy code page survived the save. A save may write every name
    /// as UTF-8 instead (a tar that gained a non-ASCII name, a copy into another container family), and the
    /// manual choice would read those as mojibake. So the file is read automatically first. With no
    /// undeclared names other than UTF-8 left, that reading is kept and the file has no choice; otherwise
    /// the choice is remembered for the file and it is read again with it. An automatic model reads once
    /// and forgets any choice left for `url`. A failed first open leaves the file without a choice; a failed
    /// second open keeps the automatic reading, and the file without a choice.
    func openSaved(_ url: URL, open: (URL, ArchiveNameEncoding) async throws -> any ArchiveReading)
        async throws -> any ArchiveReading {
        // The file holds the renames now: a model that reads it again, should this reopen fail, keeps the
        // opened copies at their new paths. So this comes before the reopen, not after it: kept
        // on a failure, the renames would take the copies back to names the file no longer has
        // (`modelReadAfterASaveKeepsCopiesAtTheSavedNewNames`).
        // Accepted edge: an edit during the awaits below notes the unsaved renames again,
        // already-written ones included (`changes` is reset only by `didSave`). Should the reopen then fail, a
        // copy made in that window is noted at a pre-save path, and a reread puts it back there.
        openedFiles.noteArchiveSaved(by: ObjectIdentifier(self))
        let chosen = reader?.nameEncoding ?? .automatic
        nameEncodingStore.remember(.automatic, for: url)
        let automatic = try await open(url, .automatic)
        guard case .specific = chosen, let legacy = automatic.legacyNameEncoding, legacy != .utf8 else {
            return automatic
        }
        nameEncodingStore.remember(chosen, for: url)
        do {
            return try await open(url, chosen)
        } catch {
            // The file reads already: keep that reading, and no choice it doesn't show.
            Self.logger.error("Reading the saved archive with its chosen name encoding failed: \(error.localizedDescription, privacy: .public)")
            nameEncodingStore.remember(.automatic, for: url)
            return automatic
        }
    }

    /// Adopts options chosen in the save panel, so later saves keep them. Never a volume size: a split
    /// is never remembered, and a later ⌘S writes one file (`ArchiveWriter.write` refuses a volume size).
    func apply(_ settings: ArchiveSaveSettings) {
        saveOptions = settings.options
        saveOptions?.volumeSize = nil
        // A password the save won't use isn't kept. (The document's open password is `password`, below.)
        if settings.options.encryption == .none { saveOptions?.password = nil }
        password = settings.password
    }

    // MARK: - Rename and New Folder

    /// What renaming the visible item at `path` to `name` would do (`EntryNameValidation`, against the
    /// visible names in its folder, pending and source, and the hidden folders kept source entries end up
    /// in). `.invalid(.unavailable)` when nothing is there.
    func check(renaming path: String, to name: String) -> EntryNameCheck {
        guard let item = item(at: path) else { return .invalid(.unavailable) }
        let parent = Self.parentPath(of: item.path)
        let siblings = children(of: parent).map(\.name)
        let result = EntryNameValidation.check(name, current: item.name, siblings: siblings)
        if case .valid = result, isHiddenSourcePath(Self.nfc(Self.join(parent, name))) {
            return .invalid(.taken(name))
        }
        return result
    }

    /// True when a kept source entry the tree hides (Finder metadata, say `x/._y` in a folder that holds
    /// nothing else) ends up at the NFC path `key` or beneath it: an item renamed onto it would share its
    /// path in the written archive.
    private func isHiddenSourcePath(_ key: String) -> Bool {
        // `finalSpellings` holds every source entry's final path and the folders above it, hidden and removed
        // ones too; only then is the scan needed.
        guard finalSpellings[key] != nil, index[key] == nil else { return false }
        return keptHiddenSourcePaths().contains { $0 == key || key.isAncestor(of: $0) }
    }

    /// The names, case-folded, that kept source entries the tree hides take directly in the visible folder
    /// `directory` ("" = top level), from one scan: New Folder's rule for `isHiddenSourcePath`. Inside and
    /// up to the next "/" on scalars, never Characters (`d/untitled folder/\u{301}z` takes "untitled folder").
    private func hiddenSourceNames(in directory: String) -> Set<String> {
        let parent = Self.nfc(directory)
        var names = Set<String>()
        for shown in keptHiddenSourcePaths() where parent.isEmpty || parent.isAncestor(of: shown) {
            let rest = parent.isEmpty ? shown : Self.scalarSuffix(of: shown, after: parent + "/")
            names.insert(String(String.UnicodeScalarView(rest.unicodeScalars.prefix { $0 != "/" })).lowercased())
        }
        return names
    }

    /// Where each kept source entry the tree hides ends up, NFC, renames applied and removed ones skipped.
    private func keptHiddenSourcePaths() -> some Sequence<String> {
        let renames = RenameMap(changes.renamedPaths)
        let rule = RemovalRule(removed: changes.removedPaths, renames: renames)
        return (reader?.entries ?? []).lazy.filter(Self.isHidden)
            .filter { !rule.drops($0.path) }
            .map { Self.nfc(self.shownPath(ofSource: $0.path, key: Self.nfc($0.path), renames: renames)) }
    }

    /// Renames the visible item at `path` to `name` (stored as typed) as one undo step "Rename", and
    /// returns its new path. A source item goes into `changes.renamedPaths` under its exact source path,
    /// its Finder metadata companions with it; a pending one changes its addition's `archiveName`; either
    /// way, what is pending inside a renamed folder moves with it. An unchanged name returns the current
    /// path and changes nothing; a refused name, or an archive that can't be edited, changes nothing.
    func rename(_ path: String, to name: String) -> Result<String, EntryNameProblem> {
        guard isEditable, let item = item(at: path) else { return .failure(.unavailable) }
        switch check(renaming: item.path, to: name) {
        case .unchanged:
            return .success(item.path)
        case .invalid(let problem):
            return .failure(problem)
        case .valid(let name):
            let newPath = Self.join(Self.parentPath(of: item.path), name)
            let actionName = String(localized: "Rename", table: "Shared",
                                    comment: "Undo action name after renaming an item in the archive (Edit > Undo Rename).")
            // Refused until a save when the writer would drop an item moved out of a deleted folder (`edit`).
            if case .holdsMovedOutItems(let folder)? = edit(actionName: actionName, moving: [(item.path, newPath)], { state in
                relocate(item, to: newPath, in: &state)
            }) {
                return .failure(.holdsMovedOutItems(folder))
            }
            return .success(self.item(at: newPath)?.path ?? newPath)
        }
    }

    /// Stages an empty folder named "untitled folder" (or the next free "untitled folder 2"…) in the
    /// visible folder `directory` ("" = top level), as one undo step "New Folder", and returns its path.
    /// The folder on disk is the model's own, in `Kernir-NewFolders-<UUID>`, removed on close only.
    func newFolder(in directory: String) throws -> String {
        guard isEditable else { throw ArchiveError.readOnlyFormat(format) }
        let directory = Self.normalizedDirectory(directory)
        guard directory.isEmpty || item(at: directory)?.isDirectory == true else {
            throw ArchiveError.entryNotFound(directory)
        }
        // Not the name of a hidden-only folder either (`hiddenSourceNames`), case twins included, as
        // `untitledFolderName` folds case. One scan and one pick, however many such folders a crafted
        // archive holds.
        let taken = children(of: directory).map(\.name) + hiddenSourceNames(in: directory)
        let name = EntryNameValidation.untitledFolderName(siblings: taken)
        let folder = try stagedNewFolder(named: name)
        let actionName = String(localized: "New Folder", table: "Shared",
                                comment: "Undo action name after adding a new folder to the archive (Edit > Undo New Folder).")
        add([folder], to: directory, actionName: actionName)
        let path = Self.join(directory, name)
        guard let item = item(at: path), item.isPendingAddition else { throw ArchiveError.entryNotFound(path) }
        return item.path
    }

    /// Maps visible paths (selection, expansion) across a rename: `oldPath` itself or anything beneath it
    /// moves to `newPath`, the rest stays. Undo maps back with the paths swapped. Beneath is found on the
    /// "/" scalar (`parentPath(of:)`), never a Character prefix: `d/\u{301}x` is beneath `d`.
    nonisolated static func remap(_ paths: Set<String>, from oldPath: String, to newPath: String) -> Set<String> {
        Set(paths.map { path in
            if path == oldPath { return newPath }
            var ancestor = parentPath(of: path)
            while !ancestor.isEmpty {
                if ancestor == oldPath { return newPath + scalarSuffix(of: path, after: ancestor) }
                ancestor = parentPath(of: ancestor)
            }
            return path
        })
    }

    /// `remap(_:from:to:)` for several disjoint roots at once (`move(_:into:)`'s result: selection, expansion, the
    /// name field); undo maps back with keys and values swapped. The nearest moved ancestor wins.
    nonisolated static func remap(_ paths: Set<String>, moves: [String: String]) -> Set<String> {
        guard !moves.isEmpty else { return paths }
        return Set(paths.map { path in
            if let moved = moves[path] { return moved }
            var ancestor = parentPath(of: path)
            while !ancestor.isEmpty {
                if let moved = moves[ancestor] { return moved + scalarSuffix(of: path, after: ancestor) }
                ancestor = parentPath(of: ancestor)
            }
            return path
        })
    }

    // MARK: - Move

    /// A checked move: the target folder as the tree spells it ("" = top level), the items that move, and the
    /// visible items in the target they replace.
    private struct MovePlan {
        let folder: String
        let roots: [ArchiveItem]
        let conflicts: [String]
    }

    /// Visible items in `folder` that moving `paths` there would replace (same rule as `conflicts(adding:to:)`:
    /// the same name after NFC; case twins are not conflicts). [] when the move is refused.
    func conflicts(moving paths: [String], into folder: String) -> [String] {
        (try? movePlan(paths, into: folder).get())?.conflicts ?? []
    }

    /// Moves the visible items at `paths` into the visible folder `folder` ("" = top level) as one undo step
    /// "Move", and returns old path -> new path per moved root ([:] = nothing moved, no undo step). Items inside
    /// another given item move with it; items already in `folder` stay. What `conflicts(moving:into:)` lists is
    /// replaced (the UI asked first, as for Add), a whole folder included. Source items go into `renamedPaths`
    /// with their Finder metadata companions; pending additions, staged folders and opened copies move too.
    @discardableResult func move(_ paths: [String], into folder: String) -> Result<[String: String], MoveProblem> {
        let plan: MovePlan
        switch movePlan(paths, into: folder) {
        case .failure(let problem): return .failure(problem)
        case .success(let checked): plan = checked
        }
        guard !plan.roots.isEmpty else { return .success([:]) }
        let moves = plan.roots.map { (from: $0.path, to: Self.join(plan.folder, $0.name)) }
        let actionName = String(localized: "Move", table: "Shared",
                                comment: "Undo action name after moving items to another folder inside the archive (Edit > Undo Move).")
        // A pending folder a mover leaves stays, emptied or not (as in Finder).
        var leftFolders: [(key: String, name: String)] = []
        for root in plan.roots {
            let key = Self.nfc(Self.parentPath(of: root.path))
            if !key.isEmpty, pending[key] != nil, !leftFolders.contains(where: { $0.key == key }),
               let folder = index[key] { leftFolders.append((key, folder.name)) }
        }
        if let problem = edit(actionName: actionName, moving: moves, { state in
            if !plan.conflicts.isEmpty { removeReplaced(plan.conflicts.map(Self.nfc), from: &state) }
            for (item, move) in zip(plan.roots, moves) { relocate(item, to: move.to, in: &state) }
        }, finishing: { state in
            keepEmptied(leftFolders, in: &state)
        }) {
            return .failure(problem)
        }
        var result: [String: String] = [:]
        for move in moves { result[move.from] = item(at: move.to)?.path ?? move.to }
        return .success(result)
    }

    /// `move(_:into:)`'s checks, in order: editable and every item there (`.unavailable`), the target a
    /// visible folder (`.notAFolder`), `MovePlanning.roots` (`.intoItself`), no two items ending up with one
    /// name in the target, a mover and an item already there included (`.taken`), no hidden kept source entry
    /// at a target path, and no replaced item holding a moved one (`.taken`).
    private func movePlan(_ paths: [String], into folder: String) -> Result<MovePlan, MoveProblem> {
        guard isEditable else { return .failure(.unavailable) }
        var visible: [String] = []
        for path in paths {
            guard let item = item(at: path) else { return .failure(.unavailable) }
            visible.append(item.path)
        }
        let directory = Self.normalizedDirectory(folder)
        var folderPath = ""
        if !directory.isEmpty {
            guard let target = item(at: directory), target.isDirectory, !hasFileAtOrAbove(directory) else {
                return .failure(.notAFolder)
            }
            folderPath = target.path
        }
        let rootPaths: [String]
        switch MovePlanning.roots(visible, into: folderPath) {
        case .failure(let problem): return .failure(problem)
        case .success(let paths): rootPaths = paths
        }
        var names = Set<String>()
        for path in MovePlanning.topLevel(visible) {
            let name = ArchiveEntry.name(of: path)
            guard names.insert(Self.nfc(name)).inserted else { return .failure(.taken(name)) }
        }
        let roots = rootPaths.compactMap { item(at: $0) }
        let state = editState
        let rootSources = state.changes.renamedPaths.isEmpty ? []
            : roots.compactMap { sourcePath(ofVisible: Self.nfc($0.path), in: state).map { Self.nfc($0.lookup) } }
        var conflicts: [String] = []
        for root in roots {
            let key = Self.nfc(Self.join(folderPath, root.name))
            if let existing = index[key] {
                // Replacing it would take a moved item with it (removals match source paths before renames).
                if roots.contains(where: { existing.path.isAncestor(of: $0.path) }) { return .failure(.taken(root.name)) }
                if let source = sourcePath(ofVisible: key, in: state).map({ Self.nfc($0.lookup) }),
                   rootSources.contains(where: { Self.isCovered($0, by: [source]) }) {
                    return .failure(.taken(root.name))
                }
                conflicts.append(existing.path)
            } else if isHiddenSourcePath(key) {
                return .failure(.taken(root.name))
            }
        }
        return .success(MovePlan(folder: folderPath, roots: roots, conflicts: conflicts))
    }

    /// Removes what a move replaces, and their Finder metadata at once (not only in `edit`): a mover's own
    /// companion then takes the freed place.
    private func removeReplaced(_ paths: [String], from state: inout EditState) {
        let before = state.changes.removedPaths
        remove(paths, from: &state)
        let removed = state.changes.removedPaths.subtracting(before)
        guard !removed.isEmpty else { return }
        if let entries = reader?.entries {
            state.changes.removedPaths.formUnion(Archive.macOSCompanions(of: Array(removed), in: entries))
        }
        state.changes.renamedPaths = Self.keptRenames(state.changes.renamedPaths, removed: state.changes.removedPaths)
    }

    /// Stages again, as an empty folder of its own, each pending folder in `folders` that the move emptied.
    private func keepEmptied(_ folders: [(key: String, name: String)], in state: inout EditState) {
        for (key, name) in folders where state.pending[key] == nil
            && !state.pending.keys.contains(where: { key.isAncestor(of: $0) })
            && !state.changes.renamedPaths.values.contains(where: { Self.isCovered(Self.nfc($0), by: [key]) }) {
            guard let url = try? stagedNewFolder(named: name) else { continue }
            state.changes.additions.append(.init(sourceURL: url,
                                                 destinationDirectory: archiveSpelling(of: Self.parentPath(of: key))))
            for entry in Self.pendingEntries(for: url, at: key) { state.pending[entry.entry.path] = entry }
        }
    }

    /// A fresh, empty folder `name` on disk for New Folder, in a folder of its own (so undo and redo can
    /// keep using it while another New Folder takes the same name elsewhere).
    private func stagedNewFolder(named name: String) throws -> URL {
        let root: URL
        if let newFoldersDirectory {
            root = newFoldersDirectory
        } else {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("Kernir-NewFolders-\(UUID().uuidString)", isDirectory: true)
            newFoldersDirectory = root
            temporaryDirectories.append(root)
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Puts the visible `item` at `newPath` in `state`: a rename (same folder, a valid, changed name) or a move
    /// (another folder, same name, nothing there any more).
    private func relocate(_ item: ArchiveItem, to newPath: String, in state: inout EditState) {
        let oldKey = Self.nfc(item.path)
        let name = ArchiveEntry.name(of: newPath)
        let newKey = Self.nfc(newPath)
        let newParent = Self.parentPath(of: newKey)
        let changesFolder = newParent != Self.parentPath(of: oldKey)
        // A source item (or source folder): through the rename map, which folds chains and drops a
        // rename back. The key is the item's source path as the reader lists it, in the tree's spelling.
        if let source = sourcePath(ofVisible: oldKey, in: state) {
            var renames = RenameMap(state.changes.renamedPaths)
            renames.rename(finalPath: item.path, to: newPath)
            for (companion, target) in RenameMap.companionMoves(of: source.lookup, to: newPath, existing: sourceEntryPaths)
            where !isKeptSourcePath(target, renames: renames, removed: state.changes.removedPaths) {
                renames.rename(finalPath: renames.finalPath(ofSource: companion), to: target)
            }
            state.changes.renamedPaths = renames.sourceToFinal
        } else if !state.changes.renamedPaths.isEmpty {
            // What was moved into a pending folder follows it.
            var renames = RenameMap(state.changes.renamedPaths)
            renames.moveFinals(from: item.path, to: newPath)
            state.changes.renamedPaths = renames.sourceToFinal
        }
        // A pending item inside an added folder: `archiveName` names only an addition's top, so the item
        // becomes an addition of its own (the folder is split as Delete splits it).
        if let entry = state.pending[oldKey], !state.changes.additions.contains(where: { Self.topPath(of: $0) == oldKey }) {
            let moved = state.pending.filter { Self.isCovered($0.key, by: [oldKey]) }
            let inner = state.changes.additions.filter { Self.isCovered(Self.topPath(of: $0), by: [oldKey]) }
            remove([oldKey], from: &state, includingSources: false)
            state.changes.additions.append(.init(sourceURL: entry.url,
                                                 destinationDirectory: archiveSpelling(of: Self.parentPath(of: oldKey)),
                                                 archiveName: Self.archiveName(name, for: entry.url)))
            state.changes.additions += inner
            state.pending.merge(moved) { _, kept in kept }
        }
        // Pending items at or beneath the item move with it: the addition at its path takes the name,
        // additions placed inside it follow.
        for index in state.changes.additions.indices {
            let addition = state.changes.additions[index]
            if Self.topPath(of: addition) == oldKey {
                state.changes.additions[index].archiveName = Self.archiveName(name, for: addition.sourceURL)
                if changesFolder { state.changes.additions[index].destinationDirectory = archiveSpelling(of: newParent) }
            } else if let moved = Self.relocated(addition.destinationDirectory, from: oldKey, to: newPath) {
                state.changes.additions[index].destinationDirectory = moved
            }
        }
        if state.pending.keys.contains(where: { Self.isCovered($0, by: [oldKey]) }) {
            var pending: [String: PendingEntry] = [:]
            for (key, entry) in state.pending {
                if let moved = Self.relocated(key, from: oldKey, to: newKey) {
                    pending[moved] = PendingEntry(entry: entry.entry.with(path: moved), url: entry.url)
                } else {
                    pending[key] = entry
                }
            }
            state.pending = pending
        }
    }

    /// The source path of the kept source item visible at the NFC path `path` in `state`: in the tree's
    /// spelling (`lookup`, what `RenameMap` and `renamedPaths` keys use) and as the reader first spells
    /// it (`reader`). Nil when no kept source item is there: a pending item, a removed one, or a free
    /// name (the old name of a renamed item included).
    private func sourcePath(ofVisible path: String, in state: EditState) -> (lookup: String, reader: String)? {
        let renames = RenameMap(state.changes.renamedPaths)
        let shown = index[path]?.path ?? path
        let lookup = renames.sourceToFinal.isEmpty ? shown : renames.sourcePath(ofFinal: shown)
        guard let spelled = sourcePaths[Self.nfc(lookup)],
              renames.sourceToFinal.isEmpty || Self.nfc(renames.finalPath(ofSource: lookup)) == path,
              !RemovalRule(removed: state.changes.removedPaths, renames: renames).drops(spelled) else { return nil }
        return (lookup, spelled)
    }

    /// True when a kept source entry already ends up at `path`: a companion never moves onto it (the
    /// writer would refuse two entries on one path).
    private func isKeptSourcePath(_ path: String, renames: RenameMap, removed: Set<String>) -> Bool {
        sourceEntryPaths.contains(path) && Self.isSameSpelling(renames.finalPath(ofSource: path), path)
            && !RemovalRule(removed: removed, renames: renames).drops(path)
    }

    /// `archiveName` for an addition of `url` named `name`: nil when that is the name on disk.
    private nonisolated static func archiveName(_ name: String, for url: URL) -> String? {
        isSameSpelling(name, url.lastPathComponent) ? nil : name
    }

    /// `path` moved from beneath the NFC path `old` to beneath `new`, component by component, the rest
    /// keeping its own spelling; nil when `path` is neither `old` nor beneath it. Split on the "/" scalar, as
    /// `depth(of:)` counts, never on Characters.
    private nonisolated static func relocated(_ path: String, from old: String, to new: String) -> String? {
        let components = path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        let count = depth(of: old) + 1
        guard components.count >= count, nfc(components.prefix(count).joined(separator: "/")) == old else { return nil }
        return ([new] + components.dropFirst(count)).joined(separator: "/")
    }

    // MARK: - Comment

    /// Whether the window shows an archive comment: ZIP only in 0.1.0, when the archive has
    /// one or one can be written.
    var showsComment: Bool {
        ArchiveCommentText.supportsComments(format) && (reader?.comment != nil || canEditComment)
    }

    /// Whether the comment can be changed: an editable single-file ZIP whose comment the reader doesn't call
    /// read-only. Never for a split set (`isEditable`): the split writer takes no comment change.
    var canEditComment: Bool {
        isEditable && ArchiveCommentText.supportsComments(format) && reader?.comment?.isWritable != false
    }

    /// The comment as the save will write it: the edited text, else the source's, else "".
    var commentText: String {
        switch changes.comment {
        case .set(let text): text
        case .remove: ""
        case .keep: reader?.comment?.text ?? ""
        }
    }

    /// Sets the comment as an undo step "Edit Comment". Text equal to the source's keeps the source's bytes
    /// (`.keep`); "" removes the comment (`.keep` when there was none); other text is written as UTF-8
    /// (`.set`), as typed. Text the engine would refuse is accepted here: `commentProblem` says why, and the
    /// save refuses it. Does nothing unless `canEditComment`.
    ///
    /// Typing is one undo step, as in any text field: consecutive calls join the step the first one made,
    /// until `endCommentTyping()`, another edit, an undo or redo, or a save. Typing back to the text the step began
    /// with removes the step: nothing is left to undo or save for it.
    func setComment(_ text: String) {
        guard canEditComment else { return }
        let source = reader?.comment
        let change: ArchiveChangeSet.CommentChange
        if let source, text == source.text {
            change = .keep
        } else if text.isEmpty {
            change = source == nil ? .keep : .remove
        } else {
            change = .set(text)
        }
        if let base = commentTypingBase, let undoManager, undoManager.canUndo, !undoManager.isUndoing,
           !undoManager.isRedoing, undoManager.undoActionName == Self.editCommentActionName {
            // The open step already restores the text from before the typing.
            var new = editState
            new.changes.comment = change
            // Back where the step began: undo it, unless a group is open (undo would close and undo that one).
            if new == base, undoManager.groupingLevel == 0 {
                isDroppingTypingStep = true
                undoManager.undo()
                isDroppingTypingStep = false
                return
            }
            apply(new)
            return
        }
        let before = editState
        edit(actionName: Self.editCommentActionName) { $0.changes.comment = change }
        // Only a step this call opened takes the typing that follows.
        commentTypingBase = undoManager != nil && editState != before ? before : nil
    }

    /// Ends the typing `setComment` joins into one undo step: the next edit of the comment is a step of its own.
    /// The comment field calls it when it closes.
    func endCommentTyping() {
        commentTypingBase = nil
    }

    private static var editCommentActionName: String { String(localized: "Edit Comment", table: "Shared") }

    /// Why the edited comment can't be saved (too long, or it holds a ZIP end-record signature); nil when it
    /// can, or when it isn't edited.
    var commentProblem: String? {
        guard case .set(let text) = changes.comment else { return nil }
        return ArchiveCommentText.validationMessage(for: text)
    }

    /// Why a save into split volumes must be refused before writing: a comment typed for it, which a split set
    /// can't hold. Every split save writes `.keep` (`writeVolumes` throws for anything else), and `.keep` writes no
    /// comment into a set, the source's included. So a pending `.remove` gets what it asks for and is no problem; a
    /// pending `.set` would be lost, and refuses the save. nil otherwise.
    var splitSaveProblem: String? {
        guard case .set = changes.comment else { return nil }
        return String(localized: "A split archive can’t have a comment.", table: "Shared")
    }

    /// What to do about `splitSaveProblem`, shown under it when the save is refused.
    static var splitSaveRecoverySuggestion: String {
        String(localized: "Remove the comment, or turn off splitting.", table: "Shared")
    }

    /// Why a save as `format` (into split volumes when `split`) must be refused before anything is written,
    /// or nil. A format without comments drops the comment edit (`saveChanges(as:)`), split or not, so the
    /// edit can't refuse that save.
    func saveProblem(as format: ArchiveFormat?, split: Bool) -> String? {
        guard ArchiveCommentText.supportsComments(format) else { return nil }
        return split ? splitSaveProblem : commentProblem
    }

    /// The changes a save as `format` writes: `changes`, but with the comment kept (`.keep`) for a format that
    /// has none, where the engine would throw for `.set`. Converting drops the source's comment the same way.
    func saveChanges(as format: ArchiveFormat?) -> ArchiveChangeSet {
        var changes = changes
        if !ArchiveCommentText.supportsComments(format) { changes.comment = .keep }
        return changes
    }

    /// The Info popover's (Mac) and Info sheet's (iOS) rows. The file size is the archive's on disk, all
    /// parts of a split set together, as `loadInfoFileSize()` last read it; nil before that, for a new
    /// archive, or when any part can't be read.
    var infoSummary: ArchiveInfoSummary {
        ArchiveInfoSummary(format: format, itemCount: itemCount, size: totalSize, compressedSize: compressedSize,
                           fileSize: infoFileSize, encryption: reader?.encryption ?? .none)
    }

    /// Reads the archive's size on disk for `infoSummary`, off the main actor (a slow or network volume would
    /// stall the window). A save while it reads makes the result stale: it is dropped, and `infoFileSize` stays
    /// nil until the next load. The Info views call it when they appear and after each save (`snapshotGeneration`).
    func loadInfoFileSize() async {
        let generation = snapshotGeneration
        let urls = reader?.volumeURLs ?? []
        let size = await Task.detached { Self.fileSize(of: urls) }.value
        guard generation == snapshotGeneration else { return }
        infoFileSize = size
    }

    private nonisolated static func fileSize(of urls: [URL]) -> Int64? {
        var total: Int64 = 0
        for url in urls {
            // A fresh URL each time: a URL caches its resource values, and the file may have been saved over.
            let fresh = url.isFileURL ? URL(filePath: url.path(percentEncoded: false), directoryHint: .notDirectory) : url
            guard let size = try? fresh.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            total += Int64(size)
        }
        return urls.isEmpty ? nil : total
    }

    // MARK: - Editing

    private var editState: EditState {
        EditState(changes: changes, pending: pending)
    }

    /// A rename's or a move's move of opened copies (`OpenedFiles.renameItems`): from and to a visible path, keeping
    /// in place the copies that stayed when the step it undoes or redoes was applied.
    private typealias CopiesMove = (from: String, to: String, keeping: Set<URL>)

    /// `moves`: the visible paths a rename or a move takes items from, and to (disjoint roots). Opened copies of
    /// them, or of items inside them, follow them there (`OpenedFiles.renameItems`), and back on undo: only
    /// those that moved, and those tracked since. Refused, nothing changed and no undo step, when the writer would
    /// drop an item moved out of a deleted folder that the edit does not remove (`lostMovedOutItem`): until a save,
    /// say, a folder renamed to the deleted folder's name with the item in it. `finishing` runs after that check
    /// (its changes leave `removedPaths` and `renamedPaths` alone): what stages files on disk, so a refused edit
    /// leaves none behind.
    @discardableResult
    private func edit(actionName: String, moving moves: [(from: String, to: String)] = [],
                      _ mutate: (inout EditState) -> Void,
                      finishing: (inout EditState) -> Void = { _ in }) -> MoveProblem? {
        // Any edit ends the comment typing; `setComment` opens it again after its own.
        commentTypingBase = nil
        let old = editState
        var new = old
        removalTargets = []
        mutate(&new)
        let targets = removalTargets
        removalTargets = []
        // Finder metadata (`__MACOSX/…`, `._name`) goes with the source items it describes; the
        // writer never drops it on its own.
        let removed = new.changes.removedPaths.subtracting(old.changes.removedPaths)
        if !removed.isEmpty, let entries = reader?.entries {
            new.changes.removedPaths.formUnion(Archive.macOSCompanions(of: Array(removed), in: entries))
        }
        // A removed source entry's rename goes with it; one moved out of a removed folder stays (`RemovalRule`).
        if !removed.isEmpty, !new.changes.renamedPaths.isEmpty {
            new.changes.renamedPaths = Self.keptRenames(new.changes.renamedPaths, removed: new.changes.removedPaths)
        }
        // Checked only when a moved-out item could be lost: removals and renames (a comment edit leaves it alone).
        let movedOut = !new.changes.removedPaths.isEmpty
            && !(old.changes.renamedPaths.isEmpty && new.changes.renamedPaths.isEmpty)
        if movedOut, let name = Self.lostMovedOutItem(from: old.changes, to: new.changes, removing: targets) {
            return .holdsMovedOutItems(name)
        }
        finishing(&new)
        guard new != old else { return nil }
        apply(new)
        let undo = moves.map { moved -> CopiesMove in
            (moved.to, moved.from, openedFiles.renameItems(from: moved.from, to: moved.to))
        }
        registerUndo(restoring: old, actionName: actionName, moving: undo)
        return nil
    }

    /// `renamed` without the renames of entries the writer drops for `removed` (`RemovalRule`).
    private nonisolated static func keptRenames(_ renamed: [String: String], removed: Set<String>) -> [String: String] {
        let rule = RemovalRule(removed: removed, renames: RenameMap(renamed))
        return renamed.filter { !rule.drops($0.key) }
    }

    /// The name of a deleted folder (its final path's) when `new` drops a source item moved out of it that `old`
    /// keeps and the edit did not remove (`targets`: the visible NFC paths it removed, Delete's and Replace's):
    /// a rename or move put it back at or beneath that folder's final path, where the writer drops it. Checked for
    /// each such rename key: the governing key decides for its whole subtree (`RemovalRule`), so an entry beneath a
    /// key is lost only with the key, or for a removed path between them, which this edit removed.
    private nonisolated static func lostMovedOutItem(from old: ArchiveChangeSet, to new: ArchiveChangeSet,
                                                     removing targets: Set<String>) -> String? {
        let removed = new.removedPaths
        guard !removed.isEmpty else { return nil }
        // Only an entry whose rename key lies strictly beneath a removed path is kept by the exception.
        let keys = Set(old.renamedPaths.keys).union(new.renamedPaths.keys)
            .filter { isCovered(parentPath(of: $0), by: removed) }
        guard !keys.isEmpty else { return nil }
        let oldRenames = RenameMap(old.renamedPaths), newRenames = RenameMap(new.renamedPaths)
        let oldRule = RemovalRule(removed: old.removedPaths, renames: oldRenames)
        let newRule = RemovalRule(removed: removed, renames: newRenames)
        for key in keys.sorted(by: byteOrder) {
            let oldFinal = oldRenames.finalPath(ofSource: key)
            guard !oldRule.drops(key), !isCovered(nfc(oldFinal), by: targets) else { continue }
            let newFinal = newRenames.finalPath(ofSource: key)
            guard newRule.drops(key) else { continue }
            let finals = removed.map(newRenames.finalPath(ofSource:))
            let folder = finals.filter { isCovered(newFinal, by: [$0]) }.max { $0.utf8.count < $1.utf8.count }
                ?? newRenames.finalPath(ofSource: coveringPath(of: parentPath(of: key), in: removed) ?? key)
            return ArchiveEntry.name(of: folder)
        }
        return nil
    }

    private func apply(_ state: EditState) {
        // A comment edit alone leaves the tree as it is: no rebuild for every keystroke in the comment field.
        var entriesBefore = changes
        entriesBefore.comment = state.changes.comment
        let treeChanged = entriesBefore != state.changes || pending != state.pending
        changes = state.changes
        pending = state.pending
        if treeChanged { rebuild() }
    }

    private func registerUndo(restoring state: EditState, actionName: String, moving moved: [CopiesMove] = []) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            model.restore(state, actionName: actionName, moving: moved)
        }
        undoManager.setActionName(actionName)
    }

    /// Undo and redo: registering the inverse while undoing puts it on the redo stack.
    private func restore(_ state: EditState, actionName: String, moving moved: [CopiesMove]) {
        commentTypingBase = nil
        let current = editState
        apply(state)
        // Opened copies follow the restored state even when no redo step is registered for it.
        let inverse = moved.reversed().map { moved -> CopiesMove in
            (moved.to, moved.from, openedFiles.renameItems(from: moved.from, to: moved.to, keeping: moved.keeping))
        }
        // A typing step typed back to where it began leaves nothing to redo.
        guard !isDroppingTypingStep else { return }
        registerUndo(restoring: current, actionName: actionName, moving: inverse)
    }

    /// Removes one visible (or about-to-be-replaced) path from `state`.
    private func remove(_ path: String, from state: inout EditState) {
        remove([path], from: &state)
    }

    /// Removes visible (or about-to-be-replaced) `paths` from `state`, none of them inside another.
    /// One pass over the additions and one over the pending entries, however many paths there are.
    /// `includingSources: false` leaves source items alone (relocate's split of a pending folder: what was
    /// moved into it moves on with it). Their visible paths are what `edit` lets go (`lostMovedOutItem`).
    private func remove(_ paths: [String], from state: inout EditState, includingSources: Bool = true) {
        let roots = Set(paths)
        if includingSources {
            removalTargets.formUnion(roots)
            // `edit` adds the Finder metadata of what this removes, and drops the renames that go with it.
            state.changes.removedPaths.formUnion(sourceRemoval(of: roots, in: state))
        }
        // What each path was before anything changes: pending, and the top of an addition or not.
        let additionTops = Set(state.changes.additions.map(Self.topPath(of:)))
        var pendingRoots = Set<String>()
        var splitRoots: [String] = []
        for path in paths {
            if state.pending[path] != nil {
                pendingRoots.insert(path)
                if !additionTops.contains(path) { splitRoots.append(path) }
            }
        }
        // Writer removals never apply to additions, so additions at or under a path go too.
        var droppedRoots = Set<String>()
        state.changes.additions.removeAll { addition in
            guard let root = Self.coveringPath(of: Self.topPath(of: addition), in: roots) else { return false }
            droppedRoots.insert(root)
            return true
        }
        // Inside a pending folder: split the innermost folder addition that contains the path.
        if !splitRoots.isEmpty { split(excluding: splitRoots, removing: roots, in: &state) }
        let pendingChanged = pendingRoots.union(droppedRoots)
        if !pendingChanged.isEmpty {
            state.pending = state.pending.filter { !Self.isCovered($0.key, by: pendingChanged) }
            // A pending item inside a folder from disk takes its `._name` companion along.
            for path in pendingChanged {
                if let companion = Self.companionPath(of: path) { state.pending[companion] = nil }
            }
        }
    }

    /// What removing the visible NFC paths `roots` takes from the source archive in `state` (`remove(_:from:)`), for
    /// `removedPaths` as the reader spells them: each root's source path, and the source path of each item moved into
    /// a root from outside that root's source (`renamedPaths` keys). Items moved out of a root stay (`RemovalRule`).
    private func sourceRemoval(of roots: Set<String>, in state: EditState) -> [String] {
        var removed: [String] = []
        var sourceOfRoot: [String: String] = [:]
        for root in roots {
            guard let source = sourcePath(ofVisible: root, in: state) else { continue }
            removed.append(source.reader)
            sourceOfRoot[root] = Self.nfc(source.lookup)
        }
        for (key, value) in state.changes.renamedPaths {
            guard let root = Self.coveringPath(of: Self.nfc(value), in: roots) else { continue }
            if let source = sourceOfRoot[root], Self.isCovered(Self.nfc(key), by: [source]) { continue }
            removed.append(key)
        }
        return removed
    }

    /// Replaces each folder addition that contains one of `paths` with one addition per remaining
    /// child along the way down to those paths, so none of them is added any more. The folders on
    /// that way stop being pending entries of their own; `rebuild` shows them as synthesized folders.
    /// Nothing in `removed` (the whole delete, `paths` included) comes back as a child: an addition
    /// nested in the folder that the same delete dropped is no longer among the other tops.
    private func split(excluding paths: [String], removing removed: Set<String>, in state: inout EditState) {
        let tops = state.changes.additions.map(Self.topPath(of:))
        var indexOfTop: [String: Int] = [:]
        for (index, top) in tops.enumerated() { indexOfTop[top] = index }
        // The folders from each owning addition's top down to the parent of an excluded path.
        var levelsByOwner: [Int: Set<String>] = [:]
        var levelOwner: [String: Int] = [:]
        var excluded = removed.union(removed.compactMap(Self.companionPath(of:)))
        for path in paths {
            // The folders between the owning top and the path, innermost first, as `path` spells them.
            var below: [String] = []
            var ancestor = Self.parentPath(of: path)
            var owner: Int?
            while !ancestor.isEmpty {
                if let index = indexOfTop[ancestor] {
                    owner = index
                    break
                }
                below.append(ancestor)
                ancestor = Self.parentPath(of: ancestor)
            }
            guard let owner else { continue }
            // Spelled like the top, then like `path` below it (cut on scalars, never a Character count).
            let levels = [tops[owner]]
                + below.reversed().map { tops[owner] + Self.scalarSuffix(of: $0, after: ancestor) }
            for level in levels {
                levelsByOwner[owner, default: []].insert(level)
                levelOwner[level] = owner
            }
        }
        guard !levelsByOwner.isEmpty else { return }
        excluded.formUnion(levelOwner.keys)
        let otherTops = Set(tops)
        var children: [String: [PendingEntry]] = [:]
        for (key, entry) in state.pending
        where levelOwner[Self.parentPath(of: entry.entry.path)] != nil && !excluded.contains(key)
            && !otherTops.contains(key) {
            children[Self.parentPath(of: entry.entry.path), default: []].append(entry)
        }
        var additions: [ArchiveChangeSet.Addition] = []
        for (index, addition) in state.changes.additions.enumerated() {
            guard let levelSet = levelsByOwner[index] else {
                additions.append(addition)
                continue
            }
            // Outermost first, as the chain runs down to the excluded path.
            let levels = levelSet.sorted { a, b in
                let (x, y) = (Self.depth(of: a), Self.depth(of: b))
                return x != y ? x < y : Self.byteOrder(a, b)
            }
            for level in levels {
                additions += (children[level] ?? [])
                    .sorted { Self.finderOrder($0.entry, $1.entry) }
                    .map { ArchiveChangeSet.Addition(sourceURL: $0.url, destinationDirectory: archiveSpelling(of: level)) }
            }
        }
        state.changes.additions = additions
        for level in levelOwner.keys { state.pending[level] = nil }
    }

    /// True when `directory` or one of its ancestors is a file, so nothing can be added there.
    private func hasFileAtOrAbove(_ directory: String) -> Bool {
        var current = directory
        while !current.isEmpty {
            if let item = item(at: current), !item.isDirectory { return true }
            current = Self.parentPath(of: current)
        }
        return false
    }

    /// `directory` as the tree spells it (the source archive's spelling, possibly NFD, or a renamed
    /// folder's final path) for its longest existing ancestor, so the writer never creates a second
    /// folder beside it and the tree never shows one. New folders stay NFC.
    private func archiveSpelling(of directory: String) -> String {
        var current = directory
        var tail = ""
        while !current.isEmpty {
            if let spelled = finalSpellings[current] { return spelled + tail }
            tail = Self.scalarSuffix(of: current, after: Self.parentPath(of: current)) + tail
            current = Self.parentPath(of: current)
        }
        return directory
    }

    private func hasAdditions(inside path: String) -> Bool {
        changes.additions.contains { path.isAncestor(of: Self.topPath(of: $0)) }
    }

    // MARK: - Merged tree

    private func indexSource() {
        var paths: [String: String] = [:]
        var mixed = Set<String>()
        var exact = Set<String>()
        for entry in reader?.entries ?? [] {
            var spelled = entry.path
            while !spelled.isEmpty, exact.insert(spelled).inserted { spelled = Self.parentPath(of: spelled) }
            let key = Self.nfc(entry.path)
            if let known = paths[key] {
                if entry.isDirectory, !Self.isSameSpelling(known, entry.path) { mixed.insert(key) }
            } else {
                paths[key] = entry.path
            }
            // Folders without an entry of their own keep the spelling their children use.
            var parent = Self.parentPath(of: entry.path)
            while !parent.isEmpty {
                let key = Self.nfc(parent)
                if let known = paths[key] {
                    // Same spelling: so are all its ancestors.
                    if Self.isSameSpelling(known, parent) { break }
                    mixed.insert(key)
                } else {
                    paths[key] = parent
                }
                parent = Self.parentPath(of: parent)
            }
        }
        sourcePaths = paths
        mixedFolders = mixed
        sourceEntryPaths = exact
        displayPaths = mixed.isEmpty ? [:] : Self.displaySpellings(for: paths)
    }

    /// Spells every path's folders like the folder's own first spelling, outermost first, and
    /// keeps the paths that then differ from `paths`. Only paths below a mixed folder can.
    private nonisolated static func displaySpellings(for paths: [String: String]) -> [String: String] {
        var display: [String: String] = [:]
        for key in paths.keys.sorted(by: { depth(of: $0) < depth(of: $1) }) {
            let parent = parentPath(of: key)
            guard !parent.isEmpty, let own = paths[key], let parentDisplay = display[parent] ?? paths[parent]
            else { continue }
            let spelled = parentDisplay + scalarSuffix(of: own, after: parentPath(of: own))
            if !isSameSpelling(spelled, own) { display[key] = spelled }
        }
        return display
    }

    private nonisolated static func depth(of path: String) -> Int {
        path.utf8.reduce(0) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
    }

    /// The path the reader knows `item` by: its own spelling in the source archive, before any rename.
    private func readerPath(of item: ArchiveItem) -> String {
        let source = changes.renamedPaths.isEmpty ? item.path
            : RenameMap(changes.renamedPaths).sourcePath(ofFinal: item.path)
        return sourcePaths[Self.nfc(source)] ?? source
    }

    /// Where the tree shows the source entry at `path` (`key` = its NFC form): its display spelling,
    /// moved to its final path when a rename moves it. Renames are looked up by display spelling, the
    /// tree's, so one key moves a folder spelled both NFC and NFD (as for the writer, where the two
    /// spellings are one key).
    private func shownPath(ofSource path: String, key: String, renames: RenameMap) -> String {
        let display = displayPaths[key] ?? path
        return renames.sourceToFinal.isEmpty ? display : renames.finalPath(ofSource: display)
    }

    /// Finder metadata, or anything inside a hidden `._` folder (which would otherwise be
    /// synthesized as a visible parent).
    private nonisolated static func isHidden(_ entry: ArchiveEntry) -> Bool {
        isHidden(path: entry.path)
    }

    /// KernirCore's `isMacOSMetadata` (`MacOSMetadata.isMetadata`: a `__MACOSX` path component at any depth,
    /// or a `._` last name), plus a `._` folder anywhere above. All on UTF-8 bytes, as
    /// `MacOSMetadata` compares them, never Characters: "/" or "_" followed by a combining mark (U+0301)
    /// is one Character, so on Characters `"._\u{301}x".hasPrefix("._")`,
    /// `"a/__MACOSX/\u{301}x"` split on "/" and `"a/._\u{301}x".contains("/._")` all miss what core counts
    /// as metadata. The targets are ASCII with no canonical equivalent but themselves, so bytes compare as
    /// String's `==` does.
    private nonisolated static func isHidden(path: String) -> Bool {
        let bytes = path.utf8
        return ArchiveEntry.isMacOSMetadata(path: path)
            || bytes.starts(with: "._".utf8) || bytes.contains("/._".utf8)
    }

    private func rebuild() {
        let removed = changes.removedPaths
        let renames = RenameMap(changes.renamedPaths)
        let rule = RemovalRule(removed: removed, renames: renames)
        var entries: [ArchiveEntry] = []
        var spellings: [String: String] = [:]
        // NFC/NFD twins are one item: first wins. The tree tells spellings apart by their bytes,
        // so entries below a folder spelled more than one way take its display spelling.
        var seen = Set<String>()
        for entry in reader?.entries ?? [] {
            let key = Self.nfc(entry.path)
            // Renames move a source entry to its final path (`renamedPaths` keys are its exact spelling).
            let shown = shownPath(ofSource: entry.path, key: key, renames: renames)
            let shownKey = Self.isSameSpelling(shown, entry.path) ? key : Self.nfc(shown)
            // Every spelling, hidden and removed entries too (as `sourcePaths` keeps them): first wins.
            var (spelled, spelledKey) = (shown, shownKey)
            while !spelled.isEmpty, spellings[spelledKey] == nil {
                spellings[spelledKey] = spelled
                spelled = Self.parentPath(of: spelled)
                spelledKey = Self.nfc(spelled)
            }
            if Self.isHidden(entry) { continue }
            if !seen.insert(key).inserted { continue }
            if !removed.isEmpty, rule.drops(entry.path) { continue }
            if !pending.isEmpty, pending[shownKey] != nil { continue }
            entries.append(Self.isSameSpelling(shown, entry.path) ? entry : entry.with(path: shown))
        }
        finalSpellings = spellings

        var pendingPaths = Set<String>()
        if !pending.isEmpty {
            var folders = Set(entries.lazy.filter(\.isDirectory).map(\.path))
            // Sorted: dictionary order varies per process.
            for key in pending.keys.sorted(by: Self.byteOrder) {
                guard let item = pending[key], !Self.isHidden(item.entry) else { continue }
                // The tree tells NFC/NFD twins apart by their bytes: spell pending paths like the
                // tree spells the source folders, or a pending file would sit in a second, NFC folder.
                let path = archiveSpelling(of: key)
                pendingPaths.insert(path)
                entries.append(item.entry.with(path: path))
                // Show folders the writer will create for additions placed in new directories.
                var parent = Self.parentPath(of: path)
                while !parent.isEmpty, pending[parent] == nil, !folders.contains(parent) {
                    folders.insert(parent)
                    pendingPaths.insert(parent)
                    entries.append(ArchiveEntry(path: parent, isDirectory: true, size: nil,
                                                compressedSize: nil, modificationDate: nil))
                    parent = Self.parentPath(of: parent)
                }
            }
        }

        // Archive.tree does not order names that compare equal (e.g. "a" / "A"); fix them by path.
        let nodes = Self.stabilized(Archive.tree(from: entries))
        var totals = Totals(compressedSize: changes.additions.isEmpty && pending.isEmpty ? 0 : nil)
        Self.accumulate(nodes, into: &totals)
        items = ArchiveItem.items(from: nodes, pendingPaths: pendingPaths)
        itemsRevision &+= 1
        index = Dictionary(items.flattened().map { (Self.nfc($0.path), $0) },
                           uniquingKeysWith: { first, _ in first })
        self.totals = totals
    }

    /// Orders runs of equal-comparing siblings by path, recursively.
    private nonisolated static func stabilized(_ nodes: [ArchiveNode]) -> [ArchiveNode] {
        var result = nodes.map { node in
            node.children == nil ? node
                : ArchiveNode(entry: node.entry, children: stabilized(node.children ?? []), totalSize: node.totalSize)
        }
        var start = 0
        while start < result.count {
            var end = start + 1
            while end < result.count,
                  result[end - 1].entry.isDirectory == result[end].entry.isDirectory,
                  result[end - 1].entry.name.localizedStandardCompare(result[end].entry.name) == .orderedSame {
                end += 1
            }
            if end - start > 1 { result[start..<end].sort { byteOrder($0.entry.path, $1.entry.path) } }
            start = end
        }
        return result
    }

    private nonisolated static func accumulate(_ nodes: [ArchiveNode], into totals: inout Totals) {
        for node in nodes {
            totals.itemCount += 1
            if let children = node.children {
                accumulate(children, into: &totals)
            } else {
                if let total = totals.totalSize {
                    totals.totalSize = node.entry.size.map { total + $0 }
                }
                if let total = totals.compressedSize {
                    totals.compressedSize = node.entry.compressedSize.map { total + $0 }
                }
            }
        }
    }

    /// UTF-8 byte order: String's `<` treats NFC and NFD spellings as equal.
    private nonisolated static func byteOrder(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }

    private nonisolated static func finderOrder(_ a: ArchiveEntry, _ b: ArchiveEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return byteOrder(a.path, b.path)  // deterministic order for names like "a" / "A"
        }
    }

    // MARK: - Extraction

    private struct ExtractionPlan: Sendable {
        var sourcePaths: [String] = []
        var directories: [String] = []
        var copies: [(from: URL, to: String)] = []
        /// Source items the reader writes under their paths before a rename (theirs or a folder's above
        /// them), each moved to its final path in staging before the pending items are written
        /// (`placeRenamed`): reader path -> final path.
        var renamed: [(from: String, to: String)] = []
        /// Each requested item's path in staging as it is written: the reader's spelling for a source
        /// item (it can differ from the NFC path on a normalization-sensitive volume), the item's own
        /// path for a renamed or pending item or a folder that is rebuilt.
        var written: [String] = []
    }

    /// Source folders whose visible contents differ from the archive's, by their final paths: a removal
    /// inside a renamed folder (removals name source paths) marks the folder under its new name, and a
    /// renamed item marks the folder it is in, so it is written child by child and moved to its new name
    /// (`placeRenamed`) rather than written under its old name with its folder.
    private func sourceDirectoriesWithEdits() -> Set<String> {
        var result = Set<String>()
        let renames = RenameMap(changes.renamedPaths)
        let removed = changes.removedPaths.map { Self.nfc(self.finalPath(ofSource: $0, renames: renames)) }
        for path in removed + changes.renamedPaths.values.map(Self.nfc) + changes.additions.map(Self.topPath(of:)) {
            var parent = Self.parentPath(of: path)
            while !parent.isEmpty, result.insert(parent).inserted {
                parent = Self.parentPath(of: parent)
            }
        }
        return result
    }

    /// Source folders holding hidden metadata, by their final paths: extracted child by child so it is
    /// left behind.
    private func sourceDirectoriesWithMetadata() -> Set<String> {
        var result = Set<String>()
        let renames = RenameMap(changes.renamedPaths)
        for entry in reader?.entries ?? [] where Self.isHidden(entry) {
            var parent = Self.nfc(Self.parentPath(of: finalPath(ofSource: entry.path, renames: renames)))
            while !parent.isEmpty, result.insert(parent).inserted {
                parent = Self.parentPath(of: parent)
            }
        }
        return result
    }

    /// `excluded`: paths left out with everything below them (case twins); the folders above them
    /// are rebuilt child by child, like folders holding hidden metadata.
    private func plan(for items: [ArchiveItem], excluding excluded: [String] = []) -> ExtractionPlan {
        var plan = ExtractionPlan()
        let renames = RenameMap(changes.renamedPaths)
        var dirtyDirectories = sourceDirectoriesWithEdits().union(sourceDirectoriesWithMetadata())
            .union(mixedFolders.map { Self.nfc(finalPath(ofSource: sourcePaths[$0] ?? $0, renames: renames)) })
        // Both spellings: a twin's path is its item's, which the tree may spell as the source does.
        for path in excluded + excluded.map(Self.nfc) {
            var parent = Self.parentPath(of: path)
            while !parent.isEmpty, dirtyDirectories.insert(parent).inserted {
                parent = Self.parentPath(of: parent)
            }
        }
        for item in items {
            collect(item, dirtyDirectories: dirtyDirectories, excluded: Set(excluded.map(Self.nfc)), into: &plan)
            let isRebuilt = item.isPendingAddition || dirtyDirectories.contains(item.path)
            plan.written.append(isRebuilt || isRenamed(item) ? item.path : readerPath(of: item))
        }
        return plan
    }

    private func collect(_ item: ArchiveItem, dirtyDirectories: Set<String>, excluded: Set<String> = [],
                         into plan: inout ExtractionPlan) {
        if !excluded.isEmpty, excluded.contains(Self.nfc(item.path)) { return }
        if item.isPendingAddition, !item.isDirectory {
            if let entry = pending[item.path] { plan.copies.append((entry.url, item.path)) }
        } else if item.isPendingAddition || dirtyDirectories.contains(item.path) {
            plan.directories.append(item.path)
            for child in item.children ?? [] {
                collect(child, dirtyDirectories: dirtyDirectories, excluded: excluded, into: &plan)
            }
        } else {
            let source = readerPath(of: item)
            plan.sourcePaths.append(source)
            if isRenamed(item) { plan.renamed.append((source, item.path)) }
        }
    }

    /// Where the source entry or folder at `path` (the reader's spelling) ends up after `renames`.
    private func finalPath(ofSource path: String, renames: RenameMap) -> String {
        renames.sourceToFinal.isEmpty ? path : renames.finalPath(ofSource: path)
    }

    /// `item`, or a folder above it, is renamed: the reader knows it by another path (`readerPath`).
    private func isRenamed(_ item: ArchiveItem) -> Bool {
        guard !changes.renamedPaths.isEmpty, !item.isPendingAddition else { return false }
        return Self.nfc(RenameMap(changes.renamedPaths).sourcePath(ofFinal: item.path)) != Self.nfc(item.path)
    }

    /// A Keep Both case twin, extracted on its own into a staging of its own: `path` is the twin's,
    /// `items` the requested items it stands for (the twin, or the requested items inside it).
    private struct TwinPass: Sendable {
        let path: String
        let items: [String]
        let plan: ExtractionPlan
    }

    /// Writes `plan` into `directory`, which must be a fresh folder of ours: the reader's part,
    /// then the pending items.
    private nonisolated static func run(_ plan: ExtractionPlan, reader: (any ArchiveReading)?, in directory: URL,
                                        fileSystem: ExtractionFileSystem,
                                        progress: ArchiveProgressHandler?) async throws {
        if !plan.sourcePaths.isEmpty, let reader {
            try await reader.extract(plan.sourcePaths, to: directory, progress: progress)
        }
        try placeRenamed(plan, in: directory, fileSystem: fileSystem)
        try await perform(plan, in: directory)
        if plan.sourcePaths.isEmpty { progress?(1, nil) }
    }

    /// Moves the source items the reader wrote under their paths before a rename (`plan.renamed`) to
    /// their final paths in `staging`, so every item sits where it will go and a folder written child by
    /// child holds all its children. First every one out into a holding folder, then each into place, so
    /// a swap or a chain of renames never lands on a name still in use. A folder whose final name is
    /// taken by a folder (the same name but for case, on a volume that folds case) merges into it, as
    /// the reader merges folder twins; anything else in the way throws `ExtractionConflictError` and is
    /// never replaced. So does a renamed folder the reader wrote as one with another folder it wrote
    /// (folder twins merged as they were written, then given names of their own): it can't be taken out
    /// alone.
    private nonisolated static func placeRenamed(_ plan: ExtractionPlan, in staging: URL,
                                                 fileSystem: ExtractionFileSystem) throws {
        guard !plan.renamed.isEmpty else { return }
        // Every folder the reader wrote, the items' own and those above them, by identity.
        var folders: [FileIdentity: String] = [:]
        for path in plan.sourcePaths {
            var folder = path
            while !folder.isEmpty {
                let url = staging.appendingPathComponent(folder)
                guard isDirectory(url), let identity = fileIdentity(url) else {
                    folder = parentPath(of: folder)
                    continue
                }
                if let other = folders[identity] {
                    if nfc(other) == nfc(folder) { break }  // and so are the folders above it
                    let pair = [nfc(other), nfc(folder)]
                    if let rename = plan.renamed.first(where: { pair.contains(nfc($0.from)) }) {
                        logger.fault("Staging holds \(other, privacy: .private), \(folder, privacy: .private) as one")
                        throw ExtractionConflictError(paths: [rename.to])
                    }
                } else {
                    folders[identity] = folder
                }
                folder = parentPath(of: folder)
            }
        }
        let fileManager = FileManager.default
        let holding = staging.appendingPathComponent("\(stagingPrefix)renamed-\(UUID().uuidString)",
                                                     isDirectory: true)
        try fileManager.createDirectory(at: holding, withIntermediateDirectories: false)
        // A renamed folder requested with an item inside it (both in `renamed`): the item follows its folder.
        // Inside on the "/" scalar (`isAncestor(of:)`), never a Character prefix: `d/\u{301}x` is inside `d`.
        let froms = plan.renamed.map { nfc($0.from) }
        let isFollower = froms.map { from in froms.contains { $0.isAncestor(of: from) } }
        let moving = zip(plan.renamed, isFollower).filter { !$1 }.map(\.0)
        for (index, rename) in moving.enumerated() {
            // Never from behind a symlink (the archive's own, say): every folder above the old path is a real
            // one, so the item itself is in staging. The item may be a symlink: it moves as one, never followed.
            guard hasRealFolders(above: rename.from, in: staging, missingIsFine: false) else {
                logger.fault("Not a folder in staging above \(rename.from, privacy: .private)")
                throw ExtractionConflictError(paths: [rename.to])
            }
            let source = staging.appendingPathComponent(rename.from)
            guard exists(source) else {
                logger.fault("Extraction didn't write \(rename.to, privacy: .private)")
                throw ArchiveError.entryNotFound(rename.to)
            }
            try moveMerging(source, to: holding.appendingPathComponent(String(index)), path: rename.to, in: staging,
                            fileSystem: fileSystem)
        }
        for (index, rename) in moving.enumerated() {
            // Never through a symlink: every folder above the final path that is already there is a real one.
            guard hasRealFolders(above: rename.to, in: staging, missingIsFine: true) else {
                logger.fault("Not a folder in staging above \(rename.to, privacy: .private)")
                throw ExtractionConflictError(paths: [rename.to])
            }
            let target = staging.appendingPathComponent(rename.to)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try moveMerging(holding.appendingPathComponent(String(index)), to: target, path: rename.to, in: staging,
                            fileSystem: fileSystem)
        }
        // A follower is where its folder went, never behind a symlink its folder moved as.
        for (rename, follows) in zip(plan.renamed, isFollower) where follows {
            guard hasRealFolders(above: rename.to, in: staging, missingIsFine: false) else {
                logger.fault("Not a folder in staging above \(rename.to, privacy: .private)")
                throw ExtractionConflictError(paths: [rename.to])
            }
        }
        // Empty by now; staging goes with whatever is left.
        try? fileManager.removeItem(at: holding)
    }

    /// Moves `source` to `target` within one staging folder, never replacing anything: a real folder
    /// merges into a real folder already there, item by item; anything else in the way throws
    /// `ExtractionConflictError` for `path`. Never into a folder that resolves outside `staging`
    /// (`renameExclusively` calls `checkContained`). One merge is one operation: its folder listings (`twins`) are
    /// this call's and the calls' it makes. Internal for tests.
    nonisolated static func moveMerging(_ source: URL, to target: URL, path: String, in staging: URL,
                                        fileSystem: ExtractionFileSystem,
                                        twins: CaseTwinListings = CaseTwinListings()) throws {
        let error = try renameExclusively(source, to: target, in: staging, fileSystem: fileSystem, twins: twins)
        if error == 0 { return }
        guard error == EEXIST else { throw posixError(error) }
        guard isDirectory(source), isDirectory(target) else {
            logger.fault("Two items on one name in staging: \(path, privacy: .private)")
            throw ExtractionConflictError(paths: [path])
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) {
            try moveMerging(source.appendingPathComponent(name), to: target.appendingPathComponent(name),
                            path: path + "/" + name, in: staging, fileSystem: fileSystem, twins: twins)
        }
        try FileManager.default.removeItem(at: source)
    }

    nonisolated static let stagingPrefix = ".kernir-"
    /// In a staging folder: it holds a user's item that Replace couldn't put back, so no sweep deletes it.
    nonisolated static let keepMarker = ".kernir-keep"

    /// The fields of a staging folder's name, `<stagingPrefix><device token>-<pid>-<uuid>`, or nil for
    /// any other name (the keep marker among them). The token has no "-", the UUID does. Strict, the
    /// way the name is made: a device token (`ExtractionFileSystem.isDeviceToken`), a pid of ASCII
    /// digits with no sign or leading zero, above 0, and a UUID; no empty field.
    nonisolated static func stagingNameFields(_ name: String) -> (deviceToken: Substring, pid: pid_t, uuid: UUID)? {
        guard name.hasPrefix(stagingPrefix) else { return nil }
        let fields = name.dropFirst(stagingPrefix.count)
            .split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, ExtractionFileSystem.isDeviceToken(fields[0]) else { return nil }
        let digits = fields[1].utf8
        guard let first = digits.first, first != UInt8(ascii: "0"),
              digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let pid = pid_t(fields[1]), pid > 0,
              let uuid = UUID(uuidString: String(fields[2])) else { return nil }
        return (fields[0], pid, uuid)
    }
    nonisolated static let recoveredName = "Lutik Recovered"
    /// The recovered folder's name in builds from before the rename. A staging folder such a
    /// build left may still hold the user's item in one, so the sweeps keep recognising it; it must
    /// stay as it is (the product rename keeps this line).
    nonisolated static let legacyRecoveredName = "Kernir Recovered"

    /// `name` is a "<recovered name> <uuid>" folder: today's name or the legacy one.
    nonisolated static func isRecoveredFolderName(_ name: String) -> Bool {
        [recoveredName, legacyRecoveredName].contains { prefix in
            name.hasPrefix("\(prefix) ") && UUID(uuidString: String(name.dropFirst(prefix.count + 1))) != nil
        }
    }

    /// Extracts into a hidden `.kernir-<device token>-<pid>-<uuid>` folder inside `directory` (same
    /// volume, so the moves are renames), then moves `items` into place. The staging folder goes in
    /// every case, with whatever was skipped or replaced in it, unless it is the only place left
    /// holding an item Replace took away (then it is marked, and the error says where). A staging
    /// with anything left in a recovered folder is never deleted, whatever the outcome.
    /// Each `beside` pass (a Keep Both case twin) is extracted into a staging of its own before
    /// anything moves, and moved in after `items` (`moveBeside`). `foldsCase`: `directory`'s volume says
    /// it folds case (staging is on the same volume), so two units staging shows as one folder merge across
    /// case without a device check. Unknown is false. Either way `moveStaged` folds only folders staging
    /// shows as one.
    /// Returns where each item went, by NFC path.
    private nonisolated static func extractStaged(_ plan: ExtractionPlan, reader: (any ArchiveReading)?,
                                                  items: [String], beside: [TwinPass] = [], to directory: URL,
                                                  resolutions: [String: ExtractionConflictResolution],
                                                  foldsCase: Bool,
                                                  fileSystem: ExtractionFileSystem,
                                                  quarantine: QuarantinePropagation.Mark? = nil,
                                                  progress: ArchiveProgressHandler?) async throws -> [String: URL] {
        let fileManager = FileManager.default
        sweepStaleStaging(in: directory, deviceToken: fileSystem.deviceToken)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        func makeStaging() throws -> URL {
            let staging = directory.appendingPathComponent(
                "\(stagingPrefix)\(fileSystem.deviceToken)-\(getpid())-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        }
        let staging = try makeStaging()
        var keepsStaging = false
        defer {
            if !keepsStaging, holdsRecoveredItem(staging) {
                // Every path that leaves a user's item here should have said so; never delete it anyway.
                logger.fault("Staging still holds a recovered item: kept")
            } else if !keepsStaging {
                do {
                    try fileManager.removeItem(at: staging)
                } catch {
                    // A locked item, say: the remnant is hidden, and only a sweep that can delete it removes it.
                    logger.error("Cannot remove staging \(staging.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                }
            }
        }
        // Twin stagings never hold a replaced item: they only ever move out exclusively.
        var besideStagings: [URL] = []
        defer {
            for besideStaging in besideStagings {
                do {
                    try fileManager.removeItem(at: besideStaging)
                } catch {
                    logger.error("Cannot remove staging \(besideStaging.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                }
            }
        }
        do {
            try await run(plan, reader: reader, in: staging, fileSystem: fileSystem, progress: progress)
            for pass in beside {
                try Task.checkCancellation()
                besideStagings.append(try makeStaging())
                try await run(pass.plan, reader: reader, in: besideStagings[besideStagings.count - 1],
                              fileSystem: fileSystem, progress: nil)
            }
        } catch let refused as ExtractionContainmentError {
            // Named for the folder the user chose, not the hidden staging folder (a twin's staging included).
            throw ExtractionContainmentError(name: refused.name, destination: directory)
        }
        // A reader that ignored the cancellation must not leave anything behind.
        try Task.checkCancellation()
        // A downloaded archive's items stay quarantined (`QuarantinePropagation`): everything staged is marked
        // before anything moves (a cancel stops it, and nothing moves), so what a failed move leaves in place
        // is marked inside. The sandbox drops the quarantine of what it renames into the chosen folder (not of
        // what is inside), so what moved, and the folders made above it, are marked again once out, on success
        // and on failure alike.
        if let quarantine {
            quarantine.apply(to: [staging] + besideStagings, stopsWhenCancelled: true)
            try Task.checkCancellation()
        }
        var placedUnits: [URL] = []
        defer { if let quarantine { quarantine.apply(to: outermost(placedUnits)) } }
        do {
            // Never from behind a symlink in a twin's staging: every twin's staged path is checked before
            // anything moves, the main items included (moveStaged checks those the same way).
            for (pass, besideStaging) in zip(beside, besideStagings) {
                guard let written = stagedPath(of: pass),
                      !hasRealFolders(above: written, in: besideStaging, missingIsFine: false) else { continue }
                logger.fault("Not a folder in staging above \(pass.path, privacy: .private)")
                throw ExtractionConflictError(paths: [pass.path])
            }
            // One extraction, one set of folder listings for the check without RENAME_EXCL.
            let twins = CaseTwinListings()
            let moved = try moveStagedUnits(Array(zip(items, plan.written)), from: staging, to: directory,
                                            resolutions: resolutions, foldsCase: foldsCase, destinationDevice: nil,
                                            fileSystem: fileSystem, twins: twins, placedUnits: &placedUnits)
            var result: [String: URL] = [:]
            for (path, url) in zip(items, moved.placed) { result[nfc(path)] = url }
            // The units too: a twin below a conflict that isn't a requested item (a link at `docs`, kept as
            // "docs 2") follows it there.
            try moveBeside(Array(zip(beside, besideStagings)), placed: Array(zip(items, moved.placed)) + moved.units,
                           to: directory, fileSystem: fileSystem, twins: twins, placedUnits: &placedUnits,
                           into: &result)
            return result
        } catch let oldItem as OldItemInStaging {
            // Never delete the user's item: bring its folder out where the user sees it, or keep the
            // staging folder, which the marker protects from any sweep.
            let recovered = freeRecoveredFolder(in: directory)
            var kept = recovered
            do {
                try moveExclusively(oldItem.folder, to: recovered, path: recovered.lastPathComponent,
                                    in: directory, fileSystem: fileSystem, twins: CaseTwinListings())
            } catch {
                keepsStaging = true
                kept = oldItem.folder
            }
            logger.error("Replace left the old item in \(kept.path, privacy: .private)")
            throw ExtractionRecoveryError(name: oldItem.name, kept: kept, kind: .inFolder,
                                          underlying: oldItem.underlying)
        }
    }

    /// Moves each item out of `staging` into place, in order, from where it was written: on its own,
    /// or with the others below the same conflict as one unit (`StagedMove`). Replaces an existing
    /// item only where `resolutions` (keyed by conflict path) says so; otherwise an item that is in
    /// the way throws `ExtractionConflictError`. Returns each item's URL, a folder's as a directory.
    /// Internal for tests.
    nonisolated static func moveStaged(_ items: [(path: String, written: String)], from staging: URL,
                                       to directory: URL,
                                       resolutions: [String: ExtractionConflictResolution],
                                       foldsCase: Bool = false,
                                       destinationDevice: dev_t? = nil,
                                       fileSystem: ExtractionFileSystem,
                                       twins: CaseTwinListings = CaseTwinListings()) throws -> [URL] {
        var placedUnits: [URL] = []
        return try moveStagedUnits(items, from: staging, to: directory, resolutions: resolutions, foldsCase: foldsCase,
                                   destinationDevice: destinationDevice, fileSystem: fileSystem, twins: twins,
                                   placedUnits: &placedUnits).placed
    }

    /// `urls` less those inside another of them (and repeats), so a recursive walk visits each item once.
    private nonisolated static func outermost(_ urls: [URL]) -> [URL] {
        let paths = Set(urls.map(\.path))
        var seen: Set<String> = []
        return urls.filter { url in
            guard seen.insert(url.path).inserted else { return false }
            var parent = (url.path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                if paths.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    /// `moveStaged`, also returning where each unit went (`StagedMove`: an item's own path, or the conflict
    /// above it, at the name the user's answer gave it), in the order they moved. `placedUnits` gets each unit
    /// once in place and the outermost folder made above one, also when a later move throws.
    private nonisolated static func moveStagedUnits(_ items: [(path: String, written: String)], from staging: URL,
                                                    to directory: URL,
                                                    resolutions: [String: ExtractionConflictResolution],
                                                    foldsCase: Bool, destinationDevice: dev_t?,
                                                    fileSystem: ExtractionFileSystem, twins: CaseTwinListings,
                                                    placedUnits: inout [URL])
        throws -> (placed: [URL], units: [(path: String, url: URL)]) {
        // Never from behind a symlink in staging (an archive can leave one where a folder above an item
        // was): every folder above each written path is a real one, checked outermost first with lstat,
        // so nothing outside staging is reached, checked or moved. Before anything moves.
        for item in items where !hasRealFolders(above: item.written, in: staging, missingIsFine: false) {
            logger.fault("Not a folder in staging above \(item.path, privacy: .private)")
            throw ExtractionConflictError(paths: [item.path])
        }
        // Every requested item is written (a folder of hidden metadata only is made by the plan), so a
        // missing one is a reader that didn't do its job: fail before anything moves, never skip it.
        for item in items where !exists(staging.appendingPathComponent(item.written)) {
            logger.fault("Extraction didn't write \(item.path, privacy: .private)")
            throw ArchiveError.entryNotFound(item.path)
        }
        // Items below the same conflict move as one unit, whole, as the user answered for it. An item inside
        // another requested one (a tree listing `d/\u{301}x` beside `d`) is already in it, so it moves with it.
        // Paths split on the "/" scalar, never on Characters (`ArchiveEntry.components(of:)`).
        // Requested folders whose names differ only by case fold into one (an item in one moves with the
        // other, and the two move as one) where staging shows them as one folder: the same real folder
        // (lstat dev+ino, both folders, never a symlink) on the destination's device (`destinationDevice`,
        // stat of `directory` unless given; another device is a conflict), whatever the volume says. Staging
        // is on the destination's volume, so it folds by that volume's own table. On a case-sensitive volume
        // they are two folders, so nothing moves with the other. Two units merge only when staging holds them as one
        // folder, never on their names alone, which would leave the other one behind in staging. Kept apart,
        // they move one by one, and on a volume that folds case the later one meets the first as a conflict.
        // (Case twins that aren't both folders never both get here: `extract` leaves one out of this staging.)
        func foldedPath(_ path: String) -> String { NameFold.key(path) }
        let device = destinationDevice ?? self.device(of: directory)
        /// `written` in staging when it is a real folder there (lstat): its identity, else nil.
        func stagedFolder(_ written: String) -> FileIdentity? {
            let url = staging.appendingPathComponent(written)
            return isDirectory(url) ? fileIdentity(url) : nil
        }
        /// Staging shows `a` and `b` as one folder. On a device other than the destination's: a conflict.
        func isOneFolder(_ a: FileIdentity?, _ b: FileIdentity?, conflict path: String) throws -> Bool {
            guard let a, a == b else { return false }
            guard a.device == device else {
                logger.fault("Staging holds \(path, privacy: .private) on another device than the destination")
                throw ExtractionConflictError(paths: [path])
            }
            return true
        }
        let requested = Set(items.map(\.path))
        let requestedFolded = Dictionary(grouping: items, by: { foldedPath($0.path) })
        var moves: [StagedMove] = []
        var folderUnits: [FileIdentity: String] = [:]
        for (index, item) in items.enumerated() {
            var top = item.path
            var ancestor = parentPath(of: item.path)
            while !ancestor.isEmpty {
                if requested.contains(ancestor) {
                    top = ancestor
                } else if let others = requestedFolded[foldedPath(ancestor)] {
                    // Only where staging shows one folder, whatever the volume says: a volume that folds
                    // case folds by its own table, and HFS+ keeps apart names the key joins (`ß` and `SS`).
                    // Lifted on the name alone, the item would move with a unit nobody answered for, and
                    // that unit would meet the requested folder as a conflict partway.
                    let depth = ArchiveEntry.components(of: ancestor).count
                    let staged = stagedFolder(
                        ArchiveEntry.components(of: item.written).prefix(depth).joined(separator: "/"))
                    for other in others {
                        if try isOneFolder(staged, stagedFolder(other.written), conflict: ancestor) { top = ancestor }
                    }
                }
                ancestor = parentPath(of: ancestor)
            }
            let unit = conflictPath(of: top, in: directory) ?? top
            let depth = ArchiveEntry.components(of: unit).count
            let rest = ArchiveEntry.components(of: item.path).dropFirst(depth).joined(separator: "/")
            let written = ArchiveEntry.components(of: item.written).prefix(depth).joined(separator: "/")
            let staged = staging.appendingPathComponent(written)
            let identity = fileIdentity(staged)
            let stagedIsDirectory = isDirectory(staged)
            // Only folders merge: two files on one inode are hard links, two names to write.
            if let identity, stagedIsDirectory,
               let existing = moves.firstIndex(where: { foldedPath($0.path) == foldedPath(unit) && $0.identity == identity }) {
                if nfc(moves[existing].path) != nfc(unit) {
                    // Across case: on a volume not known to fold it, staging's one folder is the proof.
                    if !foldsCase { _ = try isOneFolder(identity, moves[existing].identity, conflict: unit) }
                    moves[existing].mergesFolders = true
                }
                moves[existing].items.append((index, rest))
                continue
            }
            // One staged folder for two units on different names (folders differing only by case, merged
            // as they were written, then given names that don't fold together): moving either one would
            // carry the other's contents. Fail before anything moves. (Files may share one: hard links.)
            if let identity, stagedIsDirectory {
                if let other = folderUnits[identity] {
                    logger.fault("Staging holds \(other, privacy: .private) and \(unit, privacy: .private) as one folder")
                    throw ExtractionConflictError(paths: [unit])
                }
                folderUnits[identity] = unit
            }
            moves.append(StagedMove(path: unit, staged: staged, identity: identity, items: [(index, rest)]))
        }
        // Read before anything moves out of staging.
        let itemIsDirectory = items.map { isDirectory(staging.appendingPathComponent($0.written)) }
        // Names this extraction writes, so Keep Both doesn't pick one of them.
        var reserved = Set((items.map(\.path) + moves.map(\.path)).map {
            folded(directory.appendingPathComponent($0))
        })
        var placed = Array(repeating: directory, count: items.count)
        var units: [(path: String, url: URL)] = []
        for move in moves {
            if let made = try createFolders(above: move.path, in: directory) { placedUnits.append(made) }
            let unitIsDirectory = isDirectory(move.staged)
            var target = directory.appendingPathComponent(move.path, isDirectory: unitIsDirectory)
            // Folders merged across case keep the name staging gave them: the first written, as the
            // engine names them when it extracts them both.
            if move.mergesFolders, let name = try? move.staged.resourceValues(forKeys: [.nameKey]).name {
                target = target.deletingLastPathComponent().appendingPathComponent(name, isDirectory: unitIsDirectory)
            }
            switch resolutions[move.path] {
            case .replace? where exists(target):
                try replace(target, with: move.staged, path: move.path, staging: staging, in: directory,
                            fileSystem: fileSystem, twins: twins)
            case .keepBoth?:
                target = try moveKeepingBoth(move.staged, to: target, isDirectory: unitIsDirectory, path: move.path,
                                             in: directory, reserved: &reserved, fileSystem: fileSystem, twins: twins)
            default:
                try moveExclusively(move.staged, to: target, path: move.path, in: directory, fileSystem: fileSystem,
                                    twins: twins)
            }
            units.append((move.path, target))
            placedUnits.append(target)
            for (index, rest) in move.items {
                placed[index] = rest.isEmpty
                    ? target : target.appendingPathComponent(rest, isDirectory: itemIsDirectory[index])
            }
        }
        return (placed, units)
    }

    /// Moves each Keep Both case twin out of its own staging, in order, beside its earlier twin: below
    /// wherever the nearest item above it went (`placed`: the requested items and the units they moved in,
    /// then the twins moved before it, so a twin in a folder kept as "docs 2" follows it there), else at its
    /// own path in `directory`, under the dialog's `keepBothName` when its name is taken. Adds where its items
    /// went to `result`; each twin in place, and the outermost folder made above it, to `placedUnits`.
    private nonisolated static func moveBeside(_ passes: [(pass: TwinPass, staging: URL)],
                                               placed: [(path: String, url: URL)], to directory: URL,
                                               fileSystem: ExtractionFileSystem, twins: CaseTwinListings,
                                               placedUnits: inout [URL],
                                               into result: inout [String: URL]) throws {
        var above = placed
        for (pass, staging) in passes {
            // `extractStaged` checked every folder above it is a real one before anything moved.
            guard let written = stagedPath(of: pass) else { continue }
            let depth = ArchiveEntry.components(of: pass.path).count
            let staged = staging.appendingPathComponent(written)
            let isFolder = isDirectory(staged)
            var base = directory
            var rest = pass.path
            // NFC-exact first. Across case (`NameFold.key`) only where nothing matches exactly and the folder
            // was kept under another name (`DOCS/Readme` follows `docs` to "docs 2"), never the twin it is kept
            // beside (`Readme` beside `README`): a folder at its own path may be a folder of its own on the
            // volume (HFS+ keeps `straße` and `STRASSE` apart, which the key joins), so the twin keeps its path.
            var parents = above.filter { isPath(pass.path, atOrBelow: $0.path) && nfc($0.path) != nfc(pass.path) }
            if parents.isEmpty {
                // A twin under a unit it meets only across case (`DOCS/Readme`, a link at `docs` kept as "docs 2")
                // follows that unit; the answer to its own conflict `DOCS` (the same link) counts only as Skip.
                parents = above.filter {
                    isFoldedPath(pass.path, atOrBelow: $0.path) && NameFold.key($0.path) != NameFold.key(pass.path)
                        && nfc($0.url.path) != nfc(directory.appendingPathComponent($0.path).path)
                }
            }
            if let parent = parents.max(by: { $0.path.unicodeScalars.count < $1.path.unicodeScalars.count }) {
                base = parent.url
                rest = ArchiveEntry.components(of: pass.path)
                    .dropFirst(ArchiveEntry.components(of: parent.path).count)
                    .joined(separator: "/")
            }
            // Rooted at the chosen folder, never at `base`: `base` is a URL this extraction placed (a Keep
            // Both name, a merged folder, or an archive item that isn't a real folder), so every folder on the
            // way down to it is checked again, and a symlink there is refused, never followed.
            guard let baseComponents = components(of: base, below: directory) else {
                logger.fault("Placed \(base.path, privacy: .private) outside the chosen folder")
                throw ExtractionContainmentError(name: ArchiveEntry.name(of: pass.path), destination: directory)
            }
            let target: URL
            do {
                if let made = try createFolders(baseComponents + ArchiveEntry.components(of: rest).dropLast(),
                                                in: directory) {
                    placedUnits.append(made)
                }
                var tried: Set<String> = []
                target = try moveKeepingBoth(staged, to: base.appendingPathComponent(rest, isDirectory: isFolder),
                                             isDirectory: isFolder, path: pass.path, in: directory,
                                             reserved: &tried, fileSystem: fileSystem, twins: twins)
                placedUnits.append(target)
            } catch is ExtractionContainmentError {
                // Named for the twin left out, not the link in its way: the items before it are already in
                // place, so the user must learn which one isn't.
                throw ExtractionContainmentError(name: ArchiveEntry.name(of: pass.path), destination: directory)
            }
            above.append((pass.path, target))
            for item in pass.items {
                let below = ArchiveEntry.components(of: item).dropFirst(depth).joined(separator: "/")
                guard !below.isEmpty else {
                    result[nfc(item)] = target
                    continue
                }
                result[nfc(item)] = target.appendingPathComponent(
                    below, isDirectory: isDirectory(target.appendingPathComponent(below)))
            }
        }
    }

    /// Where a Keep Both twin was written in its own staging (the twin's depth of its first written path),
    /// split on the "/" scalar, never on Characters; nil when its pass wrote nothing.
    private nonisolated static func stagedPath(of pass: TwinPass) -> String? {
        guard let firstWritten = pass.plan.written.first else { return nil }
        let depth = ArchiveEntry.components(of: pass.path).count
        return ArchiveEntry.components(of: firstWritten).prefix(depth).joined(separator: "/")
    }

    /// `path` is `root` or below it, after NFC, on scalars with a "/" boundary (`isAncestor(of:)`).
    private nonisolated static func isPath(_ path: String, atOrBelow root: String) -> Bool {
        let path = nfc(path), root = nfc(root)
        return path == root || root.isAncestor(of: path)
    }

    /// `path` is `root` or below it after `NameFold.key` (case and NFD folded), on scalars with a "/" boundary.
    private nonisolated static func isFoldedPath(_ path: String, atOrBelow root: String) -> Bool {
        let path = NameFold.key(path), root = NameFold.key(root)
        return path == root || root.isAncestor(of: path)
    }

    /// Requested items that move as one: an item on its own, or every requested item below the
    /// conflicting folder above them, which moves (or replaces, or is kept beside) whole.
    private struct StagedMove {
        /// The unit's path in the destination: an item's own, or the conflict above it.
        let path: String
        /// The unit in staging, as it was written.
        let staged: URL
        /// `staged`'s file identity, read before anything moves.
        let identity: FileIdentity?
        /// The requested items in it: where they are in the request, and their path below `path`.
        var items: [(index: Int, rest: String)]
        /// Requested folders whose names differ only by case, merged into one on a destination that folds case.
        var mergesFolders = false
    }

    /// What is in the way of `path` in `directory`: the first folder above it that is something
    /// other than a real folder (lstat, a symlink is never followed), else `path` itself when
    /// anything is there, a dangling symlink included. `nil` when nothing is in the way. The folders
    /// above are found on the "/" scalar: a Character split hides `link` in `link/\u{301}x`.
    private nonisolated static func conflictPath(of path: String, in directory: URL) -> String? {
        var prefix = ""
        for component in ArchiveEntry.components(of: path).dropLast() {
            prefix = join(prefix, component)
            let url = directory.appendingPathComponent(prefix)
            if isDirectory(url) { continue }
            return exists(url) ? prefix : nil
        }
        return exists(directory.appendingPathComponent(path)) ? path : nil
    }

    /// Creates the folders above `path` in `directory` (`createFolders(_:in:)`). Split on the "/" scalar.
    @discardableResult
    private nonisolated static func createFolders(above path: String, in directory: URL) throws -> URL? {
        try createFolders(Array(ArchiveEntry.components(of: path).dropLast()), in: directory)
    }

    /// Creates the folders `components` spell in `directory`, the folder the user chose, merging with existing
    /// ones, through `makeFolders`: one at a time, never through a symlink (that throws
    /// `ExtractionContainmentError`, nothing made through it). Anything else in the way (a file) is a conflict
    /// on the first prefix that isn't a folder, never replaced. Returns the outermost folder it made (nothing was
    /// there, lstat, just before), nil when all were there already.
    @discardableResult
    private nonisolated static func createFolders(_ components: [String], in directory: URL) throws -> URL? {
        var made: URL?
        var prefix = directory
        for component in components {
            prefix = prefix.appendingPathComponent(component, isDirectory: true)
            if !exists(prefix) {
                made = prefix
                break
            }
        }
        do {
            try makeFolders(components[...], in: directory)
            return made
        } catch let error as POSIXError where error.code == .ENOTDIR || error.code == .EEXIST {
            var prefix = ""
            for component in components {
                prefix = join(prefix, component)
                if !isDirectory(directory.appendingPathComponent(prefix, isDirectory: true)) {
                    throw ExtractionConflictError(paths: [prefix])
                }
            }
            throw error
        }
    }

    /// `url`'s components below `directory`, split on the "/" scalar; nil when `url` is not `directory` or
    /// below it.
    private nonisolated static func components(of url: URL, below directory: URL) -> [String]? {
        let all = ArchiveEntry.components(of: url.path), root = ArchiveEntry.components(of: directory.path)
        guard all.count >= root.count,
              zip(all, root).allSatisfy({ $0.unicodeScalars.elementsEqual($1.unicodeScalars) }) else { return nil }
        return Array(all.dropFirst(root.count))
    }

    /// How many Keep Both names `moveKeepingBoth` tries before it gives up. Internal for tests.
    nonisolated static let keepBothAttempts = 100

    /// Keep Both: moves `source` exclusively to `target` if nothing is there, else to the dialog's
    /// `keepBothName` for it. A create that collides (EEXIST) means that name is taken, whatever the
    /// lookup said: the iOS Simulator's scratch volume folds case on create but looks names up by
    /// exact case. So the next Keep Both name is tried, up to `keepBothAttempts` names, then EEXIST
    /// throws as a POSIX error (answering again would collide again). Any other error throws as
    /// `moveExclusively` throws it. Every name tried is checked to be inside `destination` first
    /// (`renameExclusively`). Names tried go into `reserved`. Returns where `source` went. Internal for tests.
    nonisolated static func moveKeepingBoth(_ source: URL, to target: URL, isDirectory: Bool, path: String,
                                            in destination: URL, reserved: inout Set<String>,
                                            fileSystem: ExtractionFileSystem,
                                            twins: CaseTwinListings = CaseTwinListings()) throws -> URL {
        var candidate = fileSystem.exists(target.path)
            ? keepBothName(for: target, isDirectory: isDirectory, reserved: reserved) : target
        for _ in 0..<keepBothAttempts {
            reserved.insert(folded(candidate))
            let error = try renameExclusively(source, to: candidate, in: destination, fileSystem: fileSystem,
                                              twins: twins)
            if error == 0 { return candidate }
            // Only a collision tries the next name; anything else throws as `moveExclusively` throws it.
            guard error == EEXIST else { throw posixError(error) }
            candidate = keepBothName(for: target, isDirectory: isDirectory, reserved: reserved)
        }
        logger.error("Keep Both met \(keepBothAttempts) taken names for \(path, privacy: .private)")
        throw posixError(EEXIST)
    }

    /// rename(2) that fails instead of replacing: EEXIST means the item appeared after the check.
    /// Never into a folder that resolves outside `destination` (`renameExclusively` checks it).
    private nonisolated static func moveExclusively(_ source: URL, to target: URL, path: String, in destination: URL,
                                                    fileSystem: ExtractionFileSystem,
                                                    twins: CaseTwinListings) throws {
        let error = try renameExclusively(source, to: target, in: destination, fileSystem: fileSystem, twins: twins)
        if error == EEXIST { throw ExtractionConflictError(paths: [path]) }
        if error != 0 { throw posixError(error) }
    }

    /// rename(2) that fails with EEXIST instead of replacing: 0, or the error number. Calls `checkContained`
    /// first, so neither `moveExclusively` nor `moveKeepingBoth` can put an item into a folder that resolves
    /// outside `destination`: that throws `ExtractionContainmentError` (or the POSIX error of a folder that
    /// can't be resolved) and nothing is renamed.
    private nonisolated static func renameExclusively(_ source: URL, to target: URL, in destination: URL,
                                                      fileSystem: ExtractionFileSystem,
                                                      twins: CaseTwinListings) throws -> Int32 {
        try checkContained(target, in: destination)
        let error = fileSystem.rename(source.path, target.path, UInt32(RENAME_EXCL))
        // A file system without RENAME_EXCL (`lacksExclusiveRename`): check, then a plain rename, nothing in
        // between. rename(2) silently replaces a file or an empty folder, and a lookup can miss a case twin a
        // create still collides with (the iOS Simulator's scratch volume), so the check looks for one too, in the
        // operation's folder listings (`twins`).
        guard lacksExclusiveRename(error) else { return error }
        // A folder that can't be listed for permission (EACCES, EPERM: a write-only drop box) fails open on purpose;
        // exists() still refuses the exact name. Any other listing error throws, and nothing is renamed.
        return try twins.renamePlainly(source, to: target, fileSystem: fileSystem)
    }

    /// renamex_np(2)'s error when the volume has no RENAME_EXCL: ENOTSUP (45) or EOPNOTSUPP (102), separate
    /// numbers on Darwin that a volume may give either of, or EINVAL. The app's list (`renameExclusively`,
    /// `UniquePlacement.place`); the core keeps the same list in its own `lacksExclusiveRename`. Internal for
    /// `UniquePlacement` and tests.
    nonisolated static func lacksExclusiveRename(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL
    }

    /// Puts `source` where `target` is, whole, as Finder's Replace does: one atomic swap where the
    /// file system has it, otherwise the old item steps aside into `staging` first and comes back if
    /// the move fails. Never writes through a symlink: `target` may be one (the swap takes the link
    /// itself), but the folder holding it must resolve inside `destination` (`checkContained`). If the
    /// target is gone by the time of the swap, nothing needs replacing and the item just moves in.
    private nonisolated static func replace(_ target: URL, with source: URL, path: String, staging: URL,
                                            in destination: URL, fileSystem: ExtractionFileSystem,
                                            twins: CaseTwinListings) throws {
        try checkContained(target, in: destination)
        let error = fileSystem.rename(source.path, target.path, UInt32(RENAME_SWAP))
        switch error {
        case 0:
            // A new item at `target`: the operation's listings of folders there and below were the old one's.
            twins.forget(below: target)
        case ENOTSUP, EOPNOTSUPP, EINVAL:
            try replaceSteppingAside(target, with: source, path: path, staging: staging, in: destination,
                                     fileSystem: fileSystem, twins: twins)
        case ENOENT:
            // The extraction's listings may still hold the name that went: only a real twin blocks the move.
            twins.dropGone(target, fileSystem: fileSystem)
            twins.forget(below: target)
            try moveExclusively(source, to: target, path: path, in: destination, fileSystem: fileSystem,
                                twins: twins)
        default:
            throw posixError(error)
        }
    }

    /// `replace` on a file system without RENAME_SWAP. The old item steps aside under its own name
    /// into a "Lutik Recovered <uuid>" folder in `staging`, which is marked first so no sweep ever
    /// deletes it. The old item is never lost: if the new one can't move in (or the step aside
    /// reported failure but took effect), the old one goes back to its name (`restore`); if something
    /// took that name meanwhile, it goes to the next free "name 2" beside it (`ExtractionRecoveryError`
    /// `.renamed`); failing that, it stays in its folder, which `extractStaged` brings out. Once the
    /// new one is in, the folder goes with the old item. Nothing moves unless the folder holding `target`
    /// resolves inside `destination` (`checkContained`). Internal for tests.
    nonisolated static func replaceSteppingAside(_ target: URL, with source: URL, path: String, staging: URL,
                                                 in destination: URL,
                                                 fileSystem: ExtractionFileSystem = .system,
                                                 twins: CaseTwinListings = CaseTwinListings()) throws {
        try checkContained(target, in: destination)
        try markKept(staging)
        let folder = staging.appendingPathComponent("\(recoveredName) \(UUID().uuidString)", isDirectory: true)
        if mkdir(folder.path, 0o777) != 0 { throw posixError(errno) }
        let aside = folder.appendingPathComponent(target.lastPathComponent)
        let code = fileSystem.rename(target.path, aside.path, 0)
        // A rename can report failure after it took effect (SMB/NFS replaying it after a reconnect
        // gets ENOENT): then the old item is aside all the same and must come back.
        if code != 0, !exists(aside) { throw posixError(code) }
        // The operation's listings (`twins`, the extraction's) still hold the name stepped aside, perhaps in
        // another case than `target`'s: dropped once lstat finds it gone. A real twin keeps blocking. What they
        // knew of folders at `target` and below was the old item's.
        twins.dropGone(target, fileSystem: fileSystem)
        twins.forget(below: target)
        if code != 0 {
            try restore(aside, from: folder, to: target, path: path, after: posixError(code), in: destination,
                        fileSystem: fileSystem, twins: twins)
        }
        do {
            try moveExclusively(source, to: target, path: path, in: destination, fileSystem: fileSystem, twins: twins)
        } catch {
            try restore(aside, from: folder, to: target, path: path, after: error, in: destination,
                        fileSystem: fileSystem, twins: twins)
        }
        // Replaced, as the user asked: the old item goes now, so whatever stays in a recovered folder
        // is an item the staging cleanup must keep.
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            logger.error("Cannot remove a replaced item: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        }
    }

    /// Brings the old item at `aside` (in `folder`) back after a failed step-aside replace, and throws:
    /// `error` once it is back at `target`; `ExtractionRecoveryError` `.renamed` at the next free
    /// "name 2" beside it if something took the name; else `OldItemInStaging`, for `extractStaged`.
    /// A move that reports failure but leaves `aside` gone (ENOENT, not any lstat failure) and its
    /// target there took effect.
    private nonisolated static func restore(_ aside: URL, from folder: URL, to target: URL, path: String,
                                            after error: any Error, in destination: URL,
                                            fileSystem: ExtractionFileSystem, twins: CaseTwinListings) throws -> Never {
        let name = target.lastPathComponent
        func moved(to place: URL) -> Bool {
            (try? moveExclusively(aside, to: place, path: path, in: destination, fileSystem: fileSystem,
                                  twins: twins)) != nil
                || isGone(aside) && exists(place)
        }
        if moved(to: target) { throw error }
        let free = keepBothName(for: target, isDirectory: isDirectory(aside), reserved: [])
        if moved(to: free) {
            throw ExtractionRecoveryError(name: name, kept: free, kind: .renamed, underlying: error)
        }
        // Gone from its folder but nowhere we put it: never point the user at an empty folder.
        guard !isGone(aside) else { throw error }
        throw OldItemInStaging(folder: folder, name: name, underlying: error)
    }

    /// Replace couldn't put the old item anywhere but `folder` in staging, so the staging folder must
    /// not simply be deleted.
    private struct OldItemInStaging: Error {
        /// The "Lutik Recovered <uuid>" folder holding the old item under its own name.
        let folder: URL
        let name: String
        /// Why the replace failed.
        let underlying: any Error
    }

    /// Writes `staging`'s keep marker, never through a symlink. Already there is fine.
    private nonisolated static func markKept(_ staging: URL) throws {
        let marker = staging.appendingPathComponent(keepMarker)
        let descriptor = open(marker.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        if descriptor >= 0 {
            close(descriptor)
        } else if errno != EEXIST {
            throw posixError(errno)
        }
    }

    /// A "Lutik Recovered <uuid>" folder (or a `legacyRecoveredName` one) in `staging` isn't empty (or can't be read): it holds a
    /// user's item. A completed replace removes its own folder, so none should be left. The folders
    /// alone decide, not the marker: its lstat failing on a flaky volume must not read as "no marker".
    private nonisolated static func holdsRecoveredItem(_ staging: URL) -> Bool {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: staging.path) else { return true }
        return names.contains { name in
            guard isRecoveredFolderName(name) else { return false }
            let folder = staging.appendingPathComponent(name).path
            return (try? fileManager.contentsOfDirectory(atPath: folder).isEmpty) != true
        }
    }

    /// The first of "Lutik Recovered", "Lutik Recovered 2"… that is free in `directory`.
    private nonisolated static func freeRecoveredFolder(in directory: URL) -> URL {
        var name = recoveredName
        var number = 2
        while exists(directory.appendingPathComponent(name)) {
            name = "\(recoveredName) \(number)"
            number += 1
        }
        return directory.appendingPathComponent(name, isDirectory: true)
    }

    /// The first Finder-style name for `target` that is free on disk and not in `reserved`:
    /// "name 2.ext" for files, "name 2" for folders, then 3, 4… A name ending in a copy number
    /// (" 2"… " 999", no leading zero) counts on from it, as Finder does: "name 2.ext" gives
    /// "name 3.ext", not "name 2 2.ext". Any other number is part of the name: "Report 2024 2.pdf".
    private nonisolated static func keepBothName(for target: URL, isDirectory: Bool, reserved: Set<String>) -> URL {
        let parent = target.deletingLastPathComponent()
        let name = keepBothName(target.lastPathComponent, isDirectory: isDirectory) { name in
            let candidate = parent.appendingPathComponent(name, isDirectory: isDirectory)
            return exists(candidate) || reserved.contains(folded(candidate))
        }
        return parent.appendingPathComponent(name, isDirectory: isDirectory)
    }

    /// The first Finder-style name after `name` that `isTaken` doesn't reject, numbered as
    /// `keepBothName(for:isDirectory:reserved:)` describes.
    private nonisolated static func keepBothName(_ name: String, isDirectory: Bool,
                                                 isTaken: (String) -> Bool) -> String {
        let fileExtension = isDirectory ? "" : (name as NSString).pathExtension
        var base = fileExtension.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 2
        if let space = base.lastIndex(of: " "), space > base.startIndex {
            let digits = base[base.index(after: space)...]
            if digits.allSatisfy({ $0.isASCII && $0.isNumber }), digits.first != "0",
               let copy = Int(digits), (2..<1000).contains(copy) {
                base = String(base[..<space])
                number = copy + 1
            }
        }
        while true {
            let candidate = fileExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(fileExtension)"
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// Deletes staging folders a crashed run left in `directory`: this device's (`deviceToken`; a pid
    /// means nothing on another device sharing the folder), the process gone, a real folder named
    /// exactly as staging is, not holding a user's item (keep marker, or a non-empty recovered folder
    /// in case the marker's lstat failed), untouched for 10 minutes.
    /// Best effort.
    private nonisolated static func sweepStaleStaging(in directory: URL, deviceToken: String) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            guard let fields = stagingNameFields(name), fields.deviceToken == deviceToken,
                  fields.pid != getpid(), kill(fields.pid, 0) == -1, errno == ESRCH else { continue }
            let url = directory.appendingPathComponent(name, isDirectory: true)
            guard isDirectory(url), !exists(url.appendingPathComponent(keepMarker)),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified < Date(timeIntervalSinceNow: -600), !holdsRecoveredItem(url) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                logger.error("Cannot sweep \(url.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
            }
        }
    }

    /// The containment guard. Every rename or swap that puts an item into a folder the user chose, or takes
    /// one out of it, calls this first (`renameExclusively`, under `moveExclusively` and `moveKeepingBoth`;
    /// `replace`, `replaceSteppingAside`, `UniquePlacement.place`), so nothing moves through a symlink in that
    /// folder, whatever a path split saw; so does `perform` before it removes or copies an item in the
    /// extraction's own folder. Throws `ExtractionContainmentError` unless the folder that holds `target`
    /// resolves (realpath(3): the kernel follows every symlink and "..") to `destination`'s own resolved path
    /// or a folder below it,
    /// compared on bytes with a "/" boundary ("/x/Extracted Outside" is not inside "/x/Extracted"), and
    /// `target`'s name is not "." or "..". `target` itself may be a symlink: a rename replaces or swaps the
    /// link, never follows it. A folder that can't be resolved (gone, no permission) throws its POSIX error,
    /// as the rename would. Not atomic with the rename: a local process that swaps a checked folder for a
    /// symlink in between (TOCTOU) isn't caught. Archive contents can't do that: they are written to staging
    /// and only then moved, each move checked here.
    nonisolated static func checkContained(_ target: URL, in destination: URL) throws {
        let path = target.path
        let name = ArchiveEntry.name(of: path)
        let parent = ArchiveEntry.parentPath(of: path)
        let root = Array(try resolvedPath(destination.path).utf8)
        let holder = Array(try resolvedPath(parent.isEmpty ? "/" : parent).utf8)
        let base = root.last == UInt8(ascii: "/") ? root : root + [UInt8(ascii: "/")]
        guard !isDotName(name), holder == root || holder.starts(with: base) else {
            logger.error("Refused a move out of the chosen folder: \(path, privacy: .private)")
            throw ExtractionContainmentError(name: name, destination: destination)
        }
    }

    /// realpath(3) of `path`, or its POSIX error.
    private nonisolated static func resolvedPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw posixError(errno) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True when anything is at `url`, a dangling symlink included (lstat).
    private nonisolated static func exists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    /// Nothing at `url` for sure: lstat fails with ENOENT. Any other failure (EACCES, EIO on a
    /// reconnecting volume) says nothing about the item, so it isn't gone.
    private nonisolated static func isGone(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) != 0 && errno == ENOENT
    }

    /// A real folder at `url`, not a symlink to one (lstat).
    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    /// Every folder above `path` in `staging`, outermost first, is a real folder, never a symlink (lstat, so
    /// no component is followed before it is checked). `missingIsFine`: a folder not there yet counts. Split
    /// on the "/" scalar, never on Characters; a path with an empty, "." or ".." component never passes.
    /// Internal for tests.
    nonisolated static func hasRealFolders(above path: String, in staging: URL, missingIsFine: Bool) -> Bool {
        let components = path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        let isDot = { (name: String) in
            name.unicodeScalars.elementsEqual(".".unicodeScalars) || name.unicodeScalars.elementsEqual("..".unicodeScalars)
        }
        guard !components.contains(where: { $0.isEmpty || isDot($0) }) else { return false }
        var folder = staging
        for component in components.dropLast() {
            folder.appendPathComponent(component, isDirectory: true)
            if isDirectory(folder) { continue }
            return missingIsFine && isGone(folder)
        }
        return true
    }

    /// The item at `url` itself (lstat, a symlink is never followed), whatever name it is reached by.
    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// The device of the folder at `url`, as a rename into it sees it (stat, following a symlink); nil when
    /// it can't be read.
    private nonisolated static func device(of url: URL) -> dev_t? {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return nil }
        return status.st_dev
    }

    private nonisolated static func fileIdentity(_ url: URL) -> FileIdentity? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        return FileIdentity(device: status.st_dev, inode: status.st_ino)
    }

    /// `url`'s path as the default (case- and normalization-insensitive) volumes compare names.
    private nonisolated static func folded(_ url: URL) -> String {
        NameFold.key(url.path)
    }

    private nonisolated static func posixError(_ code: Int32) -> any Error {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// File work for pending items, off the main actor, into a fresh folder of ours. Folders merge;
    /// two items on one name (a case-insensitive volume) keep the later one. The reader has already
    /// written the archive's entries here, its symlinks too, and the tree is case-sensitive where the
    /// volume may not be (`Link` beside `link/s`): every folder is made by `makeFolders`, never
    /// through a symlink, and an item is only removed or copied in a folder made so, after the
    /// containment guard (`checkContained`). A symlink in the way throws `ExtractionContainmentError`.
    private nonisolated static func perform(_ plan: ExtractionPlan, in directory: URL) async throws {
        let fileManager = FileManager.default
        for path in plan.directories {
            try makeFolders(ArchiveEntry.components(of: path)[...], in: directory)
        }
        for copy in plan.copies {
            try Task.checkCancellation()
            let components = ArchiveEntry.components(of: copy.to)
            let folder = try makeFolders(components.dropLast(), in: directory)
            let target = folder.appendingPathComponent(components.last ?? copy.to, isDirectory: false)
            try checkContained(target, in: directory)
            // lstat: a symlink on the name (any case) is removed itself, never what it leads to.
            if exists(target) { try fileManager.removeItem(at: target) }
            try fileManager.copyItem(at: copy.from, to: target)
            // copyItem keeps the user's setuid, setgid and sticky bits, which the engine never writes: cleared.
            try ExclusiveCopy.dropSpecialBits(inTreeAt: target)
        }
    }

    /// Makes the folders `components` spell inside `root`, one at a time, merging with real folders
    /// already there, and returns the last one's URL as spelled (`root` for none). Never through a
    /// symlink: each folder is made (mkdirat) and opened (openat, O_NOFOLLOW) relative to the one
    /// above it, so the volume itself decides which name is in the way. A symlink there, whatever
    /// its case or normalization (`Link` is `link` on a case-insensitive volume) and wherever it
    /// leads, throws `ExtractionContainmentError`, as does a "." or ".." component; nothing is made
    /// through it. Anything else that isn't a folder throws its POSIX error (ENOTDIR for a file).
    /// `root` is ours and trusted (it may be reached through a link, as /var is). Internal for tests;
    /// `readOnlyOpens` takes the fallback open (O_RDONLY) every time, as a volume that refuses O_SEARCH makes it.
    @discardableResult
    nonisolated static func makeFolders(_ components: ArraySlice<String>, in root: URL,
                                        readOnlyOpens: Bool = false) throws -> URL {
        var folder = readOnlyOpens ? -1 : open(root.path, O_SEARCH | O_CLOEXEC)
        if folder < 0, readOnlyOpens || searchIsRefused(errno) {
            folder = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard folder >= 0 else { throw posixError(errno) }
        defer { close(folder) }
        var url = root
        for component in components {
            guard !isDotName(component), !component.isEmpty, !component.unicodeScalars.contains("/") else {
                logger.error("Refused a folder out of the extraction's own: \(component, privacy: .private)")
                throw ExtractionContainmentError(name: component, destination: root)
            }
            let made = mkdirat(folder, component, 0o777) == 0 ? 0 : errno
            var next = readOnlyOpens ? -1 : openat(folder, component, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, readOnlyOpens || searchIsRefused(errno) {
                next = openat(folder, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                let failure = errno
                var status = stat()
                if fstatat(folder, component, &status, AT_SYMLINK_NOFOLLOW) == 0, status.st_mode & S_IFMT == S_IFLNK {
                    logger.error("Refused a folder through a link: \(url.appendingPathComponent(component).path, privacy: .private)")
                    throw ExtractionContainmentError(name: component, destination: root)
                }
                throw posixError(made != 0 && made != EEXIST ? made : failure)
            }
            close(folder)
            folder = next
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        return url
    }

    /// The file system won't open a folder for search only (O_SEARCH): open it for reading instead.
    /// ENOTSUP (45) and EOPNOTSUPP (102) are separate numbers on Darwin; a volume may give either.
    /// Internal for tests.
    nonisolated static func searchIsRefused(_ code: Int32) -> Bool {
        code == EACCES || code == EPERM || code == EINVAL || code == ENOTSUP || code == EOPNOTSUPP
    }

    /// "." or "..", compared on scalars (".\u{301}" is a name like any other).
    private nonisolated static func isDotName(_ name: String) -> Bool {
        name.unicodeScalars.elementsEqual(".".unicodeScalars) || name.unicodeScalars.elementsEqual("..".unicodeScalars)
    }

    // MARK: - Paths

    /// Entries for `url` (and everything inside it when it is a folder) placed at `path`.
    private nonisolated static func pendingEntries(for url: URL, at path: String) -> [PendingEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        func entry(for url: URL, at path: String) -> PendingEntry? {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: Set(keys))
            } catch {
                logger.error("Cannot read \(url.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                return nil
            }
            let isDirectory = values.isDirectory ?? false
            let entry = ArchiveEntry(path: path, isDirectory: isDirectory,
                                     size: isDirectory ? nil : values.fileSize.map { Int64($0) },
                                     compressedSize: nil, modificationDate: values.contentModificationDate)
            return PendingEntry(entry: entry, url: url)
        }
        guard let root = entry(for: url, at: path) else { return [] }
        guard root.entry.isDirectory,
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                                errorHandler: { failed, error in
                  logger.error("Cannot enumerate \(failed.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                  return true
              })
        else { return [root] }
        var result = [root]
        var components: [String] = []
        while let child = enumerator.nextObject() as? URL {
            let name = nfc(child.lastPathComponent)
            components = Array(components.prefix(enumerator.level - 1)) + [name]
            // Not listed, but no skipDescendants(): on a file it hides the next folder's contents, which
            // the writer saves. A `.DS_Store` folder's contents are saved too, so they stay listed.
            if name == ".DS_Store" { continue }
            if let item = entry(for: child, at: path + "/" + components.joined(separator: "/")) {
                result.append(item)
            }
        }
        return result
    }

    private nonisolated static func nfc(_ string: String) -> String {
        string.precomposedStringWithCanonicalMapping
    }

    /// Byte equality: String's `==` treats NFC and NFD spellings as equal.
    private nonisolated static func isSameSpelling(_ a: String, _ b: String) -> Bool {
        a.utf8.elementsEqual(b.utf8)
    }

    private nonisolated static func isIgnored(_ url: URL) -> Bool {
        url.lastPathComponent == ".DS_Store"
    }

    private nonisolated static func normalizedDirectory(_ directory: String) -> String {
        nfc(directory).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private nonisolated static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }

    /// The folder holding `path`, "" at the top. On the "/" scalar, never on Characters: "/" with a combining
    /// mark or ZWJ after it, or a Prepend scalar before it, is one Character that is not "/".
    nonisolated static func parentPath(of path: String) -> String {
        ArchiveEntry.parentPath(of: path)
    }

    /// `path` after its first `prefix.unicodeScalars.count` scalars: what follows a folder path in one of its
    /// descendants (`parentPath(of:)` keeps the path's own scalars), never a Character count.
    private nonisolated static func scalarSuffix(of path: String, after prefix: String) -> String {
        String(String.UnicodeScalarView(path.unicodeScalars.dropFirst(prefix.unicodeScalars.count)))
    }

    /// Archive path of what an addition puts in place (NFC), under its `archiveName` when renamed.
    private nonisolated static func topPath(of addition: ArchiveChangeSet.Addition) -> String {
        join(nfc(addition.destinationDirectory), nfc(addition.archiveName ?? addition.sourceURL.lastPathComponent))
    }

    /// The AppleDouble companion (`parent/._name`) of `path`, nil for a companion itself. Name and folder both
    /// split on the "/" scalar, and "._" is a scalar prefix: a mark or ZWJ after it fuses "_" into another Character.
    nonisolated static func companionPath(of path: String) -> String? {
        let name = ArchiveEntry.name(of: path)
        guard !name.unicodeScalars.starts(with: "._".unicodeScalars) else { return nil }
        return join(parentPath(of: path), "._" + name)
    }

    /// `path` or its nearest ancestor that is in `paths`.
    private nonisolated static func coveringPath(of path: String, in paths: Set<String>) -> String? {
        var current = path
        while !current.isEmpty {
            if paths.contains(current) { return current }
            current = parentPath(of: current)
        }
        return nil
    }

    /// True when `path` or one of its ancestors is in `paths`. Walks the ancestors, so it costs
    /// the path's depth, not the size of `paths`.
    nonisolated static func isCovered(_ path: String, by paths: Set<String>) -> Bool {
        var current = path
        while !current.isEmpty {
            if paths.contains(current) { return true }
            current = parentPath(of: current)
        }
        return false
    }
}

private extension ArchiveEntry {
    /// This entry at `path`, every other field kept.
    func with(path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: isDirectory, size: size, compressedSize: compressedSize,
                     modificationDate: modificationDate, isEncrypted: isEncrypted, permissions: permissions)
    }
}

private extension String {
    /// True when `path` is strictly inside the folder at `self`. Canonically equivalent spellings match, as
    /// `hasPrefix` did, but on scalars with a "/" boundary: a Character `hasPrefix` misses `d/\u{301}x` in `d`.
    func isAncestor(of path: String) -> Bool {
        guard !isEmpty else { return false }
        let folder = precomposedStringWithCanonicalMapping.unicodeScalars
        let inner = path.precomposedStringWithCanonicalMapping.unicodeScalars
        guard inner.count > folder.count, inner.starts(with: folder) else { return false }
        return inner[inner.index(inner.startIndex, offsetBy: folder.count)] == "/"
    }
}
