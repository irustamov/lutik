import Foundation
import Testing
import KernirCore
import os
import UIKit
@testable import Kernir

/// Extract Here on iPhone and iPad (issue 01, "iOS / iPadOS (reduced)"): ScreenState plans with
/// `ExtractHerePlan`, writes next to the archive through `ExtractHereService` (never replacing:
/// `UniquePlacement`), and asks for the archive's folder in the Files picker until
/// `FolderAccessStore` holds a grant that covers it.
///
/// Extract Here, including its being off for archives in tmp/ and Documents/Inbox, is covered; the follow-ups
/// stay disabled until what they wait on lands. Each doc comment says what the test asserts and the
/// mutants it must kill. The helpers clear `extractHereExcludedFolders`: fixtures sit in tmp.
/// Kept apart from ScreenStateTests, with its own
/// `open`/`openLive`.
/// Serialized: `ArchiveDocument.engine` is a process-wide test seam.
@MainActor @Suite(.serialized) final class ExtractHereTests {
    /// Opens `fixture` (copied, optionally renamed) with a fake engine listing `reader`'s entries.
    /// `keepingExcludedFolders` leaves the app's own `extractHereExcludedFolders` in place.
    private func open(_ fixture: String = "zip/deflate.zip", as name: String? = nil,
                      reader: FakeReader = FakeReader(entries: SampleArchive().entries),
                      keepingExcludedFolders: Bool = false) async throws -> ScreenState {
        let url = try Fixture.copy(fixture, as: name)
        ArchiveDocument.engine = FakeEngine(reader: { url in
            FakeReader(entries: reader.entries, format: reader.format, url: url, isEncrypted: reader.isEncrypted,
                       failure: reader.failure, failureAfter: reader.failureAfter,
                       extractDelay: reader.extractDelay)
        }).engine
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        #expect(document.session.model != nil)
        let state = ScreenState(document: document)
        // Fixture.copy puts the archive in tmp, which Extract Here leaves out.
        if !keepingExcludedFolders { state.extractHereExcludedFolders = [] }
        return state
    }

    /// Opens a copy of `fixture` with KernirCore's real engine.
    private func openLive(_ fixture: String) async throws -> ScreenState {
        ArchiveDocument.engine = .live
        let document = ArchiveDocument(fileURL: try Fixture.copy(fixture))
        #expect(await document.openOnMain())
        #expect(document.session.model != nil)
        let state = ScreenState(document: document)
        // Fixture.copy puts the archive in tmp, which Extract Here leaves out.
        state.extractHereExcludedFolders = []
        return state
    }

    /// A folder-access store on `defaults` with fake bookmarks, scope and volumes. A second store
    /// on the same defaults stands for the app after a relaunch.
    private func makeStore(_ defaults: UserDefaults, bookmarks: FakeBookmarks, scope: FakeScope,
                           volumes: FakeVolumes) -> FolderAccessStore {
        FolderAccessStore(defaults: defaults, key: "ExtractHereTests", coder: bookmarks, scope: scope.scope,
                          volumes: volumes.volumes)
    }

    // MARK: - Helpers

    /// A folder-access store with fakes on a defaults suite of the test's own; `remove()` deletes
    /// the suite.
    private struct Grants {
        let store: FolderAccessStore
        let bookmarks: FakeBookmarks
        let scope: FakeScope
        let volumes: FakeVolumes
        let defaults: UserDefaults
        let suite: String

        func remove() { removeTestDefaults(defaults, suite: suite) }
    }

    /// `Grants` with `makeStore`, or with `paths` and `ownContainer` when given.
    private func makeGrants(paths: PathStatus? = nil, ownContainer: URL? = nil) -> Grants {
        let (defaults, suite) = makeTestDefaults("ExtractHereTests")
        let bookmarks = FakeBookmarks(), scope = FakeScope(), volumes = FakeVolumes()
        let store = paths == nil && ownContainer == nil
            ? makeStore(defaults, bookmarks: bookmarks, scope: scope, volumes: volumes)
            : FolderAccessStore(defaults: defaults, key: "ExtractHereTests", coder: bookmarks, scope: scope.scope,
                                volumes: volumes.volumes, paths: paths ?? .system, ownContainer: ownContainer)
        return Grants(store: store, bookmarks: bookmarks, scope: scope, volumes: volumes, defaults: defaults, suite: suite)
    }

    /// The archive's folder.
    private func folder(of state: ScreenState) -> URL {
        state.document.fileURL.deletingLastPathComponent()
    }

    /// The names in `folder`, hidden ones included.
    private func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    /// Polls until `condition` holds, for up to about five seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Where it writes

    /// zip/macos-finder.zip (live), its folder granted: `extractHere(nil)` writes "Project" next
    /// to the archive (docs/readme.md, hello.txt), no "__MACOSX", nothing else new in the folder;
    /// no picker request, no alert; the grant's scope started once and stopped once.
    /// Mutants: extracting into the grant's folder instead of the archive's; skipping the plan
    /// (a wrapper folder for one item); leaving the scope started.
    @Test func extractHereWithGrantWritesNextToArchive() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await openLive("zip/macos-finder.zip")
        let folder = folder(of: state)
        try grants.store.grant(folder)
        state.folderAccessStore = grants.store
        #expect(state.canExtractHere)

