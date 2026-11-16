import Testing
import AppKit
@testable import Kernir
import KernirCore
import os

// A save with Split on writes a set of volumes into the folder the panel names
// (`ArchiveDocument.saveSplit`). These extend `ArchiveDocumentTests`, so they run serialized with it:
// both swap the process-wide `ArchiveDocument.engine`. Hosted (an `ArchiveDocument`), never with the
// real Trash: `ArchiveDocument.splitSetPlacement` gets a fake one.

/// `open` gives a `FakeReader` (one ZIP, or the first part of a two-part 7z set); `write` and
/// `writeVolumes` record their calls and answer from `volumes`.
private final class SplitFakeEngine: Sendable {
    enum Volumes: Sendable {
        /// Writes `<base>.<ext>.001` and `.002` into the folder.
        case succeed
        case fail(ArchiveError)
        /// Too many volumes, found while writing.
        case limit
        /// Runs until its task is cancelled, then throws `.cancelled`, like the real writer.
        case runUntilCancelled
        /// Writes like `.succeed`, then runs `body` (the destination changing meanwhile).
        case succeedThen(@Sendable () throws -> Void)
        /// Like the real writer when it fails: runs `before` with the folder (a file dropped in), creates
        /// each part exclusively (EEXIST on a name taken), then fails with `error` if it got that far, and
        /// on any failure removes the parts it made, and only those.
        case failRemovingOwnParts(ArchiveError, before: @Sendable (URL) throws -> Void)
    }

    struct VolumesCall: Sendable {
        let source: (any ArchiveReading)?
        let changes: ArchiveChangeSet
        let format: ArchiveFormat
        let directory: URL
        let baseName: String
        let options: ArchiveWriteOptions
    }

    private struct State {
        var writes: [ArchiveWriteOptions?] = []
        var volumeCalls: [VolumesCall] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let volumes: Volumes
    private let isVolumeSet: Bool

    init(_ volumes: Volumes = .succeed, volumeSet: Bool = false) {
        self.volumes = volumes
        isVolumeSet = volumeSet
    }

    var writes: [ArchiveWriteOptions?] { state.withLock { $0.writes } }
    var volumeCalls: [VolumesCall] { state.withLock { $0.volumeCalls } }

    var engine: ArchiveEngine {
        var engine = ArchiveEngine(
            open: { url, _ in
                guard self.isVolumeSet else { return FakeReader(entries: SampleArchive().entries, format: .zip, url: url) }
                let second = url.deletingLastPathComponent().appendingPathComponent("parts/set.7z.002")
                return FakeReader(entries: SampleArchive().entries, format: .sevenZip, url: url,
                                  volumeURLs: [url, second])
            },
            write: { _, _, format, url, options, _ in
                self.state.withLock { $0.writes.append(options) }
                try Data("written \(format.rawValue)".utf8).write(to: url)
            }
        )
        engine.writeVolumes = { source, changes, format, directory, baseName, options, _ in
            self.state.withLock {
                $0.volumeCalls.append(VolumesCall(source: source, changes: changes, format: format,
                                                  directory: directory, baseName: baseName, options: options))
            }
            switch self.volumes {
            case .succeed:
                return try Self.writeParts(into: directory, baseName: baseName, format: format)
            case .succeedThen(let body):
                let parts = try Self.writeParts(into: directory, baseName: baseName, format: format)
                try body()
                return parts
            case .fail(let error):
                throw error
            case .failRemovingOwnParts(let error, let before):
                try before(directory)
                var made: [URL] = []
                do {
                    for number in ["001", "002"] {
                        let url = directory.appendingPathComponent("\(baseName).\(format.fileExtension).\(number)")
                        try Data("part \(number)".utf8).write(to: url, options: .withoutOverwriting)
                        made.append(url)
                    }
                    throw error
                } catch {
                    for url in made { try? FileManager.default.removeItem(at: url) }
                    throw error
                }
            case .limit:
                throw ArchiveVolumeLimitError(maximum: 999)
            case .runUntilCancelled:
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                throw ArchiveError.cancelled
            }
        }
        return engine
    }

