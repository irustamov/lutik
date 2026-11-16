import Testing
import AppKit
import UniformTypeIdentifiers
@testable import Kernir
import KernirCore

/// `OpenRequest`, the work of
/// `AppDelegate.application(_:open:)`, with the real `ServicesRequest.opensInKernir`, recorded
/// `open` and fake Dock-session windows. Names only: no file is read.
@Suite @MainActor struct OpenRequestTests {
    private let folder = URL(fileURLWithPath: "/Users/u/Downloads", isDirectory: true)

    private func urls(_ names: [String]) -> [URL] { names.map { folder.appendingPathComponent($0) } }

    /// A Dock-session window: what it was given and asked to do.
    @MainActor final class FakeSession: NewArchiveSession {
        var takesMoreItems = true
        var newArchiveProposal: CompressPlan.Destination?
        var added: [[URL]] = []
        var broughtToFront = 0
        /// The proposal at each `beginSave`.
        var saves: [CompressPlan.Destination?] = []
        func add(_ items: [URL]) { added.append(items) }
        func bringToFront() { broughtToFront += 1 }
        func beginSave() { saves.append(newArchiveProposal) }
    }

    /// The request under test; `made` keeps every session it made (the request holds them weakly).
    private final class Harness {
        var opened: [URL] = []
        var made: [FakeSession] = []
        var fails = false
    }

    private func make() -> (OpenRequest, Harness) {
        let harness = Harness()
        let request = OpenRequest(open: { harness.opened.append($0) }, newSession: {
            guard !harness.fails else { return nil }
            let session = FakeSession()
            harness.made.append(session)
            return session
        })
        return (request, harness)
    }

    @Test func archivesOpenEachAndMakeNoWindow() {
        let (request, harness) = make()
        let archives = urls(["a.zip", "b.tar.gz", "c.7z"])
        request.handle(archives)
        #expect(harness.opened == archives)
        #expect(harness.made.isEmpty)
    }

    /// One plain file: a new window holding it, its Save sheet up at once proposing "notes.txt.zip"
    /// in the file's folder.
    @Test func aPlainFileMakesANewArchiveWithTheSaveSheet() throws {
        let (request, harness) = make()
        request.handle(urls(["notes.txt"]))
        #expect(harness.opened.isEmpty)
        let session = try #require(harness.made.first)
        #expect(harness.made.count == 1)
        #expect(session.added == [urls(["notes.txt"])])
        #expect(session.saves == [CompressPlan.Destination(directory: folder, name: "notes.txt.zip")])
    }

    @Test func aFolderProposesItsNameDotZip() throws {
        let (request, harness) = make()
        request.handle([folder.appendingPathComponent("Photos", isDirectory: true)])
        #expect(try #require(harness.made.first).saves.first??.name == "Photos.zip")
    }

    /// Archives among plain files are items too: one new archive of every item, "Archive.zip",
    /// in the first item's folder.
    @Test func aMixedDropGoesWholeIntoOneNewArchive() throws {
        let (request, harness) = make()
        let other = URL(fileURLWithPath: "/Users/u/Desktop/b.7z")
        let mixed = urls(["a.zip", "notes.txt"]) + [other]
        request.handle(mixed)
        #expect(harness.opened.isEmpty)
        let session = try #require(harness.made.first)
        #expect(harness.made.count == 1)
        #expect(session.added == [mixed])
        #expect(session.saves == [CompressPlan.Destination(directory: folder, name: "Archive.zip")])
    }

    /// While the window is open and unsaved, the next drop goes into it and brings it to the front;
    /// the Save sheet isn't opened again, and its proposal now names several items.
    @Test func aSecondDropJoinsTheOpenUnsavedSession() throws {
        let (request, harness) = make()
        request.handle(urls(["notes.txt"]))
        request.handle(urls(["photo.jpg", "a.zip"]))
        let session = try #require(harness.made.first)
        #expect(harness.made.count == 1)
        #expect(session.added == [urls(["notes.txt"]), urls(["photo.jpg", "a.zip"])])
        #expect(session.broughtToFront == 1)
        #expect(session.saves.count == 1)
        #expect(session.newArchiveProposal == CompressPlan.Destination(directory: folder, name: "Archive.zip"))
    }

