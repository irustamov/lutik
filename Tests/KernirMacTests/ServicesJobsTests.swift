import Testing
import AppKit
import KernirCore
@testable import Kernir

/// Finder Services' jobs. Runs without the app: the runner and the queue take fakes
/// for the Allow panel, the grants, the alert, Finder and the progress panel, so no test shows a
/// panel, opens a Finder window or quits.
@MainActor
struct ServicesJobRunnerTests {
    /// What the fakes saw.
    @MainActor private final class Log {
        var works = 0
        var asks: [URL] = []
        var grants: [URL] = []
        var accesses = 0
        var starts = 0
        var stops = 0
        /// The folder each work ran in (nil: beside its items).
        var targets: [URL?] = []
        /// What "Choose Another Folder" was offered for.
        var offers: [ServicesJobFailure] = []
        /// The asks and offers, and the prompting around them.
        var events: [String] = []
        /// What went to the Trash, and how many grants were stopped by then.
        var trashed: [URL] = []
        var stopsAtTrash: [Int] = []
        /// What the open-in-Kernir check was asked about.
        var openChecks: [URL] = []
    }

    private let log = Log()

    /// A folder of its own, removed at the end of the test by the caller.
    private static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServicesJobsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static let folder = URL(fileURLWithPath: "/Users/u/Downloads", isDirectory: true)
    private static let archive = folder.appendingPathComponent("project.zip")
    private static let result = folder.appendingPathComponent("project", isDirectory: true)

    /// A runner whose work is `work` (Extract Here and Compress alike), with `granted` grants
    /// (a folder each, covering what is inside), an Allow panel that picks `pick` for its first
    /// `maxAsks` asks and then cancels, a grant that throws when `grantFails`, and a "Choose
    /// Another Folder" alert that picks `others` in turn, then cancels. Extract Here's Trash
    /// setting is `trashOn`; the archive extracted is part of a split set when `isVolumeSet`, has
    /// a Kernir window as `open` says, can't be trashed when `trashFails`, and reads as `stamp`
    /// each time (the same file throughout).
    private func runner(granted: [URL] = [], pick: URL? = nil, maxAsks: Int = .max, grantFails: Bool = false,
                        others: [URL] = [], trashOn: Bool = false, isVolumeSet: Bool = false,
                        open: ServicesOpenArchive = .notOpen, trashFails: Bool = false,
                        stamp: ServicesFileStamp? = ServicesJobRunnerTests.stamp,
                        work: @escaping @MainActor (Int) throws -> URL) -> ServicesJobRunner {
        let log = log
        var granted = granted
        let scope = SecurityScope(start: { _ in true }, stop: { _ in MainActor.assumeIsolated { log.stops += 1 } })
        return ServicesJobRunner(
            extract: { _, folder, _ in
                log.works += 1
                log.targets.append(folder)
                return ServicesExtraction(result: try work(log.works), isVolumeSet: isVolumeSet)
            },
            compress: { _, _, folder, _ in log.works += 1; log.targets.append(folder); return try work(log.works) },
            access: { destination in
                log.accesses += 1
                guard let folder = granted.first(where: { FolderAccessStore.covers($0, destination) }) else { return nil }
                log.starts += 1
                return ScopedFolder(url: folder, isAccessing: true, scope: scope)
            },
            grant: { folder in
                log.grants.append(folder)
                if grantFails { throw Self.posix(EIO) }
                granted.append(folder)
            },
            askForAccess: { destination, _ in
                log.events.append("ask")
                log.asks.append(destination)
                return log.asks.count <= maxAsks ? pick : nil
            },
            offerAnotherFolder: { failure, _ in
                log.events.append("offer")
                log.offers.append(failure)
                return log.offers.count <= others.count ? others[log.offers.count - 1] : nil
            },
            movesArchiveToTrash: { trashOn },
            openInKernir: { archive in
                log.openChecks.append(archive)
                return open
            },
            moveToTrash: { archive in
                if trashFails { throw Self.cocoa(.fileWriteNoPermission) }
                log.trashed.append(archive)
                log.stopsAtTrash.append(log.stops)
            },
            fileStamp: { _ in stamp })
    }

    /// The fake archive's stamp: it doesn't exist, so `ServicesFileStamp.of` would read nil.
    private static let stamp = ServicesFileStamp(identity: nil, size: 3, modified: Date(timeIntervalSince1970: 1_700_000_000))

    /// Prompting that logs its calls in `log.events`.
    private var prompting: ServicesPrompting {
        let log = log
        return ServicesPrompting(begin: { log.events.append("begin") }, end: { log.events.append("end") })
    }

    /// Every grant started is stopped by the time the job ends.
    private func expectBalancedAccess(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(log.starts == log.stops, "starts \(log.starts), stops \(log.stops)", sourceLocation: sourceLocation)
    }