    private static func writeParts(into directory: URL, baseName: String, format: ArchiveFormat) throws -> [URL] {
        try ["001", "002"].map { number in
            let url = directory.appendingPathComponent("\(baseName).\(format.fileExtension).\(number)")
            try Data("part \(number)".utf8).write(to: url)
            return url
        }
    }
}

/// Records what a split save asked the Trash for, and moves it into a test folder instead.
private final class FakeTrash: Sendable {
    private let calls = OSAllocatedUnfairLock<[URL]>(initialState: [])
    let folder: URL
    /// The item-replacement directory throws, as on an SMB share under the sandbox.
    let deniesReplacementDirectory: Bool
    /// The Trash fails as on smbfs: NSCocoaErrorDomain 3328 over OSStatus -120, "the volume
    /// doesn't have one". The call is still recorded.
    let failsLikeSMB: Bool

    init(in root: URL, deniesReplacementDirectory: Bool = false, failsLikeSMB: Bool = false) {
        folder = root.appendingPathComponent("Trash", isDirectory: true)
        self.deniesReplacementDirectory = deniesReplacementDirectory
        self.failsLikeSMB = failsLikeSMB
    }

    /// What `FileManager.trashItem` throws on an SMB share.
    static let smbError = NSError(domain: NSCocoaErrorDomain, code: 3328,
                                  userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -120)])

    var trashed: [String] { calls.withLock { $0.map(\.standardizedFileURL.path) } }

    var placement: SplitSetPlacement {
        SplitSetPlacement(
            trashItem: { url in
                self.calls.withLock { $0.append(url) }
                if self.failsLikeSMB { throw Self.smbError }
                try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: self.folder.appendingPathComponent(url.lastPathComponent))
            },
            replaceItem: { _, _ in Issue.record("no replaceItemAt while the Trash works") },
            replacementDirectory: deniesReplacementDirectory
                ? { @Sendable (_: URL) throws -> URL in throw CocoaError(.fileWriteNoPermission) }
                : SplitSetPlacement.live.replacementDirectory
        )
    }
}

extension ArchiveDocumentTests {
    /// A fresh folder holding `a.zip` (4 bytes); the caller removes the folder.
    private func makeSplitRoot() throws -> (root: URL, archive: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveDocumentSplitSaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("a.zip")
        try Data("PK\u{3}\u{4}".utf8).write(to: archive)
        return (root, archive)
    }

    /// Runs `body` with `fake` and `trash` installed, then restores the live engine and placement.
    private func withSplitEngine<T>(_ fake: SplitFakeEngine, trash: FakeTrash,
                                    _ body: () async throws -> T) async rethrows -> T {
        ArchiveDocument.engine = fake.engine
        ArchiveDocument.splitSetPlacement = trash.placement
        defer {
            ArchiveDocument.engine = .live
            ArchiveDocument.splitSetPlacement = .live
        }
        return try await body()
    }

