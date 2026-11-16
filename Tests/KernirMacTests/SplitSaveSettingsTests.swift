import Testing
import Foundation
import KernirCore
@testable import Kernir

/// Split saves: the folder name the panel proposes, which folders must never be
/// replaced by a split set because they hold the archive being saved, and which existing folder a
/// set may replace (steps 2 and 9).
struct SplitSaveSettingsTests {
    // MARK: - Folder name

    /// One recognized suffix goes, a compound one ("tar.gz") counting as one:
    /// "strip ONE recognized suffix, as done in practice" (`ArchiveBaseName`).
    /// So "s2-plain.tar.tgz" keeps its "tar".
    @Test func folderProposalDropsOneArchiveSuffix() {
        #expect(ArchiveSaveSettings.splitFolderProposal("Photos.zip") == "Photos")
        #expect(ArchiveSaveSettings.splitFolderProposal("Photos.tar.gz") == "Photos")
        #expect(ArchiveSaveSettings.splitFolderProposal("s2-plain.tar.tgz") == "s2-plain.tar")
        #expect(ArchiveSaveSettings.splitFolderProposal("Photos") == "Photos")
        #expect(ArchiveSaveSettings.splitFolderProposal("notes.txt") == "notes.txt")
    }

    @Test func folderProposalForAVolumeSetIsTheSetsName() {
        #expect(ArchiveSaveSettings.splitFolderProposal("s7.7z.001", isVolumeSet: true) == "s7")
        #expect(ArchiveSaveSettings.splitFolderProposal("Photos.part1.rar", isVolumeSet: true) == "Photos")
        #expect(ArchiveSaveSettings.splitFolderProposal("span.z01", isVolumeSet: true) == "span")
    }

    /// A set whose stem is "", "." or "..": "...part1.rar", "...7z.001" and "...zip.001" leave "..",
    /// "..part1.rar", "..001" and "..z01" leave ".". Dot-only stems fall back to the file name, so no
    /// proposed set folder, volume or Save As name is a dot name or puts one in a path. The volumes
    /// are "<folder>.<ext>.001", as `VolumeWriter` names them. The second split proposal starts from
    /// the name field, which then holds the Save As proposal (`SavePanelOptions.updatePanel`).
    @Test(arguments: ["...part1.rar", "...7z.001", "...zip.001", "..part1.rar", "..001", "..z01"])
    func dotOnlyStemsFallBackToTheFileName(_ name: String) {
        #expect(ArchiveSaveSettings.volumeSetBaseName(name) == name)
        let folder = ArchiveSaveSettings.splitFolderProposal(name, isVolumeSet: true)
        #expect(folder == name)
        var paths = [folder]
        for format in [ArchiveFormat.sevenZip, .zip] {
            paths.append("\(folder)/\(folder).\(format.fileExtension).001")
            let saveAs = ArchiveSaveSettings.savePanelProposal(name, for: format, isVolumeSet: true)
            paths.append(saveAs)
            paths.append(ArchiveSaveSettings.fileName(name, for: format, isVolumeSet: true))
            paths.append(ArchiveSaveSettings.splitFolderProposal(saveAs))
        }
        for path in paths {
            #expect(!["", ".", ".."].contains(path), "\(name) → \(path)")
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            #expect(!components.contains { ["", ".", ".."].contains($0) }, "\(name) → \(path)")
        }
    }

    /// The fallback is only for dot-only stems: a set name with dots in it keeps them.
    @Test(arguments: [
        ("v1.2 notes.7z.003", "v1.2 notes"),
        (".hidden.part1.rar", ".hidden"),
        ("....part1.rar", "..."),
        ("a..zip.001", "a."),
    ])
    func setNamesKeepTheirDots(_ name: String, _ expected: String) {
        #expect(ArchiveSaveSettings.volumeSetBaseName(name) == expected)
        #expect(ArchiveSaveSettings.splitFolderProposal(name, isVolumeSet: true) == expected)
    }