    nonisolated private static func cocoa(_ code: CocoaError.Code, path: String? = nil) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code.rawValue,
                userInfo: path.map { [NSFilePathErrorKey: $0] } ?? [:])
    }

    nonisolated private static func posix(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static let folderName = ServicesJobRunner.displayName(of: folder)

    // MARK: Running for real

    /// Extract Here of a fixture: the result is beside the archive, nothing is asked.
    @Test(.enabled(if: Fixture.isReadable))
    func extractsAnArchiveNextToIt() async throws {
        let archive = try Fixture.copy("showcase/project.zip")
        let folder = archive.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = ServicesJobRunner(access: { _ in nil }, grant: { _ in },
                                       askForAccess: { _, _ in Issue.record("asked"); return nil })
        let outcome = await runner.run(.extractHere(archive), progress: nil)
        guard case let .done(result) = outcome else { Issue.record("\(outcome)"); return }
        #expect(result.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: result.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.hasPrefix(".kernir-") })
    }

    /// An encrypted archive is opened as a document (which asks for its password); nothing is
    /// written beside it.
    @Test(.enabled(if: Fixture.isReadable))
    func aPasswordArchiveIsOpenedForItsPassword() async throws {
        let archive = try Fixture.copy("zip/aes256.zip")
        let folder = archive.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let runner = ServicesJobRunner(access: { _ in nil }, grant: { _ in }, askForAccess: { _, _ in nil })
        #expect(await runner.run(.extractHere(archive), progress: nil) == .needsPassword(archive))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["aes256.zip"])
    }

    /// Extract Here into another folder puts the result there, with no staging
    /// left; the archive's folder is left as it was.
    @Test(.enabled(if: Fixture.isReadable))
    func extractHereInAnotherFolderLandsThere() async throws {
        let archive = try Fixture.copy("zip/deflate.zip")
        let source = archive.deletingLastPathComponent()
        let other = try Self.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: other)
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
        let extraction = try await ServicesJobRunner.extractHere(archive, in: other, progress: nil)
        #expect(!extraction.isVolumeSet)
        let result = extraction.result
        #expect(result.deletingLastPathComponent().resolvingSymlinksInPath().path == other.resolvingSymlinksInPath().path)
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() == before)
        let inOther = try FileManager.default.contentsOfDirectory(atPath: other.path)
        #expect(inOther == [result.lastPathComponent])
        #expect(!inOther.contains { $0.hasPrefix(".kernir-") })
    }

    /// Compress puts the archive beside the items.
    @Test func compressesItemsBesideThem() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let runner = ServicesJobRunner(access: { _ in nil }, grant: { _ in }, askForAccess: { _, _ in nil })
        let outcome = await runner.run(.compress([file], format: .zip), progress: nil)
        guard case let .done(result) = outcome else { Issue.record("\(outcome)"); return }
        #expect(result.lastPathComponent == "notes.txt.zip")
        #expect(FileManager.default.fileExists(atPath: result.path))
    }

    // MARK: Folder access

    /// A granted folder: its access is held while the job runs and stopped after; nothing is asked.
    @Test func aGrantedFolderRunsUnderItsGrant() async {
        let runner = runner(granted: [URL(fileURLWithPath: "/Users/u", isDirectory: true)]) { _ in Self.result }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.starts == 1)
        #expect(log.asks.isEmpty)
        expectBalancedAccess()
    }

    /// No grant and no permission: the Allow panel once, on the destination folder; the pick is
    /// kept and the job runs again under it.
    @Test(arguments: [cocoa(.fileWriteNoPermission), posix(EPERM), posix(EACCES),
                      cocoa(.fileWriteUnknown).withUnderlying(posix(EACCES))])
    func noPermissionAsksOnceThenRunsAgain(error: NSError) async {
        let picked = URL(fileURLWithPath: "/Users/u", isDirectory: true)
        let runner = runner(pick: picked) { attempt in
            if attempt == 1 { throw error }
            return Self.result
        }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.asks == [Self.folder])
        #expect(log.grants == [picked])
        #expect(log.works == 2)
        #expect(log.starts == 1)
        expectBalancedAccess()
    }

    /// Compress asks for the items' folder.
    @Test func compressAsksForTheItemsFolder() async {
        let items = ["a.txt", "b.txt"].map { Self.folder.appendingPathComponent($0) }
        let runner = runner(pick: Self.folder) { attempt in
            if attempt == 1 { throw Self.posix(EPERM) }
            return Self.folder.appendingPathComponent("Archive.zip")
        }
        #expect(await runner.run(.compress(items, format: .zip), progress: nil)
            == .done(Self.folder.appendingPathComponent("Archive.zip")))
        #expect(log.asks == [Self.folder])
    }

    /// A split set whose other parts are out of reach asks for their folder too.
    @Test func aSplitSetOutOfReachAsksForItsFolder() async {
        let runner = runner(pick: Self.folder) { attempt in
            if attempt == 1 { throw Self.splitSetOutOfReach }
            return Self.result
        }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.asks == [Self.folder])
    }

    /// A split set still out of reach after the pick: choosing another destination can't help
    /// (the parts are what can't be read), so it fails with the set's own text, offering nothing.
    @Test func aSplitSetStillOutOfReachFailsWithItsOwnText() async {
        let runner = runner(pick: Self.folder, others: [Self.elsewhere]) { _ in throw Self.splitSetOutOfReach }
        let outcome = await runner.run(.extractHere(Self.archive), progress: nil)
        #expect(outcome == .failed(ServicesJobRunner.failure(for: Self.splitSetOutOfReach, job: .extractHere(Self.archive))))
        #expect(log.asks.count == 1)
        #expect(log.offers.isEmpty)
    }

    /// The split set's message is its own, not the folder-permission one.
    @Test func aSplitSetOutOfReachSaysSo() {
        let failure = ServicesJobRunner.failure(for: Self.splitSetOutOfReach, job: .extractHere(Self.archive))
        #expect(failure.reason == Self.splitSetOutOfReach.localizedDescription)
        #expect(failure.reason != String(localized: "Lutik doesn't have permission to write in “\(Self.folderName)”."))
    }

    private static let splitSetOutOfReach = ArchiveVolumeError(reason: .noAccess, part: 2, fileName: "project.zip.002",
                                                               setName: "project.zip.001", folder: folder, openedPart: 1)
    private static let elsewhere = URL(fileURLWithPath: "/Users/u/Desktop", isDirectory: true)

    /// The Allow panel is a prompt of the job's own: the queue's progress panel keeps out of its way.
    @Test func theAllowPanelIsPrompting() async {
        let runner = runner(pick: Self.folder) { attempt in
            if attempt == 1 { throw Self.posix(EPERM) }
            return Self.result
        }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil, prompting: prompting) == .done(Self.result))
        #expect(log.events == ["begin", "ask", "end"])
    }

    /// A grant that can't be kept (`grant` throws): the pick still carries access this launch,
    /// and the Allow panel isn't shown again if the job still can't write.
    @Test func aGrantThatCannotBeKeptAsksOnlyOnce() async {
        let runner = runner(pick: Self.folder, maxAsks: 1, grantFails: true) { _ in throw Self.posix(EACCES) }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .cancelled)
        #expect(log.asks.count == 1)
        #expect(log.works == 2)
        #expect(log.offers.count == 1)
        expectBalancedAccess()
    }

    /// Cancel in the Allow panel ends the job quietly, with nothing kept.
    @Test func cancelInTheAllowPanelEndsQuietly() async {
        let runner = runner(pick: nil) { _ in throw Self.posix(EPERM) }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .cancelled)
        #expect(log.asks.count == 1)
        #expect(log.grants.isEmpty)
        #expect(log.works == 1)
    }

    private static let noPermission = ServicesJobFailure(
        title: String(localized: "Couldn't extract “\(ServicesJobRunner.displayName(of: archive))”."),
        reason: String(localized: "Lutik doesn't have permission to write in “\(folderName)”."))

    /// Still no permission after the pick: one ask only, then the failure, with another folder
    /// offered; Cancel there ends the job, the user having seen why.
    @Test func stillNoPermissionAfterThePickOffersAnotherFolder() async {
        let runner = runner(pick: Self.folder) { _ in throw Self.posix(EACCES) }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .cancelled)
        #expect(log.offers == [Self.noPermission])
        #expect(log.asks.count == 1)
        #expect(log.works == 2)
    }

    /// A folder already granted that still refuses (its own permissions): asking again won't
    /// help, so another folder is offered.
    @Test func aGrantedFolderThatRefusesOffersAnotherFolder() async {
        let runner = runner(granted: [Self.folder]) { _ in throw Self.posix(EACCES) }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .cancelled)
        #expect(log.offers == [Self.noPermission])
        #expect(log.asks.isEmpty)
        #expect(log.works == 1)
        expectBalancedAccess()
    }

    /// A read-only volume: a grant can't help, so nothing is asked; another folder is offered.
    /// Found anywhere down the underlying errors, as `ExtractHereService.isReadOnlyVolume` does.
    @Test(arguments: [cocoa(.fileWriteVolumeReadOnly), posix(EROFS),
                      cocoa(.fileWriteUnknown).withUnderlying(cocoa(.fileWriteVolumeReadOnly)),
                      cocoa(.fileWriteUnknown).withUnderlying(cocoa(.fileWriteUnknown).withUnderlying(posix(EROFS)))])
    func aReadOnlyVolumeOffersAnotherFolder(error: NSError) async {
        let runner = runner(pick: Self.folder) { _ in throw error }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .cancelled)
        #expect(log.offers.map(\.reason) == [String(localized: "“\(Self.folderName)” is on a read-only volume.")])
        #expect(log.asks.isEmpty)
    }

    /// Cocoa's no-permission error (513) over EROFS is still a read-only volume: no Allow panel
    /// (a grant can't help), straight to the offer of another folder.
    @Test func noPermissionOverEROFSIsAReadOnlyVolume() async {
        let error = Self.cocoa(.fileWriteNoPermission).withUnderlying(Self.posix(EROFS))
        let runner = runner(pick: Self.folder) { _ in throw error }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil, prompting: prompting) == .cancelled)
        #expect(log.asks.isEmpty)
        #expect(log.offers.map(\.reason) == [String(localized: "“\(Self.folderName)” is on a read-only volume.")])
        #expect(log.events == ["begin", "offer", "end"])
        #expect(log.works == 1)
    }

    /// The folder chosen instead gets the job, for Extract Here and Compress alike; the offer is
    /// prompting, as the Allow panel is.
    @Test(arguments: [ServicesJob.extractHere(URL(fileURLWithPath: "/Users/u/Downloads/project.zip")),
                      .compress([URL(fileURLWithPath: "/Users/u/Downloads/project.zip")], format: .zip)])
    func anotherFolderGetsTheJob(job: ServicesJob) async {
        let runner = runner(others: [Self.elsewhere]) { attempt in
            if attempt == 1 { throw Self.posix(EROFS) }
            return Self.elsewhere.appendingPathComponent("project")
        }
        #expect(await runner.run(job, progress: nil, prompting: prompting) == .done(Self.elsewhere.appendingPathComponent("project")))
        #expect(log.targets == [nil, Self.elsewhere])
        #expect(log.events == ["begin", "offer", "end"])
        #expect(log.asks.isEmpty)
    }

    /// Another folder that refuses too is offered again, naming it; the pick already carries
    /// access, so the Allow panel isn't shown for it.
    @Test func anotherFolderThatRefusesIsOfferedAgain() async {
        let runner = runner(pick: Self.elsewhere, others: [Self.elsewhere]) { attempt in
            throw attempt == 1 ? Self.posix(EROFS) : Self.posix(EACCES)
        }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .cancelled)
        #expect(log.offers.map(\.reason) == [
            String(localized: "“\(Self.folderName)” is on a read-only volume."),
            String(localized: "Lutik doesn't have permission to write in “\(ServicesJobRunner.displayName(of: Self.elsewhere))”."),
        ])
        #expect(log.targets == [nil, Self.elsewhere])
        #expect(log.asks.isEmpty)
    }

    /// With no offer to make (a runner built without one), a read-only volume is a plain failure.
    @Test func withNoOfferAReadOnlyVolumeFails() async {
        let runner = ServicesJobRunner(extract: { _, _, _ in throw Self.posix(EROFS) }, access: { _ in nil },
                                       grant: { _ in }, askForAccess: { _, _ in Issue.record("asked"); return nil })
        let outcome = await runner.run(.extractHere(Self.archive), progress: nil)
        #expect(outcome == .failed(ServicesJobFailure(
            title: String(localized: "Couldn't extract “\(ServicesJobRunner.displayName(of: Self.archive))”."),
            reason: String(localized: "“\(Self.folderName)” is on a read-only volume."))))
    }

    /// Other failures (a damaged archive, a full disk) aren't the folder's: nothing is offered.
    @Test func otherFailuresOfferNothing() async {
        let runner = runner(others: [Self.elsewhere]) { _ in throw Self.posix(ENOSPC) }
        guard case .failed = await runner.run(.extractHere(Self.archive), progress: nil) else {
            Issue.record("not a failure")
            return
        }
        #expect(log.offers.isEmpty)
    }

    // MARK: Move to Trash (the Trash setting applies to Services jobs)

    /// A whole, completed Extract Here with the setting on moves the archive to the Trash, while
    /// the folder's grant is still held, and the job is done.
    @Test func aCompletedExtractHereMovesTheArchiveToTheTrash() async {
        let runner = runner(granted: [Self.folder], trashOn: true) { _ in Self.result }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.trashed == [Self.archive])
        #expect(log.stopsAtTrash == [0])
        #expect(log.openChecks == [Self.archive])
        expectBalancedAccess()
    }

    /// The Allow panel, then a retry in the same folder, is still Extract Here in place: trashed.
    @Test func afterTheAllowPanelTheArchiveIsTrashed() async {
        let runner = runner(pick: Self.folder, trashOn: true) { attempt in
            if attempt == 1 { throw Self.posix(EPERM) }
            return Self.result
        }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.trashed == [Self.archive])
        #expect(log.stopsAtTrash == [0])
    }

    /// The setting off: the archive stays.
    @Test func withTheSettingOffTheArchiveStays() async {
        let runner = runner(trashOn: false) { _ in Self.result }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.trashed.isEmpty)
    }

    /// One part of a split set: its other parts would stay behind, so it stays, as in Extract Here.
    @Test func aSplitSetStays() async {
        let runner = runner(trashOn: true, isVolumeSet: true) { _ in Self.result }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.trashed.isEmpty)
    }

    /// An archive open in Kernir with unsaved changes stays: the Trash would lose them. No alert:
    /// the job is done as usual.
    @Test func anArchiveWithUnsavedChangesStays() async {
        let runner = runner(trashOn: true, open: .openWithUnsavedChanges) { _ in Self.result }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.trashed.isEmpty)
        #expect(log.openChecks == [Self.archive])
    }

    /// An archive open in a Kernir window with no changes stays too. Unlike Extract Here, a
    /// Services job never closes a window the user didn't act from, so the window keeps its file.
    @Test func anArchiveOpenInACleanWindowStays() async {
        let runner = runner(trashOn: true, open: .open) { _ in Self.result }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.trashed.isEmpty)
        #expect(log.openChecks == [Self.archive])
    }

    /// A stop, a failure, a password or a Cancel in the Allow panel: nothing extracted in full,
    /// so the archive stays.
    @Test(arguments: [ArchiveError.cancelled as any Error, CancellationError(), posix(ENOSPC),
                      ArchiveError.corrupted("x"), ArchiveError.passwordRequired, posix(EPERM)])
    func anUnfinishedExtractHereKeepsTheArchive(error: any Error) async {
        let runner = runner(pick: nil, trashOn: true) { _ in throw error }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) != .done(Self.result))
        #expect(log.trashed.isEmpty)
    }

    /// Extracted in another folder: the archive's own folder refused writes, so
    /// the Trash would fail there too; the archive stays, and nothing is tried.
    @Test(arguments: [posix(EROFS), posix(EACCES)])
    func extractedElsewhereKeepsTheArchive(error: NSError) async {
        let runner = runner(granted: [Self.folder], others: [Self.elsewhere], trashOn: true) { attempt in
            if attempt == 1 { throw error }
            return Self.elsewhere.appendingPathComponent("project")
        }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil)
            == .done(Self.elsewhere.appendingPathComponent("project")))
        #expect(log.trashed.isEmpty)
    }

    /// A Trash that fails leaves the job done: no failure, no offer, no second panel.
    @Test func aTrashThatFailsLeavesTheJobDone() async {
        let runner = runner(granted: [Self.folder], others: [Self.elsewhere], trashOn: true, trashFails: true) { _ in Self.result }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil, prompting: prompting) == .done(Self.result))
        #expect(log.events.isEmpty)
        #expect(log.offers.isEmpty)
        #expect(log.asks.isEmpty)
        #expect(log.works == 1)
        expectBalancedAccess()
    }

    /// Compress never moves its items to the Trash.
    @Test func compressNeverTrashes() async {
        let runner = runner(trashOn: true) { _ in Self.folder.appendingPathComponent("Archive.zip") }
        #expect(await runner.run(.compress([Self.archive], format: .zip), progress: nil)
            == .done(Self.folder.appendingPathComponent("Archive.zip")))
        #expect(log.trashed.isEmpty)
        #expect(log.openChecks.isEmpty)
    }

    /// A runner made without the setting never trashes.
    @Test func aRunnerWithoutTheSettingNeverTrashes() {
        let runner = ServicesJobRunner(access: { _ in nil }, grant: { _ in }, askForAccess: { _, _ in nil })
        #expect(!runner.movesArchiveToTrash())
    }

    /// The open-in-Kernir check: a document on the same file (by path, links resolved), edited
    /// or not; edited wins when there are several.
    @Test func openStateIsADocumentOnTheSameFile() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("project.zip")
        try Data().write(to: archive)
        let link = folder.appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archive)
        let other = folder.appendingPathComponent("other.zip")
        let state = { ServicesJobRunner.openState(of: archive, in: $0) }
        #expect(state([(fileURL: archive, isEdited: true)]) == .openWithUnsavedChanges)
        #expect(state([(fileURL: link, isEdited: true)]) == .openWithUnsavedChanges)
        #expect(state([(fileURL: archive, isEdited: false)]) == .open)
        #expect(state([(fileURL: link, isEdited: false)]) == .open)
        #expect(state([(fileURL: archive, isEdited: false), (fileURL: link, isEdited: true)]) == .openWithUnsavedChanges)
        #expect(state([(fileURL: other, isEdited: true)]) == .notOpen)
        #expect(state([(fileURL: nil, isEdited: true)]) == .notOpen)
        #expect(state([]) == .notOpen)
    }

    /// Other paths of `file` on this Mac: a hard link to it made in `folder` (the same file under
    /// another name, which no path resolution matches), its name and its folder's in upper case
    /// (APFS ignores case unless formatted case-sensitive), through the /System/Volumes/Data
    /// firmlink, and through a symbolic link to its folder made in `folder`. Only those that
    /// exist here. (On macOS 26, `resolvingSymlinksInPath` already gives an existing file's
    /// case and firmlink spellings their real path; the identity doesn't count on it.)
    private static func otherSpellings(of file: URL, linkIn folder: URL) throws -> [URL] {
        let hardLink = folder.appendingPathComponent("hard-link.zip")
        try FileManager.default.linkItem(at: file, to: hardLink)
        // realpath(3): `resolvingSymlinksInPath` drops /private, which the firmlink path needs.
        guard let resolved = realpath(file.path, nil) else { throw Self.posix(errno) }
        defer { free(resolved) }
        let real = URL(fileURLWithPath: String(cString: resolved))
        let parent = real.deletingLastPathComponent()
        let upper = parent.deletingLastPathComponent()
            .appendingPathComponent(parent.lastPathComponent.uppercased(), isDirectory: true)
            .appendingPathComponent(real.lastPathComponent.uppercased())
        let linkedFolder = folder.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: file.deletingLastPathComponent())
        let spellings = [hardLink, upper, URL(fileURLWithPath: "/System/Volumes/Data" + real.path),
                         linkedFolder.appendingPathComponent(file.lastPathComponent)]
        return spellings.filter { FileManager.default.fileExists(atPath: $0.path) && $0.path != file.path }
    }

    /// The open check goes by the file's identity, so a document whose path names
    /// the archive another way (a hard link, another case, a firmlink) has it open all the same.
    @Test func openStateSeesTheSameFileSpelledAnotherWay() throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inner = folder.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        let archive = inner.appendingPathComponent("project.zip")
        try Data("zip".utf8).write(to: archive)
        let spellings = try Self.otherSpellings(of: archive, linkIn: folder)
        // The upper-case one needs a case-insensitive volume; the others are always there.
        #expect(spellings.contains { $0.lastPathComponent == "hard-link.zip" })
        #expect(spellings.contains { $0.path.hasPrefix("/System/Volumes/Data/") })
        for spelling in spellings {
            #expect(ServicesJobRunner.openState(of: archive, in: [(fileURL: spelling, isEdited: false)]) == .open,
                    "\(spelling.path)")
            #expect(ServicesJobRunner.openState(of: spelling, in: [(fileURL: archive, isEdited: true)])
                == .openWithUnsavedChanges, "\(spelling.path)")
        }
        let other = inner.appendingPathComponent("other.zip")
        try Data("zip".utf8).write(to: other)
        #expect(ServicesJobRunner.openState(of: archive, in: [(fileURL: other, isEdited: true)]) == .notOpen)
    }

    /// The identity decides when both can be read; the path, links resolved, when either can't.
    @Test func openStateFallsBackToThePathWithoutAnIdentity() {
        let archive = Self.archive
        let elsewhere = Self.elsewhere.appendingPathComponent("project.zip")
        let same = ServicesFileIdentity(file: "file-1" as NSString, volume: "volume-1" as NSString)
        let known: (URL) -> ServicesFileIdentity? = { _ in same }
        #expect(ServicesJobRunner.openState(of: archive, in: [(fileURL: elsewhere, isEdited: false)], identity: known) == .open)
        let none: (URL) -> ServicesFileIdentity? = { _ in nil }
        #expect(ServicesJobRunner.openState(of: archive, in: [(fileURL: elsewhere, isEdited: false)], identity: none) == .notOpen)
        #expect(ServicesJobRunner.openState(of: archive, in: [(fileURL: archive, isEdited: true)], identity: none)
            == .openWithUnsavedChanges)
        let onlyTheArchive: (URL) -> ServicesFileIdentity? = { $0 == archive ? same : nil }
        #expect(ServicesJobRunner.openState(of: archive, in: [(fileURL: archive, isEdited: false)], identity: onlyTheArchive) == .open)
        let otherVolume = ServicesFileIdentity(file: "file-1" as NSString, volume: "volume-2" as NSString)
        let twoVolumes: (URL) -> ServicesFileIdentity? = { $0 == archive ? same : otherVolume }
        #expect(ServicesJobRunner.openState(of: archive, in: [(fileURL: elsewhere, isEdited: false)], identity: twoVolumes) == .notOpen)
    }

    /// A runner with the Trash on whose work returns `result` after `work` ran, with the app's
    /// open check over `documents` and a Trash that logs.
    private func trashingRunner(documents: [(fileURL: URL?, isEdited: Bool)] = [],
                                work: @escaping @MainActor () throws -> Void = {}) -> ServicesJobRunner {
        let log = log
        return ServicesJobRunner(extract: { archive, _, _ in
                                     try work()
                                     return ServicesExtraction(result: archive.deletingLastPathComponent()
                                         .appendingPathComponent("project", isDirectory: true))
                                 },
                                 access: { _ in nil }, grant: { _ in },
                                 askForAccess: { _, _ in Issue.record("asked"); return nil },
                                 movesArchiveToTrash: { true },
                                 openInKernir: { ServicesJobRunner.openState(of: $0, in: documents) },
                                 moveToTrash: { log.trashed.append($0) })
    }

    /// The job's archive open in a clean window under another path stays.
    @Test func anArchiveOpenUnderAnotherSpellingStays() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let inner = folder.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: false)
        let archive = inner.appendingPathComponent("project.zip")
        try Data("zip".utf8).write(to: archive)
        let spellings = try Self.otherSpellings(of: archive, linkIn: folder)
        #expect(!spellings.isEmpty)
        for spelling in spellings {
            let runner = trashingRunner(documents: [(fileURL: spelling, isEdited: false)])
            guard case .done = await runner.run(.extractHere(archive), progress: nil) else {
                Issue.record("not done")
                return
            }
            #expect(log.trashed.isEmpty, "\(spelling.path)")
        }
        // The same runner with the window on another file trashes it.
        let other = inner.appendingPathComponent("other.zip")
        try Data("zip".utf8).write(to: other)
        _ = await trashingRunner(documents: [(fileURL: other, isEdited: false)]).run(.extractHere(archive), progress: nil)
        #expect(log.trashed == [archive])
    }

    /// A Stop that lands as the work returns (after the staging folder's removal,
    /// the last await) keeps the archive; the result is in place, so the job is done.
    @Test func aStopAsTheWorkReturnsKeepsTheArchive() async {
        let runner = runner(trashOn: true) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return Self.result
        }
        let outcome = await Task { await runner.run(.extractHere(Self.archive), progress: nil) }.value
        #expect(outcome == .done(Self.result))
        #expect(log.trashed.isEmpty)
        #expect(log.works == 1)
    }

    /// The unsaved-changes rule on its own, apart from the open-window guard that
    /// keeps an open archive in any case.
    @Test func unsavedChangesAreTheReasonToKeep() {
        let decide = { ServicesJobRunner.trashDecision(enabled: $0, open: $1, isVolumeSet: $2) }
        #expect(decide(true, .openWithUnsavedChanges, false) == .keep(.unsavedChanges))
        #expect(decide(true, .open, false) == .moveToTrash)
        #expect(decide(true, .notOpen, false) == .moveToTrash)
        #expect(decide(false, .openWithUnsavedChanges, false) == .keep(nil))
        #expect(decide(true, .notOpen, true) == .keep(nil))
    }

    /// The app's runner reads Extract Here's Trash setting from the defaults given.
    @Test func theLiveRunnerFollowsTheTrashSetting() {
        let (defaults, suite) = makeTestDefaults("KernirTests-ServicesLiveTrash")
        defer { removeTestDefaults(defaults, suite: suite) }
        let settings = ExtractHereSettings(defaults: defaults)
        let runner = ServicesJobRunner.live(store: FolderAccessStore(defaults: defaults), settings: settings)
        #expect(!runner.movesArchiveToTrash())
        settings.movesArchiveToTrash = true
        #expect(runner.movesArchiveToTrash())
        settings.movesArchiveToTrash = false
        #expect(!runner.movesArchiveToTrash())
    }

    /// An archive rewritten or replaced (by another app) while the job ran stays;
    /// one left as it was goes to the Trash. Two changes pin one part of the stamp each: a file
    /// put in its place with the same size and the old date set back differs only by its
    /// identity, and one rewritten in place to the same size differs only by its date.
    @Test(arguments: ["unchanged", "rewritten", "replaced", "replacedKeepingTheDate", "rewrittenToTheSameSize"])
    func anArchiveChangedDuringTheJobStays(change: String) async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("project.zip")
        try Data("zip".utf8).write(to: archive)
        // A date in whole seconds, long past: it survives being set again exactly, and a rewrite
        // now can't land on it.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: archive.path)
        let before = try #require(ServicesFileStamp.of(archive))
        #expect(before.modified == date)
        let runner = trashingRunner {
            switch change {
            case "rewritten":
                try Data("zip, longer".utf8).write(to: archive)
            case "replaced":
                try FileManager.default.removeItem(at: archive)
                try Data("zip".utf8).write(to: archive)
            case "replacedKeepingTheDate":
                // Made before the original goes, so it can't get the original's file ID back.
                let other = folder.appendingPathComponent("other.zip")
                try Data("zap".utf8).write(to: other)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: other.path)
                try FileManager.default.removeItem(at: archive)
                try FileManager.default.moveItem(at: other, to: archive)
                let after = try #require(ServicesFileStamp.of(archive))
                #expect(after.size == before.size)
                #expect(after.modified == before.modified)
                #expect(after.identity != before.identity)
            case "rewrittenToTheSameSize":
                let handle = try FileHandle(forWritingTo: archive)
                try handle.write(contentsOf: Data("zap".utf8))
                try handle.close()
                let after = try #require(ServicesFileStamp.of(archive))
                #expect(after.identity == before.identity)
                #expect(after.size == before.size)
                #expect(after.modified != before.modified)
            default:
                break
            }
        }
        guard case .done = await runner.run(.extractHere(archive), progress: nil) else {
            Issue.record("not done")
            return
        }
        #expect(log.trashed == (change == "unchanged" ? [archive] : []))
    }

    /// A runner over the fake archive whose folder is granted once `granted` holds it (none at
    /// first), whose first work fails for permission when `failsFirst`, and whose archive's stamp
    /// can be read without the grant only when `readableWithoutGrant`, as the sandbox may have it,
    /// and under it unless not `readableUnderGrant`.
    /// `log.events` has "access", "stamp", "work" and "ask" in order.
    private func stampingRunner(granted: [URL] = [], failsFirst: Bool = false,
                                readableWithoutGrant: Bool = false,
                                readableUnderGrant: Bool = true) -> ServicesJobRunner {
        let log = log
        var granted = granted
        var underGrant = false
        let scope = SecurityScope(start: { _ in true }, stop: { _ in MainActor.assumeIsolated { log.stops += 1 } })
        let stamp = Self.stamp
        return ServicesJobRunner(
            extract: { _, _, _ in
                log.events.append("work")
                log.works += 1
                if failsFirst, log.works == 1 { throw Self.posix(EPERM) }
                return ServicesExtraction(result: Self.result)
            },
            compress: { _, _, _, _ in log.events.append("work"); return Self.result },
            access: { destination in
                log.events.append("access")
                guard let folder = granted.first(where: { FolderAccessStore.covers($0, destination) }) else { return nil }
                underGrant = true
                log.starts += 1
                return ScopedFolder(url: folder, isAccessing: true, scope: scope)
            },
            grant: { granted.append($0) },
            askForAccess: { _, _ in log.events.append("ask"); return Self.folder },
            movesArchiveToTrash: { true },
            moveToTrash: { log.trashed.append($0) },
            fileStamp: { _ in
                log.events.append("stamp")
                return (underGrant && readableUnderGrant) || readableWithoutGrant ? stamp : nil
            })
    }

    /// The archive's stamp is taken under the folder's grant, before the work, as
    /// the Trash's check is: one taken before the grant (nil in the sandbox) kept every archive.
    @Test func theArchiveIsStampedUnderItsGrant() async {
        let runner = stampingRunner(granted: [Self.folder])
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.events == ["access", "stamp", "work", "stamp"])
        #expect(log.trashed == [Self.archive])
        expectBalancedAccess()
    }

    /// With no grant at first, a stamp that couldn't be read is taken again under
    /// the grant the Allow panel gave, before the work runs again; one that could is kept.
    @Test(arguments: [false, true])
    func afterTheAllowPanelTheStampIsTakenUnderTheGrant(readableWithoutGrant: Bool) async {
        let runner = stampingRunner(failsFirst: true, readableWithoutGrant: readableWithoutGrant)
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        let retry = readableWithoutGrant ? ["access", "work"] : ["access", "stamp", "work"]
        #expect(log.events == ["access", "stamp", "work", "ask"] + retry + ["stamp"])
        #expect(log.trashed == [Self.archive])
        expectBalancedAccess()
    }

    /// An archive unreadable when the job began and again before the Trash stays:
    /// two missing stamps don't show it is the same file. One readable both times goes.
    @Test(arguments: [false, true])
    func anArchiveUnreadableBothTimesStays(readable: Bool) async {
        let runner = runner(trashOn: true, stamp: readable ? Self.stamp : nil) { _ in Self.result }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.trashed == (readable ? [Self.archive] : []))
    }

    /// An archive unreadable when the job began and still unreadable under the
    /// grant the Allow panel gave has no stamp at all, so it stays: the Trash can't tell it is the
    /// same file (nor is it read again before the Trash). Unlike
    /// `anArchiveUnreadableBothTimesStays`, the stamp is taken again under the grant here.
    @Test func anArchiveUnreadableBeforeAndAfterTheAllowPanelStays() async {
        let runner = stampingRunner(failsFirst: true, readableUnderGrant: false)
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .done(Self.result))
        #expect(log.events == ["access", "stamp", "work", "ask", "access", "stamp", "work"])
        #expect(log.trashed == [])
        expectBalancedAccess()
    }

    /// Compress takes no stamp: it trashes nothing.
    @Test func compressTakesNoStamp() async {
        let runner = stampingRunner(granted: [Self.folder])
        #expect(await runner.run(.compress([Self.archive], format: .zip), progress: nil) == .done(Self.result))
        #expect(log.events == ["access", "work"])
    }

    /// Extract Here's launch arguments with a test Trash folder.
    private static func trashArguments(_ trash: URL) -> ExtractHereLaunchArguments {
        var arguments = ExtractHereLaunchArguments()
        arguments.trashDirectory = trash
        return arguments
    }

    /// For real, with Extract Here's test Trash folder (`ExtractHereEffects.moveToTrash` under a
    /// `trashDirectory`): the archive leaves its folder for the Trash, the result stays.
    @Test(.enabled(if: Fixture.isReadable))
    func extractHereMovesARealArchiveToATestTrash() async throws {
        let archive = try Fixture.copy("showcase/project.zip")
        let folder = archive.deletingLastPathComponent()
        let trash = try Self.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: trash)
        }
        let arguments = Self.trashArguments(trash)
        let runner = ServicesJobRunner(access: { _ in nil }, grant: { _ in },
                                       askForAccess: { _, _ in Issue.record("asked"); return nil },
                                       movesArchiveToTrash: { true },
                                       moveToTrash: { _ = try ExtractHereEffects.moveToTrash($0, arguments: arguments) })
        let outcome = await runner.run(.extractHere(archive), progress: nil)
        guard case let .done(result) = outcome else { Issue.record("\(outcome)"); return }
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path) == ["project.zip"])
    }

    /// A real split set says so, and with the setting on its parts all stay.
    @Test(.enabled(if: Fixture.isReadable))
    func aRealSplitSetStays() async throws {
        let first = try Fixture.copy("multivolume/s7.7z.001")
        let folder = first.deletingLastPathComponent()
        let trash = try Self.makeFolder()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: trash)
        }
        for part in ["s7.7z.002", "s7.7z.003"] {
            try FileManager.default.copyItem(at: Fixture.root.appendingPathComponent("multivolume/\(part)"),
                                             to: folder.appendingPathComponent(part))
        }
        let arguments = Self.trashArguments(trash)
        let runner = ServicesJobRunner(access: { _ in nil }, grant: { _ in },
                                       askForAccess: { _, _ in Issue.record("asked"); return nil },
                                       movesArchiveToTrash: { true },
                                       moveToTrash: { _ = try ExtractHereEffects.moveToTrash($0, arguments: arguments) })
        let outcome = await runner.run(.extractHere(first), progress: nil)
        guard case .done = outcome else { Issue.record("\(outcome)"); return }
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        for part in ["s7.7z.001", "s7.7z.002", "s7.7z.003"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(part).path))
        }
        #expect(try await ServicesJobRunner.extractHere(first, in: nil, progress: nil).isVolumeSet)
    }

    // MARK: Endings

    @Test(arguments: [ArchiveError.cancelled as any Error, CancellationError(), cocoa(.userCancelled)])
    func aStopEndsQuietly(error: any Error) async {
        let runner = runner { _ in throw error }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .cancelled)
    }

    /// A password asked for mid-extraction opens the document too.
    @Test func aPasswordAskedForLaterOpensTheDocument() async {
        let runner = runner { _ in throw ArchiveError.passwordRequired }
        #expect(await runner.run(.extractHere(Self.archive), progress: nil) == .needsPassword(Self.archive))
    }

    @Test(.enabled(if: Fixture.isReadable))
    func anEmptyArchiveSaysSo() async throws {
        let archive = try Fixture.copy("zip/empty.zip")
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let runner = ServicesJobRunner(access: { _ in nil }, grant: { _ in }, askForAccess: { _, _ in nil })
        let outcome = await runner.run(.extractHere(archive), progress: nil)
        guard case let .failed(failure) = outcome else { Issue.record("\(outcome)"); return }
        #expect(failure.reason == String(localized: "The archive is empty."))
    }

    // MARK: Messages

    /// A system message naming the hidden staging folder is replaced by one naming the
    /// destination; the staging's name and path appear nowhere.
    @Test func aMessageNeverNamesTheStagingFolder() {
        let staging = Self.folder.appendingPathComponent(".kernir-feedface00000000-123-\(UUID().uuidString)").path
        let errors: [NSError] = [
            Self.cocoa(.fileWriteUnknown, path: staging),
            Self.cocoa(.fileReadNoSuchFile, path: staging),
            NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't write \(staging)."]),
        ]
        for error in errors {
            #expect(error.localizedDescription.contains(".kernir-"), "the test's error must name the staging")
            for job in [ServicesJob.extractHere(Self.archive), .compress([Self.archive], format: .zip)] {
                let failure = ServicesJobRunner.failure(for: error, job: job)
                #expect(!failure.reason.contains(".kernir-"))
                #expect(!failure.title.contains(".kernir-"))
                #expect(failure.reason == String(localized: "The files couldn't be written in “\(Self.folderName)”."))
            }
        }
    }

    /// Compress that finds no free name (every one refused, `UniquePlacement.maxAttempts`) says so.
    @Test func noFreeNameSaysSo() {
        let compress = ServicesJob.compress([Self.archive], format: .zip)
        for error in [POSIXError(.EEXIST) as any Error, Self.cocoa(.fileWriteFileExists).withUnderlying(Self.posix(EEXIST))] {
            #expect(ServicesJobRunner.failure(for: error, job: compress).reason
                == String(localized: "Couldn't find a free name for the archive in “\(Self.folderName)”."))
            #expect(ServicesJobRunner.failure(for: error, job: .extractHere(Self.archive)).reason
                == String(localized: "Couldn't find a free name for the extracted items in “\(Self.folderName)”."))
        }
    }

    /// The core's errors keep their own text; the title names what failed.
    @Test func otherErrorsKeepTheirText() {
        let failure = ServicesJobRunner.failure(for: ArchiveError.corrupted("x"), job: .extractHere(Self.archive))
        #expect(failure.reason == ArchiveError.corrupted("x").localizedDescription)
        let items = ["a.txt", "b.txt", "c.txt"].map { Self.folder.appendingPathComponent($0) }
        #expect(ServicesJobRunner.failure(for: Self.posix(ENOSPC), job: .compress(items, format: .zip)).title
            == String(localized: "Couldn't compress \(3) items."))
        let one = ServicesJobRunner.displayName(of: items[0])
        #expect(ServicesJobRunner.failure(for: Self.posix(ENOSPC), job: .compress([items[0]], format: .zip)).title
            == String(localized: "Couldn't compress “\(one)”."))
        #expect(ServicesJobRunner.failure(for: Self.posix(ENOSPC), job: .extractHere(Self.archive)).title
            == "Couldn't extract “\(ServicesJobRunner.displayName(of: Self.archive))”.")
    }

    /// One item is named, in quotes; several are counted, through a plural key (no
    /// English-only "items" pasted into the sentence).
    @Test(arguments: [2, 3, 21])
    func severalItemsAreCountedOneIsNamed(count: Int) {
        let items = (1...count).map { Self.folder.appendingPathComponent("f\($0).txt") }
        let several = ServicesJob.compress(items, format: .zip)
        #expect(several.subject == .items(count))
        #expect(several.failureTitle == "Couldn't compress \(count) items.")
        #expect(several.progressTitle == "Compressing \(count) items…")
        let one = ServicesJob.compress([items[0]], format: .zip)
        #expect(one.subject == .named(ServicesJobRunner.displayName(of: items[0])))
        #expect(one.failureTitle == "Couldn't compress “\(ServicesJobRunner.displayName(of: items[0]))”.")
        #expect(ServicesJob.extractHere(Self.archive).subject == .named(ServicesJobRunner.displayName(of: Self.archive)))
    }

    /// Hosted in Lutik.app, `String(localized:)` reads the app's built catalog: each count key is
    /// a plural there (its English "one" form says "item"), so a language with more forms gets them.
    /// Skipped when not hosted (the scratch SwiftPM run), where no catalog is built.
    @Test(.enabled(if: Bundle.main.bundleIdentifier?.hasPrefix("com.kernir.app") == true))
    func theCountKeysArePluralsInTheApp() {
        #expect(String(localized: "Couldn't compress \(1) items.") == "Couldn't compress 1 item.")
        #expect(String(localized: "Compressing \(1) items…") == "Compressing 1 item…")
        #expect(String(localized: "Choose where to save the archive of \(1) items.") == "Choose where to save the archive of 1 item.")
        #expect(String(localized: "Couldn't compress \(21) items.") == "Couldn't compress 21 items.")
    }
}