    /// A later drop repeating a name the session holds (notes.txt again) is one item, not
    /// two: the proposal stays "notes.txt.zip".
    @Test func aRepeatedNameCountsOnceInTheProposal() throws {
        let (request, harness) = make()
        request.handle(urls(["notes.txt"]))
        request.handle(urls(["notes.txt"]))
        let session = try #require(harness.made.first)
        #expect(harness.made.count == 1)
        #expect(session.added == [urls(["notes.txt"]), urls(["notes.txt"])])
        #expect(session.newArchiveProposal == CompressPlan.Destination(directory: folder, name: "notes.txt.zip"))
        request.handle(urls(["photo.jpg"]))
        #expect(session.newArchiveProposal == CompressPlan.Destination(directory: folder, name: "Archive.zip"))
    }

    /// Archives alone still open for viewing while a session is open; they don't join it.
    @Test func archivesAloneDoNotJoinTheSession() throws {
        let (request, harness) = make()
        request.handle(urls(["notes.txt"]))
        request.handle(urls(["a.zip"]))
        #expect(harness.opened == urls(["a.zip"]))
        #expect(try #require(harness.made.first).added == [urls(["notes.txt"])])
    }

    /// Saved (it has a file now) or busy: the next drop opens a new window with its own sheet.
    @Test func aSavedSessionTakesNoMoreDrops() throws {
        let (request, harness) = make()
        request.handle(urls(["notes.txt"]))
        let first = try #require(harness.made.first)
        first.takesMoreItems = false
        request.handle(urls(["photo.jpg"]))
        #expect(harness.made.count == 2)
        #expect(harness.made[0].added == [urls(["notes.txt"])])
        #expect(harness.made[1].added == [urls(["photo.jpg"])])
        #expect(harness.made[1].saves == [CompressPlan.Destination(directory: folder, name: "photo.jpg.zip")])
    }

    /// Closed: the window is gone (the request held it weakly), so the next drop opens a new one.
    @Test func aClosedSessionIsForgotten() {
        let (request, harness) = make()
        request.handle(urls(["notes.txt"]))
        harness.made.removeAll()
        request.handle(urls(["photo.jpg"]))
        #expect(harness.made.count == 1)
        #expect(harness.made.first?.added == [urls(["photo.jpg"])])
        #expect(harness.made.first?.saves.count == 1)
    }

    /// No window could be made: nothing happens, and the next drop tries again.
    @Test func aFailedWindowLeavesNoSession() {
        let (request, harness) = make()
        harness.fails = true
        request.handle(urls(["notes.txt"]))
        harness.fails = false
        request.handle(urls(["photo.jpg"]))
        #expect(harness.made.count == 1)
        #expect(harness.made.first?.saves == [CompressPlan.Destination(directory: folder, name: "photo.jpg.zip")])
    }

    @Test func nonFileURLsAreIgnored() throws {
        let (request, harness) = make()
        let web = try #require(URL(string: "https://example.com/notes.txt"))
        request.handle([web])
        #expect(harness.opened.isEmpty && harness.made.isEmpty)
        request.handle([web] + urls(["a.zip"]))
        #expect(harness.opened == urls(["a.zip"]))
        request.handle(urls(["notes.txt"]) + [web])
        #expect(harness.made.first?.added == [urls(["notes.txt"])])
    }

    /// The gate's bug: AppKit handed `open -a Lutik note2.txt a.zip` over in two calls. Through
    /// `OpenBatch`, as `AppDelegate` routes them, the two calls make one new archive of both items
    /// and open nothing.
    @Test func aMixedSetSplitAcrossTwoCallsMakesOneNewArchive() {
        let (request, harness) = make()
        var scheduled: [@MainActor @Sendable () -> Void] = []
        let batch = OpenBatch(schedule: { scheduled.append($0) }, deliver: { request.handle($0) })
        batch.add(urls(["note2.txt"]))
        batch.add(urls(["a.zip"]))
        scheduled.forEach { $0() }
        #expect(harness.opened.isEmpty)
        #expect(harness.made.count == 1)
        #expect(harness.made.first?.added == [urls(["note2.txt", "a.zip"])])
    }
}