        await state.extractHere(nil)
        #expect(names(in: folder) == ["macos-finder.zip", "Project"])
        #expect(names(in: folder.appendingPathComponent("Project")) == ["docs", "hello.txt"])
        #expect(names(in: folder.appendingPathComponent("Project/docs")) == ["readme.md"])
        #expect(state.extractHereRequest == nil)
        #expect(state.presentedAlert == nil)
        #expect(grants.scope.started(folder.path) == 1)
        #expect(grants.scope.stopped(folder.path) == 1)
    }

    /// showcase/project.zip (live), granted: everything lands in a new "project" folder next to
    /// the archive, holding LICENSE, README.md, assets, brief.pdf, cover.png, src.
    /// Mutants: no wrapper for several items; a wrapper named after the first item.
    @Test func extractHereManyItemsWrapsInArchiveNamedFolder() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await openLive("showcase/project.zip")
        let folder = folder(of: state)
        try grants.store.grant(folder)
        state.folderAccessStore = grants.store

        await state.extractHere(nil)
        #expect(names(in: folder) == ["project.zip", "project"])
        #expect(names(in: folder.appendingPathComponent("project"))
                == ["LICENSE", "README.md", "assets", "brief.pdf", "cover.png", "src"])
        #expect(state.presentedAlert == nil)
    }

    /// single/hello.txt.gz (live), granted: a file "hello.txt" next to the archive, not a folder.
    /// Mutant: wrapping a single stream in a folder.
    @Test func extractHereSingleStreamGivesFile() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await openLive("single/hello.txt.gz")
        let folder = folder(of: state)
        try grants.store.grant(folder)
        state.folderAccessStore = grants.store

        await state.extractHere(nil)
        #expect(names(in: folder) == ["hello.txt.gz", "hello.txt"])
        var isDirectory: ObjCBool = true
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("hello.txt").path,
                                               isDirectory: &isDirectory))
        #expect(!isDirectory.boolValue)
    }

    /// "Project" already next to macos-finder.zip, granted: the new one is "Project 2" and the
    /// old one is untouched (same contents); no conflict question (`extractionQuestion` nil).
    /// Mutants: replacing; asking as Extract To… does.
    @Test func extractHereTakenNameGetsSuffix() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await openLive("zip/macos-finder.zip")
        let folder = folder(of: state)
        let existing = folder.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try Data("mine".utf8).write(to: existing.appendingPathComponent("mine.txt"))
        try grants.store.grant(folder)
        state.folderAccessStore = grants.store

        await state.extractHere(nil)
        #expect(names(in: folder) == ["macos-finder.zip", "Project", "Project 2"])
        #expect(names(in: existing) == ["mine.txt"])
        #expect(try Data(contentsOf: existing.appendingPathComponent("mine.txt")) == Data("mine".utf8))
        #expect(names(in: folder.appendingPathComponent("Project 2")) == ["docs", "hello.txt"])
        #expect(state.extractionQuestion == nil)
        #expect(state.pendingExtraction == nil)
    }

    /// In select mode with "src" and "src/main.swift" selected (fake engine), only "src" is
    /// extracted (`extractTargets()`, topmost only), as a folder next to the archive.
    /// Mutant: passing the raw selection, which writes main.swift twice.
    @Test func extractHereSelectionUsesTopmost() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        try grants.store.grant(folder)
        state.folderAccessStore = grants.store
        state.isSelecting = true
        state.selection = ["src", "src/main.swift"]
        #expect(state.extractTargets() == ["src"])

        await state.extractHere(state.extractTargets())
        #expect(names(in: folder) == ["deflate.zip", "src"])
        #expect(names(in: folder.appendingPathComponent("src")) == ["main.swift", "utils.swift"])
    }

    // MARK: - Asking for the folder

    /// No grant: `extractHere(nil)` sets the request to `.grant` with the archive's folder as the
    /// picker's default directory; nothing is written, no progress.
    /// Mutants: extracting without a grant; another default directory (the grant's, Documents).
    @Test func extractHereWithoutGrantAsksForFolder() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        state.folderAccessStore = grants.store

        await state.extractHere(nil)
        #expect(state.extractHereRequest == ExtractHereRequest(step: .grant, paths: nil, folder: folder))
        #expect(state.extractHereAlert == nil)
        #expect(state.canExtractHere == false)
        #expect(names(in: folder) == ["deflate.zip"])
        #expect(state.progress == nil)
    }

    /// The picker returns the archive's folder, then (a fresh state) its parent: each is granted
    /// (`store.grants`) and the extraction runs next to the archive; the request is cleared.
    /// Mutants: granting only an exact match; extracting into the picked folder.
    @Test func extractHerePickOfArchiveFolderOrAncestorGrantsAndExtracts() async throws {
        for pickParent in [false, true] {
            let grants = makeGrants()
            defer { grants.remove() }
            let state = try await open()
            let folder = folder(of: state)
            state.folderAccessStore = grants.store
            await state.extractHere(nil)
            #expect(state.extractHereRequest?.step == .grant)

            let picked = pickParent ? folder.deletingLastPathComponent() : folder
            await state.extractHereFolderPicked(picked)
            #expect(grants.store.grants.map(\.standardizedFileURL.path) == [picked.standardizedFileURL.path])
            #expect(state.extractHereRequest == nil)
            #expect(names(in: folder) == ["deflate.zip", "deflate"])
            #expect(state.presentedAlert == nil)
            #expect(grants.scope.isBalanced)
        }
    }

    /// The picker returns a sibling folder: no grant saved, nothing written, the alert "That folder
    /// doesn't contain “X”."; OK takes the alert away, and once it has gone the picker is asked for
    /// again (`.grant`).
    /// Mutants: granting any pick; a string-prefix check (/a/b vs /a/bc); OK moving on to the
    /// picker while the alert is still up.
    @Test func extractHerePickOutsideAsksAgain() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        state.folderAccessStore = grants.store
        // A sibling whose name starts with the archive folder's.
        let sibling = URL(fileURLWithPath: folder.path + "c", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: sibling) }

        await state.extractHere(nil)
        await state.extractHereFolderPicked(sibling)
        #expect(grants.store.grants.isEmpty)
        #expect(names(in: folder) == ["deflate.zip"])
        #expect(names(in: sibling).isEmpty)
        #expect(state.extractHereRequest?.step == .notContaining)
        #expect(state.extractHereAlert?.title == "That folder doesn't contain “\(folder.lastPathComponent)”.")

        state.pickAgainForExtractHere()
        #expect(state.extractHereAlert == nil)
        #expect(state.extractHereRequest?.step == .notContaining)
        state.extractHereAlertDidDismiss()
        #expect(state.extractHereRequest == ExtractHereRequest(step: .grant, paths: nil, folder: folder))
    }

    /// The archive moved while the picker was up: the request's folder (here the sibling "…c")
    /// is where it was, not where it is. Picking the folder it is in now grants that folder and
    /// extracts there, with no alert.
    /// Mutants: checking the pick against the request's stale folder (the wrong-folder alert);
    /// extracting into the stale folder.
    @Test func extractHerePickOfTheArchivesFolderNowExtracts() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        state.folderAccessStore = grants.store
        let sibling = URL(fileURLWithPath: folder.path + "c", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: sibling) }

        await state.extractHere(nil)
        state.extractHereRequest?.folder = sibling
        await state.extractHereFolderPicked(folder)
        #expect(grants.store.grants.map(\.standardizedFileURL.path) == [folder.standardizedFileURL.path])
        #expect(state.extractHereRequest == nil)
        #expect(state.extractHereAlert == nil)
        #expect(state.presentedAlert == nil)
        #expect(names(in: folder) == ["deflate.zip", "deflate"])
        #expect(names(in: sibling).isEmpty)
        #expect(grants.scope.isBalanced)
    }

    /// The same move, and the pick is the folder the archive was in: no grant saved, nothing
    /// written, and the wrong-folder alert names the folder the archive is in now; dismissing it
    /// asks for that folder (`.grant`).
    /// Mutants: granting the stale folder; the alert naming the stale folder.
    @Test func extractHerePickOfTheArchivesOldFolderAsksAgain() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        state.folderAccessStore = grants.store
        let sibling = URL(fileURLWithPath: folder.path + "c", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: sibling) }

        await state.extractHere(nil)
        state.extractHereRequest?.folder = sibling
        await state.extractHereFolderPicked(sibling)
        #expect(grants.store.grants.isEmpty)
        #expect(names(in: folder) == ["deflate.zip"])
        #expect(names(in: sibling).isEmpty)
        #expect(state.extractHereRequest == ExtractHereRequest(step: .notContaining, paths: nil, folder: folder))
        #expect(state.extractHereAlert?.title == "That folder doesn't contain “\(folder.lastPathComponent)”.")

        state.pickAgainForExtractHere()
        #expect(state.extractHereAlert == nil)
        #expect(state.extractHereRequest?.step == .notContaining)
        state.extractHereAlertDidDismiss()
        #expect(state.extractHereRequest == ExtractHereRequest(step: .grant, paths: nil, folder: folder))
        #expect(grants.scope.isBalanced)
    }

    /// The pick is granted, but access to it won't start (`FakeScope.refuse`): nothing is written,
    /// the request is cleared and the alert says why, with Extract's title and "The folder you
    /// chose couldn't be opened. Try again."; the grant stays.
    /// Mutant: bringing the picker back with no alert (a loop with no reason given).
    @Test func extractHerePickWhoseAccessWontStartSaysSo() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        state.folderAccessStore = grants.store
        grants.scope.refuse(folder.path)

        await state.extractHere(nil)
        await state.extractHereFolderPicked(folder)
        let topLevel = try #require(state.model).items.count
        #expect(state.extractHereRequest == nil)
        #expect(state.presentedAlert?.title == "Couldn't extract \(topLevel) items")
        #expect(state.presentedAlert?.message == "The folder you chose couldn't be opened. Try again.")
        #expect(names(in: folder) == ["deflate.zip"])
        #expect(grants.store.grants.map(\.standardizedFileURL.path) == [folder.standardizedFileURL.path])
        #expect(grants.scope.isBalanced)
    }

    /// A save starts while the picker is up (`.grant`, then `.otherFolder` after a read-only
    /// error): the pick extracts nothing and the alert says so, with Extract's title and "The
    /// archive is being saved. Try again."; the request is cleared. As Add says (`isBusy`).
    /// Mutant: returning silently after the pick when the gate is off.
    @Test func extractHerePickWhileSavingSaysSo() async throws {
        do {
            let grants = makeGrants()
            defer { grants.remove() }
            let state = try await open()
            let folder = folder(of: state)
            state.folderAccessStore = grants.store
            await state.extractHere(nil)
            #expect(state.extractHereRequest?.step == .grant)

            state.session.saveFraction = 0.5
            await state.extractHereFolderPicked(folder)
            let topLevel = try #require(state.model).items.count
            #expect(state.presentedAlert?.title == "Couldn't extract \(topLevel) items")
            #expect(state.presentedAlert?.message == "The archive is being saved. Try again.")
            #expect(state.extractHereRequest == nil)
            #expect(names(in: folder) == ["deflate.zip"])
            #expect(grants.scope.isBalanced)
            state.session.saveFraction = nil
        }
        do {
            let grants = makeGrants()
            defer { grants.remove() }
            let state = try await open()
            let folder = folder(of: state)
            try grants.store.grant(folder)
            state.folderAccessStore = grants.store
            state.extractHereRun = readOnlyArchiveFolder(folder)
            let other = FileManager.default.temporaryDirectory
                .appendingPathComponent("ExtractHereOther-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: other) }
            await state.extractHere(nil)
            state.chooseAnotherFolderForExtractHere()
            state.extractHereAlertDidDismiss()
            #expect(state.extractHereRequest?.step == .otherFolder)

            state.session.saveFraction = 0.5
            await state.extractHereFolderPicked(other)
            let topLevel = try #require(state.model).items.count
            #expect(state.presentedAlert?.title == "Couldn't extract \(topLevel) items")
            #expect(state.presentedAlert?.message == "The archive is being saved. Try again.")
            #expect(state.extractHereRequest == nil)
            #expect(names(in: other).isEmpty)
            #expect(names(in: folder) == ["deflate.zip"])
            state.session.saveFraction = nil
        }
    }

    /// The picker is cancelled: no grant, nothing written, no alert, the request cleared.
    /// Mutant: treating a cancel as a pick of the default directory.
    @Test func extractHereGrantCancelExtractsNothing() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        state.folderAccessStore = grants.store

        await state.extractHere(nil)
        await state.extractHereFolderPicked(nil)
        #expect(state.extractHereRequest == nil)
        #expect(grants.store.grants.isEmpty)
        #expect(names(in: folder) == ["deflate.zip"])
        #expect(state.presentedAlert == nil)
        #expect(state.canExtractHere)
    }

    /// A grant on the archive's folder, then a new store on the same defaults (a relaunch) and an
    /// archive in a subfolder of it: silent, no request.
    /// Mutants: grants kept in memory only; an exact-folder match.
    @Test func extractHereGrantIsKeptForSubfolder() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        try grants.store.grant(folder.deletingLastPathComponent())
        let relaunched = makeStore(grants.defaults, bookmarks: grants.bookmarks, scope: grants.scope,
                                   volumes: grants.volumes)
        state.folderAccessStore = relaunched

        await state.extractHere(nil)
        #expect(state.extractHereRequest == nil)
        #expect(names(in: folder) == ["deflate.zip", "deflate"])
    }

    /// A grant whose folder is gone (`markDead`, nothing at its path, its volume mounted): asks
    /// again (`.grant`) and the dead grant is dropped.
    /// Mutant: trusting a stored grant without `access(for:)`.
    @Test func extractHereGoneGrantAsksAgain() async throws {
        let grants = makeGrants(paths: PathStatus(lstatErrno: { _ in ENOENT }))
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        try grants.store.grant(folder)
        grants.bookmarks.markDead(folder.path)
        state.folderAccessStore = grants.store

        await state.extractHere(nil)
        #expect(state.extractHereRequest?.step == .grant)
        #expect(grants.store.grants.isEmpty)
        #expect(names(in: folder) == ["deflate.zip"])
    }

    /// The archive in the app's own container (store made with the fixture's parent as the
    /// container): silent, no request, no grant saved, no scope started.
    /// Mutants: asking anyway; saving a grant for it.
    @Test func extractHereInOwnContainerIsSilent() async throws {
        let state = try await open()
        let folder = folder(of: state)
        let grants = makeGrants(ownContainer: folder.deletingLastPathComponent())
        defer { grants.remove() }
        state.folderAccessStore = grants.store

        await state.extractHere(nil)
        #expect(state.extractHereRequest == nil)
        #expect(grants.store.grants.isEmpty)
        #expect(grants.scope.started(folder.path) == 0)
        #expect(grants.bookmarks.bookmarksMade == 0)
        #expect(names(in: folder) == ["deflate.zip", "deflate"])
    }

    // MARK: - Cancel, failure, read-only

    /// A slow fake extraction cancelled from the progress sheet: the folder holds only the archive
    /// (no "Project", no hidden ".kernir-*" staging); no failure alert.
    /// Mutants: no staging cleanup on cancel; reporting the cancel as a failure.
    @Test func extractHereCancelLeavesNoStaging() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open(reader: FakeReader(entries: SampleArchive().entries, extractDelay: .seconds(30)))
        let folder = folder(of: state)
        try grants.store.grant(folder)
        state.folderAccessStore = grants.store

        let run = Task { await state.extractHere(nil) }
        try await waitUntil { state.progress != nil }
        let cancel = try #require(state.progress?.cancel)
        cancel()
        await run.value
        #expect(names(in: folder) == ["deflate.zip"])
        #expect(state.presentedAlert == nil)
        #expect(grants.scope.isBalanced)
    }

    /// A fake reader failing after the first entry: the failure alert (Extract's title) and the
    /// folder holds only the archive.
    /// Mutant: a half-written item left next to the archive.
    @Test func extractHereFailureLeavesNoStaging() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let damage = ArchiveError.corrupted("CRC mismatch in src/utils.swift")
        let state = try await open(reader: FakeReader(entries: SampleArchive().entries, failure: damage, failureAfter: 1))
        let folder = folder(of: state)
        try grants.store.grant(folder)
        state.folderAccessStore = grants.store

        await state.extractHere(nil)
        #expect(names(in: folder) == ["deflate.zip"])
        let topLevel = try #require(state.model).items.count
        #expect(state.presentedAlert?.title == "Couldn't extract \(topLevel) items")
        #expect(state.extractHereRequest == nil)
    }

    /// `extractHereRun` throwing EROFS for the archive's folder, else extracting.
    private func readOnlyArchiveFolder(_ folder: URL) -> ExtractHereRun {
        { plan, model, directory, progress in
            if directory.standardizedFileURL.path == folder.standardizedFileURL.path {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))
            }
            return try await ExtractHereService.extract(plan, from: model, in: directory, progress: progress)
        }
    }

    /// The run seam throws EROFS: the alert "“X” is on a read-only volume." with "Choose Another
    /// Folder…" and Cancel; Cancel writes nothing and asks nothing more.
    /// Mutants: the generic failure alert; no way to pick another folder.
    @Test func extractHereReadOnlyOffersAnotherFolder() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        try grants.store.grant(folder)
        state.folderAccessStore = grants.store
        state.extractHereRun = readOnlyArchiveFolder(folder)

        await state.extractHere(nil)
        #expect(state.extractHereRequest?.step == .readOnly)
        #expect(state.extractHereAlert?.title == "“\(folder.lastPathComponent)” is on a read-only volume.")
        #expect(state.presentedAlert == nil)

        state.cancelExtractHere()
        #expect(state.extractHereRequest == nil)
        #expect(state.extractHereAlert == nil)
        #expect(names(in: folder) == ["deflate.zip"])
    }

    /// The safety net: a picker that never came up, or went without a pick or a
    /// cancel, leaves the request waiting on it, and Extract Here off. `extractHerePickerDidClose`
    /// cancels a `.grant` or `.otherFolder` request, so Extract Here is on again; it leaves the
    /// alerts' questions alone, answered or not.
    /// Mutants: the safety net doing nothing (Extract Here off until the archive is reopened); it
    /// clearing a question, or an answer whose picker comes once the alert has gone.
    @Test func extractHerePickerThatNeverAnsweredIsCancelled() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        state.folderAccessStore = grants.store

        await state.extractHere(nil)
        #expect(state.extractHereRequest?.step == .grant)
        #expect(!state.canExtractHere)
        state.extractHerePickerDidClose()
        #expect(state.extractHereRequest == nil)
        #expect(state.canExtractHere)

        await state.extractHere(nil)
        await state.extractHereFolderPicked(folder.deletingLastPathComponent().appendingPathComponent("elsewhere"))
        #expect(state.extractHereRequest?.step == .notContaining)
        state.extractHerePickerDidClose()
        #expect(state.extractHereRequest?.step == .notContaining)
        state.pickAgainForExtractHere()
        state.extractHerePickerDidClose()
        #expect(state.extractHereRequest?.step == .notContaining)
        #expect(state.extractHereAlert == nil)
        state.extractHereAlertDidDismiss()
        #expect(state.extractHereRequest?.step == .grant)
        state.extractHerePickerDidClose()
        #expect(state.extractHereRequest == nil)

        try grants.store.grant(folder)
        state.extractHereRun = readOnlyArchiveFolder(folder)
        await state.extractHere(nil)
        #expect(state.extractHereRequest?.step == .readOnly)
        state.extractHerePickerDidClose()
        #expect(state.extractHereRequest?.step == .readOnly)
        state.chooseAnotherFolderForExtractHere()
        state.extractHereAlertDidDismiss()
        #expect(state.extractHereRequest?.step == .otherFolder)
        state.extractHerePickerDidClose()
        #expect(state.extractHereRequest == nil)
        #expect(state.canExtractHere)
        #expect(names(in: folder) == ["deflate.zip"])
        #expect(grants.scope.isBalanced)
    }

    /// After the read-only alert, "Choose Another Folder…" (the picker once the alert has gone) and a
    /// pick: the result lands in the picked folder (`ExtractHereService.extract(_:from:in:)`), and no
    /// grant is saved for it.
    /// Mutants: extracting next to the archive again; granting the other folder; the picker asked
    /// for while the alert is still up.
    @Test func extractHereOtherFolderGetsTheResult() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        try grants.store.grant(folder)
        state.folderAccessStore = grants.store
        state.extractHereRun = readOnlyArchiveFolder(folder)
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractHereOther-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: other) }

        await state.extractHere(nil)
        state.chooseAnotherFolderForExtractHere()
        #expect(state.extractHereAlert == nil)
        #expect(state.extractHereRequest?.step == .readOnly)
        state.extractHereAlertDidDismiss()
        #expect(state.extractHereRequest?.step == .otherFolder)
        await state.extractHereFolderPicked(other)
        #expect(state.extractHereRequest == nil)
        #expect(names(in: other) == ["deflate"])
        #expect(names(in: folder) == ["deflate.zip"])
        #expect(grants.store.grants.map(\.standardizedFileURL.path) == [folder.standardizedFileURL.path])
        #expect(state.presentedAlert == nil)
    }

    // MARK: - Gate

    /// `canExtractHere` is false with no model, while saving, with a picker request, a conflict
    /// question or its pending extraction after the answer, an Add's Replace question, progress up,
    /// an operation running before its progress sheet comes up, and when the plan is empty (select
    /// mode, nothing selected); true otherwise. False for an archive in an excluded
    /// folder (tmp/, Documents/Inbox, here the fixture's folder injected), while Extract To…'s
    /// targets stay everything; true again with the excluded folder elsewhere.
    /// Mutants: each condition dropped in turn.
    @Test func canExtractHereGates() async throws {
        let unopened = ScreenState(document: ArchiveDocument(fileURL: try Fixture.copy("zip/deflate.zip")))
        unopened.extractHereExcludedFolders = []
        #expect(unopened.model == nil)
        #expect(unopened.canExtractHere == false)

        let state = try await open()
        let folder = folder(of: state)
        #expect(state.canExtractHere)

        state.session.saveFraction = 0.5
        #expect(state.canExtractHere == false)
        state.session.saveFraction = nil
        #expect(state.canExtractHere)

        state.extractHereRequest = ExtractHereRequest(step: .grant, paths: nil, folder: folder)
        #expect(state.canExtractHere == false)
        state.extractHereRequest = nil

        let pending = PendingExtraction(paths: nil, folder: folder, folderName: folder.lastPathComponent,
                                        scan: ExtractionConflictScan(conflicts: ["README.md"]))
        #expect(state.extractionQuestions.start(pending) { _ in })
        #expect(state.extractionQuestion != nil)
        #expect(state.canExtractHere == false)
        // Answered: the question goes, the extraction still waits for the alert to go.
        state.answerExtractionConflict(.skip, at: 0)
        #expect(state.extractionQuestion == nil)
        #expect(state.pendingExtraction != nil)
        #expect(state.canExtractHere == false)
        state.cancelExtraction()
        #expect(state.canExtractHere)

        state.pendingReplacement = PendingReplacement(urls: [], directory: "", conflicts: ["README.md"])
        #expect(state.canExtractHere == false)
        state.pendingReplacement = nil
        #expect(state.canExtractHere)

        state.progress = OperationProgress(title: "Extracting")
        #expect(state.canExtractHere == false)
        state.progress = nil

        // A preview or share preparing: running, its sheet not up yet.
        let running = Task {
            try await state.perform("P", showingAfter: .seconds(10)) { _ in try await Task.sleep(for: .seconds(30)) }
        }
        try await waitUntil { state.runningOperations == 1 }
        #expect(state.runningOperations == 1)
        #expect(state.progress == nil)
        #expect(state.canExtractHere == false)
        running.cancel()
        _ = await running.result
        #expect(state.runningOperations == 0)
        #expect(state.canExtractHere)

        state.isSelecting = true
        #expect(state.extractTargets() == [])
        #expect(state.canExtractHere == false)
        state.selection = ["README.md"]
        #expect(state.canExtractHere)
        state.isSelecting = false
        #expect(state.canExtractHere)

        // The archive's folder stands in for tmp/ or Documents/Inbox.
        state.extractHereExcludedFolders = [folder]
        #expect(state.canExtractHere == false)
        #expect(state.extractTargets() == nil)
        state.extractHereExcludedFolders = [folder.deletingLastPathComponent()]
        #expect(state.canExtractHere == false)
        let sibling = URL(fileURLWithPath: folder.path + "c", isDirectory: true)
        state.extractHereExcludedFolders = [sibling]
        #expect(state.canExtractHere)
    }

    /// `extractHere(nil)` on an archive in an excluded folder (a Mail or Share copy)
    /// writes nothing, raises no `.grant` request and shows no alert, without a grant and with one;
    /// covers ⌥⌘E and stray calls, which skip the menu's disabled item.
    /// Mutant: `extractHere` not guarding on `canExtractHere`.
    @Test func extractHereFromIncomingCopyDoesNothing() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        state.folderAccessStore = grants.store
        state.extractHereExcludedFolders = [folder]

        await state.extractHere(nil)
        #expect(state.extractHereRequest == nil)
        #expect(state.presentedAlert == nil)
        #expect(names(in: folder) == ["deflate.zip"])

        try grants.store.grant(folder)
        await state.extractHere(nil)
        #expect(state.extractHereRequest == nil)
        #expect(state.presentedAlert == nil)
        #expect(names(in: folder) == ["deflate.zip"])
        #expect(grants.scope.started(folder.path) == 0)
    }

    /// As shipped: without the helpers' override, `extractHereExcludedFolders` is
    /// `ExtractHereLocation.excludedFolders` (tmp/ and Documents/Inbox), so the fixture (in tmp) gets
    /// no Extract Here; with the list emptied it does.
    /// Mutant: the production default `[]`.
    @Test func extractHereExcludesTmpAndInboxByDefault() async throws {
        let state = try await open(keepingExcludedFolders: true)
        #expect(state.extractHereExcludedFolders.map(\.standardizedFileURL.path)
                == ExtractHereLocation.excludedFolders.map(\.standardizedFileURL.path))
        #expect(state.canExtractHere == false)
        state.extractHereExcludedFolders = []
        #expect(state.canExtractHere)
    }

    /// The archive moves out of an excluded folder while open (Files' Move):
    /// UIDocument's `fileURL` changes, `fileURLChanges` grows, a view reading `canExtractHere` is
    /// told, and it turns on. The wait is on `fileURLChanges` itself, not only on the view being
    /// told: `onChange` fires for any property `canExtractHere` reads, so a late, unrelated change
    /// could tell the view even with no observation of `fileURL`.
    /// Mutants: no observation of `fileURL` (the menus stay off until something else redraws them);
    /// a location cache that ignores the URL.
    @Test func canExtractHereFollowsAMove() async throws {
        let state = try await open()
        let folder = folder(of: state)
        state.extractHereExcludedFolders = [folder]
        #expect(state.canExtractHere == false)
        let changesBefore = state.fileURLChanges
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = state.canExtractHere } onChange: { changed.withLock { $0 = true } }

        let moved = folder.deletingLastPathComponent()
            .appendingPathComponent("ExtractHereMoved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: moved) }
        let newURL = moved.appendingPathComponent(state.document.fileURL.lastPathComponent)
        try FileManager.default.moveItem(at: state.document.fileURL, to: newURL)
        state.document.presentedItemDidMove(to: newURL)
        try await waitUntil { state.fileURLChanges > changesBefore && changed.withLock { $0 } }
        #expect(state.fileURLChanges > changesBefore)
        #expect(changed.withLock { $0 })
        #expect(state.document.fileURL.standardizedFileURL.path == newURL.standardizedFileURL.path)
        #expect(state.canExtractHere)
    }

    /// ⌥⌘E: the navigation controller takes Extract Here only while `canExtractHere`
    /// (not without a document, not for an archive in an excluded folder, not while its picker is
    /// up), and performing it runs Extract Here on the targets: here the `.grant` request.
    /// Mutants: validating ⌥⌘E like Extract To… (on in an excluded folder); ⌥⌘E doing nothing. Not
    /// killed here: `extractHere(_:)` performing past its own gate, since `ScreenState.extractHere(_:)`
    /// checks `canExtractHere` again (that guard is `extractHereFromIncomingCopyDoesNothing`'s).
    @Test func extractHereCommandFollowsTheGate() async throws {
        let action = #selector(ArchiveNavigationController.extractHere(_:))
        let none = ArchiveNavigationController(rootViewController: UIViewController())
        #expect(!none.canPerformAction(action, withSender: nil))

        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        state.folderAccessStore = grants.store
        let navigation = ArchiveNavigationController(rootViewController: UIViewController())
        navigation.screenState = state

        state.extractHereExcludedFolders = [folder]
        #expect(!navigation.canPerformAction(action, withSender: nil))
        navigation.extractHere(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.extractHereRequest == nil)

        state.extractHereExcludedFolders = []
        #expect(navigation.canPerformAction(action, withSender: nil))
        navigation.extractHere(nil)
        try await waitUntil { state.extractHereRequest != nil }
        #expect(state.extractHereRequest == ExtractHereRequest(step: .grant, paths: nil, folder: folder))
        #expect(!navigation.canPerformAction(action, withSender: nil))
    }

    // MARK: - The alert's hand-off

    /// The read-only question is asked the moment the extraction fails, while its progress sheet is
    /// still going away: its alert waits until the sheet has gone, and for another alert or the Mac
    /// metadata question. Published earlier, UIKit would drop it and, the condition staying true,
    /// never retry it: Extract Here off until the archive is opened again.
    /// Mutants: `canShowExtractHereAlert` checking `activeProgress` only (true while the sheet goes);
    /// leaving out `presentedAlert` or `macMetadataQuestion`; true after the answer.
    @Test func extractHereAlertWaitsForTheSheetAndOtherQuestions() async throws {
        let state = try await open()
        let folder = folder(of: state)
        #expect(!state.canShowExtractHereAlert, "no question")

        // The extraction's sheet is up; its operation fails as read-only and the sheet goes.
        state.session.saveFraction = 0
        state.progressSheetDidAppear()
        state.session.saveFraction = nil
        state.extractHereRequest = ExtractHereRequest(step: .readOnly, paths: nil, folder: folder)
        #expect(state.extractHereAlert != nil)
        #expect(!state.canShowExtractHereAlert, "the sheet is still going away")
        state.session.saveFraction = 0
        #expect(!state.canShowExtractHereAlert, "a sheet is asked for")
        state.session.saveFraction = nil
        state.progressSheetDidDismiss()
        #expect(state.canShowExtractHereAlert, "the sheet has gone")

        state.macMetadataQuestion = true
        #expect(!state.canShowExtractHereAlert, "the Mac metadata question is up")
        state.macMetadataQuestion = false
        #expect(state.canShowExtractHereAlert)

        state.alert = AlertContent(title: "Other", message: "")
        #expect(!state.canShowExtractHereAlert, "another alert is up")
        state.dismissAlert()
        #expect(state.canShowExtractHereAlert)

        state.extractHereAlertFallback = nil
        state.chooseAnotherFolderForExtractHere()
        #expect(!state.canShowExtractHereAlert, "answered")
        state.cancelExtractHere()
        #expect(!state.canShowExtractHereAlert)
    }

    /// Extract Here stays off while an alert or the Mac metadata question is up, and a pick that
    /// comes back meanwhile extracts nothing (`isReadyForExtractHere`).
    /// Mutants: the gate without `macMetadataQuestion` or `presentedAlert`.
    @Test func extractHereWaitsForAlertsAndTheMacMetadataQuestion() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        state.folderAccessStore = grants.store
        #expect(state.canExtractHere)

        state.macMetadataQuestion = true
        #expect(!state.canExtractHere)
        await state.extractHere(nil)
        #expect(state.extractHereRequest == nil)
        state.macMetadataQuestion = false
        #expect(state.canExtractHere)

        state.alert = AlertContent(title: "Other", message: "")
        #expect(!state.canExtractHere)
        await state.extractHere(nil)
        #expect(state.extractHereRequest == nil)
        state.dismissAlert()
        #expect(state.canExtractHere)

        // The pick comes back while the question is up: granted, but nothing extracted.
        await state.extractHere(nil)
        #expect(state.extractHereRequest?.step == .grant)
        state.macMetadataQuestion = true
        await state.extractHereFolderPicked(folder)
        #expect(state.extractHereRequest == nil)
        #expect(names(in: folder) == ["deflate.zip"])
        #expect(grants.scope.isBalanced)
        state.macMetadataQuestion = false
        #expect(state.canExtractHere)
    }

    /// After Choose Another Folder…, the alert's condition going false (`extractHereAlertDidGo`, from
    /// `FolderScreen`'s `onChange`) brings the picker once the settle has passed, and only once:
    /// a second signal joins the hand-off already settling, and a later `extractHereAlertDidDismiss`
    /// (the binding's setter, should UIKit call it too) does nothing. Without an answer, the signal
    /// does nothing.
    /// Mutants: the picker step taken from the setter only; `alertDidDismiss` without its
    /// `isAnswered` guard (`.otherFolder` turned into `.grant`); a second signal scheduling again.
    @Test func extractHereAnswerMovesOnOnceItsAlertHasGone() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        try grants.store.grant(folder)
        state.folderAccessStore = grants.store
        state.extractHereRun = readOnlyArchiveFolder(folder)
        state.extractHereAlertSettle = .zero
        state.extractHereAlertFallback = nil

        await state.extractHere(nil)
        #expect(state.extractHereRequest?.step == .readOnly)
        state.extractHereAlertDidGo()
        #expect(state.extractHereHandOff == nil, "not answered: the question stays")
        #expect(state.extractHereRequest?.step == .readOnly)

        state.chooseAnotherFolderForExtractHere()
        #expect(state.extractHereAlert == nil)
        #expect(state.extractHereRequest?.step == .readOnly)
        #expect(state.extractHereHandOff == nil, "no fallback")
        state.extractHereAlertDidGo()
        let handOff = try #require(state.extractHereHandOff)
        state.extractHereAlertDidGo()
        #expect(state.extractHereHandOff == handOff, "already settling")
        await handOff.value
        #expect(state.extractHereRequest?.step == .otherFolder)
        #expect(state.extractHereHandOff == nil)

        state.extractHereAlertDidDismiss()
        #expect(state.extractHereRequest?.step == .otherFolder, "once")
        state.extractHereAlertDidGo()
        #expect(state.extractHereHandOff == nil)
        #expect(state.extractHereRequest?.step == .otherFolder)
        state.cancelExtractHere()
    }

    /// Should the alert's going never be reported, the fallback brings the picker; a late signal then
    /// does nothing. Cancel stops a hand-off still waiting.
    /// Mutants: no fallback (the request stays answered: no alert, no picker); the late signal
    /// moving the request on again; Cancel leaving the hand-off to run.
    @Test func extractHereAnswerFallsBackWithoutTheSignal() async throws {
        let grants = makeGrants()
        defer { grants.remove() }
        let state = try await open()
        let folder = folder(of: state)
        state.folderAccessStore = grants.store
        state.extractHereAlertSettle = .seconds(60)
        state.extractHereAlertFallback = .zero
        let elsewhere = folder.deletingLastPathComponent().appendingPathComponent("elsewhere")

        await state.extractHere(nil)
        await state.extractHereFolderPicked(elsewhere)
        #expect(state.extractHereRequest?.step == .notContaining)
        state.pickAgainForExtractHere()
        let fallback = try #require(state.extractHereHandOff)
        await fallback.value
        #expect(state.extractHereRequest == ExtractHereRequest(step: .grant, paths: nil, folder: folder))
        state.extractHereAlertDidGo()
        #expect(state.extractHereHandOff == nil)
        #expect(state.extractHereRequest?.step == .grant)

        await state.extractHereFolderPicked(elsewhere)
        #expect(state.extractHereRequest?.step == .notContaining)
        state.extractHereAlertFallback = .seconds(60)
        state.pickAgainForExtractHere()
        let waiting = try #require(state.extractHereHandOff)
        state.cancelExtractHere()
        #expect(state.extractHereHandOff == nil)
        await waiting.value
        #expect(state.extractHereRequest == nil)
        #expect(state.canExtractHere)
    }

    // MARK: - Follow-ups

    /// An archive with "README" and "Readme" at its root (case twins): both kept next to the
    /// archive on the case-insensitive simulator volume ("Readme 2" or the like), nothing lost.
    @Test(.disabled("after ExtractHereService gets .keepBoth"))
    func extractHereKeepsCaseTwins() async throws {}

    /// A hidden ".kernir-*" staging folder from a crashed run beside the archive is swept by the
    /// next Extract Here there.
    @Test(.disabled("after ArchiveModel.sweepStaleStaging becomes internal"))
    func extractHereSweepsACrashRemnant() async throws {}

    /// `canExtractHere` is false while the archive is read again in another text encoding.
    /// Mutant: no `!isBusy` in the gate.
    @Test(.disabled("the gate has isBusy; needs a held Text Encoding reopen with a scratch encoding store"))
    func extractHereDisabledWhileTextEncodingReads() async throws {}
}