extension NSError {
    /// This error with `underlying` as its `NSUnderlyingErrorKey`.
    func withUnderlying(_ underlying: NSError) -> NSError {
        var info = userInfo
        info[NSUnderlyingErrorKey] = underlying
        return NSError(domain: domain, code: code, userInfo: info)
    }
}

/// The queue: one job at a time, a progress panel only for a slow one, then one
/// Finder selection, one alert, the documents to open, and the quit rule.
@MainActor
struct ServicesJobQueueTests {
    /// What the queue did outside itself.
    @MainActor private final class Effects {
        var revealed: [[URL]] = []
        var opened: [URL] = []
        var alerts: [ServicesAlertText] = []
        var terminations = 0
        var shown: [String] = []
        var updates: [Double] = []
        var hides = 0
        var stop: (@MainActor () -> Void)?
        var delays: [Duration] = []
        var isDefaultLaunch = false
        var hasOpenWindows = false
        var hasVisiblePanels = false
        var hasModal = false
        /// Delays started from now on never elapse, whatever the queue was made with.
        var holdsDelays = false
        /// Runs while the alert is up, as other main-actor work runs under a modal alert.
        var onAlert: (@MainActor () async -> Void)?
        /// Alerts closing and terminations, in order.
        var events: [String] = []
    }

