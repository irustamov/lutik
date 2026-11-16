import Testing
import AppKit
import UniformTypeIdentifiers
@testable import Kernir
import KernirCore
import os

/// The save panel follows the split choice. Splitting, it saves a folder
/// whose proposed name never collides (rule (b)), and `validate` refuses a folder the set must not
/// replace: one holding the archive or an addition, or one that isn't an earlier set (rule (a)).
/// The panels here are real but never run, so these need an app host (a hosted UI test run).
@MainActor
struct SavePanelOptionsTests {
    private func settings(_ format: ArchiveFormat, split: VolumeSplit = .none) -> ArchiveSaveSettings {
        var settings = ArchiveSaveSettings(format: format, options: ArchiveWriteOptions())
        settings.formatDidChange()
        settings.split = split
        return settings
    }

    /// A fresh temp folder holding the folders in `folders`; the caller removes it.
    private func makeDirectory(holding folders: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavePanelOptionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for folder in folders {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder, isDirectory: true),
                                                    withIntermediateDirectories: false)
        }
        return root
    }

    /// A panel showing `options`, in `directory` when given, proposing from `fileName`.
    private func attach(_ options: SavePanelOptions, fileName: String, in directory: URL? = nil) -> NSSavePanel {
        let panel = NSSavePanel()
        if let directory { panel.directoryURL = directory }
        options.attach(to: panel, fileName: fileName)
        return panel
    }

    // MARK: - Type and name follow Split

    @Test func splitOnSavesAFolderAndOffGivesTheArchiveBack() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = SavePanelOptions(settings: settings(.sevenZip))
        let panel = attach(options, fileName: "Photos.7z", in: directory)
        #expect(panel.allowedContentTypes == KernirDocumentTypes.savePanelTypes(for: .sevenZip))
        #expect(panel.nameFieldStringValue == "Photos.7z")

        options.split = .preset(.mb100)
        #expect(panel.allowedContentTypes == [.folder])
        #expect(panel.nameFieldStringValue == "Photos")

        options.split = .none
        #expect(panel.allowedContentTypes == KernirDocumentTypes.savePanelTypes(for: .sevenZip))
        #expect(panel.nameFieldStringValue == "Photos.7z")
    }

    @Test func aStackedExtensionGivesTheBareFolderName() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = SavePanelOptions(settings: settings(.zip))
        let panel = attach(options, fileName: "Photos.tar.gz", in: directory)
        options.split = .preset(.mb25)
        #expect(panel.nameFieldStringValue == "Photos")
    }

    @Test func aVolumeSetProposesTheSetsFolder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parts = ["s7.7z.001", "s7.7z.002"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        let options = SavePanelOptions(settings: settings(.sevenZip), volumeURLs: parts)
        let panel = attach(options, fileName: "s7.7z.001", in: directory)
        #expect(panel.nameFieldStringValue == "s7.7z")
        options.split = .preset(.mb700)
        #expect(panel.nameFieldStringValue == "s7")
        options.split = .none
        #expect(panel.nameFieldStringValue == "s7.7z")
    }

    /// The panel turns to a folder once; another size, or Custom, keeps the name, typed or not.
    @Test func changingTheSizeKeepsTheName() {
        let options = SavePanelOptions(settings: settings(.zip))
        let panel = attach(options, fileName: "Photos.zip")
        options.split = .preset(.mb25)
        panel.nameFieldStringValue = "Mine"
        options.split = .preset(.fat32)
        options.split = .custom(amount: "2", unit: .gb)
        #expect(panel.allowedContentTypes == [.folder])
        #expect(panel.nameFieldStringValue == "Mine")
    }

    @Test func switchingBetweenFormatsThatSplitKeepsTheFolder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = SavePanelOptions(settings: settings(.zip))
        let panel = attach(options, fileName: "Photos.zip", in: directory)
        options.split = .preset(.mb100)
        options.format = .sevenZip
        #expect(options.split == .preset(.mb100))
        #expect(panel.allowedContentTypes == [.folder])
        #expect(panel.nameFieldStringValue == "Photos")
        // And back from the folder in the new format.
        options.split = .none
        #expect(panel.nameFieldStringValue == "Photos.7z")
    }

    /// TAR can't split: choosing it drops the split, hides the row (`SaveOptionsViewTests`) and
    /// restores the archive types, with TAR's extension.
    @Test func switchingToTARDropsTheSplitAndRestoresTheTypes() {
        let options = SavePanelOptions(settings: settings(.zip))
        let panel = attach(options, fileName: "Photos.zip")
        options.split = .preset(.mb100)
        options.format = .tar
        #expect(options.split == .none)
        #expect(!options.isSplitting)
        #expect(options.settings.options.volumeSize == nil)
        #expect(panel.allowedContentTypes == KernirDocumentTypes.savePanelTypes(for: .tar))
        #expect(panel.nameFieldStringValue == "Photos.tar")
    }

    /// A folder name the user typed is kept when Split goes off, with the archive's extension.
    @Test func aTypedFolderNameIsKeptWhenSplitGoesOff() {
        let options = SavePanelOptions(settings: settings(.zip))
        let panel = attach(options, fileName: "Photos.zip")
        options.split = .preset(.mb100)
        panel.nameFieldStringValue = "Holiday"
        options.split = .none
        #expect(panel.nameFieldStringValue == "Holiday.zip")
    }

    // MARK: - Rule (b): the proposed folder name never collides

    @Test func aTakenFolderNameIsNumbered() throws {
        let directory = try makeDirectory(holding: ["Photos", "Photos 2"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = SavePanelOptions(settings: settings(.zip))
        let panel = attach(options, fileName: "Photos.zip", in: directory)
        options.split = .preset(.mb100)
        #expect(panel.nameFieldStringValue == "Photos 3")
        // The archive name comes back, not "Photos 3.zip".
        options.split = .none
        #expect(panel.nameFieldStringValue == "Photos.zip")
    }

    @Test func movingToAnotherFolderProposesAgain() throws {
        let free = try makeDirectory()
        let taken = try makeDirectory(holding: ["Photos"])
        defer {
            for directory in [free, taken] { try? FileManager.default.removeItem(at: directory) }
        }
        let options = SavePanelOptions(settings: settings(.zip))
        let panel = attach(options, fileName: "Photos.zip", in: free)
        options.split = .preset(.mb100)
        #expect(panel.nameFieldStringValue == "Photos")

        options.panel(panel, didChangeToDirectoryURL: taken)
        #expect(panel.nameFieldStringValue == "Photos 2")
        options.panel(panel, didChangeToDirectoryURL: free)
        #expect(panel.nameFieldStringValue == "Photos")
        // Unknown folder: the base name, unchecked.
        options.panel(panel, didChangeToDirectoryURL: nil)
        #expect(panel.nameFieldStringValue == "Photos")
    }

    @Test func aTypedNameIsNeverProposedOver() throws {
        let free = try makeDirectory()
        let taken = try makeDirectory(holding: ["Mine"])
        defer {
            for directory in [free, taken] { try? FileManager.default.removeItem(at: directory) }
        }
        let options = SavePanelOptions(settings: settings(.zip))
        let panel = attach(options, fileName: "Photos.zip", in: free)
        options.split = .preset(.mb100)
        panel.nameFieldStringValue = "Mine"
        options.panel(panel, didChangeToDirectoryURL: taken)
        #expect(panel.nameFieldStringValue == "Mine")
    }

    @Test func movingFolderWithoutSplitChangesNothing() throws {
        let taken = try makeDirectory(holding: ["Photos.zip"])
        defer { try? FileManager.default.removeItem(at: taken) }
        let options = SavePanelOptions(settings: settings(.zip))
        let panel = attach(options, fileName: "Photos.zip")
        options.panel(panel, didChangeToDirectoryURL: taken)
        #expect(panel.nameFieldStringValue == "Photos.zip")
    }
}

/// `validate` for a split save, and the split choice's settings. No panel: these run without a window.
@MainActor
struct SplitSaveValidationTests {
    private func splitOptions(sourceURLs: [URL] = [], split: VolumeSplit = .preset(.mb100)) -> SavePanelOptions {
        var settings = ArchiveSaveSettings(format: .zip, options: ArchiveWriteOptions())
        settings.formatDidChange()
        settings.split = split
        return SavePanelOptions(settings: settings, sourceURLs: sourceURLs)
    }

    /// A fresh temp folder; the caller removes it.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitSaveValidationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFolder(_ name: String, in root: URL, holding files: [String] = []) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data(file.utf8).write(to: folder.appendingPathComponent(file, isDirectory: false))
        }
        return folder
    }

    @Test func theSplitAccessorEditsTheSettings() {
        let options = splitOptions(split: .none)
        #expect(!options.isSplitting)
        options.split = .preset(.mb25)
        #expect(options.settings.split == .preset(.mb25))
        #expect(options.settings.options.volumeSize == 25_000_000)
        #expect(options.isSplitting)
        // A typed size is a split even before it is a valid one; `problems` refuses it.
        options.split = .custom(amount: "", unit: .mb)
        #expect(options.isSplitting)
        #expect(options.settings.options.volumeSize == nil)
    }

    @Test func aFolderHoldingTheDocumentIsRefused() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeFolder("Photos", in: root, holding: ["Photos.zip"])
        let options = splitOptions(sourceURLs: [folder.appendingPathComponent("Photos.zip")])
        #expect(throws: SplitOntoSourceError.self) { try options.panel(NSObject(), validate: folder) }
        // Through the trailing-slash URL the panel returns for an existing folder (q2), and without it.
        #expect(throws: SplitOntoSourceError.self) {
            try options.panel(NSObject(), validate: URL(fileURLWithPath: folder.path, isDirectory: false))
        }
    }

    /// The source check comes first: even an earlier set's folder is refused while it holds a part
    /// of the set being saved.
    @Test func aSetFolderHoldingTheOpenSetIsRefusedAsASource() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeFolder("Photos", in: root, holding: ["Photos.zip.001", "Photos.zip.002"])
        let parts = ["Photos.zip.001", "Photos.zip.002"].map { folder.appendingPathComponent($0) }
        let options = splitOptions(sourceURLs: parts)
        #expect(throws: SplitOntoSourceError.self) { try options.panel(NSObject(), validate: folder) }
    }

    @Test func aFolderBeingAddedOrInsideOneIsRefused() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let added = try makeFolder("Photos", in: root)
        let inside = try makeFolder("Photos/Inner", in: root)
        let options = splitOptions(sourceURLs: [added])
        #expect(throws: SplitOntoSourceError.self) { try options.panel(NSObject(), validate: added) }
        #expect(throws: SplitOntoSourceError.self) { try options.panel(NSObject(), validate: inside) }
    }

    @Test func aFolderHoldingOtherFilesIsRefused() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeFolder("Photos", in: root, holding: ["IMG_0001.jpg"])
        let options = splitOptions()
        #expect(throws: NotASplitSetFolderError.self) { try options.panel(NSObject(), validate: folder) }
    }

    @Test func aFileOrSymlinkAtTheURLIsRefused() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Photos")
        try Data("x".utf8).write(to: file)
        let set = try makeFolder("Set", in: root, holding: ["Set.zip.001"])
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: set)
        let options = splitOptions()
        #expect(throws: NotASplitSetFolderError.self) { try options.panel(NSObject(), validate: file) }
        #expect(throws: NotASplitSetFolderError.self) { try options.panel(NSObject(), validate: link) }
    }

    @Test func anEarlierSetAnEmptyFolderOrANewNameIsAccepted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try makeFolder("Photos", in: root, holding: ["Photos.zip.001", "Photos.zip.002", ".DS_Store"])
        let empty = try makeFolder("Empty", in: root)
        let options = splitOptions(sourceURLs: [root.appendingPathComponent("elsewhere.zip")])
        try options.panel(NSObject(), validate: set)
        try options.panel(NSObject(), validate: empty)
        try options.panel(NSObject(), validate: root.appendingPathComponent("New", isDirectory: false))
    }

    /// Without Split the folder rules don't apply: NSDocument writes one file, and its own
    /// "Replace?" covers what is there.
    @Test func withoutSplitTheFolderRulesDoNotRun() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try makeFolder("Photos", in: root, holding: ["Photos.zip", "IMG_0001.jpg"])
        let options = splitOptions(sourceURLs: [folder.appendingPathComponent("Photos.zip")], split: .none)
        try options.panel(NSObject(), validate: folder)
    }

    @Test func aSplitWithAProblemIsRefused() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let options = splitOptions(split: .custom(amount: "0.5", unit: .mb))
        let problem = try #require(options.settings.problems.first)
        let error = #expect(throws: NSError.self) {
            try options.panel(NSObject(), validate: root.appendingPathComponent("New"))
        }
        #expect(error?.localizedDescription == problem.message)
    }

    @Test func theRefusalsSayWhy() {
        // The set-folder refusal is in the Shared table (iOS too), the other in macOS Localizable (the
        // panel's own strings); no catalog here, so the same calls.
        #expect(NotASplitSetFolderError().localizedDescription
                == String(localized: "Only a folder holding an earlier split archive can be replaced.", table: "Shared"))
        #expect(NotASplitSetFolderError().localizedDescription
                == "Only a folder holding an earlier split archive can be replaced.")
        let name = "Photos"
        #expect(SplitOntoSourceError(name: name).localizedDescription == String(
            localized: "Saving to “\(name)” would replace this archive or files being added to it. Choose another name."))
    }

    /// The new set is left in a temporary folder, which can be cleared, so the suggestion says to move it;
    /// when the earlier folder was moved to a temporary folder too, it says to move both.
    @Test func aSetNotPlacedSaysToMoveTheVolumesOut() {
        let underlying = CocoaError(.fileWriteUnknown)
        let error = SplitSetNotPlacedError(name: "Photos", setFolder: URL(fileURLWithPath: "/tmp/T/Photos"),
                                           originalLocation: URL(fileURLWithPath: "/tmp/O/Photos"),
                                           underlying: underlying)
        #expect(error.errorDescription == "Lutik couldn't replace “Photos”.")
        #expect(error.recoverySuggestion == [
            underlying.localizedDescription,
            "The earlier folder is now at “/tmp/O/Photos”.",
            "The new volumes are in “/tmp/T/Photos”.",
            "Move the earlier folder and the new volumes to another folder to keep them. "
                + "Temporary folders can be cleared at any time.",
        ].joined(separator: " "))

        let newOnly = SplitSetNotPlacedError(name: "Photos", setFolder: URL(fileURLWithPath: "/tmp/T/Photos"),
                                             originalLocation: nil, underlying: underlying)
        #expect(newOnly.recoverySuggestion == [
            underlying.localizedDescription,
            "The new volumes are in “/tmp/T/Photos”.",
            "Move them to another folder to keep them. Temporary folders can be cleared at any time.",
        ].joined(separator: " "))
    }

    /// Leftover (b): the earlier set went to the Trash and the new one wasn't moved in: the suggestion
    /// says the earlier folder is in the Trash, where the new volumes are, and to move both out.
    @Test func aSetNotPlacedAfterTheTrashSaysTheEarlierFolderIsInTheTrash() {
        let underlying = CocoaError(.fileWriteUnknown)
        let error = SplitSetNotPlacedError.earlierFolderInTrash(name: "Photos",
                                                                setFolder: URL(fileURLWithPath: "/tmp/T/Photos"),
                                                                underlying: underlying)
        #expect(error.earlierFolderInTrash)
        #expect(error.originalLocation == nil)
        #expect(error.errorDescription == "Lutik couldn't replace “Photos”.")
        #expect(error.recoverySuggestion == [
            underlying.localizedDescription,
            "The earlier folder is in the Trash.",
            "The new volumes are in “/tmp/T/Photos”.",
            "Move the earlier folder and the new volumes to another folder to keep them. "
                + "Temporary folders can be cleared at any time.",
        ].joined(separator: " "))
        #expect(SplitSetNotPlacedError(name: "Photos", setFolder: URL(fileURLWithPath: "/tmp/T/Photos"),
                                       originalLocation: nil, underlying: underlying).earlierFolderInTrash == false)
    }

    /// The Trash threw, but the earlier set folder was gone by then, so it may be in the Trash: the
    /// suggestion says so, where the new volumes are, and to move both out.
    @Test func aSetNotPlacedAfterAFailedTrashSaysTheEarlierFolderMayBeInTheTrash() {
        let underlying = CocoaError(.fileWriteUnknown)
        let error = SplitSetNotPlacedError.earlierFolderMayBeInTrash(name: "Photos",
                                                                     setFolder: URL(fileURLWithPath: "/tmp/T/Photos"),
                                                                     underlying: underlying)
        #expect(error.earlierFolderMayBeInTrash)
        #expect(!error.earlierFolderInTrash)
        #expect(error.originalLocation == nil)
        #expect(error.errorDescription == "Lutik couldn't replace “Photos”.")
        #expect(error.recoverySuggestion == [
            underlying.localizedDescription,
            "The earlier folder may be in the Trash.",
            "The new volumes are in “/tmp/T/Photos”.",
            "Move the earlier folder and the new volumes to another folder to keep them. "
                + "Temporary folders can be cleared at any time.",
        ].joined(separator: " "))
        #expect(!SplitSetNotPlacedError.earlierFolderInTrash(name: "Photos",
                                                             setFolder: URL(fileURLWithPath: "/tmp/T/Photos"),
                                                             underlying: underlying).earlierFolderMayBeInTrash)
    }

    /// E0 ask 5: the split size never reaches `saveOptions`, or a later ⌘S fails or splits too.
    /// `ArchiveModel.apply(_:)` drops `volumeSize`, and the split save never calls `apply`
    /// anyway.
    @Test func aSplitChoiceNeverReachesSaveOptions() {
        let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
        let options = SavePanelOptions(settings: ArchiveSaveSettings(model: model))
        options.settings.options.method = .store
        options.split = .preset(.mb100)
        #expect(options.settings.options.volumeSize != nil)

        model.apply(options.settings)
        #expect(model.saveOptions?.volumeSize == nil)
        #expect(model.saveOptions?.method == .store)
        let next = ArchiveSaveSettings(model: model)
        #expect(next.split == .none)
        #expect(next.options.volumeSize == nil)
    }
}