    /// A single archive's folder proposal drops one archive suffix, "tar.gz" as one, so
    /// "..zip", "..tgz", "...zip" and "...tar.gz" leave a dot-only stem and fall back to the file name.
    @Test(arguments: [
        ("..zip", "..zip"),
        ("..tgz", "..tgz"),
        ("...zip", "...zip"),
        ("...tar.gz", "...tar.gz"),
        ("....zip", "..."),
        ("Photos.zip", "Photos"),
    ])
    func folderProposalOfADotOnlyStemIsTheFileName(_ name: String, _ expected: String) {
        #expect(ArchiveSaveSettings.splitFolderProposal(name) == expected)
    }

    /// The fallback is the part's own name, so in the part's folder it is taken: the panel numbers it.
    @Test func theFallbackFolderNameIsNumberedPastThePart() {
        let directory = URL(fileURLWithPath: "/tmp/Downloads", isDirectory: true)
        let folder = ArchiveSaveSettings.splitFolderProposal("...7z.001", isVolumeSet: true)
        let name = ArchiveSaveSettings.freeSplitFolderName(folder, in: directory) {
            $0.lastPathComponent == "...7z.001"
        }
        #expect(name == "...7z.001 2")
    }

    // MARK: - Destination safety

    /// A fresh folder holding `a.zip` and the parts `set.7z.001`, `set.7z.002`; the caller removes it.
    private func makeSources() throws -> (root: URL, document: URL, parts: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitSaveSettingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = folder.appendingPathComponent("a.zip")
        try Data("zip".utf8).write(to: document)
        let parts = try ["set.7z.001", "set.7z.002"].map { name in
            let sub = folder.appendingPathComponent(name == "set.7z.001" ? "." : "parts", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let part = sub.appendingPathComponent(name)
            try Data(name.utf8).write(to: part)
            return part.standardizedFileURL
        }
        return (root, document, parts)
    }

    @Test func aFolderHoldingTheDocumentIsUnsafe() throws {
        let (root, document, _) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(folder, sources: [document]))
        // Any folder above it too: replacing it deletes the document with it.
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(root, sources: [document]))
    }

    @Test func theDocumentItselfIsUnsafe() throws {
        let (root, document, _) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(document, sources: [document]))
    }

    @Test func aFolderHoldingAnotherPartOfTheSetIsUnsafe() throws {
        let (root, document, parts) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        let partsFolder = root.appendingPathComponent("Photos/parts", isDirectory: true)
        // The document is part 1; part 2 lives in "parts".
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(partsFolder, sources: [parts[0]] + parts))
        #expect(!ArchiveSaveSettings.isUnsafeSplitDestination(partsFolder, sources: [document]))
    }

    @Test func theDocumentsFolderSeenThroughASymlinkIsUnsafe() throws {
        let (root, document, _) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: root.appendingPathComponent("Photos"))
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(link, sources: [document]))
        // And the document reached through the link, saved to its real folder.
        let viaLink = link.appendingPathComponent("a.zip")
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(root.appendingPathComponent("Photos"),
                                                              sources: [viaLink]))
    }

    @Test func theFolderOfADocumentOpenedThroughAFileSymlinkIsUnsafe() throws {
        let (root, document, _) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let alias = elsewhere.appendingPathComponent("alias.zip")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: document)
        // Replacing Photos deletes the file the link points to; replacing Elsewhere only the link.
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(root.appendingPathComponent("Photos"),
                                                              sources: [alias]))
    }

    @Test func aFolderSpelledInAnotherCaseIsUnsafeWhereTheVolumeIgnoresCase() throws {
        let (root, document, _) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        let upper = root.appendingPathComponent("PHOTOS", isDirectory: true)
        let caseSensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? false
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(upper, sources: [document]) == !caseSensitive)
    }

    @Test func aSiblingFolderIsSafe() throws {
        let (root, document, parts) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        let sibling = root.appendingPathComponent("Photos Split", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        #expect(!ArchiveSaveSettings.isUnsafeSplitDestination(sibling, sources: [document] + parts))
        // A name that only starts like the document's folder is no parent of it.
        let prefix = root.appendingPathComponent("Photo", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        #expect(!ArchiveSaveSettings.isUnsafeSplitDestination(prefix, sources: [document] + parts))
    }

    @Test func aFolderThatDoesNotExistYetIsSafe() throws {
        let (root, document, parts) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        let new = root.appendingPathComponent("Photos/New", isDirectory: true)
        #expect(!ArchiveSaveSettings.isUnsafeSplitDestination(new, sources: [document] + parts))
        let nowhere = root.appendingPathComponent("Missing/Deeper", isDirectory: true)
        #expect(!ArchiveSaveSettings.isUnsafeSplitDestination(nowhere, sources: [document]))
    }

    // MARK: - Pending additions

    /// A new archive that adds ~/Desktop/Photos, split-saved to ~/Desktop/Photos with Replace,
    /// would replace the originals with an archive of them that lost their xattrs and tags. Callers
    /// pass every pending addition's URL with the archive's parts, as `model.changes.additions` has them.
    @MainActor @Test func aFolderBeingAddedIsUnsafe() throws {
        let (root, _, _) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let notes = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: notes)
        let model = ArchiveModel(newArchiveFormat: .zip, undoManager: nil)
        model.add([photos, notes], to: "")
        let sources = model.changes.additions.map(\.sourceURL)
        #expect(sources.count == 2)

        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(photos, sources: sources))
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(root, sources: sources))
        // A folder inside an added folder is part of what is being added, too (here it holds
        // part 2 of the set made by makeSources); so is a file being added.
        let parts = photos.appendingPathComponent("parts", isDirectory: true)
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(parts, sources: sources))
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(notes, sources: sources))
        let sibling = root.appendingPathComponent("Photos Split", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        #expect(!ArchiveSaveSettings.isUnsafeSplitDestination(sibling, sources: sources))
    }

    // MARK: - A source that no longer exists

    @Test func aFolderThatHeldAMissingSourceIsStillUnsafe() throws {
        let (root, _, _) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let gone = photos.appendingPathComponent("gone.zip")
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(photos, sources: [gone]))
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(root, sources: [gone]))
        // Gone with the folders between it and Photos.
        let deep = photos.appendingPathComponent("Old/Deeper/gone.zip")
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(photos, sources: [deep]))
        // A missing source in a folder that only starts like Photos is no reason to refuse.
        let elsewhere = root.appendingPathComponent("Photos Old/gone.zip")
        #expect(!ArchiveSaveSettings.isUnsafeSplitDestination(photos, sources: [elsewhere]))
    }

    @Test func aMissingSourceSpelledInAnotherCaseIsUnsafeWhereTheVolumeIgnoresCase() throws {
        let (root, _, _) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let caseSensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? false
        let gone = root.appendingPathComponent("PHOTOS/Old/gone.zip")
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(photos, sources: [gone]) == !caseSensitive)
    }

    @Test func aMissingSourceReachedThroughASymlinkIsUnsafe() throws {
        let (root, _, _) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: photos)
        // "Old" is gone too, so the path can't be resolved past the link; only identity finds Photos.
        let gone = link.appendingPathComponent("Old/gone.zip")
        #expect(ArchiveSaveSettings.isUnsafeSplitDestination(photos, sources: [gone]))
    }

    @Test func noSourcesIsSafe() throws {
        let (root, _, _) = try makeSources()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!ArchiveSaveSettings.isUnsafeSplitDestination(root, sources: []))
    }

    // MARK: - Which folder a set may replace

    /// A fresh temp folder `name` holding `files` (regular files); the caller removes `root`.
    private func makeFolder(_ name: String = "Photos", holding files: [String] = [])
        throws -> (root: URL, folder: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitSaveSettingsTests-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data(file.utf8).write(to: folder.appendingPathComponent(file, isDirectory: false))
        }
        return (root, folder)
    }

    @Test func anEarlierSetIsReplaceable() throws {
        let (root, folder) = try makeFolder(holding: ["Photos.7z.001", "Photos.7z.002", "Photos.7z.003"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
        // Finder leaves a .DS_Store in a folder it shows: the one extra allowed.
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    @Test func anEmptyFolderIsReplaceable() throws {
        let (root, folder) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    /// The listing must not skip hidden files: they are exactly what must refuse. That includes
    /// an iCloud placeholder of an evicted part (open, plan) and an AppleDouble file of any name
    /// but a part's.
    @Test(arguments: [".notes", ".Photos.7z.002.icloud", "._notes", "._Other.7z.001", "._", "._.DS_Store",
                      "._._Photos.7z.001"])
    func aHiddenFileAmongThePartsIsNotASet(_ hidden: String) throws {
        let (root, folder) = try makeFolder(holding: ["Photos.7z.001", hidden])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    /// FAT and exFAT keep a file's extended attributes in an AppleDouble file "._<name>" beside
    /// it, so a set written there has one per part: a regular "._" file of a part's name counts.
    @Test(arguments: ["._Photos.7z.001", "._Photos.7z.002", "._photos.ZIP.003", "._Photos.7z"])
    func anAppleDoubleFileOfAPartCounts(_ companion: String) throws {
        let (root, folder) = try makeFolder(holding: ["Photos.7z.001", "Photos.7z.002", companion])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    @Test func aSubfolderAmongThePartsIsNotASet() throws {
        let (root, folder) = try makeFolder(holding: ["Photos.7z.001"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub", isDirectory: true),
                                                withIntermediateDirectories: false)
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    /// Only regular files: a folder named like a part, or like .DS_Store, is no part.
    @Test(arguments: ["Photos.7z.002", ".DS_Store", "._Photos.7z.001"])
    func aFolderNamedLikeAPartIsNotASet(_ name: String) throws {
        let (root, folder) = try makeFolder(holding: ["Photos.7z.001"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(name, isDirectory: true),
                                                withIntermediateDirectories: false)
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    @Test func aSymlinkAmongThePartsIsNotASet() throws {
        let (root, folder) = try makeFolder(holding: ["Photos.7z.001"])
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere.bin")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Photos.7z.002"),
                                                   withDestinationURL: target)
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    /// The writer renames a set of one volume to the plain archive name.
    @Test(arguments: ["Photos.7z", "Photos.zip"])
    func aOneVolumeSetIsReplaceable(_ name: String) throws {
        let (root, folder) = try makeFolder(holding: [name])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    /// Three digits after `.7z` or `.zip`, the shape KernirCore's writer names volumes, and the
    /// folder's own name: anything else is someone's other files.
    @Test(arguments: ["Photos.7z.01", "Photos.7z.0001", "Photos.7z0001", "Photos.7z.00a", "Photos.7z.١٢٣", "Photos.tar.001",
                      "Photos.001", "Other.7z.001", "Photos 2.7z.001", "Photos.7z.001.txt", "Photos.tar",
                      "Photos", ".7z.001"])
    func otherNamesAreNotASet(_ name: String) throws {
        let (root, folder) = try makeFolder(holding: [name])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    /// The name is matched by its suffix, so a base with dots of its own works.
    @Test func aBaseWithDotsOfItsOwnCounts() throws {
        let (root, folder) = try makeFolder("v1.2 notes", holding: ["v1.2 notes.zip.001", "v1.2 notes.zip.002"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
        let (oneRoot, one) = try makeFolder("v1.2 notes", holding: ["v1.2 notes.7z"])
        defer { try? FileManager.default.removeItem(at: oneRoot) }
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(one))
    }

    /// The probe's `existing-set` held .001 and a stale .004: a set with gaps, and a stale part
    /// of the other format, is still a set. The replace removes them all.
    @Test func gapsAndStalePartsStillCount() throws {
        let (root, folder) = try makeFolder(holding: ["Photos.7z.001", "Photos.7z.002", "Photos.7z.004",
                                                      "Photos.zip.003"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    @Test func theBaseNameIgnoresCase() throws {
        let (root, folder) = try makeFolder(holding: ["photos.7z.001", "PHOTOS.7Z.002"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    /// `caseInsensitiveCompare` is NSString's non-literal compare, which treats NFC and NFD as
    /// equal: a part spelled in NFD counts in a folder named in NFC.
    @Test func theBaseNameIgnoresTheUnicodeForm() throws {
        // Checked on the names directly too: the file system may hand back either form.
        #expect(ArchiveSaveSettings.isSplitVolumeName("Cafe\u{301}.7z.001", baseName: "Caf\u{E9}"))
        let (root, folder) = try makeFolder("Caf\u{E9}", holding: ["Cafe\u{301}.7z.001"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    @Test func aFileAtTheURLIsNotReplaceable() throws {
        let (root, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Photos.7z.001")
        try Data("x".utf8).write(to: file)
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(file))
    }

    /// Even a link to a set folder: replacing it would delete the link, and `lstat` is never
    /// led to follow it by the trailing slash an existing folder's panel URL has.
    @Test func aSymlinkAtTheURLIsNotReplaceable() throws {
        let (root, folder) = try makeFolder(holding: ["Photos.7z.001"])
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("Photos Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(link.hasDirectoryPath)
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(link))
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(URL(fileURLWithPath: link.path, isDirectory: false)))
    }

    /// A link with the set's own name, to a real set folder elsewhere: the folder is opened with
    /// `O_NOFOLLOW`, so the link is refused, not the folder behind it listed.
    @Test func aSymlinkWithTheSetsNameAtTheURLIsNotReplaceable() throws {
        let (root, folder) = try makeFolder(holding: ["Photos.7z.001", "Photos.7z.002"])
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let link = other.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(link))
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(URL(fileURLWithPath: link.path, isDirectory: false)))
    }

    /// q2: an existing folder comes back from the panel with a trailing slash; a new name without.
    @Test func aTrailingSlashURLOfASetFolderIsReplaceable() throws {
        let (root, folder) = try makeFolder(holding: ["Photos.7z.001"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(folder.hasDirectoryPath)
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(URL(fileURLWithPath: folder.path, isDirectory: false)))
    }

    @Test func nothingAtTheURLIsNoSetFolder() throws {
        let (root, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(root.appendingPathComponent("New", isDirectory: true)))
    }

    /// A listing error means not replaceable.
    @Test func aFolderThatCannotBeListedIsNotReplaceable() throws {
        let (root, folder) = try makeFolder(holding: ["Photos.7z.001"])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        #expect(!ArchiveSaveSettings.isReplaceableSetFolder(folder))
    }

    /// Drift guard: what KernirCore's writer really writes (`VolumePlan.name`, internal there) is a
    /// set by the app's rule, for a set of three volumes and for the one-volume rename alike.
    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func whatTheWriterWritesIsASet(_ format: ArchiveFormat) async throws {
        let (root, folder) = try makeFolder("v1.2 Photos")
        defer { try? FileManager.default.removeItem(at: root) }
        let noise = root.appendingPathComponent("noise.bin")
        try Data((0..<2_500_000).map { _ in UInt8.random(in: 0...255) }).write(to: noise)
        let urls = try await ArchiveWriter.writeVolumes(
            source: nil, changes: ArchiveChangeSet(additions: [.init(sourceURL: noise, destinationDirectory: "")]),
            format: format, into: folder, baseName: folder.lastPathComponent,
            options: ArchiveWriteOptions(volumeSize: 1_000_000))
        #expect(urls.count == 3)
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(folder))

        let (oneRoot, one) = try makeFolder("Notes")
        defer { try? FileManager.default.removeItem(at: oneRoot) }
        let small = oneRoot.appendingPathComponent("small.txt")
        try Data("small".utf8).write(to: small)
        let single = try await ArchiveWriter.writeVolumes(
            source: nil, changes: ArchiveChangeSet(additions: [.init(sourceURL: small, destinationDirectory: "")]),
            format: format, into: one, baseName: one.lastPathComponent,
            options: ArchiveWriteOptions(volumeSize: 1_000_000))
        #expect(single.map(\.lastPathComponent) == ["Notes." + format.fileExtension])
        #expect(ArchiveSaveSettings.isReplaceableSetFolder(one))
    }

    // MARK: - The proposed folder name

    @Test func aFreeNameIsProposedAsIs() throws {
        let (root, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveSaveSettings.freeSplitFolderName("Holiday", in: root) == "Holiday")
    }

    /// Like Finder: "Photos" → "Photos 2" → "Photos 3". A file takes a name as much as a folder does.
    @Test func aTakenNameGetsTheNextNumber() throws {
        let (root, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveSaveSettings.freeSplitFolderName("Photos", in: root) == "Photos 2")
        try Data("x".utf8).write(to: root.appendingPathComponent("Photos 2"))
        #expect(ArchiveSaveSettings.freeSplitFolderName("Photos", in: root) == "Photos 3")
    }

    /// `stat` would call a link to nothing free, and the panel would then ask to replace the link.
    @Test func aDanglingSymlinkTakesTheName() throws {
        let (root, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("Holiday")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("gone"))
        #expect(ArchiveSaveSettings.isNameTaken(link))
        #expect(ArchiveSaveSettings.freeSplitFolderName("Holiday", in: root) == "Holiday 2")
    }

    /// Only ENOENT means free. In a folder the user can't search `lstat` fails with EACCES, which
    /// may hide an item, so the name counts as taken (EPERM, without a grant, likewise).
    @Test func aNameLstatCannotAnswerForIsTaken() throws {
        let (root, folder) = try makeFolder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: root)
        }
        let name = folder.appendingPathComponent("Holiday")
        #expect(!ArchiveSaveSettings.isNameTaken(name))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        #expect(ArchiveSaveSettings.isNameTaken(name))
        // Every name is taken there, so the numbering runs out and falls back to the name.
        #expect(ArchiveSaveSettings.freeSplitFolderName("Holiday", in: folder) == "Holiday")
    }

    @Test func aNameTakenForAnyReasonGetsANumber() {
        let directory = URL(fileURLWithPath: "/nowhere", isDirectory: true)
        let name = ArchiveSaveSettings.freeSplitFolderName("Photos", in: directory) { url in
            url.lastPathComponent == "Photos"
        }
        #expect(name == "Photos 2")
    }

    /// No folder known (the panel's `directoryURL` is nil): the name as is, unchecked, even when
    /// it would be taken in some folder; nothing is asked about any folder.
    @Test func noFolderProposesTheNameUnchecked() {
        var checked: [URL] = []
        let name = ArchiveSaveSettings.freeSplitFolderName("Photos", in: nil) { url in
            checked.append(url)
            return url.lastPathComponent == "Photos"
        }
        #expect(name == "Photos")
        #expect(checked.isEmpty)
    }

    /// "Photos 2" … "Photos 999", then the base name: the late guard in `validate` takes over.
    @Test func theNumberingStopsAt999() throws {
        let (root, _) = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        for number in 2...998 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos \(number)"),
                                                    withIntermediateDirectories: false)
        }
        #expect(ArchiveSaveSettings.freeSplitFolderName("Photos", in: root) == "Photos 999")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Photos 999"),
                                                withIntermediateDirectories: false)
        #expect(ArchiveSaveSettings.freeSplitFolderName("Photos", in: root) == "Photos")
        // Never past the cap.
        var checked: [String] = []
        _ = ArchiveSaveSettings.freeSplitFolderName("Photos", in: root) { url in
            checked.append(url.lastPathComponent)
            return true
        }
        #expect(checked.count == 999)
        #expect(checked.last == "Photos 999")
    }
}