    /// Holds a job until the test lets it go.
    @MainActor private final class Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var isOpen = false
        var isWaiting: Bool { waiter != nil }

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func open() {
            isOpen = true
            waiter?.resume()
            waiter = nil
        }
    }

    private let effects = Effects()
    private static let folder = URL(fileURLWithPath: "/Users/u/Downloads", isDirectory: true)

    private static func archive(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// A queue whose jobs end as `run` says; the panel's delay elapses at once (`elapses`) or never.
    private func queue(elapses: Bool = false,
                       run: @escaping @MainActor (ServicesJob, ArchiveProgressHandler?) async -> ServicesJobOutcome)
        -> ServicesJobQueue {
        queue(elapses: elapses, prompting: { job, progress, _ in await run(job, progress) })
    }

    /// The same, for jobs that prompt.
    private func queue(elapses: Bool = false, prompting run: @escaping ServicesJobQueue.Run) -> ServicesJobQueue {
        let effects = effects
        let display = ServicesProgressDisplay(
            show: { title, stop in effects.shown.append(title); effects.stop = stop },
            update: { effects.updates.append($0) },
            hide: { effects.hides += 1 })
        let live = ServicesJobEffects(
            reveal: { effects.revealed.append($0) },
            openDocument: { effects.opened.append($0) },
            showAlert: { alert in
                effects.alerts.append(alert)
                await effects.onAlert?()
                effects.events.append("alert closed")
            },
            appState: {
                ServicesQuitState(launchedForServicesOnly: !effects.isDefaultLaunch,
                                  hasDocumentWindows: effects.hasOpenWindows,
                                  hasVisiblePanels: effects.hasVisiblePanels, hasModal: effects.hasModal)
            },
            terminate: { effects.terminations += 1; effects.events.append("terminate") },
            progress: display)
        return ServicesJobQueue(run: run, effects: live, sleep: { delay in
            let held = await MainActor.run { effects.delays.append(delay); return effects.holdsDelays }
            if !elapses || held { try await Task.sleep(for: .seconds(3600)) }
        })
    }

    /// Waits (up to 2 s) for `condition`, letting the queue's tasks run.
    private func eventually(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func failure(_ name: String) -> ServicesJobFailure {
        ServicesJobFailure(title: "Couldn't extract “\(name)”.", reason: "The archive is damaged.")
    }

    // MARK: Order

    @Test func jobsRunOneAtATimeInOrder() async {
        var events: [String] = []
        let gates = ["a.zip": Gate(), "b.zip": Gate()]
        let queue = queue { job, _ in
            guard case let .extractHere(archive) = job else { return .cancelled }
            let name = archive.lastPathComponent
            events.append("start \(name)")
            await gates[name]!.wait()
            events.append("end \(name)")
            return .done(archive)
        }
        queue.submit(.extractHere(Self.archive("a.zip")))
        queue.submit(.extractHere(Self.archive("b.zip")))
        await eventually { gates["a.zip"]!.isWaiting }
        gates["b.zip"]!.open()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(events == ["start a.zip"])
        gates["a.zip"]!.open()
        await queue.waitUntilIdle()
        #expect(events == ["start a.zip", "end a.zip", "start b.zip", "end b.zip"])
    }

    // MARK: When the queue drains

    /// Every result is shown in one Finder selection; nothing else happens after a default launch.
    @Test func everyResultIsRevealedOnce() async {
        effects.isDefaultLaunch = true
        let queue = queue { job, _ in
            guard case let .extractHere(archive) = job else { return .cancelled }
            return .done(archive.deletingPathExtension())
        }
        queue.submit(.extractHere(Self.archive("a.zip")))
        queue.submit(.extractHere(Self.archive("b.zip")))
        await queue.waitUntilIdle()
        #expect(effects.revealed == [[Self.archive("a"), Self.archive("b")]])
        #expect(effects.alerts.isEmpty)
        #expect(effects.opened.isEmpty)
        #expect(effects.terminations == 0)
    }

    /// Failures make one alert; the results that worked are still shown.
    @Test func failuresMakeOneAlert() async {
        effects.isDefaultLaunch = true
        let queue = queue { job, _ in
            guard case let .extractHere(archive) = job else { return .cancelled }
            return archive.lastPathComponent == "ok.zip" ? .done(Self.archive("ok")) : .failed(Self.failure(archive.lastPathComponent))
        }
        for name in ["a.zip", "ok.zip", "b.zip"] { queue.submit(.extractHere(Self.archive(name))) }
        await queue.waitUntilIdle()
        #expect(effects.revealed == [[Self.archive("ok")]])
        #expect(effects.alerts == [ServicesAlertText(failures: [Self.failure("a.zip"), Self.failure("b.zip")])])
    }

    @Test func oneFailureIsTheAlertsTitleAndReason() {
        let alert = ServicesAlertText(failures: [Self.failure("a.zip")])
        #expect(alert.message == "Couldn't extract “a.zip”.")
        #expect(alert.information == "The archive is damaged.")
        let two = ServicesAlertText(failures: [Self.failure("a.zip"), Self.failure("b.zip")])
        #expect(two.message == String(localized: "Some jobs couldn't be finished."))
        #expect(two.information.contains("Couldn't extract “a.zip”. The archive is damaged."))
        #expect(two.information.contains("Couldn't extract “b.zip”. The archive is damaged."))
    }

    /// An archive that needs a password is opened as a document, which asks for it.
    @Test func aPasswordArchiveIsOpenedAsADocument() async {
        let queue = queue { _, _ in .needsPassword(Self.archive("secret.zip")) }
        queue.submit(.extractHere(Self.archive("secret.zip")))
        await queue.waitUntilIdle()
        #expect(effects.opened == [Self.archive("secret.zip")])
        #expect(effects.revealed.isEmpty)
        // Its window is about to open: no quit.
        #expect(effects.terminations == 0)
    }

    // MARK: The quit rule

    /// Quit after the last job only after a Services-only launch with no window or document open
    /// and none about to open.
    @Test(arguments: [(false, false, false, true), (true, false, false, false), (false, true, false, false),
                      (false, false, true, false), (true, true, true, false)])
    func quitsOnlyAfterAServicesOnlyLaunchWithNothingOpen(isDefaultLaunch: Bool, hasOpenWindows: Bool,
                                                          opensDocuments: Bool, quits: Bool) {
        let state = ServicesQuitState(launchedForServicesOnly: !isDefaultLaunch, hasDocumentWindows: hasOpenWindows,
                                      opensDocuments: opensDocuments)
        #expect(ServicesJobQueue.shouldQuit(state) == quits)
    }

    /// Every guard on its own keeps the app; the default state, a Services-only
    /// launch with nothing else, is the one that quits.
    @Test(arguments: ["usual launch", "user activated", "jobs", "document windows", "visible panels", "modal",
                      "opens documents"])
    func eachGuardKeepsTheApp(guardName: String) {
        #expect(ServicesJobQueue.shouldQuit(ServicesQuitState()))
        var state = ServicesQuitState()
        switch guardName {
        case "usual launch": state.launchedForServicesOnly = false
        case "user activated": state.userActivated = true
        case "jobs": state.hasJobs = true
        case "document windows": state.hasDocumentWindows = true
        case "visible panels": state.hasVisiblePanels = true
        case "modal": state.hasModal = true
        case "opens documents": state.opensDocuments = true
        default: Issue.record("no guard \(guardName)")
        }
        #expect(!ServicesJobQueue.shouldQuit(state))
    }

    /// The app's side of the state comes from the launch flag: a Services-only launch, then the
    /// user's use of the app (a window opened, a Dock click), each read apart.
    @Test func theLaunchFlagFillsTheAppsSide() {
        var flag = ServicesLaunchFlag()
        flag.finishLaunching(isDefault: false)
        let state = ServicesQuitState(flag: flag, hasDocumentWindows: false, hasVisiblePanels: true, hasModal: true)
        #expect(state == ServicesQuitState(hasVisiblePanels: true, hasModal: true))
        flag.noteOpened()
        let used = ServicesQuitState(flag: flag, hasDocumentWindows: true, hasVisiblePanels: false, hasModal: false)
        #expect(used == ServicesQuitState(userActivated: true, hasDocumentWindows: true))
        #expect(ServicesQuitState(flag: ServicesLaunchFlag(), hasDocumentWindows: false, hasVisiblePanels: false,
                                  hasModal: false).launchedForServicesOnly == false)
    }

    /// A panel on screen (an Open panel, About) or a modal session keeps the app
    /// when the queue drains; the queue passes them on with its own jobs and documents.
    @Test(arguments: ["panel", "modal"])
    func aPanelOrAModalKeepsTheApp(what: String) async {
        if what == "panel" { effects.hasVisiblePanels = true } else { effects.hasModal = true }
        let queue = queue { _, _ in .cancelled }
        queue.submit(.extractHere(Self.archive("a.zip")))
        await queue.waitUntilIdle()
        #expect(effects.terminations == 0)
    }

    /// A Services-only launch quits once the queue drains, also after a Stop.
    @Test(arguments: [ServicesJobOutcome.done(URL(fileURLWithPath: "/Users/u/Downloads/a")), .cancelled])
    func aServicesOnlyLaunchQuitsWhenTheQueueDrains(outcome: ServicesJobOutcome) async {
        let queue = queue { _, _ in outcome }
        queue.submit(.extractHere(Self.archive("a.zip")))
        await queue.waitUntilIdle()
        #expect(effects.terminations == 1)
    }

    /// A window open (state restoration also launches without the default-launch flag): no quit.
    @Test func aWindowOpenKeepsTheApp() async {
        effects.hasOpenWindows = true
        let queue = queue { _, _ in .cancelled }
        queue.submit(.extractHere(Self.archive("a.zip")))
        await queue.waitUntilIdle()
        #expect(effects.terminations == 0)
    }

    /// A job sent while the alert is up runs before the app quits, and the app quits once.
    @Test func aJobSentDuringTheAlertRunsBeforeTheQuit() async {
        var ran: [String] = []
        let queue = queue { job, _ in
            guard case let .extractHere(archive) = job else { return .cancelled }
            ran.append(archive.lastPathComponent)
            return archive.lastPathComponent == "a.zip" ? .failed(Self.failure("a.zip")) : .done(Self.archive("b"))
        }
        effects.onAlert = { [effects] in
            effects.onAlert = nil
            queue.submit(.extractHere(Self.archive("b.zip")))
        }
        queue.submit(.extractHere(Self.archive("a.zip")))
        await queue.waitUntilIdle()
        #expect(ran == ["a.zip", "b.zip"])
        #expect(effects.terminations == 1)
    }

    /// The app's alert is modal and main-actor work goes on under it: a job sent then must not
    /// end the queue (and quit the app) while the alert is up, nor make it quit twice. It runs
    /// once the alert has gone, and the app quits once, after.
    @Test func aJobSentDuringTheAlertCannotQuitUnderIt() async {
        var ran: [String] = []
        let queue = queue { job, _ in
            guard case let .extractHere(archive) = job else { return .cancelled }
            ran.append(archive.lastPathComponent)
            return archive.lastPathComponent == "a.zip" ? .failed(Self.failure("a.zip")) : .done(Self.archive("b"))
        }
        effects.onAlert = { [effects] in
            effects.onAlert = nil
            queue.submit(.extractHere(Self.archive("b.zip")))
            // Long enough for b.zip's job and a drain's ending to run here, under the alert.
            try? await Task.sleep(for: .milliseconds(100))
        }
        queue.submit(.extractHere(Self.archive("a.zip")))
        await queue.waitUntilIdle()
        #expect(ran == ["a.zip", "b.zip"])
        #expect(effects.events == ["alert closed", "terminate"])
        #expect(effects.revealed == [[Self.archive("b")]])
    }

    /// A document opened for its password in an earlier round keeps the app, as a job sent
    /// during the alert makes a second round.
    @Test func aDocumentOpenedInAnEarlierRoundKeepsTheApp() async {
        let queue = queue { job, _ in
            guard case let .extractHere(archive) = job else { return .cancelled }
            return archive.lastPathComponent == "secret.zip" ? .needsPassword(archive) : .failed(Self.failure("a.zip"))
        }
        effects.onAlert = { [effects] in
            effects.onAlert = nil
            queue.submit(.extractHere(Self.archive("b.zip")))
        }
        queue.submit(.extractHere(Self.archive("secret.zip")))
        queue.submit(.extractHere(Self.archive("a.zip")))
        await queue.waitUntilIdle()
        #expect(effects.opened == [Self.archive("secret.zip")])
        #expect(effects.alerts.count == 2)
        #expect(effects.terminations == 0)
    }

    // MARK: The launch flag

    /// Once a document or a window has opened, the launch counts as a usual one for good,
    /// so a later queue doesn't quit an app the user has been using, even with nothing open then.
    @Test func anythingOpenedMakesTheLaunchAUsualOne() {
        let quits = { (flag: ServicesLaunchFlag) in
            ServicesJobQueue.shouldQuit(ServicesQuitState(flag: flag, hasDocumentWindows: false,
                                                          hasVisiblePanels: false, hasModal: false))
        }
        var flag = ServicesLaunchFlag()
        #expect(!quits(flag))
        flag.finishLaunching(isDefault: false)
        #expect(quits(flag))
        flag.noteOpened()
        #expect(!quits(flag))
        // A file opened at launch opens before the launch finishes.
        var early = ServicesLaunchFlag()
        early.noteOpened()
        early.finishLaunching(isDefault: false)
        #expect(!quits(early))
    }

    /// The menu bar, as `ServicesMenuActivity` sees it: an app menu with About (⌘I here), and a
    /// File menu with an Open Recent submenu.
    private final class MenuBar: NSObject {
        let main = NSMenu(title: "Main")
        let app = NSMenu(title: "Kernir")
        let file = NSMenu(title: "File")
        let recent = NSMenu(title: "Open Recent")
        var actions = 0
        /// How many times `noteOpened` was called.
        var notes = 0
        /// Whether `main` is the app's menu bar (`mainMenu`).
        var isInstalled = true
        /// Whether the queue's own prompt is up (`isQueuePrompting`).
        var isQueuePrompting = false
        var mainMenu: NSMenu? { isInstalled ? main : nil }

        override init() {
            super.init()
            for (title, submenu) in [("Kernir", app), ("File", file)] {
                main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
            }
            app.addItem(withTitle: "About", action: #selector(act(_:)), keyEquivalent: "i").target = self
            file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recent
            recent.addItem(withTitle: "a.zip", action: #selector(act(_:)), keyEquivalent: "").target = self
        }

        @objc func act(_ sender: Any?) { actions += 1 }
    }

    /// An action sent from the menu bar, at any depth, counts as using the app
    /// (`noteOpened`), before it runs (a modal Open panel) and after; a menu elsewhere (a panel's
    /// pop-up), another object or no menu bar don't.
    @Test(arguments: [NSMenu.willSendActionNotification, NSMenu.didSendActionNotification])
    func menuBarActionsCountAsUse(name: Notification.Name) {
        let center = NotificationCenter()
        let bar = MenuBar()
        let activity = ServicesMenuActivity(center: center, mainMenu: { bar.mainMenu }, isQueuePrompting: { false },
                                            noteOpened: { bar.notes += 1 })
        let popUp = NSMenu(title: "Where")
        let popUpSub = NSMenu(title: "Recent Places")
        popUp.addItem(withTitle: "Recent Places", action: nil, keyEquivalent: "").submenu = popUpSub
        for object in [popUp, popUpSub, NSObject(), bar.main.items[0]] as [Any] {
            center.post(name: name, object: object)
        }
        center.post(name: name, object: nil)
        #expect(bar.notes == 0)
        for (count, menu) in [bar.main, bar.app, bar.file, bar.recent].enumerated() {
            center.post(name: name, object: menu)
            #expect(bar.notes == count + 1, "\(menu.title)")
        }
        bar.isInstalled = false
        center.post(name: name, object: bar.recent)
        #expect(bar.notes == 4)
        withExtendedLifetime(activity) {}
    }

    /// An item chosen from a submenu posts both notifications the observer counts
    /// on: menu tracking calls `performActionForItem(at:)` (NSMenu.h). The action itself goes
    /// through `NSApp`, which only the hosted run has.
    @Test func aChosenItemCountsAsUse() {
        let bar = MenuBar()
        let activity = ServicesMenuActivity(mainMenu: { bar.mainMenu }, isQueuePrompting: { false }, noteOpened: { bar.notes += 1 })
        bar.recent.performActionForItem(at: 0)
        #expect(bar.notes == 2)
        if NSApp != nil { #expect(bar.actions == 1) }
        withExtendedLifetime(activity) {}
    }

    /// A key equivalent (⌘I for About here) posts them as well. Hosted only: with
    /// no `NSApp` AppKit sends neither the action nor the notifications. File > Open's ⌘O counts
    /// in any case (`KernirDocumentController.openDocument(_:)`).
    @Test(.enabled { await MainActor.run { NSApp != nil } })
    func aKeyEquivalentCountsAsUse() throws {
        let bar = MenuBar()
        let activity = ServicesMenuActivity(mainMenu: { bar.mainMenu }, isQueuePrompting: { false }, noteOpened: { bar.notes += 1 })
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                  timestamp: 0, windowNumber: 0, context: nil, characters: "i",
                                                  charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34))
        #expect(bar.main.performKeyEquivalent(with: event))
        #expect(bar.actions == 1)
        #expect(bar.notes == 2)
        withExtendedLifetime(activity) {}
    }

    // MARK: The queue's own prompts (Proposal A)

    /// What the queue's prompts and its job's work saw, as "<what> <isPrompting>".
    @MainActor private final class Prompts {
        weak var queue: ServicesJobQueue?
        var seen: [String] = []
        /// Runs in each prompt (not in the work), as a user's menu action would under it.
        var during: (@MainActor () -> Void)?

        func note(_ what: String) {
            seen.append("\(what) \(queue?.isPrompting == true)")
            if what != "work" { during?() }
        }
    }

    private static func posix(_ code: Int32) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }

    /// The queue running a real `ServicesJobRunner` (as `AppDelegate` builds it) over fakes: the
    /// work throws `errors` in turn and is then done; the Allow panel picks `pick`, the
    /// other-folder offer picks `other` (nil: Cancel). The work, both prompts and the failures
    /// alert note in `prompts` whether the queue is prompting then.
    private func promptingQueue(errors: [NSError], pick: URL? = nil, other: URL? = nil,
                                prompts: Prompts) -> ServicesJobQueue {
        var errors = errors
        let runner = ServicesJobRunner(
            extract: { _, _, _ in
                prompts.note("work")
                if !errors.isEmpty { throw errors.removeFirst() }
                return ServicesExtraction(result: Self.archive("a"))
            },
            access: { _ in nil },
            grant: { _ in },
            askForAccess: { _, _ in prompts.note("allow"); return pick },
            offerAnotherFolder: { _, _ in prompts.note("other folder"); return other },
            fileStamp: { _ in nil })
        effects.onAlert = { prompts.note("alert") }
        let queue = queue(prompting: { await runner.run($0, progress: $1, prompting: $2) })
        prompts.queue = queue
        return queue
    }

    /// Proposal A: each of the queue's own prompts (the Allow panel, the other-folder offer, the
    /// failures alert) is prompting while it is up, and only then: not in the work around it, and
    /// not once it has gone, whether the job then goes on, fails (throws) or ends there (Cancel).
    @Test(arguments: ["allow", "allow, cancelled", "allow, then a failure", "other folder",
                      "other folder, cancelled", "failures alert"])
    func theQueuesPromptsArePromptingWhileUp(path: String) async {
        let elsewhere = URL(fileURLWithPath: "/Users/u/Desktop", isDirectory: true)
        let (errors, pick, other, expected): ([NSError], URL?, URL?, [String]) = switch path {
        case "allow": ([Self.posix(EPERM)], Self.folder, nil, ["work false", "allow true", "work false"])
        case "allow, cancelled": ([Self.posix(EPERM)], nil, nil, ["work false", "allow true"])
        case "allow, then a failure":
            ([Self.posix(EPERM), Self.posix(ENOSPC)], Self.folder, nil,
             ["work false", "allow true", "work false", "alert true"])
        case "other folder": ([Self.posix(EROFS)], nil, elsewhere, ["work false", "other folder true", "work false"])
        case "other folder, cancelled": ([Self.posix(EROFS)], nil, nil, ["work false", "other folder true"])
        default: ([Self.posix(ENOSPC)], nil, nil, ["work false", "alert true"])
        }
        let prompts = Prompts()
        let queue = promptingQueue(errors: errors, pick: pick, other: other, prompts: prompts)
        #expect(!queue.isPrompting)
        queue.submit(.extractHere(Self.archive("a.zip")))
        await queue.waitUntilIdle()
        #expect(prompts.seen == expected)
        #expect(!queue.isPrompting)
    }

    /// Prompts may nest (a count, not a flag): the queue is prompting until the outer one ends.
    @Test func nestedPromptsEndWithTheOuterOne() async {
        let prompts = Prompts()
        let queue = queue(prompting: { _, _, prompting in
            prompting.begin()
            prompting.begin()
            prompts.note("inner")
            prompting.end()
            prompts.note("outer")
            prompting.end()
            prompts.note("work")
            return .done(Self.archive("a"))
        })
        prompts.queue = queue
        queue.submit(.extractHere(Self.archive("a.zip")))
        await queue.waitUntilIdle()
        #expect(prompts.seen == ["inner true", "outer true", "work false"])
        #expect(!queue.isPrompting)
    }

    /// A menu bar action while the queue's own prompt is up
    /// (⌘V or ⌘A in the Allow panel's Go to Folder) isn't use, so it can't keep a Services-only
    /// launch; the same action with no prompt up is.
    @Test(arguments: [NSMenu.willSendActionNotification, NSMenu.didSendActionNotification])
    func aMenuActionWhileTheQueuePromptsIsNotUse(name: Notification.Name) {
        let center = NotificationCenter()
        let bar = MenuBar()
        bar.isQueuePrompting = true
        let activity = ServicesMenuActivity(center: center, mainMenu: { bar.mainMenu },
                                            isQueuePrompting: { bar.isQueuePrompting }, noteOpened: { bar.notes += 1 })
        center.post(name: name, object: bar.recent)
        #expect(bar.notes == 0)
        bar.isQueuePrompting = false
        center.post(name: name, object: bar.recent)
        #expect(bar.notes == 1)
        withExtendedLifetime(activity) {}
    }

    /// The same, built from the queue as `AppDelegate` builds it (`init(queue:)`), through each of
    /// the queue's prompts: menu actions under them aren't counted; one once the queue is done is.
    @Test func menuActionsUnderTheQueuesPromptsAreNotUse() async {
        let center = NotificationCenter()
        let bar = MenuBar()
        let prompts = Prompts()
        let queue = promptingQueue(errors: [Self.posix(EPERM), Self.posix(EROFS), Self.posix(ENOSPC)],
                                   pick: Self.folder, other: URL(fileURLWithPath: "/Users/u/Desktop"),
                                   prompts: prompts)
        let activity = ServicesMenuActivity(queue: queue, center: center, mainMenu: { bar.mainMenu },
                                            noteOpened: { bar.notes += 1 })
        prompts.during = {
            for name in [NSMenu.willSendActionNotification, NSMenu.didSendActionNotification] {
                center.post(name: name, object: bar.file)
            }
        }
        queue.submit(.extractHere(Self.archive("a.zip")))
        await queue.waitUntilIdle()
        #expect(prompts.seen == ["work false", "allow true", "work false", "other folder true", "work false",
                                 "alert true"])
        #expect(bar.notes == 0)
        center.post(name: NSMenu.didSendActionNotification, object: bar.file)
        #expect(bar.notes == 1)
        withExtendedLifetime(activity) {}
    }

    /// Built from the queue, the activity doesn't keep it (`AppDelegate` owns it); with the queue
    /// gone, no prompt is up, so a menu action is use.
    @Test func theMenuActivityDoesNotKeepTheQueue() {
        let center = NotificationCenter()
        let bar = MenuBar()
        weak var gone: ServicesJobQueue?
        var activity: ServicesMenuActivity?
        do {
            let queue = queue(run: { _, _ in .done(Self.archive("a")) })
            activity = ServicesMenuActivity(queue: queue, center: center, mainMenu: { bar.mainMenu },
                                            noteOpened: { bar.notes += 1 })
            gone = queue
        }
        #expect(gone == nil)
        center.post(name: NSMenu.didSendActionNotification, object: bar.file)
        #expect(bar.notes == 1)
        withExtendedLifetime(activity) {}
    }

    /// A window counts as open when visible or in the Dock (minimized); panels (the progress
    /// panel, alerts, the Allow panel) never do.
    @Test(arguments: [(true, false, false, true), (false, true, false, true), (false, false, false, false),
                      (true, false, true, false), (false, true, true, false)])
    func whichWindowsCountAsOpen(isVisible: Bool, isMiniaturized: Bool, isPanel: Bool, counts: Bool) {
        #expect(ServicesJobEffects.countsAsOpen(isVisible: isVisible, isMiniaturized: isMiniaturized,
                                                isPanel: isPanel) == counts)
    }

    // MARK: The progress panel

    /// A job done before the delay shows no panel.
    @Test func aFastJobShowsNoPanel() async {
        let queue = queue(elapses: false) { _, _ in .done(Self.archive("a")) }
        queue.submit(.extractHere(Self.archive("a.zip")))
        await queue.waitUntilIdle()
        // The panel's task, cancelled when the job ended, must not show it late either.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(effects.delays == [ServicesJobQueue.panelDelay])
        #expect(effects.shown.isEmpty)
        #expect(effects.hides == 0)
        #expect(ServicesJobQueue.panelDelay == .seconds(1))
    }

    /// A slow job shows the panel with its title and progress, and hides it when done.
    @Test func aSlowJobShowsThePanelUntilItEnds() async {
        let gate = Gate()
        let queue = queue(elapses: true) { _, progress in
            await gate.wait()
            progress?(1, nil)
            return .done(Self.archive("a"))
        }
        queue.submit(.extractHere(Self.archive("a.zip")))
        await eventually { !effects.shown.isEmpty }
        #expect(effects.shown == [String(localized: "Extracting “\(ServicesJobRunner.displayName(of: Self.archive("a.zip")))”…")])
        #expect(effects.hides == 0)
        gate.open()
        await queue.waitUntilIdle()
        #expect(effects.hides == 1)
    }

    /// Progress reaches the panel while its job runs.
    @Test func progressReachesThePanel() async {
        let gate = Gate()
        let queue = queue(elapses: true) { _, progress in
            progress?(0.5, nil)
            await gate.wait()
            return .done(Self.archive("a"))
        }
        queue.submit(.extractHere(Self.archive("a.zip")))
        await eventually { effects.updates.contains(0.5) }
        #expect(effects.updates.contains(0.5))
        gate.open()
        await queue.waitUntilIdle()
    }

    /// Progress an earlier job sends late (its handler outlives it) doesn't reach the next job's panel.
    @Test func lateProgressOfAnEarlierJobIsDropped() async {
        var first: ArchiveProgressHandler?
        let gate = Gate()
        let queue = queue(elapses: true) { job, progress in
            guard case let .extractHere(archive) = job else { return .cancelled }
            if archive.lastPathComponent == "a.zip" {
                first = progress
                return .done(Self.archive("a"))
            }
            await gate.wait()
            return .done(Self.archive("b"))
        }
        queue.submit(.extractHere(Self.archive("a.zip")))
        queue.submit(.extractHere(Self.archive("b.zip")))
        await eventually { gate.isWaiting }
        first?(0.7, nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!effects.updates.contains(0.7))
        gate.open()
        await queue.waitUntilIdle()
    }

    /// While the job shows a panel or an alert of its own (the Allow panel), the progress panel
    /// hides and stays hidden; afterwards its delay starts again.
    @Test func theProgressPanelKeepsOutOfTheJobsPrompts() async {
        let gates = (shown: Gate(), asking: Gate(), after: Gate())
        let queue = queue(elapses: true, prompting: { _, _, prompting in
            await gates.shown.wait()
            prompting.begin()
            await gates.asking.wait()
            prompting.end()
            await gates.after.wait()
            return .done(Self.archive("a"))
        })
        queue.submit(.extractHere(Self.archive("a.zip")))
        await eventually { effects.shown.count == 1 && gates.shown.isWaiting }
        gates.shown.open()
        await eventually { gates.asking.isWaiting }
        #expect(effects.hides == 1)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(effects.shown.count == 1)
        gates.asking.open()
        await eventually { effects.shown.count == 2 }
        #expect(effects.delays.count == 2)
        gates.after.open()
        await queue.waitUntilIdle()
        #expect(effects.hides == 2)
    }

    /// A panel hidden for a prompt is hidden once: a job that ends right after the prompt, before
    /// the panel's delay is out again, doesn't hide it a second time.
    @Test func aPanelHiddenForAPromptIsNotHiddenAgain() async {
        let gate = Gate()
        let queue = queue(elapses: true, prompting: { _, _, prompting in
            await gate.wait()
            prompting.begin()
            prompting.end()
            return .done(Self.archive("a"))
        })
        queue.submit(.extractHere(Self.archive("a.zip")))
        await eventually { effects.shown.count == 1 && gate.isWaiting }
        effects.holdsDelays = true
        gate.open()
        await queue.waitUntilIdle()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(effects.delays.count == 2)
        #expect(effects.shown.count == 1)
        #expect(effects.hides == 1)
    }

    /// A prompt before the delay is out: the panel's delay starts over after it.
    @Test func aPromptRestartsThePanelsDelay() async {
        let gate = Gate()
        let queue = queue(elapses: false, prompting: { _, _, prompting in
            prompting.begin()
            await gate.wait()
            prompting.end()
            return .done(Self.archive("a"))
        })
        queue.submit(.extractHere(Self.archive("a.zip")))
        await eventually { gate.isWaiting }
        try? await Task.sleep(for: .milliseconds(20))
        gate.open()
        await queue.waitUntilIdle()
        #expect(effects.delays.count == 2)
        #expect(effects.shown.isEmpty)
    }

    /// Stop in the panel cancels the running job and drops the queued ones.
    @Test func stopCancelsTheJobAndDropsTheRest() async {
        var ran: [String] = []
        let queue = queue(elapses: true) { job, _ in
            guard case let .extractHere(archive) = job else { return .cancelled }
            ran.append(archive.lastPathComponent)
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                return .cancelled
            }
            return .done(Self.archive("a"))
        }
        queue.submit(.extractHere(Self.archive("a.zip")))
        queue.submit(.extractHere(Self.archive("b.zip")))
        await eventually { effects.stop != nil }
        effects.stop?()
        await queue.waitUntilIdle()
        #expect(ran == ["a.zip"])
        #expect(effects.revealed.isEmpty)
        #expect(effects.alerts.isEmpty)
    }

    @Test func titlesSayWhatIsRunning() {
        let items = ["a.txt", "b.txt", "c.txt"].map { Self.folder.appendingPathComponent($0) }
        #expect(ServicesJob.compress(items, format: .zip).progressTitle == String(localized: "Compressing \(3) items…"))
        #expect(ServicesJob.compress([items[0]], format: .zip).progressTitle
            == String(localized: "Compressing “\(ServicesJobRunner.displayName(of: items[0]))”…"))
        #expect(ServicesJob.extractHere(Self.folder.appendingPathComponent("x.zip")).progressTitle
            == "Extracting “\(ServicesJobRunner.displayName(of: Self.folder.appendingPathComponent("x.zip")))”…")
    }
}