/// The hook in `ArchiveDocument.prepareSavePanel`: a Dock drop's untitled archive proposes its
/// name and folder; a document with a file, or without a proposal, is unchanged.
@Suite(.serialized) @MainActor struct NewArchiveProposalTests {
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewArchiveProposalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    @Test func theSavePanelProposesTheNameAndFolder() throws {
        try withFolder { folder in
            let document = try ArchiveDocument(type: UTType.zip.identifier)
            document.newArchiveProposal = CompressPlan.Destination(directory: folder, name: "notes.txt.zip")
            let panel = NSSavePanel()
            _ = document.prepareSavePanel(panel)
            #expect(panel.nameFieldStringValue == "notes.txt.zip")
            #expect(panel.directoryURL?.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        }
    }

    /// No proposal: the name a File > New document's panel gets (`SavePanelOptions` from the
    /// panel's own empty field, as ZIP), and the folder the panel had.
    @Test func withoutAProposalTheNameIsNotSet() throws {
        try withFolder { folder in
            let document = try ArchiveDocument(type: UTType.zip.identifier)
            let panel = NSSavePanel()
            panel.directoryURL = folder
            let defaultName = ArchiveSaveSettings.savePanelProposal(NSSavePanel().nameFieldStringValue, for: .zip)
            _ = document.prepareSavePanel(panel)
            #expect(panel.nameFieldStringValue == defaultName)
            #expect(panel.directoryURL?.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        }
    }

    /// A document with a file (the Dock window once saved) keeps its own name and the panel's
    /// folder, whatever proposal it still holds.
    @Test func aDocumentWithAFileIgnoresTheProposal() throws {
        try withFolder { folder in
            let elsewhere = folder.appendingPathComponent("elsewhere", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let document = try ArchiveDocument(type: UTType.zip.identifier)
            defer { document.close() }
            document.fileURL = folder.appendingPathComponent("Saved.zip")
            document.newArchiveProposal = CompressPlan.Destination(directory: elsewhere, name: "notes.txt.zip")
            let panel = NSSavePanel()
            panel.directoryURL = folder
            _ = document.prepareSavePanel(panel)
            #expect(panel.nameFieldStringValue == "Saved.zip")
            #expect(panel.directoryURL?.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        }
    }

    /// A bare document (not in the document controller) takes no Dock drops, even with its window
    /// controller made and able to add: the controller clause decides.
    @Test func aDocumentOutsideTheControllerTakesNoDrops() throws {
        let document = try ArchiveDocument(type: UTType.zip.identifier)
        document.makeWindowControllers()
        defer { document.close() }
        #expect(document.actions?.canAdd == true)
        #expect(document.fileURL == nil)
        #expect(!NSDocumentController.shared.documents.contains { $0 === document })
        #expect(!document.takesMoreItems)
    }

    /// A second drop while the Save sheet is up renames it ("notes.txt.zip" → "Archive.zip"); a
    /// panel that isn't on screen keeps its name. (A sheet can't be shown here:
    /// `NewArchiveSavePanelTests` covers the shown case.)
    @Test func aProposalUpdateLeavesAPanelThatIsNotShown() throws {
        try withFolder { folder in
            let document = try ArchiveDocument(type: UTType.zip.identifier)
            document.newArchiveProposal = CompressPlan.Destination(directory: folder, name: "notes.txt.zip")
            let panel = NSSavePanel()
            _ = document.prepareSavePanel(panel)
            document.newArchiveProposal = CompressPlan.Destination(directory: folder, name: "Archive.zip")
            #expect(!panel.isVisible)
            #expect(panel.nameFieldStringValue == "notes.txt.zip")
        }
    }
}

/// The Save sheet a Dock window's proposal named takes a later drop's new name
/// while it is up and the user hasn't edited its name.
@Suite @MainActor struct NewArchiveSavePanelTests {
    @Test func theNameFollowsOnlyAnUneditedShownField() {
        let rename = NewArchiveSavePanel.newName
        #expect(rename("notes.txt.zip", "notes.txt.zip", true, "Archive.zip") == "Archive.zip")
        // Edited by the user: kept.
        #expect(rename("Mine.zip", "notes.txt.zip", true, "Archive.zip") == nil)
        // Not on screen (closed, or never shown): left alone.
        #expect(rename("notes.txt.zip", "notes.txt.zip", false, "Archive.zip") == nil)
        // Nothing tracked, or the same name: nothing to do.
        #expect(rename("notes.txt.zip", nil, true, "Archive.zip") == nil)
        #expect(rename("Archive.zip", "Archive.zip", true, "Archive.zip") == nil)
    }

    /// A real panel (not shown; its being on screen given): renamed while unedited, and the new
    /// name is the one a later update compares with; kept once the user typed another.
    @Test func aTrackedPanelIsRenamedUntilTheUserEditsIt() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "notes.txt.zip"
        let tracker = NewArchiveSavePanel()
        tracker.propose("Archive.zip", isShown: true)
        #expect(panel.nameFieldStringValue == "notes.txt.zip")
        tracker.track(panel)
        tracker.propose("Archive.zip", isShown: true)
        #expect(panel.nameFieldStringValue == "Archive.zip")
        tracker.propose("Photos.zip", isShown: true)
        #expect(panel.nameFieldStringValue == "Photos.zip")
        panel.nameFieldStringValue = "Mine.zip"
        tracker.propose("Archive.zip", isShown: true)
        #expect(panel.nameFieldStringValue == "Mine.zip")
        tracker.propose(nil, isShown: true)
        #expect(panel.nameFieldStringValue == "Mine.zip")
    }
}

/// `ArchiveDocument`'s own `NewArchiveSession` conformance, hosted: a real untitled ZIP from the
/// shared document controller, its window made but never shown. `beginSave` isn't called (it
/// opens the Save sheet).
@Suite(.serialized) @MainActor struct NewArchiveSessionDocumentTests {
    /// A session made as a Dock drop makes it, without showing its window; closed afterwards.
    private func withSession(_ body: (ArchiveDocument) throws -> Void) throws {
        let document = try #require(ArchiveDocument.makeNewArchiveSession(display: false))
        defer { document.close() }
        try body(document)
    }

    private func withFile(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewArchiveSessionDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        try body(file)
    }

    @Test func aNewSessionIsAnUntitledZipInTheController() throws {
        try withSession { document in
            #expect(NSDocumentController.shared.documents.contains { $0 === document })
            #expect(document.fileURL == nil)
            #expect(document.fileType == UTType.zip.identifier)
            #expect(document.windowControllers.count == 1)
            #expect(document.windowControllers.first?.window?.isVisible == false)
            #expect(document.actions != nil)
            #expect(document.takesMoreItems)
        }
    }

    @Test func addingAFileMakesAPendingItem() throws {
        try withFile { file in
            try withSession { document in
                document.add([file])
                #expect(document.model?.item(at: "notes.txt")?.isPendingAddition == true)
                #expect(document.takesMoreItems)
            }
        }
    }

    /// Saved: it has a file now.
    @Test func aDocumentWithAFileTakesNoMoreItems() throws {
        try withFile { file in
            try withSession { document in
                document.fileURL = file.deletingLastPathComponent().appendingPathComponent("notes.txt.zip")
                #expect(!document.takesMoreItems)
            }
        }
    }

    /// Busy: a save (or another operation) is running.
    @Test func aBusyDocumentTakesNoMoreItems() throws {
        try withSession { document in
            document.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
            #expect(!document.takesMoreItems)
            document.state.progress = nil
            #expect(document.takesMoreItems)
        }
    }

    /// Split saved: Save To semantics leave it untitled, but the user did save it.
    @Test func aSplitSavedDocumentTakesNoMoreItems() throws {
        try withSession { document in
            document.savedSplitSet = true
            #expect(!document.takesMoreItems)
        }
    }

    @Test func aRemovedDocumentTakesNoMoreItems() throws {
        try withSession { document in
            NSDocumentController.shared.removeDocument(document)
            #expect(!document.takesMoreItems)
        }
    }

    @Test func aClosedDocumentTakesNoMoreItems() throws {
        let document = try #require(ArchiveDocument.makeNewArchiveSession(display: false))
        document.close()
        #expect(!NSDocumentController.shared.documents.contains { $0 === document })
        #expect(!document.takesMoreItems)
    }
}

/// An open request (a Dock drop, Open With, `open`) counts as use as soon as
/// `AppDelegate.application(_:open:)` gets it, so a Services job's queue that drains after a
/// Services-only launch doesn't quit the app under the window the request opens.
@Suite @MainActor struct OpenRequestQuitRuleTests {
    private func quits(_ flag: ServicesLaunchFlag) -> Bool {
        ServicesJobQueue.shouldQuit(ServicesQuitState(flag: flag, hasDocumentWindows: false,
                                                      hasVisiblePanels: false, hasModal: false))
    }

    @Test func anOpenRequestKeepsTheAppAfterAServicesJob() throws {
        // A delegate the app never launched: nothing but its launch flag is touched. The URL isn't
        // a file, so the request opens nothing.
        let delegate = AppDelegate()
        var untouched = delegate.launchFlag
        untouched.finishLaunching(isDefault: false)
        #expect(quits(untouched))

        delegate.application(NSApplication.shared, open: [try #require(URL(string: "https://example.com/a.txt"))])
        var used = delegate.launchFlag
        used.finishLaunching(isDefault: false)
        #expect(used.userActivated)
        #expect(!quits(used))
    }
}