    /// The panel's options for `document` with `split` chosen, as `prepareSavePanel` makes them.
    private func chooseSplit(_ split: VolumeSplit = .preset(.mb25), in document: ArchiveDocument) throws {
        var settings = ArchiveSaveSettings(model: try #require(document.model))
        settings.split = split
        document.savePanelOptions = SavePanelOptions(settings: settings)
    }

    /// An earlier set's folder "Photos" in `root`, holding "Photos.7z.001" and ".002" ("old").
    private func makeEarlierSet(in root: URL) throws -> URL {
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for name in ["Photos.7z.001", "Photos.7z.002"] {
            try Data("old".utf8).write(to: destination.appendingPathComponent(name))
        }
        return destination
    }

    /// Every name in `folder`, "._" files too (`contentsOfDirectory` hides those).
    private func allNames(in folder: URL) throws -> Set<String> {
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

    private func names(in folder: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// (a) The set is written into a temporary folder named like the destination, with `baseName` the
    /// folder's name (also "Photos 2", and the trailing-slash URL of an existing folder), then moved
    /// there. Never `write`; nothing at the URL means no Trash (j); the comment change is `.keep`.
    @Test(arguments: ["Photos", "Photos 2"])
    func aSplitSaveWritesTheSetIntoTheFolderNamedByThePanel(_ name: String) async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = SplitFakeEngine()
        let trash = FakeTrash(in: root)
        try await withSplitEngine(fake, trash: trash) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)
            let destination = root.appendingPathComponent(name, isDirectory: false)

            try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)

            let call = try #require(fake.volumeCalls.first)
            #expect(fake.volumeCalls.count == 1)
            #expect(fake.writes.isEmpty)
            #expect(call.baseName == name)
            #expect(call.directory.lastPathComponent == name)
            #expect(call.directory.standardizedFileURL.path != destination.standardizedFileURL.path)
            #expect(call.options.volumeSize == 25_000_000)
            #expect(call.format == .zip)
            #expect(call.changes.comment == .keep)
            #expect(call.source?.url.standardizedFileURL.path == archive.standardizedFileURL.path)
            #expect(try names(in: destination) == ["\(name).zip.001", "\(name).zip.002"])
            #expect(!FileManager.default.fileExists(atPath: call.directory.deletingLastPathComponent().path))
            #expect(trash.trashed.isEmpty)
            #expect(document.state.progress == nil)
        }
    }

    /// A set split from a downloaded archive stays quarantined, every volume, as a plain save does
    /// (`savingADownloadedArchiveKeepsItsQuarantine`): the sandbox no longer marks what Lutik writes.
    @Test func aSplitSaveOfADownloadedArchiveKeepsItsQuarantine() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var marked = archive
        var values = URLResourceValues()
        values.quarantineProperties = ["LSQuarantineAgentName": "Safari",
                                       "LSQuarantineEventIdentifier": sampleQuarantineEvent]
        try marked.setResourceValues(values)
        try await withSplitEngine(SplitFakeEngine(), trash: FakeTrash(in: root)) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)
            let destination = root.appendingPathComponent("Photos", isDirectory: false)

            try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)

            for name in ["Photos.zip.001", "Photos.zip.002"] {
                #expect(try quarantineEvent(of: destination.appendingPathComponent(name)) == sampleQuarantineEvent, "\(name)")
            }
        }
    }

    /// (a, j) An existing set folder, through the trailing-slash URL the panel returns for it (q2): it
    /// goes to the Trash, and the new set, named after it, takes its place.
    @Test func aSplitSaveOverAnEarlierSetMovesItToTheTrash() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        for part in ["Photos.7z.001", "Photos.7z.002", "Photos.7z.003"] {
            try Data(part.utf8).write(to: destination.appendingPathComponent(part))
        }
        let fake = SplitFakeEngine()
        let trash = FakeTrash(in: root)
        try await withSplitEngine(fake, trash: trash) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)
            #expect(destination.hasDirectoryPath)

            try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)

            #expect(fake.volumeCalls.first?.baseName == "Photos")
            #expect(trash.trashed == [destination.standardizedFileURL.path])
            #expect(try names(in: destination) == ["Photos.zip.001", "Photos.zip.002"])
            #expect(try names(in: trash.folder.appendingPathComponent("Photos"))
                    == ["Photos.7z.001", "Photos.7z.002", "Photos.7z.003"])
        }
    }

    /// (b) Save To semantics: the document keeps its file, type, edited state and saved options, and
    /// the split size never reaches `saveOptions`. The listing stays, so an open preview stays too.
    @Test func aSplitSaveChangesNothingInTheDocument() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let added = root.appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: added)
        try await withSplitEngine(SplitFakeEngine(), trash: FakeTrash(in: root)) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            let actions = ArchiveActions(document: document)
            document.actions = actions
            let model = try #require(document.model)
            model.add([added], to: "")
            document.updateChangeCount(.changeDone)
            let changes = model.changes
            let extracted = URL(fileURLWithPath: "/tmp/README.md")
            document.state.previewEntries = [PreviewEntry(path: "README.md", url: extracted)]
            document.state.previewURL = extracted
            try chooseSplit(in: document)

            try await document.save(to: root.appendingPathComponent("Photos"), ofType: "public.zip-archive",
                                    for: .saveAsOperation)

            #expect(document.fileURL?.standardizedFileURL.path == archive.standardizedFileURL.path)
            #expect(document.fileType == "public.zip-archive")
            #expect(document.isDocumentEdited)
            #expect(document.model === model)
            #expect(model.changes == changes)
            #expect(model.saveOptions == nil)
            #expect(document.savePanelOptions == nil)
            #expect(document.state.previewURL == extracted)
            #expect(document.state.previewEntries.map(\.path) == ["README.md"])
        }
    }

    /// (g) An untitled new archive stays untitled after a split save.
    @Test func anUntitledDocumentStaysUntitled() async throws {
        let (root, _) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let added = root.appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: added)
        let fake = SplitFakeEngine()
        try await withSplitEngine(fake, trash: FakeTrash(in: root)) {
            let document = try ArchiveDocument(type: "public.zip-archive")
            try #require(document.model).add([added], to: "")
            try chooseSplit(in: document)

            try await document.save(to: root.appendingPathComponent("New Set"), ofType: "public.zip-archive",
                                    for: .saveToOperation)

            #expect(fake.volumeCalls.count == 1)
            #expect(fake.volumeCalls.first?.source == nil)
            #expect(document.fileURL == nil)
        }
    }

    /// (c) A ⌘S after a split save writes one file, unsplit; also after an `apply` of settings that
    /// carried a volume size (`ArchiveModel.apply` drops it).
    @Test func aPlainSaveAfterASplitSaveWritesOneUnsplitFile() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = SplitFakeEngine()
        try await withSplitEngine(fake, trash: FakeTrash(in: root)) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)
            try await document.save(to: root.appendingPathComponent("Photos"), ofType: "public.zip-archive",
                                    for: .saveAsOperation)

            try await document.save(to: archive, ofType: "public.zip-archive", for: .saveOperation)
            #expect(fake.writes.count == 1)
            // Explicit options (macOS strips Mac metadata by default), so a nil can't pass the check.
            #expect(try #require(fake.writes.last ?? nil).volumeSize == nil)

            let model = try #require(document.model)
            var settings = ArchiveSaveSettings(model: model)
            settings.split = .preset(.mb100)
            model.apply(settings)
            try await document.save(to: archive, ofType: "public.zip-archive", for: .saveOperation)
            #expect(fake.writes.count == 2)
            #expect(try #require(fake.writes.last ?? nil).volumeSize == nil)
            #expect(fake.volumeCalls.count == 1)
        }
    }

    /// (d) Cancel from the progress sheet: `userCancelled` (never presented), nothing at the destination.
    @Test func cancellingASplitSaveLeavesNothing() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = SplitFakeEngine(.runUntilCancelled)
        try await withSplitEngine(fake, trash: FakeTrash(in: root)) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)
            let destination = root.appendingPathComponent("Photos")
            let saving = Task {
                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
            }
            try await waitForSplitWrite(fake)
            let cancel = try #require(document.state.progress?.cancel)
            cancel()

            let result = await saving.result
            #expect(throws: CocoaError.self) { try result.get() }
            if case .failure(let error) = result {
                #expect((error as? CocoaError)?.code == .userCancelled)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let temporary = try #require(fake.volumeCalls.first).directory.deletingLastPathComponent()
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
            #expect(document.state.progress == nil)
        }
    }

    private func waitForSplitWrite(_ fake: SplitFakeEngine) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while fake.volumeCalls.isEmpty {
            try #require(ContinuousClock.now < deadline, "the split write never started")
            await Task.yield()
        }
    }

    /// (e) An engine error is reported once, after the progress sheet has gone; the destination is
    /// untouched and the temporary folder gone.
    @Test func anEngineErrorIsReportedOnce() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = SplitFakeEngine(.fail(.io("disk full")))
        try await withSplitEngine(fake, trash: FakeTrash(in: root)) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)
            let destination = root.appendingPathComponent("Photos")

            await #expect(throws: ArchiveError.io("disk full")) {
                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
            }
            #expect(fake.volumeCalls.count == 1)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let temporary = try #require(fake.volumeCalls.first).directory.deletingLastPathComponent()
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
            #expect(document.state.progress == nil)
        }
    }

    /// (h) `ArchiveVolumeLimitError` shows the too-many-volumes text, not `ArchiveError`'s, and an
    /// earlier set at the destination stays as it was.
    @Test func tooManyVolumesSaysSoAndLeavesTheDestinationAlone() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: destination.appendingPathComponent("Photos.zip.001"))
        let trash = FakeTrash(in: root)
        try await withSplitEngine(SplitFakeEngine(.limit), trash: trash) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)

            let error = await #expect(throws: (any Error).self) {
                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
            }
            #expect(error?.localizedDescription == ArchiveSaveSettings.Problem.tooManyVolumes.message)
            #expect(error?.localizedDescription == "Too many volumes. Choose a larger volume size.")
            #expect(try names(in: destination) == ["Photos.zip.001"])
            #expect(trash.trashed.isEmpty)
        }
    }

    /// (f) A read-only volume set saves split like any archive (Save As), but never into a folder
    /// holding one of its parts.
    @Test func aVolumeSetSavesSplitButNeverOverItsOwnParts() async throws {
        let (root, _) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("set.7z.001")
        try Data("7z".utf8).write(to: first)
        let partsFolder = root.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: partsFolder, withIntermediateDirectories: false)
        try Data("7z".utf8).write(to: partsFolder.appendingPathComponent("set.7z.002"))
        let fake = SplitFakeEngine(volumeSet: true)
        try await withSplitEngine(fake, trash: FakeTrash(in: root)) {
            let document = try ArchiveDocument(contentsOf: first, ofType: "org.7-zip.7-zip-archive")
            try chooseSplit(in: document)
            await #expect(throws: SplitOntoSourceError.self) {
                try await document.save(to: partsFolder, ofType: "org.7-zip.7-zip-archive", for: .saveAsOperation)
            }
            #expect(fake.volumeCalls.isEmpty)
            #expect(try names(in: partsFolder) == ["set.7z.002"])

            try chooseSplit(in: document)
            try await document.save(to: root.appendingPathComponent("Copy"), ofType: "org.7-zip.7-zip-archive",
                                    for: .saveAsOperation)
            #expect(fake.volumeCalls.first?.source?.volumeURLs.count == 2)
            #expect(try names(in: root.appendingPathComponent("Copy")) == ["Copy.7z.001", "Copy.7z.002"])
            #expect(document.fileURL?.standardizedFileURL.path == first.standardizedFileURL.path)
        }
    }

    /// (f2) A new archive with a folder being added: never onto that folder, a folder above it, or one
    /// inside it.
    @Test func aSplitSaveNeverReplacesAFolderBeingAdded() async throws {
        let (root, _) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Desktop/Photos", isDirectory: true)
        let inner = photos.appendingPathComponent("Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: inner.appendingPathComponent("IMG_0001.jpg"))
        let fake = SplitFakeEngine()
        try await withSplitEngine(fake, trash: FakeTrash(in: root)) {
            let document = try ArchiveDocument(type: "public.zip-archive")
            try #require(document.model).add([photos], to: "")
            for destination in [photos, photos.deletingLastPathComponent(), inner] {
                try chooseSplit(in: document)
                await #expect(throws: SplitOntoSourceError.self) {
                    try await document.save(to: destination, ofType: "public.zip-archive", for: .saveToOperation)
                }
            }
            #expect(fake.volumeCalls.isEmpty)
            #expect(try names(in: inner) == ["IMG_0001.jpg"])
        }
    }

    /// (i) The recheck: a set folder that gains another file while the set is written is refused right
    /// before the move. The temporary folder goes, the folder is left as it is, and nothing is trashed.
    @Test func aSetFolderThatChangedDuringTheWriteIsRefused() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: destination.appendingPathComponent("Photos.zip.001"))
        let notes = destination.appendingPathComponent("notes.txt")
        let fake = SplitFakeEngine(.succeedThen { try Data("mine".utf8).write(to: notes) })
        let trash = FakeTrash(in: root)
        try await withSplitEngine(fake, trash: trash) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)

            await #expect(throws: NotASplitSetFolderError.self) {
                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
            }
            #expect(fake.volumeCalls.count == 1)
            #expect(try names(in: destination) == ["Photos.zip.001", "notes.txt"])
            #expect(trash.trashed.isEmpty)
            let temporary = try #require(fake.volumeCalls.first).directory.deletingLastPathComponent()
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
        }
    }

    /// A new name (no Replace in the panel), and a set folder appears there while the set is written
    /// (another window saving to the same name): refused as already existing. That folder is left as
    /// it is, nothing is trashed, and the temporary folder goes.
    @Test func aSetFolderThatAppearedAtANewNameDuringTheWriteIsRefused() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Backup", isDirectory: false)
        let other = destination.appendingPathComponent("Backup.zip.001")
        let fake = SplitFakeEngine(.succeedThen {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("other window".utf8).write(to: other)
        })
        let trash = FakeTrash(in: root)
        try await withSplitEngine(fake, trash: trash) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)

            let error = await #expect(throws: CocoaError.self) {
                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
            }
            #expect(error?.code == .fileWriteFileExists)
            #expect(fake.volumeCalls.count == 1)
            #expect(try names(in: destination) == ["Backup.zip.001"])
            #expect(try Data(contentsOf: other) == Data("other window".utf8))
            #expect(trash.trashed.isEmpty)
            let temporary = try #require(fake.volumeCalls.first).directory.deletingLastPathComponent()
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
            #expect(document.state.progress == nil)
        }
    }

    /// Settings with a problem (an empty Custom size: Split is on, but there is no size yet) are
    /// refused with the panel's message, and nothing is written.
    @Test func aSplitWithAProblemWritesNothing() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = SplitFakeEngine()
        try await withSplitEngine(fake, trash: FakeTrash(in: root)) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(.custom(amount: "", unit: .mb), in: document)
            let destination = root.appendingPathComponent("Photos")

            let error = await #expect(throws: (any Error).self) {
                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
            }
            #expect(error?.localizedDescription == ArchiveSaveSettings.Problem.volumeSizeInvalid.message)
            #expect(fake.volumeCalls.isEmpty)
            #expect(fake.writes.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(document.state.progress == nil)
        }
    }

    /// The gate's other half: `init(format:options:)` takes `options` as given and doesn't sync
    /// `volumeSize` from `split`, so a volume size with `split` `.none` (not `isSplitting`) is still a
    /// split save: it never reaches the single-file `write`.
    @Test func aVolumeSizeWithoutSplitIsStillASplitSave() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = SplitFakeEngine()
        try await withSplitEngine(fake, trash: FakeTrash(in: root)) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            var options = ArchiveWriteOptions()
            options.volumeSize = 25_000_000
            let settings = ArchiveSaveSettings(format: .zip, options: options)
            #expect(settings.split == .none)
            document.savePanelOptions = SavePanelOptions(settings: settings)

            try await document.save(to: root.appendingPathComponent("Photos"), ofType: "public.zip-archive",
                                    for: .saveAsOperation)

            #expect(fake.writes.isEmpty)
            #expect(fake.volumeCalls.first?.options.volumeSize == 25_000_000)
        }
    }

    // MARK: - In place, when the item-replacement directory is denied

    /// A fresh name: the engine writes the set straight into the folder the panel names.
    @Test func aDeniedReplacementDirectoryWritesTheSetInPlace() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = SplitFakeEngine()
        let trash = FakeTrash(in: root, deniesReplacementDirectory: true)
        try await withSplitEngine(fake, trash: trash) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)
            let destination = root.appendingPathComponent("Photos", isDirectory: false)

            try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)

            let call = try #require(fake.volumeCalls.first)
            #expect(call.directory.standardizedFileURL.path == destination.standardizedFileURL.path)
            #expect(call.baseName == "Photos")
            #expect(try names(in: destination) == ["Photos.zip.001", "Photos.zip.002"])
            #expect(try names(in: root) == ["a.zip", "Photos"])
            #expect(trash.trashed.isEmpty)
            #expect(document.state.progress == nil)
        }
    }

    /// An earlier set at the URL: the engine writes the new set into a staging folder inside it,
    /// named like the panel's URL; the earlier volumes go to the Trash, the new ones take their place,
    /// and the staging folder goes.
    @Test func aDeniedReplacementDirectoryReplacesAnEarlierSetInPlace() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try makeEarlierSet(in: root)
        let fake = SplitFakeEngine()
        let trash = FakeTrash(in: root, deniesReplacementDirectory: true)
        try await withSplitEngine(fake, trash: trash) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)

            try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)

            let call = try #require(fake.volumeCalls.first)
            #expect(call.directory.deletingLastPathComponent().standardizedFileURL.path == destination.path)
            #expect(call.directory.lastPathComponent.hasPrefix(".kernir-replace-"))
            #expect(call.baseName == "Photos")
            #expect(Set(trash.trashed.map { URL(fileURLWithPath: $0).lastPathComponent })
                        == ["Photos.7z.001", "Photos.7z.002"])
            #expect(try names(in: destination) == ["Photos.zip.001", "Photos.zip.002"])
            #expect(try names(in: root) == ["a.zip", "Photos", "Trash"])
            #expect(document.state.progress == nil)
        }
    }

    /// The real SMB path: no item-replacement directory and no Trash (3328 / -120), so each earlier
    /// volume is unlinked after its Trash attempt. End to end: the earlier volumes are gone, the new set is
    /// in place, the staging folder is gone, and nothing else is touched.
    @Test func anInPlaceReplaceOnAShareWithNoTrashUnlinksTheEarlierSet() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try makeEarlierSet(in: root)
        try Data("old".utf8).write(to: destination.appendingPathComponent("._Photos.7z.001"))
        try Data("finder".utf8).write(to: destination.appendingPathComponent(".DS_Store"))
        try Data("sibling".utf8).write(to: root.appendingPathComponent("sibling.txt"))
        let fake = SplitFakeEngine()
        let trash = FakeTrash(in: root, deniesReplacementDirectory: true, failsLikeSMB: true)
        try await withSplitEngine(fake, trash: trash) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)

            try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)

            let call = try #require(fake.volumeCalls.first)
            #expect(call.directory.lastPathComponent.hasPrefix(".kernir-replace-"))
            #expect(Set(trash.trashed.map { URL(fileURLWithPath: $0).lastPathComponent })
                        == ["Photos.7z.001", "Photos.7z.002", "._Photos.7z.001"])
            #expect(!FileManager.default.fileExists(atPath: trash.folder.path))
            #expect(try allNames(in: destination) == ["Photos.zip.001", "Photos.zip.002", ".DS_Store"])
            #expect(try Data(contentsOf: destination.appendingPathComponent("Photos.zip.001")) == Data("part 001".utf8))
            #expect(try Data(contentsOf: destination.appendingPathComponent(".DS_Store")) == Data("finder".utf8))
            #expect(try allNames(in: root) == ["a.zip", "Photos", "sibling.txt"])
            #expect(try Data(contentsOf: root.appendingPathComponent("sibling.txt")) == Data("sibling".utf8))
            #expect(try Data(contentsOf: archive) == Data("PK\u{3}\u{4}".utf8))
            #expect(document.state.progress == nil)
        }
    }

    /// A file dropped into the earlier set's folder, or a leftover staging folder appearing, while the
    /// set is written: nothing is replaced, the new volumes and the staging folder go, the rest stays.
    @Test(arguments: ["notes.txt", ".kernir-replace-0"])
    func aSetFolderThatChangedDuringAnInPlaceReplaceReplacesNothing(_ dropped: String) async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try makeEarlierSet(in: root)
        let fake = SplitFakeEngine(.succeedThen {
            if dropped.hasPrefix(".") {
                try FileManager.default.createDirectory(at: destination.appendingPathComponent(dropped),
                                                        withIntermediateDirectories: false)
            } else {
                try Data("mine".utf8).write(to: destination.appendingPathComponent(dropped))
            }
        })
        let trash = FakeTrash(in: root, deniesReplacementDirectory: true)
        try await withSplitEngine(fake, trash: trash) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)

            let error = await #expect(throws: SplitSetChangedError.self) {
                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
            }

            #expect(error?.name == "Photos")
            #expect(trash.trashed.isEmpty)
            #expect(try names(in: destination) == ["Photos.7z.001", "Photos.7z.002", dropped])
            #expect(try Data(contentsOf: destination.appendingPathComponent("Photos.7z.001")) == Data("old".utf8))
            #expect(try names(in: root) == ["a.zip", "Photos"])
            #expect(document.state.progress == nil)
        }
    }

    /// A leftover staging folder from a crash is already there: the folder isn't an earlier set's any
    /// more, so the save refuses up front and writes nothing.
    @Test func aLeftoverStagingFolderRefusesTheReplaceUpFront() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try makeEarlierSet(in: root)
        let leftover = destination.appendingPathComponent(".kernir-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: false)
        let fake = SplitFakeEngine()
        let trash = FakeTrash(in: root, deniesReplacementDirectory: true)
        try await withSplitEngine(fake, trash: trash) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)

            await #expect(throws: NotASplitSetFolderError.self) {
                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
            }

            #expect(fake.volumeCalls.isEmpty)
            #expect(trash.trashed.isEmpty)
            #expect(try names(in: destination) == ["Photos.7z.001", "Photos.7z.002", leftover.lastPathComponent])
        }
    }

    /// The engine fails (it removed its own volumes) or the save is cancelled: the staging folder goes,
    /// the earlier set stays as it was.
    @Test(arguments: [false, true])
    func aFailedInPlaceReplaceLeavesTheEarlierSet(cancelled: Bool) async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try makeEarlierSet(in: root)
        let fake = SplitFakeEngine(cancelled ? .runUntilCancelled : .failRemovingOwnParts(.io("disk full"),
                                                                                          before: { _ in }))
        let trash = FakeTrash(in: root, deniesReplacementDirectory: true)
        try await withSplitEngine(fake, trash: trash) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)
            let saving = Task {
                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
            }
            if cancelled {
                try await waitForSplitWrite(fake)
                let cancel = try #require(document.state.progress?.cancel)
                cancel()
            }

            let result = await saving.result
            if case .failure(let error) = result {
                if cancelled { #expect((error as? CocoaError)?.code == .userCancelled) }
            } else {
                Issue.record("the save went through")
            }
            #expect(fake.volumeCalls.first?.directory.lastPathComponent.hasPrefix(".kernir-replace-") == true)
            #expect(trash.trashed.isEmpty)
            #expect(try names(in: destination) == ["Photos.7z.001", "Photos.7z.002"])
            #expect(try Data(contentsOf: destination.appendingPathComponent("Photos.7z.002")) == Data("old".utf8))
            #expect(try names(in: root) == ["a.zip", "Photos"])
            #expect(document.state.progress == nil)
        }
    }

    /// Cancel during an in-place write: our folder goes, the folder above and the archive beside it stay.
    @Test func cancellingAnInPlaceSplitSaveLeavesTheFolderAboveAlone() async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = SplitFakeEngine(.runUntilCancelled)
        try await withSplitEngine(fake, trash: FakeTrash(in: root, deniesReplacementDirectory: true)) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)
            let destination = root.appendingPathComponent("Photos")
            let saving = Task {
                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
            }
            try await waitForSplitWrite(fake)
            #expect(fake.volumeCalls.first?.directory.standardizedFileURL.path == destination.standardizedFileURL.path)
            let cancel = try #require(document.state.progress?.cancel)
            cancel()

            let result = await saving.result
            if case .failure(let error) = result {
                #expect((error as? CocoaError)?.code == .userCancelled)
            } else {
                Issue.record("the save went through")
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try names(in: root) == ["a.zip"])
            #expect(try Data(contentsOf: archive) == Data("PK\u{3}\u{4}".utf8))
            #expect(document.state.progress == nil)
        }
    }

    /// An engine error: it removed the parts it made, so our folder goes, and the folder above stays. A
    /// file dropped in meanwhile named like a part (the engine's exclusive create then fails) isn't ours:
    /// it stays, with the folder.
    @Test(arguments: [false, true])
    func anInPlaceEngineErrorRemovesOnlyWhatTheSaveWrote(foreignPart: Bool) async throws {
        let (root, archive) = try makeSplitRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Photos")
        let fake = SplitFakeEngine(.failRemovingOwnParts(.io("disk full"), before: { directory in
            if foreignPart { try Data("mine".utf8).write(to: directory.appendingPathComponent("Photos.zip.002")) }
        }))
        try await withSplitEngine(fake, trash: FakeTrash(in: root, deniesReplacementDirectory: true)) {
            let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
            try chooseSplit(in: document)

            await #expect(throws: (any Error).self) {
                try await document.save(to: destination, ofType: "public.zip-archive", for: .saveAsOperation)
            }

            if foreignPart {
                #expect(try names(in: destination) == ["Photos.zip.002"])
                #expect(try Data(contentsOf: destination.appendingPathComponent("Photos.zip.002")) == Data("mine".utf8))
                #expect(try names(in: root) == ["a.zip", "Photos"])
            } else {
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                #expect(try names(in: root) == ["a.zip"])
            }
            #expect(try Data(contentsOf: archive) == Data("PK\u{3}\u{4}".utf8))
            #expect(document.state.progress == nil)
        }
    }
}