/// The destination rules `validate` and the move into place share, and how a finished
/// set goes in place: the recheck right before the move (TOCTOU), the earlier set folder to the
/// Trash, and `replaceItemAt` when the Trash fails. The Trash is a fake here: a real
/// `trashItem` runs only in a hosted run. No panel: these run without a window.
struct SplitSetPlacementTests {
    /// Records the URLs a fake Trash or replace was asked for.
    private final class Calls: Sendable {
        private let urls = OSAllocatedUnfairLock<[URL]>(initialState: [])
        var all: [URL] { urls.withLock { $0 } }
        func record(_ url: URL) { urls.withLock { $0.append(url) } }
    }

    /// A fresh temp folder; the caller removes it.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitSetPlacementTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeFolder(_ folder: URL, holding files: [String]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data("old \(file)".utf8).write(to: folder.appendingPathComponent(file, isDirectory: false))
        }
    }

    /// A finished set for `destination`, made where a split save makes it.
    private func makeNewSet(for destination: URL, placement: SplitSetPlacement) throws -> URL {
        let folder = try placement.makeFolder(for: destination).url
        try Data("new".utf8).write(to: folder.appendingPathComponent("\(destination.lastPathComponent).zip.001"))
        return folder
    }

    private func contents(_ folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// A Trash that moves the item into `trash` (a test folder) and records it.
    private func movingTrash(into trash: URL, calls: Calls) -> @Sendable (URL) throws -> Void {
        { url in
            calls.record(url)
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
    }

    private func failingTrash(_ calls: Calls, before: @escaping @Sendable (URL) throws -> Void = { _ in })
        -> @Sendable (URL) throws -> Void {
        { url in
            calls.record(url)
            try before(url)
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func recordingReplace(_ calls: Calls) -> @Sendable (URL, URL) throws -> Void {
        { original, replacement in
            calls.record(original)
            try SplitSetPlacement.live.replaceItem(original, replacement)
        }
    }

    // MARK: - The shared rules (L3)

    @Test func theDestinationRulesAreTheOnesValidateApplies() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(photos, holding: ["Photos.zip.001", "Photos.zip.002"])
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        try makeFolder(notes, holding: ["todo.txt"])
        let file = root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)

        #expect(SplitSetPlacement.splitDestinationError(root.appendingPathComponent("New"), sources: []) == nil)
        #expect(SplitSetPlacement.splitDestinationError(photos, sources: []) == nil)
        #expect(SplitSetPlacement.splitDestinationError(notes, sources: []) is NotASplitSetFolderError)
        #expect(SplitSetPlacement.splitDestinationError(file, sources: []) is NotASplitSetFolderError)
        let holding = SplitSetPlacement.splitDestinationError(notes, sources: [notes.appendingPathComponent("todo.txt")])
        #expect((holding as? SplitOntoSourceError)?.name == "Notes")
    }

    // MARK: - The temporary folder

    @Test func theSetIsMadeInAnEmptyFolderOfItsOwnNamedLikeTheDestination() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let placement = SplitSetPlacement.live
        let destination = root.appendingPathComponent("Photos 2", isDirectory: true)
        let folder = try placement.makeFolder(for: destination).url
        #expect(folder.lastPathComponent == "Photos 2")
        #expect(try contents(folder).isEmpty)
        #expect(try contents(folder.deletingLastPathComponent()) == ["Photos 2"])
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        placement.discard(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    /// The folder can't be made (here a name too long for the volume): the temporary folder made for it
    /// goes too. The error names the folder, so the test finds the temporary folder around it.
    @Test func aFolderThatCannotBeMadeLeavesNoTemporaryFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent(String(repeating: "x", count: 300), isDirectory: true)

        let error = #expect(throws: CocoaError.self) {
            try SplitSetPlacement.live.makeFolder(for: destination)
        }

        let folder = try #require(error?.userInfo[NSURLErrorKey] as? URL)
        #expect(folder.lastPathComponent == destination.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
        #expect(try contents(root).isEmpty)
    }

    // MARK: - Into place (test (j))

    /// Nothing at the URL: a plain move. Also when something was there when the save started
    /// (`replacing`) and is gone now.
    @Test(arguments: [false, true])
    func aNewNameIsAPlainMoveWithNoTrash(replacing: Bool) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let trashed = Calls()
        let placement = SplitSetPlacement(trashItem: movingTrash(into: root.appendingPathComponent("Trash"), calls: trashed),
                                          replaceItem: { _, _ in Issue.record("no replace") })
        let destination = root.appendingPathComponent("Photos", isDirectory: false)
        let folder = try makeNewSet(for: destination, placement: placement)

        try placement.place(folder, at: destination, sources: [], replacing: replacing)

        #expect(trashed.all.isEmpty)
        #expect(try contents(destination) == ["Photos.zip.001"])
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    @Test func anEarlierSetGoesToTheTrashAndTheNewOneTakesItsPlace() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001", "Photos.7z.002", "Photos.7z.004", ".DS_Store"])
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let trashed = Calls()
        let placement = SplitSetPlacement(trashItem: movingTrash(into: trash, calls: trashed),
                                          replaceItem: { _, _ in Issue.record("no replace") })
        let folder = try makeNewSet(for: destination, placement: placement)

        try placement.place(folder, at: destination, sources: [], replacing: true)

        #expect(trashed.all.map(\.standardizedFileURL.path) == [destination.standardizedFileURL.path])
        #expect(try contents(destination) == ["Photos.zip.001"])
        #expect(try contents(trash.appendingPathComponent("Photos"))
                == ["Photos.7z.001", "Photos.7z.002", "Photos.7z.004", ".DS_Store"])
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    /// A new name (no Replace in the panel), and a set folder appears there while the set is written
    /// (another window saving to the same name): refused, nothing trashed, the folder left as it is.
    /// Without this, a volume with no Trash would lose it for good to the `replaceItemAt` fallback.
    @Test func aSetFolderThatAppearedAtANewNameIsRefusedAndLeftAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Backup", isDirectory: false)
        let trashed = Calls()
        let replaced = Calls()
        let placement = SplitSetPlacement(trashItem: failingTrash(trashed), replaceItem: recordingReplace(replaced))
        let folder = try makeNewSet(for: destination, placement: placement)
        try makeFolder(destination, holding: ["Backup.zip.001", "Backup.zip.002"])

        let error = #expect(throws: CocoaError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: false)
        }

        #expect(error?.code == .fileWriteFileExists)
        #expect(trashed.all.isEmpty)
        #expect(replaced.all.isEmpty)
        #expect(try contents(destination) == ["Backup.zip.001", "Backup.zip.002"])
        #expect(try Data(contentsOf: destination.appendingPathComponent("Backup.zip.001"))
                == Data("old Backup.zip.001".utf8))
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    /// L1: a file or another folder appears at a new name while the set is written. Refused as a taken
    /// name (`fileWriteFileExists`), not as a folder that isn't a set: the user chose no Replace.
    @Test(arguments: [false, true])
    func anItemThatAppearedAtANewNameIsRefusedAsTakenAndLeftAlone(isFolder: Bool) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Backup", isDirectory: false)
        let trashed = Calls()
        let replaced = Calls()
        let placement = SplitSetPlacement(trashItem: failingTrash(trashed), replaceItem: recordingReplace(replaced))
        let folder = try makeNewSet(for: destination, placement: placement)
        if isFolder {
            try makeFolder(destination, holding: ["notes.txt"])
        } else {
            try Data("mine".utf8).write(to: destination)
        }

        let error = #expect(throws: CocoaError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: false)
        }

        #expect(error?.code == .fileWriteFileExists)
        #expect(trashed.all.isEmpty)
        #expect(replaced.all.isEmpty)
        if isFolder {
            #expect(try contents(destination) == ["notes.txt"])
        } else {
            #expect(try Data(contentsOf: destination) == Data("mine".utf8))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    /// A Cancel that comes after the engine's last check still stops the save before anything is
    /// trashed or moved, and the temporary folder goes.
    @Test func aCancelBeforeTheMoveTrashesNothingAndRemovesTheTemporaryFolder() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let trashed = Calls()
        let placement = SplitSetPlacement(trashItem: movingTrash(into: root.appendingPathComponent("Trash"), calls: trashed),
                                          replaceItem: { _, _ in Issue.record("no replace") })
        let folder = try makeNewSet(for: destination, placement: placement)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(trashed.all.isEmpty)
        #expect(try contents(destination) == ["Photos.7z.001"])
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    // MARK: - The recheck (test (i))

    @Test func aSetFolderThatGainedAnotherFileIsRefusedAndLeftAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let trashed = Calls()
        let placement = SplitSetPlacement(trashItem: movingTrash(into: root.appendingPathComponent("Trash"), calls: trashed),
                                          replaceItem: { _, _ in Issue.record("no replace") })
        let folder = try makeNewSet(for: destination, placement: placement)
        // Accepted by `validate`, then changed before the move.
        try Data("mine".utf8).write(to: destination.appendingPathComponent("notes.txt"))

        #expect(throws: NotASplitSetFolderError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(trashed.all.isEmpty)
        #expect(try contents(destination) == ["Photos.7z.001", "notes.txt"])
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    @Test func aSetFolderSwappedForASymlinkIsRefusedAndLeftAlone() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("elsewhere/Photos", isDirectory: true)
        try makeFolder(real, holding: ["Photos.7z.001"])
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: real)
        let trashed = Calls()
        let placement = SplitSetPlacement(trashItem: movingTrash(into: root.appendingPathComponent("Trash"), calls: trashed),
                                          replaceItem: { _, _ in Issue.record("no replace") })
        let folder = try makeNewSet(for: destination, placement: placement)

        #expect(throws: NotASplitSetFolderError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(trashed.all.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == real.path)
        #expect(try contents(real) == ["Photos.7z.001"])
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    @Test func aDestinationThatNowHoldsASourceIsRefused() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.zip"])
        let placement = SplitSetPlacement(trashItem: { _ in Issue.record("no Trash") },
                                          replaceItem: { _, _ in Issue.record("no replace") })
        let folder = try makeNewSet(for: destination, placement: placement)

        #expect(throws: SplitOntoSourceError.self) {
            try placement.place(folder, at: destination, sources: [destination.appendingPathComponent("Photos.zip")],
                                replacing: true)
        }
        #expect(try contents(destination) == ["Photos.zip"])
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    // MARK: - When the Trash fails

    @Test func aFailedTrashFallsBackToReplacingTheEarlierSet() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001", "Photos.7z.002"])
        let trashed = Calls()
        let replaced = Calls()
        let placement = SplitSetPlacement(trashItem: failingTrash(trashed), replaceItem: recordingReplace(replaced))
        let folder = try makeNewSet(for: destination, placement: placement)

        try placement.place(folder, at: destination, sources: [], replacing: true)

        #expect(trashed.all.count == 1)
        #expect(replaced.all.map(\.standardizedFileURL.path) == [destination.standardizedFileURL.path])
        #expect(try contents(destination) == ["Photos.zip.001"])
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    /// The Trash failed because the earlier set is gone by then: a plain move, no `replaceItemAt` with
    /// nothing to replace.
    @Test func aTrashThatFailsOnAGoneSetMovesTheNewSetIn() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let replaced = Calls()
        let trash = failingTrash(Calls()) { url in try FileManager.default.removeItem(at: url) }
        let placement = SplitSetPlacement(trashItem: trash, replaceItem: { original, _ in replaced.record(original) })
        let folder = try makeNewSet(for: destination, placement: placement)

        try placement.place(folder, at: destination, sources: [], replacing: true)

        #expect(replaced.all.isEmpty)
        #expect(try contents(destination) == ["Photos.zip.001"])
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    /// Both rules run again right before `replaceItemAt`.
    @Test func theFallbackChecksAgainBeforeItReplaces() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let replaced = Calls()
        let trash = failingTrash(Calls()) { url in
            try Data("mine".utf8).write(to: url.appendingPathComponent("notes.txt"))
        }
        let placement = SplitSetPlacement(trashItem: trash, replaceItem: recordingReplace(replaced))
        let folder = try makeNewSet(for: destination, placement: placement)

        #expect(throws: NotASplitSetFolderError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(replaced.all.isEmpty)
        #expect(try contents(destination) == ["Photos.7z.001", "notes.txt"])
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    /// A failed replace keeps the new set and says where the earlier folder went. Here
    /// something else takes the name before it can go back, so it stays where `replaceItemAt` moved it.
    @Test func aFailedReplaceKeepsTheNewSetAndSaysWhereTheEarlierFolderIs() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let moved = root.appendingPathComponent("Moved Photos", isDirectory: true)
        let placement = SplitSetPlacement(trashItem: failingTrash(Calls()), replaceItem: { original, _ in
            try FileManager.default.moveItem(at: original, to: moved)
            try Data("other".utf8).write(to: original)
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [SplitSetPlacement.originalItemLocationKey: moved])
        })
        let folder = try makeNewSet(for: destination, placement: placement)
        // The error keeps the new set's temporary folder.
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let error = #expect(throws: SplitSetNotPlacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(try Data(contentsOf: destination) == Data("other".utf8))
        #expect(try contents(moved) == ["Photos.7z.001"])
        #expect(error?.originalLocation == moved)
        #expect(error?.setFolder == folder)
        #expect(try contents(folder) == ["Photos.zip.001"])
        #expect(error?.errorDescription == String(localized: "Lutik couldn't replace “Photos”."))
        #expect(error?.recoverySuggestion?.contains(moved.path) == true)
        #expect(error?.recoverySuggestion?.contains(folder.path) == true)
    }

    /// The key names a place where nothing is (the earlier folder never left): the error names no
    /// place for it.
    @Test func aFailedReplaceNamesNoPlaceWhereTheEarlierFolderIsNot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let moved = root.appendingPathComponent("Moved Photos", isDirectory: true)
        let placement = SplitSetPlacement(trashItem: failingTrash(Calls()), replaceItem: { _, _ in
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [SplitSetPlacement.originalItemLocationKey: moved])
        })
        let folder = try makeNewSet(for: destination, placement: placement)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let error = #expect(throws: SplitSetNotPlacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(try contents(destination) == ["Photos.7z.001"])
        #expect(error?.originalLocation == nil)
        #expect(error?.setFolder == folder)
        #expect(error?.recoverySuggestion?.contains(moved.path) == false)
        #expect(error?.recoverySuggestion?.contains(folder.path) == true)
    }

    /// `replaceItemAt` moved the new set too before it failed (`newItemLocationKey`): the error names
    /// that place, and the emptied temporary folder goes. A key naming a place where nothing is changes
    /// nothing.
    @Test(arguments: [true, false])
    func aFailedReplaceSaysWhereItMovedTheNewSet(moves: Bool) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let elsewhere = root.appendingPathComponent("New Photos", isDirectory: true)
        let placement = SplitSetPlacement(trashItem: failingTrash(Calls()), replaceItem: { _, replacement in
            if moves { try FileManager.default.moveItem(at: replacement, to: elsewhere) }
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [SplitSetPlacement.newItemLocationKey: elsewhere])
        })
        let folder = try makeNewSet(for: destination, placement: placement)
        let temporary = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: temporary) }

        let error = #expect(throws: SplitSetNotPlacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        let setFolder = moves ? elsewhere : folder
        #expect(error?.setFolder == setFolder)
        #expect(try contents(setFolder) == ["Photos.zip.001"])
        #expect(error?.recoverySuggestion?.contains(setFolder.path) == true)
        #expect(error?.originalLocation == nil)
        #expect(try contents(destination) == ["Photos.7z.001"])
        #expect(FileManager.default.fileExists(atPath: temporary.path) == !moves)
    }

    /// The key names a place where something is, but the new set never left `folder`:
    /// the error keeps naming `folder`, and its temporary folder stays.
    @Test func aFailedReplaceThatLeftTheNewSetInPlaceNamesItThere() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let elsewhere = root.appendingPathComponent("New Photos", isDirectory: true)
        try makeFolder(elsewhere, holding: ["other"])
        let placement = SplitSetPlacement(trashItem: failingTrash(Calls()), replaceItem: { _, _ in
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [SplitSetPlacement.newItemLocationKey: elsewhere])
        })
        let folder = try makeNewSet(for: destination, placement: placement)
        let temporary = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: temporary) }

        let error = #expect(throws: SplitSetNotPlacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(error?.setFolder == folder)
        #expect(try contents(folder) == ["Photos.zip.001"])
        #expect(error?.recoverySuggestion?.contains(folder.path) == true)
        #expect(error?.recoverySuggestion?.contains(elsewhere.path) == false)
        #expect(try contents(elsewhere) == ["other"])
        #expect(try contents(destination) == ["Photos.7z.001"])
    }

    /// The new set moved out, but something else is in its temporary folder: that folder
    /// is not empty, so it stays with what is in it.
    @Test func aTemporaryFolderTheNewSetLeftThatHoldsAnotherFileStays() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let elsewhere = root.appendingPathComponent("New Photos", isDirectory: true)
        let placement = SplitSetPlacement(trashItem: failingTrash(Calls()), replaceItem: { _, replacement in
            try FileManager.default.moveItem(at: replacement, to: elsewhere)
            try Data("stray".utf8).write(to: replacement.deletingLastPathComponent()
                .appendingPathComponent("stray", isDirectory: false))
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [SplitSetPlacement.newItemLocationKey: elsewhere])
        })
        let folder = try makeNewSet(for: destination, placement: placement)
        let temporary = folder.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: temporary) }

        let error = #expect(throws: SplitSetNotPlacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(error?.setFolder == elsewhere)
        #expect(try contents(elsewhere) == ["Photos.zip.001"])
        #expect(try contents(temporary) == ["stray"])
        #expect(try contents(destination) == ["Photos.7z.001"])
    }

    /// L2:`replaceItemAt` moved the earlier set away, then failed. The earlier set goes back to its
    /// name, so the error has no other place to name for it; the new set stays where it was written.
    /// The folder it was moved into stays: it isn't a temporary folder of `replaceItemAt`'s.
    @Test func aReplaceThatFailsAfterMovingTheEarlierSetAwayPutsItBack() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001", "Photos.7z.002"])
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        let moved = elsewhere.appendingPathComponent("Photos", isDirectory: true)
        let placement = SplitSetPlacement(trashItem: failingTrash(Calls()), replaceItem: { original, _ in
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: original, to: moved)
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [SplitSetPlacement.originalItemLocationKey: moved])
        })
        let folder = try makeNewSet(for: destination, placement: placement)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let error = #expect(throws: SplitSetNotPlacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(try contents(destination) == ["Photos.7z.001", "Photos.7z.002"])
        #expect(!FileManager.default.fileExists(atPath: moved.path))
        #expect(try contents(elsewhere).isEmpty)
        #expect(error?.originalLocation == nil)
        #expect(error?.setFolder == folder)
        #expect(try contents(folder) == ["Photos.zip.001"])
        #expect(error?.recoverySuggestion?.contains(moved.path) == false)
        #expect(error?.recoverySuggestion?.contains(folder.path) == true)
    }

    /// The earlier set went into a temporary folder of `replaceItemAt`'s own (an item-replacement
    /// folder) and came back from it: that folder, now empty, goes too.
    @Test func aSetPutBackLeavesNoEmptyTemporaryFolderOfReplaceItemAt() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let replacementFolder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                            appropriateFor: root, create: true)
        defer { try? FileManager.default.removeItem(at: replacementFolder) }
        let moved = replacementFolder.appendingPathComponent("Photos", isDirectory: true)
        let placement = SplitSetPlacement(trashItem: failingTrash(Calls()), replaceItem: { original, _ in
            try FileManager.default.moveItem(at: original, to: moved)
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [SplitSetPlacement.originalItemLocationKey: moved])
        })
        let folder = try makeNewSet(for: destination, placement: placement)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let error = #expect(throws: SplitSetNotPlacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(try contents(destination) == ["Photos.7z.001"])
        #expect(error?.originalLocation == nil)
        #expect(!FileManager.default.fileExists(atPath: replacementFolder.path))
        #expect(try contents(folder) == ["Photos.zip.001"])
    }

    /// The temporary folder of `replaceItemAt`'s the earlier set came back from holds
    /// another file: it is not empty, so it stays with what is in it.
    @Test func aTemporaryFolderOfReplaceItemAtThatHoldsAnotherFileStays() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let replacementFolder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                            appropriateFor: root, create: true)
        defer { try? FileManager.default.removeItem(at: replacementFolder) }
        let moved = replacementFolder.appendingPathComponent("Photos", isDirectory: true)
        let placement = SplitSetPlacement(trashItem: failingTrash(Calls()), replaceItem: { original, _ in
            try FileManager.default.moveItem(at: original, to: moved)
            try Data("stray".utf8).write(to: replacementFolder.appendingPathComponent("stray", isDirectory: false))
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [SplitSetPlacement.originalItemLocationKey: moved])
        })
        let folder = try makeNewSet(for: destination, placement: placement)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let error = #expect(throws: SplitSetNotPlacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(try contents(destination) == ["Photos.7z.001"])
        #expect(error?.originalLocation == nil)
        #expect(try contents(replacementFolder) == ["stray"])
        #expect(try contents(folder) == ["Photos.zip.001"])
    }

    /// A folder named like an item-replacement folder, but not in `TemporaryItems`, isn't
    /// one of `replaceItemAt`'s: emptied when the earlier set goes back, it still stays.
    @Test func anEmptiedNSIRDFolderOutsideTemporaryItemsStays() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let lookalike = root.appendingPathComponent("NSIRD_SplitSetPlacementTests", isDirectory: true)
        try makeFolder(lookalike, holding: [])
        let moved = lookalike.appendingPathComponent("Photos", isDirectory: true)
        let placement = SplitSetPlacement(trashItem: failingTrash(Calls()), replaceItem: { original, _ in
            try FileManager.default.moveItem(at: original, to: moved)
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                          userInfo: [SplitSetPlacement.originalItemLocationKey: moved])
        })
        let folder = try makeNewSet(for: destination, placement: placement)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let error = #expect(throws: SplitSetNotPlacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(try contents(destination) == ["Photos.7z.001"])
        #expect(error?.originalLocation == nil)
        #expect(try contents(lookalike).isEmpty)
        #expect(try contents(folder) == ["Photos.zip.001"])
    }

    /// The Trash took the earlier set, then the move failed.
    /// The new set is kept where it was written, and the error says where it is and that the earlier
    /// set is in the Trash.
    @Test func aFailedMoveAfterTheTrashKeepsTheNewSetAndSaysTheEarlierOneIsInTheTrash() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let trashed = Calls()
        let moveToTrash = movingTrash(into: trash, calls: trashed)
        let placement = SplitSetPlacement(trashItem: { url in
            try moveToTrash(url)
            // Something else takes the name before the move.
            try Data("other".utf8).write(to: url)
        }, replaceItem: { _, _ in Issue.record("no replace") })
        let folder = try makeNewSet(for: destination, placement: placement)
        // The error keeps the new set's temporary folder.
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let error = #expect(throws: SplitSetNotPlacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(error?.name == "Photos")
        #expect(error?.earlierFolderInTrash == true)
        #expect(error?.originalLocation == nil)
        #expect(error?.setFolder == folder)
        #expect((error?.underlying as? CocoaError)?.code == .fileWriteFileExists)
        #expect(try contents(folder) == ["Photos.zip.001"])
        #expect(trashed.all.map(\.standardizedFileURL.path) == [destination.standardizedFileURL.path])
        #expect(try contents(trash.appendingPathComponent("Photos")) == ["Photos.7z.001"])
        #expect(try Data(contentsOf: destination) == Data("other".utf8))
        #expect(error?.errorDescription == String(localized: "Lutik couldn't replace “Photos”."))
        #expect(error?.recoverySuggestion == [
            error?.underlying.localizedDescription ?? "",
            "The earlier folder is in the Trash.",
            "The new volumes are in “\(folder.path)”.",
            "Move the earlier folder and the new volumes to another folder to keep them. "
                + "Temporary folders can be cleared at any time.",
        ].joined(separator: " "))
    }

    /// The Trash moved the earlier set, then threw, and then the move failed. The earlier set is gone,
    /// maybe to the Trash, so the new set is kept where it was written, and the error says where it is
    /// and that the earlier set may be in the Trash.
    @Test func aFailedMoveAfterATrashThatThrewOnceTheSetWasGoneKeepsTheNewSet() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let trashed = Calls()
        let placement = SplitSetPlacement(trashItem: failingTrash(trashed, before: { url in
            // The earlier set goes to the Trash, and the folder around it takes no new item, so the move
            // fails.
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        }), replaceItem: { _, _ in Issue.record("no replace") })
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        let folder = try makeNewSet(for: destination, placement: placement)
        // The error keeps the new set's temporary folder.
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let error = #expect(throws: SplitSetNotPlacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(error?.name == "Photos")
        #expect(error?.earlierFolderMayBeInTrash == true)
        #expect(error?.earlierFolderInTrash == false)
        #expect(error?.originalLocation == nil)
        #expect(error?.setFolder == folder)
        // The move's error, not the Trash's.
        #expect((error?.underlying as? CocoaError)?.code == .fileWriteNoPermission)
        #expect((error?.underlying as NSError?)?.userInfo["NSSourceFilePathErrorKey"] as? String == folder.path)
        #expect(try contents(folder) == ["Photos.zip.001"])
        #expect(trashed.all.map(\.standardizedFileURL.path) == [destination.standardizedFileURL.path])
        #expect(try contents(trash.appendingPathComponent("Photos")) == ["Photos.7z.001"])
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(error?.errorDescription == String(localized: "Lutik couldn't replace “Photos”."))
        #expect(error?.recoverySuggestion == [
            error?.underlying.localizedDescription ?? "",
            "The earlier folder may be in the Trash.",
            "The new volumes are in “\(folder.path)”.",
            "Move the earlier folder and the new volumes to another folder to keep them. "
                + "Temporary folders can be cleared at any time.",
        ].joined(separator: " "))
    }

    /// The Trash took the earlier set, then the move failed because the temporary new set
    /// had vanished too (the fake Trash simulates that). Nothing is there to keep, so the raw error, and
    /// the temporary folder goes.
    @Test func aFailedMoveAfterTheTrashWithTheNewSetGoneReportsTheRawError() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let trashed = Calls()
        let newSet = Calls()
        let moveToTrash = movingTrash(into: trash, calls: trashed)
        let placement = SplitSetPlacement(trashItem: { url in
            try moveToTrash(url)
            // Simulates the temporary new set vanishing, so the move fails.
            for folder in newSet.all { try FileManager.default.removeItem(at: folder) }
        }, replaceItem: { _, _ in Issue.record("no replace") })
        let folder = try makeNewSet(for: destination, placement: placement)
        newSet.record(folder)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let error = #expect(throws: (any Error).self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(!(error is SplitSetNotPlacedError))
        // The move's error.
        #expect((error as? CocoaError)?.code == .fileNoSuchFile)
        #expect((error as NSError?)?.userInfo["NSSourceFilePathErrorKey"] as? String == folder.path)
        #expect(trashed.all.map(\.standardizedFileURL.path) == [destination.standardizedFileURL.path])
        #expect(try contents(trash.appendingPathComponent("Photos")) == ["Photos.7z.001"])
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    /// The Trash moved the earlier set and threw, then the move failed because the
    /// temporary new set had vanished too (the fake Trash simulates that). Nothing is there to keep, so
    /// the raw error, and the temporary folder goes.
    @Test func aFailedMoveAfterATrashThatThrewWithTheNewSetGoneReportsTheRawError() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: ["Photos.7z.001"])
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let trashed = Calls()
        let newSet = Calls()
        let placement = SplitSetPlacement(trashItem: failingTrash(trashed, before: { url in
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
            // Simulates the temporary new set vanishing, so the move fails.
            for folder in newSet.all { try FileManager.default.removeItem(at: folder) }
        }), replaceItem: { _, _ in Issue.record("no replace") })
        let folder = try makeNewSet(for: destination, placement: placement)
        newSet.record(folder)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let error = #expect(throws: (any Error).self) {
            try placement.place(folder, at: destination, sources: [], replacing: true)
        }

        #expect(!(error is SplitSetNotPlacedError))
        // The move's error, not the Trash's.
        #expect((error as? CocoaError)?.code == .fileNoSuchFile)
        #expect((error as NSError?)?.userInfo["NSSourceFilePathErrorKey"] as? String == folder.path)
        #expect(trashed.all.map(\.standardizedFileURL.path) == [destination.standardizedFileURL.path])
        #expect(try contents(trash.appendingPathComponent("Photos")) == ["Photos.7z.001"])
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    /// Nothing at the URL, then a failed move: nothing went to the Trash, so the raw error, and the
    /// temporary folder goes, as before leftover (b).
    @Test func aFailedMoveWithNothingTrashedReportsAndRemovesTheTemporaryFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        let trashed = Calls()
        let placement = SplitSetPlacement(trashItem: failingTrash(trashed), replaceItem: { _, _ in
            Issue.record("no replace")
        })
        let folder = try makeNewSet(for: destination, placement: placement)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        // The folder takes no new item, so the move fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }

        let error = #expect(throws: (any Error).self) {
            try placement.place(folder, at: destination, sources: [], replacing: false)
        }

        #expect(error != nil)
        #expect(!(error is SplitSetNotPlacedError))
        // The move's error, not the recheck's.
        #expect((error as? CocoaError)?.code == .fileWriteNoPermission)
        #expect((error as NSError?)?.userInfo["NSSourceFilePathErrorKey"] as? String == folder.path)
        #expect(trashed.all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    // MARK: - In place, when the item-replacement directory is denied

    /// The item-replacement directory refused, as on an SMB share under the sandbox: smbfs has no
    /// .TemporaryItems, and the panel's grant doesn't cover a folder beside the destination.
    private func deniedPlacement(trash: URL, calls: Calls) -> SplitSetPlacement {
        SplitSetPlacement(trashItem: movingTrash(into: trash, calls: calls),
                          replaceItem: { _, _ in Issue.record("no replace") },
                          replacementDirectory: { _ in throw CocoaError(.fileWriteNoPermission) })
    }

    /// A folder holding `sibling.txt` and `Other/kept.txt`, the user's items around the destination.
    private func makeParent(in root: URL) throws -> URL {
        let parent = root.appendingPathComponent("Exports", isDirectory: true)
        try makeFolder(parent, holding: ["sibling.txt"])
        try makeFolder(parent.appendingPathComponent("Other", isDirectory: true), holding: ["kept.txt"])
        return parent
    }

    /// The user's items in `parent` as `makeParent` made them, and nothing else but `plus`.
    private func expectParentUntouched(_ parent: URL, plus: String? = nil,
                                       sourceLocation: SourceLocation = #_sourceLocation) throws {
        let expected = Set(["sibling.txt", "Other"] + (plus.map { [$0] } ?? []))
        #expect(try allNames(parent) == expected, sourceLocation: sourceLocation)
        #expect(try Data(contentsOf: parent.appendingPathComponent("sibling.txt")) == Data("old sibling.txt".utf8),
                sourceLocation: sourceLocation)
        #expect(try contents(parent.appendingPathComponent("Other")) == ["kept.txt"], sourceLocation: sourceLocation)
    }

    /// Writes `names` into `folder` as the engine would; the URLs it reports.
    @discardableResult
    private func writeVolumes(_ names: [String], into folder: URL) throws -> [URL] {
        try names.map { name in
            let url = folder.appendingPathComponent(name)
            try Data("new \(name)".utf8).write(to: url, options: .withoutOverwriting)
            return url
        }
    }

    /// Every name in `folder`, "._" files too (`contentsOfDirectory` hides those).
    private func allNames(_ folder: URL) throws -> Set<String> {
        let directory = try #require(opendir(folder.path))
        defer { closedir(directory) }
        var names: Set<String> = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { names.insert(name) }
        }
        return names
    }

    @Test(arguments: ["Photos", "Photos/"])
    func aDeniedReplacementDirectoryWritesTheSetInPlace(_ name: String) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let trashed = Calls()
        let placement = deniedPlacement(trash: root.appendingPathComponent("Trash"), calls: trashed)
        let destination = URL(fileURLWithPath: parent.path + "/" + name)

        let folder = try placement.makeFolder(for: destination, replacing: false)

        #expect(folder.inPlace)
        #expect(folder.url.standardizedFileURL.path == parent.appendingPathComponent("Photos").path)
        #expect(try contents(folder.url).isEmpty)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)
        try placement.place(folder, at: destination, sources: [], replacing: false, volumes: volumes)

        #expect(trashed.all.isEmpty)
        #expect(try contents(parent) == ["sibling.txt", "Other", "Photos"])
        #expect(try contents(parent.appendingPathComponent("Photos")) == ["Photos.zip.001", "Photos.zip.002"])
    }

    /// Something at the URL that the save may not replace in place: an earlier set that came in at a free
    /// name (not `replacing`), or, with the panel's Replace, a folder that isn't an earlier set (any more).
    /// No in-place write, the original error, and the item stays as it was.
    @Test(arguments: [(false, ["Photos.7z.001", "Photos.7z.002"]), (true, ["Photos.7z.001", "notes.txt"])])
    func aDeniedReplacementDirectoryWithSomethingThereRethrowsTheOriginalError(replacing: Bool,
                                                                              files: [String]) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = parent.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: files)
        let trashed = Calls()
        let placement = deniedPlacement(trash: root.appendingPathComponent("Trash"), calls: trashed)

        let error = #expect(throws: CocoaError.self) {
            try placement.makeFolder(for: destination, replacing: replacing)
        }

        #expect(error?.code == .fileWriteNoPermission)
        #expect(error?.userInfo.isEmpty == true)
        #expect(trashed.all.isEmpty)
        #expect(try contents(parent) == ["sibling.txt", "Other", "Photos"])
        #expect(try allNames(destination) == Set(files))
        #expect(try Data(contentsOf: destination.appendingPathComponent("Photos.7z.001")) == Data("old Photos.7z.001".utf8))
    }

    /// A case-variant twin holds the name on a volume that ignores case: the exclusive create fails, so
    /// the original error, and the twin stays as it was.
    @Test func aDeniedReplacementDirectoryWithACaseTwinThereRethrowsTheOriginalError() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        guard isCaseInsensitive(root) else { return }
        let twin = root.appendingPathComponent("photos", isDirectory: true)
        try makeFolder(twin, holding: ["mine.txt"])
        let placement = deniedPlacement(trash: root.appendingPathComponent("Trash"), calls: Calls())

        let error = #expect(throws: CocoaError.self) {
            try placement.makeFolder(for: root.appendingPathComponent("Photos"), replacing: false)
        }

        #expect(error?.code == .fileWriteNoPermission)
        #expect(error?.userInfo.isEmpty == true)
        #expect(try contents(root) == ["photos"])
        #expect(try contents(twin) == ["mine.txt"])
        #expect(try Data(contentsOf: twin.appendingPathComponent("mine.txt")) == Data("old mine.txt".utf8))
    }

    /// An engine error or Cancel during the write: the engine removed its own volumes, so `SplitSaveJob`
    /// discards with none, and only the folder we made goes, never the folder above, even when nothing
    /// else is in it.
    @Test(arguments: [false, true])
    func aFailedInPlaceWriteRemovesOnlyItsOwnFolder(parentHoldsOthers: Bool) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent: URL
        if parentHoldsOthers {
            parent = try makeParent(in: root)
        } else {
            parent = root.appendingPathComponent("Empty", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }
        let placement = deniedPlacement(trash: root.appendingPathComponent("Trash"), calls: Calls())
        let destination = parent.appendingPathComponent("Photos", isDirectory: false)
        let folder = try placement.makeFolder(for: destination, replacing: false)

        placement.discard(folder, volumes: [])

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        if parentHoldsOthers {
            try expectParentUntouched(parent)
        } else {
            #expect(try contents(parent).isEmpty)
        }
        #expect(try contents(root).contains(parent.lastPathComponent))
    }

    /// Files dropped into the in-place folder during the write aren't ours, even one named like a volume
    /// (the real engine then fails with EEXIST and removes its own volumes): they stay, and so does the
    /// folder holding them.
    @Test func foreignFilesInTheInPlaceFolderSurviveCleanup() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let placement = deniedPlacement(trash: root.appendingPathComponent("Trash"), calls: Calls())
        let destination = parent.appendingPathComponent("Photos", isDirectory: false)
        let folder = try placement.makeFolder(for: destination, replacing: false)
        try Data("mine".utf8).write(to: folder.url.appendingPathComponent("notes.txt"))
        try Data("mine too".utf8).write(to: folder.url.appendingPathComponent("Photos.zip.002"))

        placement.discard(folder, volumes: [])

        #expect(try allNames(destination) == ["notes.txt", "Photos.zip.002"])
        #expect(try Data(contentsOf: destination.appendingPathComponent("Photos.zip.002")) == Data("mine too".utf8))
        #expect(try contents(parent) == ["sibling.txt", "Other", "Photos"])
    }

    /// A Cancel after the engine finished: no Trash, no move; the volumes it wrote go (with their "._"
    /// companions), then our folder; the user's items stay.
    @Test func aCancelledInPlaceSaveRemovesOnlyWhatItWrote() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let trashed = Calls()
        let placement = deniedPlacement(trash: root.appendingPathComponent("Trash"), calls: trashed)
        let destination = parent.appendingPathComponent("Photos", isDirectory: false)
        let folder = try placement.makeFolder(for: destination, replacing: false)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)
        try writeVolumes(["._Photos.zip.001"], into: folder.url)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try placement.place(folder, at: destination, sources: [], replacing: false, volumes: volumes)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(trashed.all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try expectParentUntouched(parent)
    }

    /// The recheck right before the set counts as placed still refuses, and then only what the save wrote
    /// goes: a destination that now holds a source (the folder goes too), and one that gained other files,
    /// one named like a volume (they stay, with the folder).
    @Test func aFailedInPlaceRecheckRemovesOnlyWhatItWrote() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let trashed = Calls()
        let placement = deniedPlacement(trash: root.appendingPathComponent("Trash"), calls: trashed)
        let destination = parent.appendingPathComponent("Photos", isDirectory: false)
        let folder = try placement.makeFolder(for: destination, replacing: false)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)

        let onto = #expect(throws: SplitOntoSourceError.self) {
            try placement.place(folder, at: destination, sources: [volumes[0]], replacing: false, volumes: volumes)
        }
        #expect(onto?.name == "Photos")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try expectParentUntouched(parent)

        let again = try placement.makeFolder(for: destination, replacing: false)
        let written = try writeVolumes(["Photos.zip.001"], into: again.url)
        try Data("mine".utf8).write(to: again.url.appendingPathComponent("notes.txt"))
        try Data("mine too".utf8).write(to: again.url.appendingPathComponent("Photos.zip.002"))
        #expect(throws: NotASplitSetFolderError.self) {
            try placement.place(again, at: destination, sources: [], replacing: false, volumes: written)
        }
        #expect(trashed.all.isEmpty)
        #expect(try allNames(destination) == ["notes.txt", "Photos.zip.002"])
        #expect(try contents(parent) == ["sibling.txt", "Other", "Photos"])
    }

    /// The normal path is unchanged: the seam succeeds, so the set is made in its container, not in place.
    @Test func aWorkingReplacementDirectoryNeverWritesInPlace() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = parent.appendingPathComponent("Photos", isDirectory: false)
        let folder = try SplitSetPlacement.live.makeFolder(for: destination, replacing: false)
        #expect(!folder.inPlace)
        #expect(folder.url.standardizedFileURL.path != destination.standardizedFileURL.path)
        try expectParentUntouched(parent)
        SplitSetPlacement.live.discard(folder, volumes: [])
        #expect(!FileManager.default.fileExists(atPath: folder.url.deletingLastPathComponent().path))
        try expectParentUntouched(parent)
    }

    // MARK: - Replacing an earlier set when the item-replacement directory is denied

    /// The earlier set's names `makeEarlierSet` makes, a Finder `.DS_Store` and an AppleDouble file too.
    private static let earlierSet: Set<String> = ["Photos.7z.001", "Photos.7z.002", "._Photos.7z.001", ".DS_Store"]

    /// An earlier set's folder "Photos" in `parent`, holding `earlierSet`.
    private func makeEarlierSet(in parent: URL) throws -> URL {
        let destination = parent.appendingPathComponent("Photos", isDirectory: true)
        try makeFolder(destination, holding: Array(Self.earlierSet))
        return destination
    }

    /// The item-replacement directory refused, with the given Trash and the live file removal and
    /// rename unless a test swaps them.
    private func replacingPlacement(
        trash: @escaping @Sendable (URL) throws -> Void,
        removeFile: @escaping @Sendable (URL) throws -> Void = SplitSetPlacement.live.removeFile,
        renameFile: @escaping @Sendable (String, String, UInt32) -> Int32 = SplitSetPlacement.live.renameFile
    ) -> SplitSetPlacement {
        SplitSetPlacement(trashItem: trash, replaceItem: { _, _ in Issue.record("no replace") },
                          replacementDirectory: { _ in throw CocoaError(.fileWriteNoPermission) },
                          removeFile: removeFile, renameFile: renameFile)
    }

    /// The names in `folder` that are a staging folder of ours.
    private func stagingNames(_ folder: URL) throws -> [String] {
        try allNames(folder).filter { $0.hasPrefix(".kernir-replace-") }
    }

    @Test(arguments: ["Photos", "Photos/"])
    func aDeniedReplacementDirectoryReplacesAnEarlierSetInPlace(_ name: String) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let trashed = Calls()
        let trash = root.appendingPathComponent("Trash")
        let placement = replacingPlacement(trash: movingTrash(into: trash, calls: trashed))
        let url = URL(fileURLWithPath: parent.path + "/" + name)

        let folder = try placement.makeFolder(for: url, replacing: true)

        #expect(!folder.inPlace)
        #expect(folder.url.deletingLastPathComponent().standardizedFileURL.path == destination.path)
        #expect(folder.url.lastPathComponent.hasPrefix(".kernir-replace-"))
        #expect(try allNames(folder.url).isEmpty)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)
        try placement.place(folder, at: url, sources: [], replacing: true, volumes: volumes)

        #expect(Set(trashed.all.map(\.lastPathComponent)) == ["Photos.7z.001", "Photos.7z.002", "._Photos.7z.001"])
        #expect(try allNames(trash) == ["Photos.7z.001", "Photos.7z.002", "._Photos.7z.001"])
        #expect(try allNames(destination) == ["Photos.zip.001", "Photos.zip.002", ".DS_Store"])
        #expect(try Data(contentsOf: destination.appendingPathComponent("Photos.zip.002"))
                    == Data("new Photos.zip.002".utf8))
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// The Trash fails as on smbfs (NSCocoaErrorDomain 3328 over OSStatus -120, no Trash on the
    /// volume): each earlier volume is unlinked instead, never a recursive delete, and the new set is in
    /// place; the staging folder is gone and nothing else is touched.
    @Test func aFailingTrashUnlinksTheEarlierVolumesInstead() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let trashed = Calls()
        let removed = Calls()
        let placement = replacingPlacement(trash: { url in
            trashed.record(url)
            throw NSError(domain: NSCocoaErrorDomain, code: 3328,
                          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -120)])
        }, removeFile: { url in
            removed.record(url)
            try SplitSetPlacement.live.removeFile(url)
        })
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)

        try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)

        #expect(trashed.all.count == 3)
        #expect(Set(removed.all.map(\.lastPathComponent)) == ["Photos.7z.001", "Photos.7z.002", "._Photos.7z.001"])
        #expect(try allNames(destination) == ["Photos.zip.001", "Photos.zip.002", ".DS_Store"])
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// What may come in or go while the set is written, compared by exact name: a file dropped in, a
    /// leftover staging folder (a crash), an earlier volume gone. Nothing replaced: the new
    /// volumes go, then the staging folder; nothing else is touched, and no recovered folder is made.
    /// A Finder `.DS_Store` that comes or goes is no change: the set is replaced, and the `.DS_Store`
    /// is never removed.
    @Test(arguments: ["dropped", "leftover", "missing", "dsStoreCame", "dsStoreWent"])
    func aSetFolderThatChangedDuringTheWriteReplacesNothing(_ change: String) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let dsStore = destination.appendingPathComponent(".DS_Store")
        if change == "dsStoreCame" { try FileManager.default.removeItem(at: dsStore) }
        let trashed = Calls()
        let placement = replacingPlacement(trash: movingTrash(into: root.appendingPathComponent("Trash"),
                                                              calls: trashed),
                                           removeFile: { _ in Issue.record("no removal") })
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)
        if change.hasPrefix("dsStore") {
            if change == "dsStoreCame" {
                try Data("finder".utf8).write(to: dsStore)
            } else {
                try FileManager.default.removeItem(at: dsStore)
            }

            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)

            #expect(Set(trashed.all.map(\.lastPathComponent)) == ["Photos.7z.001", "Photos.7z.002", "._Photos.7z.001"])
            #expect(try allNames(destination) == (change == "dsStoreCame"
                ? ["Photos.zip.001", "Photos.zip.002", ".DS_Store"] : ["Photos.zip.001", "Photos.zip.002"]))
            if change == "dsStoreCame" {
                #expect(try Data(contentsOf: dsStore) == Data("finder".utf8))
            }
            try expectParentUntouched(parent, plus: "Photos")
            return
        }
        var expected = Self.earlierSet
        switch change {
        case "dropped":
            try Data("mine".utf8).write(to: destination.appendingPathComponent("notes.txt"))
            expected.insert("notes.txt")
        case "leftover":
            let leftover = ".kernir-replace-\(UUID().uuidString)"
            try FileManager.default.createDirectory(at: destination.appendingPathComponent(leftover),
                                                    withIntermediateDirectories: false)
            expected.insert(leftover)
        default:
            try FileManager.default.removeItem(at: destination.appendingPathComponent("Photos.7z.002"))
            expected.remove("Photos.7z.002")
        }

        let error = #expect(throws: SplitSetChangedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
        }

        #expect(error?.name == "Photos")
        #expect(error?.errorDescription == "“Photos” changed while saving.")
        #expect(error?.recoverySuggestion == "Nothing was replaced.")
        #expect(trashed.all.isEmpty)
        #expect(try allNames(destination) == expected)
        #expect(try Data(contentsOf: destination.appendingPathComponent("Photos.7z.001"))
                    == Data("old Photos.7z.001".utf8))
        if change == "dropped" {
            #expect(try Data(contentsOf: destination.appendingPathComponent("notes.txt")) == Data("mine".utf8))
        }
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// The engine reported no volumes at all: nothing to put in place, so nothing is replaced; the
    /// staging folder goes and the earlier set stays as it was.
    @Test func anEmptyVolumeListReplacesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let trashed = Calls()
        let placement = replacingPlacement(trash: movingTrash(into: root.appendingPathComponent("Trash"),
                                                              calls: trashed),
                                           removeFile: { _ in Issue.record("no removal") })
        let folder = try placement.makeFolder(for: destination, replacing: true)

        let error = #expect(throws: SplitSetChangedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: [])
        }

        #expect(error?.name == "Photos")
        #expect(error?.recoverySuggestion == "Nothing was replaced.")
        #expect(trashed.all.isEmpty)
        #expect(try allNames(destination) == Self.earlierSet)
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// An engine error (it removed its own volumes) or a Cancel after it finished: only what the save
    /// wrote goes, then the staging folder; the earlier set stays as it was.
    @Test(arguments: [false, true])
    func aFailedOrCancelledReplaceLeavesTheEarlierSet(cancelled: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let trashed = Calls()
        let placement = replacingPlacement(trash: movingTrash(into: root.appendingPathComponent("Trash"),
                                                              calls: trashed))
        let folder = try placement.makeFolder(for: destination, replacing: true)

        if cancelled {
            let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)
            try writeVolumes(["._Photos.zip.001"], into: folder.url)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            placement.discard(folder, volumes: [])
        }

        #expect(trashed.all.isEmpty)
        #expect(try allNames(destination) == Self.earlierSet)
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// A removal fails part-way: the rest stays, the new set goes to a visible "Lutik Recovered"
    /// inside the set's folder; when that name is taken, to the first free "Lutik Recovered 2", "3", …;
    /// when the rename fails otherwise, it stays in the hidden staging folder, and Show in Finder selects
    /// the set's folder, which Finder shows.
    @Test(arguments: ["free", "taken", "twoTaken", "renameFails"])
    func aRemovalThatFailsPartWayKeepsTheNewSet(_ recovery: String) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let taken = ["taken": ["Lutik Recovered"], "twoTaken": ["Lutik Recovered", "Lutik Recovered 2"]][recovery] ?? []
        let live = SplitSetPlacement.live.renameFile
        let placement = replacingPlacement(trash: failingTrash(Calls()), removeFile: { url in
            guard url.lastPathComponent == "Photos.7z.002" else { return try SplitSetPlacement.live.removeFile(url) }
            for name in taken {
                try FileManager.default.createDirectory(at: destination.appendingPathComponent(name),
                                                        withIntermediateDirectories: false)
            }
            throw POSIXError(.EACCES)
        }, renameFile: { from, to, flags in
            recovery == "renameFails" && to.contains("Lutik Recovered") ? EACCES : live(from, to, flags)
        })
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)

        let error = #expect(throws: SplitSetPartlyReplacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
        }

        #expect(error?.name == "Photos")
        #expect(error?.errorDescription == "“Photos” was only partly replaced.")
        #expect(error?.recoverySuggestion == """
            The new volumes are in the folder “Lutik Recovered” inside it. Some earlier volumes may have been \
            moved to the Trash or deleted.
            """)
        // Removed in name order, volumes before their "._" files: the first went, the rest stay.
        let kept = Set([".DS_Store", "Photos.7z.002", "._Photos.7z.001"] + taken)
        for name in taken {
            #expect(try allNames(destination.appendingPathComponent(name)).isEmpty)
        }
        if recovery == "renameFails" {
            #expect(error?.recoveredFolder.standardizedFileURL.path == destination.path)
            #expect(try allNames(destination) == kept.union([folder.url.lastPathComponent]))
            #expect(try allNames(folder.url) == ["Photos.zip.001", "Photos.zip.002"])
        } else {
            let name = ["taken": "Lutik Recovered 2", "twoTaken": "Lutik Recovered 3"][recovery] ?? "Lutik Recovered"
            let recovered = destination.appendingPathComponent(name, isDirectory: true)
            #expect(error?.recoveredFolder.standardizedFileURL.path == recovered.path)
            #expect(try allNames(destination) == kept.union([name]))
            #expect(try allNames(recovered) == ["Photos.zip.001", "Photos.zip.002"])
        }
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// The partly-replaced alert offers Show in Finder (a stock recoverable error, which NSDocument's alert shows as
    /// buttons); OK only closes it.
    @Test func aPartlyReplacedErrorOffersShowInFinder() {
        let error = SplitSetPartlyReplacedError(name: "Photos",
                                                recoveredFolder: URL(fileURLWithPath: "/tmp/Photos/Lutik Recovered"))
        #expect(error.recoveryOptions == ["OK", "Show in Finder"])
        let bridged = error as NSError
        #expect(bridged.localizedRecoveryOptions == ["OK", "Show in Finder"])
        #expect(bridged.recoveryAttempter != nil)
        #expect(bridged.localizedDescription == "“Photos” was only partly replaced.")
        #expect(!error.attemptRecovery(optionIndex: 0))
    }

    /// Something takes a new volume's name after the earlier set went: the exclusive move never
    /// replaces it, also where the share has no exclusive rename (smbfs: ENOTSUP, then a check).
    @Test(arguments: [true, false])
    func aNameTakenWhilePlacingIsNeverReplaced(exclusiveRename: Bool) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let live = SplitSetPlacement.live.renameFile
        let trash = movingTrash(into: root.appendingPathComponent("Trash"), calls: Calls())
        let placement = replacingPlacement(trash: { url in
            try trash(url)
            if url.lastPathComponent == "._Photos.7z.001" {
                try Data("mine".utf8).write(to: destination.appendingPathComponent("Photos.zip.002"))
            }
        }, renameFile: { from, to, flags in
            exclusiveRename || flags & UInt32(RENAME_EXCL) == 0 ? live(from, to, flags) : ENOTSUP
        })
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)

        let error = #expect(throws: SplitSetPartlyReplacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
        }

        let recovered = destination.appendingPathComponent("Lutik Recovered", isDirectory: true)
        #expect(error?.recoveredFolder.standardizedFileURL.path == recovered.path)
        #expect(try allNames(destination) == [".DS_Store", "Photos.zip.001", "Photos.zip.002", "Lutik Recovered"])
        #expect(try Data(contentsOf: destination.appendingPathComponent("Photos.zip.002")) == Data("mine".utf8))
        #expect(try allNames(recovered) == ["Photos.zip.002"])
        #expect(try Data(contentsOf: recovered.appendingPathComponent("Photos.zip.002"))
                    == Data("new Photos.zip.002".utf8))
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// A lone Finder `.DS_Store` left in the staging folder goes with it, so no hidden folder
    /// stays to refuse the next Replace. Anything else there (`notes.txt`): the plain rmdir fails, the
    /// staging folder stays with what is in it, and the save still succeeds.
    @Test(arguments: [".DS_Store", "notes.txt"])
    func aStagingFolderThatIsNotEmptyAfterThePlaceIsLeftOnlyForAForeignItem(_ stray: String) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let placement = replacingPlacement(trash: movingTrash(into: root.appendingPathComponent("Trash"),
                                                              calls: Calls()))
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)
        try Data("finder".utf8).write(to: folder.url.appendingPathComponent(stray))

        try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)

        if stray == ".DS_Store" {
            #expect(try allNames(destination) == ["Photos.zip.001", "Photos.zip.002", ".DS_Store"])
        } else {
            #expect(try allNames(destination)
                        == ["Photos.zip.001", "Photos.zip.002", ".DS_Store", folder.url.lastPathComponent])
            #expect(try allNames(folder.url) == ["notes.txt"])
        }
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// The very first removal fails (a locked file, EACCES) so nothing earlier was removed: the new volumes and the
    /// staging folder go, no "Lutik Recovered" is made, and the original permission error (the refused item-replacement
    /// directory's) is thrown.
    @Test func aFirstRemovalThatFailsLeavesNoRecoveredFolder() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let removed = Calls()
        let placement = replacingPlacement(trash: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: 3328,
                          userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -120)])
        }, removeFile: { url in
            removed.record(url)
            throw POSIXError(.EACCES)
        })
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)

        let error = #expect(throws: CocoaError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
        }

        #expect(error?.code == .fileWriteNoPermission)
        #expect(removed.all.map(\.lastPathComponent) == ["Photos.7z.001"])
        #expect(try allNames(destination) == Self.earlierSet)
        #expect(try Data(contentsOf: destination.appendingPathComponent("Photos.7z.001"))
                    == Data("old Photos.7z.001".utf8))
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// An earlier volume rewritten under its own name while the set was written (a sync client, another
    /// save): same name and type, another file. Nothing replaced, and
    /// the rewritten file stays.
    @Test func anEarlierVolumeRewrittenDuringTheWriteReplacesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let trashed = Calls()
        let placement = replacingPlacement(trash: movingTrash(into: root.appendingPathComponent("Trash"),
                                                              calls: trashed),
                                           removeFile: { _ in Issue.record("no removal") })
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)
        let rewritten = destination.appendingPathComponent("Photos.7z.002")
        try FileManager.default.removeItem(at: rewritten)
        try Data("synced".utf8).write(to: rewritten)

        #expect(throws: SplitSetChangedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
        }

        #expect(trashed.all.isEmpty)
        #expect(try allNames(destination) == Self.earlierSet)
        #expect(try Data(contentsOf: rewritten) == Data("synced".utf8))
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// The set's folder itself was swapped for another one holding the very same entries, the staging
    /// folder too, moved over. Nothing
    /// replaced: no earlier volume is removed from either folder.
    @Test func aSetFolderSwappedForAnotherReplacesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let trashed = Calls()
        let placement = replacingPlacement(trash: movingTrash(into: root.appendingPathComponent("Trash"),
                                                              calls: trashed),
                                           removeFile: { _ in Issue.record("no removal") })
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)
        let moved = root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: destination, to: moved)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for name in try allNames(moved) {
            try FileManager.default.moveItem(at: moved.appendingPathComponent(name),
                                             to: destination.appendingPathComponent(name))
        }

        #expect(throws: SplitSetChangedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
        }

        #expect(trashed.all.isEmpty)
        #expect(try allNames(destination) == Self.earlierSet)
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// An earlier volume rewritten under its name after another was removed (rechecked right before each
    /// removal): it is never removed, and the replace stops partly done; the new volumes are in
    /// "Lutik Recovered".
    @Test func anEarlierVolumeRewrittenDuringTheRemovalsIsNeverRemoved() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let trashed = Calls()
        let trash = movingTrash(into: root.appendingPathComponent("Trash"), calls: trashed)
        let rewritten = destination.appendingPathComponent("Photos.7z.002")
        let placement = replacingPlacement(trash: { url in
            try trash(url)
            if url.lastPathComponent == "Photos.7z.001" {
                try FileManager.default.removeItem(at: rewritten)
                try Data("synced".utf8).write(to: rewritten)
            }
        }, removeFile: { _ in Issue.record("no removal") })
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)

        let error = #expect(throws: SplitSetPartlyReplacedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
        }

        let recovered = destination.appendingPathComponent("Lutik Recovered", isDirectory: true)
        #expect(error?.recoveredFolder.standardizedFileURL.path == recovered.path)
        #expect(trashed.all.map(\.lastPathComponent) == ["Photos.7z.001"])
        #expect(try Data(contentsOf: rewritten) == Data("synced".utf8))
        #expect(try allNames(destination) == [".DS_Store", "Photos.7z.002", "._Photos.7z.001", "Lutik Recovered"])
        #expect(try allNames(recovered) == ["Photos.zip.001", "Photos.zip.002"])
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// FAT, exFAT or a share without streams keeps the staging folder's extended attributes in an
    /// AppleDouble "._.kernir-replace-<uuid>" beside it: no change to the set's folder, never
    /// removed as part of the earlier set, and it goes once the staging folder is gone, after a replace
    /// and after a replace that changed nothing alike.
    @Test(arguments: [false, true])
    func theStagingFoldersAppleDoubleFileIsNoChange(dropped: Bool) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let trashed = Calls()
        let placement = replacingPlacement(trash: movingTrash(into: root.appendingPathComponent("Trash"),
                                                              calls: trashed))
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)
        try Data("xattrs".utf8).write(to: destination.appendingPathComponent("._" + folder.url.lastPathComponent))
        if dropped { try Data("mine".utf8).write(to: destination.appendingPathComponent("notes.txt")) }

        if dropped {
            #expect(throws: SplitSetChangedError.self) {
                try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
            }
            #expect(trashed.all.isEmpty)
            #expect(try allNames(destination) == Self.earlierSet.union(["notes.txt"]))
        } else {
            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
            #expect(Set(trashed.all.map(\.lastPathComponent)) == ["Photos.7z.001", "Photos.7z.002", "._Photos.7z.001"])
            #expect(try allNames(destination) == ["Photos.zip.001", "Photos.zip.002", ".DS_Store"])
        }
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// An earlier volume someone else removes after the check before the removals, right before its own
    /// removal: it is not counted as removed by us. The first one: nothing was removed, the
    /// rest of the earlier set stays and the new volumes go. A later one: the replace stops
    /// partly done, the new volumes in "Lutik Recovered". A "._" file gone with its volume (FAT,
    /// exFAT, a share without streams drop it along) is no change: the set is replaced.
    @Test(arguments: ["Photos.7z.001", "Photos.7z.002", "._Photos.7z.001"])
    func anEarlierEntryGoneRightBeforeItsRemovalIsNotRemovedByUs(_ gone: String) throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let trashed = Calls()
        var placement = replacingPlacement(trash: movingTrash(into: root.appendingPathComponent("Trash"),
                                                              calls: trashed),
                                           removeFile: { _ in Issue.record("no removal") })
        placement.beforeRemoval = { url in
            if url.lastPathComponent == gone { try? FileManager.default.removeItem(at: url) }
        }
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)

        switch gone {
        case "Photos.7z.001":
            let error = #expect(throws: SplitSetChangedError.self) {
                try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
            }
            #expect(error?.recoverySuggestion == "Nothing was replaced.")
            #expect(trashed.all.isEmpty)
            #expect(try allNames(destination) == [".DS_Store", "Photos.7z.002", "._Photos.7z.001"])
        case "Photos.7z.002":
            let error = #expect(throws: SplitSetPartlyReplacedError.self) {
                try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
            }
            let recovered = destination.appendingPathComponent("Lutik Recovered", isDirectory: true)
            #expect(error?.recoveredFolder.standardizedFileURL.path == recovered.path)
            #expect(trashed.all.map(\.lastPathComponent) == ["Photos.7z.001"])
            #expect(try allNames(destination) == [".DS_Store", "._Photos.7z.001", "Lutik Recovered"])
            #expect(try allNames(recovered) == ["Photos.zip.001", "Photos.zip.002"])
        default:
            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
            #expect(trashed.all.map(\.lastPathComponent) == ["Photos.7z.001", "Photos.7z.002"])
            #expect(try allNames(destination) == ["Photos.zip.001", "Photos.zip.002", ".DS_Store"])
        }
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// The first earlier volume rewritten under its name after the check before the removals, right
    /// before its removal: nothing was removed yet, so
    /// nothing is replaced: the rewritten file and the rest stay, the new volumes go, and no
    /// recovered folder is made.
    @Test func anEarlierVolumeRewrittenRightBeforeTheFirstRemovalReplacesNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let destination = try makeEarlierSet(in: parent)
        let trashed = Calls()
        var placement = replacingPlacement(trash: movingTrash(into: root.appendingPathComponent("Trash"),
                                                              calls: trashed),
                                           removeFile: { _ in Issue.record("no removal") })
        let rewritten = destination.appendingPathComponent("Photos.7z.001")
        placement.beforeRemoval = { url in
            guard url.lastPathComponent == "Photos.7z.001" else { return }
            try? FileManager.default.removeItem(at: url)
            try? Data("synced".utf8).write(to: url)
        }
        let folder = try placement.makeFolder(for: destination, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)

        let error = #expect(throws: SplitSetChangedError.self) {
            try placement.place(folder, at: destination, sources: [], replacing: true, volumes: volumes)
        }

        #expect(error?.errorDescription == "“Photos” changed while saving.")
        #expect(trashed.all.isEmpty)
        #expect(try allNames(destination) == Self.earlierSet)
        #expect(try Data(contentsOf: rewritten) == Data("synced".utf8))
        #expect(try Data(contentsOf: destination.appendingPathComponent("Photos.7z.002"))
                    == Data("old Photos.7z.002".utf8))
        try expectParentUntouched(parent, plus: "Photos")
    }

    /// Replace onto a case variant of the set's folder on a volume that ignores case ("photos" holding
    /// Photos.7z.001…, saved as "Photos"): the folder keeps its name, only the volumes are swapped (plan
    /// decision: no folder rename, as Finder's Replace keeps the folder).
    @Test(.enabled(if: isCaseInsensitive(FileManager.default.temporaryDirectory),
                   "needs a volume that ignores case"))
    func aCaseVariantSetFolderKeepsItsNameOnReplaceInPlace() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeParent(in: root)
        let existing = parent.appendingPathComponent("photos", isDirectory: true)
        try makeFolder(existing, holding: ["Photos.7z.001", "Photos.7z.002"])
        let trashed = Calls()
        let placement = replacingPlacement(trash: movingTrash(into: root.appendingPathComponent("Trash"),
                                                              calls: trashed))
        let url = parent.appendingPathComponent("Photos", isDirectory: true)
        let folder = try placement.makeFolder(for: url, replacing: true)
        let volumes = try writeVolumes(["Photos.zip.001", "Photos.zip.002"], into: folder.url)

        try placement.place(folder, at: url, sources: [], replacing: true, volumes: volumes)

        #expect(Set(trashed.all.map(\.lastPathComponent)) == ["Photos.7z.001", "Photos.7z.002"])
        try expectParentUntouched(parent, plus: "photos")
        #expect(try allNames(existing) == ["Photos.zip.001", "Photos.zip.002"])
    }
}
