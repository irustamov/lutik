import Testing
import Foundation
@testable import Kernir
import KernirCore

/// `ArchiveModel`'s copies for opening in other apps: owned by the document until it closes,
/// reported when changed, and put back on Update.
@MainActor
struct OpenedFileModelTests {
    private static func file(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
    }

    private static func folder(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
    }

    private static let entries = [folder("docs"), file("docs/notes.txt"), file("readme.md")]

    /// Where this test's copies go: a folder of its own, so a test sees every copy made.
    private let copiesFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenedFileModelTests-\(UUID().uuidString)", isDirectory: true)
    /// The user's own files this test adds, outside `copiesFolder`.
    private var ownFolder: URL {
        copiesFolder.deletingLastPathComponent().appendingPathComponent(copiesFolder.lastPathComponent + "-own")
    }

    private func makeModel(entries: [ArchiveEntry] = Self.entries, format: ArchiveFormat = .zip,
                           undoManager: UndoManager? = nil, openedFiles: OpenedFiles? = nil) -> ArchiveModel {
        ArchiveModel(reader: FakeReader(entries: entries, format: format), undoManager: undoManager,
                     openedFiles: openedFiles ?? OpenedFiles(in: copiesFolder))
    }

    /// Closes the copies, as the document does, and deletes the test's folder.
    private func close(_ model: ArchiveModel) {
        model.openedFiles.close()
        try? FileManager.default.removeItem(at: copiesFolder)
        try? FileManager.default.removeItem(at: ownFolder)
    }

    /// What is in the test's folder: one `Kernir-<UUID>` folder per copy still on disk.
    private func copyFolders() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: copiesFolder.path)) ?? []
    }

    /// Changes the copy as another app's save would: new bytes and a later modification date.
    private func edit(_ url: URL, to contents: String) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: url.path)
    }

    /// Changes `url` as another app's save would, `seconds` from now. Callable off the main actor.
    private nonisolated static func write(_ contents: String, to url: URL, later seconds: TimeInterval) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(seconds)],
                                              ofItemAtPath: url.path)
    }

    /// Deletes folder "docs" and adds a file named "docs" in its place.
    private func replaceDocsWithAFile(in model: ArchiveModel) throws {
        try FileManager.default.createDirectory(at: ownFolder, withIntermediateDirectories: true)
        let docs = ownFolder.appendingPathComponent("docs")
        try Data("x".utf8).write(to: docs)
        model.remove(["docs"])
        model.add([docs], to: "")
    }

    @Test func copySurvivesSaveAndGoesOnClose() async throws {
        let model = makeModel()
        let url = try await model.copyForOpening("docs/notes.txt")
        #expect(url.lastPathComponent == "notes.txt")
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "docs/notes.txt")
        // Not the reader's cache, which a save drops.
        #expect(url != (try await model.localFileURL(for: "docs/notes.txt")))
        model.didSave(reader: FakeReader(entries: Self.entries))
        #expect(FileManager.default.fileExists(atPath: url.path))
        // The model's own temporary files go without it: the document owns the copies.
        model.removeTemporaryFiles()
        #expect(FileManager.default.fileExists(atPath: url.path))
        close(model)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(model.changedOpenedFiles().isEmpty)
    }

    /// Revert to Saved and a failed reopen after a save replace the model; the copies stay the
    /// document's, so a change is still offered back and the copy still goes on close.
    @Test func replacementModelKeepsTheCopies() async throws {
        let opened = OpenedFiles(in: copiesFolder)
        let first = makeModel(openedFiles: opened)
        let url = try await first.copyForOpening("docs/notes.txt")
        first.removeTemporaryFiles()
        let second = makeModel(openedFiles: opened)
        defer { close(second) }
        try edit(url, to: "edited")
        let changed = try #require(second.changedOpenedFiles().first)
        #expect(changed.url == url && changed.path == "docs/notes.txt")
        #expect(await second.update(from: changed))
        #expect(second.item(at: "docs/notes.txt")?.isPendingAddition == true)
        #expect(second.changedOpenedFiles().isEmpty)
    }

    @Test func removeTemporaryFilesKeepsOpenedCopies() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        model.removeTemporaryFiles()
        #expect(FileManager.default.fileExists(atPath: url.path))
        try edit(url, to: "edited")
        #expect(model.changedOpenedFiles().map(\.url) == [url])
        model.openedFiles.close()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(copyFolders().isEmpty)
        #expect(model.changedOpenedFiles().isEmpty)
    }

    /// The document closed while the open waited: the copy would outlive the close.
    @Test func copyAfterCloseIsNotMadeAndThrows() async throws {
        let model = makeModel()
        defer { close(model) }
        model.openedFiles.close()
        await #expect(throws: CancellationError.self) { try await model.copyForOpening("readme.md") }
        #expect(copyFolders().isEmpty)
        #expect(model.openedFiles.files.isEmpty)
    }

    /// `discard` is for a url `copy` returned: any other url, one no tracked folder holds, changes nothing.
    @Test func discardOfAnUntrackedUrlDoesNothing() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        // A file in a folder of the same parent that no copy made, and one outside the copies' folder.
        let stranger = copiesFolder.appendingPathComponent("Kernir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        let strangerFile = stranger.appendingPathComponent("x.txt")
        try Data("x".utf8).write(to: strangerFile)
        try FileManager.default.createDirectory(at: ownFolder, withIntermediateDirectories: true)
        let own = ownFolder.appendingPathComponent("own.txt")
        try Data("own".utf8).write(to: own)
        let before = model.openedFiles.files
        let folders = copyFolders()

        model.openedFiles.discard(strangerFile)
        model.openedFiles.discard(own)

        #expect(FileManager.default.fileExists(atPath: strangerFile.path))
        #expect(FileManager.default.fileExists(atPath: own.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(model.openedFiles.files == before)
        #expect(copyFolders() == folders)
    }

    @Test func discardOfOneCopyKeepsTheOther() async throws {
        let model = makeModel()
        defer { close(model) }
        let first = try await model.copyForOpening("readme.md")
        let second = try await model.copyForOpening("docs/notes.txt")

        model.openedFiles.discard(first)

        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: second.deletingLastPathComponent().path))
        #expect(model.openedFiles.files.map(\.url) == [second])
        #expect(copyFolders() == [second.deletingLastPathComponent().lastPathComponent])
    }

    /// A discarded copy's folder takes its kept new items (Don't Update) with it: none stays listed as kept.
    @Test func discardForgetsTheKeptNewItemsInTheFolder() async throws {
        let model = makeModel()
        defer { close(model) }
        let first = try await model.copyForOpening("readme.md")
        let second = try await model.copyForOpening("docs/notes.txt")
        for copy in [first, second] {
            try Data("new".utf8).write(to: copy.deletingLastPathComponent().appendingPathComponent("new.txt"))
        }
        for found in model.changedOpenedFiles() { model.markSeen(found) }
        func keptFolders() -> [String] {
            model.openedFiles.keptNewItems.map { $0.deletingLastPathComponent().lastPathComponent }.sorted()
        }
        let folders = [first, second].map { $0.deletingLastPathComponent().lastPathComponent }
        #expect(keptFolders() == folders.sorted())

        model.openedFiles.discard(first)

        #expect(keptFolders() == [folders[1]])
    }

    /// A model replacing this one (Revert to Saved) restores the saved path of each copy an unsaved rename
    /// moved; the discarded copy is gone and stays gone, the other is restored.
    @Test func adoptAfterDiscardRestoresNothingForTheDiscardedCopy() async throws {
        let model = makeModel()
        defer { close(model) }
        #expect(model.rename("readme.md", to: "intro.md") == .success("intro.md"))
        #expect(model.rename("docs", to: "papers") == .success("papers"))
        let discarded = try await model.copyForOpening("intro.md")
        let kept = try await model.copyForOpening("papers/notes.txt")
        #expect(model.openedFiles.files.map(\.path) == ["intro.md", "papers/notes.txt"])

        model.openedFiles.discard(discarded)
        let reverted = makeModel(openedFiles: model.openedFiles)
        defer { reverted.removeTemporaryFiles() }

        #expect(!FileManager.default.fileExists(atPath: discarded.path))
        #expect(model.openedFiles.files.map(\.url) == [kept])
        #expect(model.openedFiles.files.map(\.path) == ["docs/notes.txt"])
        #expect(copyFolders() == [kept.deletingLastPathComponent().lastPathComponent])
    }

    @Test func cancelledOpenMakesNoCopy() async throws {
        let model = makeModel()
        defer { close(model) }
        let task = Task { try await model.copyForOpening("readme.md") }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(copyFolders().isEmpty)
        #expect(model.openedFiles.files.isEmpty)
    }

    /// The copy runs off the main actor (a pending addition can be a big file on a slow volume);
    /// a close or cancel while it runs deletes it once it's done, and nothing is tracked.
    /// Time-limited: if the copy ran on the main actor, `gate.wait()` would hang, not fail.
    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func copyInterruptedWhileRunningIsDeletedAndThrows(byClose: Bool) async throws {
        let opened = OpenedFiles(in: copiesFolder)
        let started = AsyncStream<Bool>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        opened.copyItem = { source, destination in
            started.continuation.yield(Thread.isMainThread)
            gate.wait()
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let model = makeModel(openedFiles: opened)
        defer { close(model) }
        let task = Task { try await model.copyForOpening("readme.md") }
        var onMainThread: Bool?
        for await value in started.stream {
            onMainThread = value
            break
        }
        #expect(onMainThread == false)
        if byClose { opened.close() } else { task.cancel() }
        gate.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(copyFolders().isEmpty)
        #expect(opened.files.isEmpty)
    }

    /// A copy that fails leaves no folder behind and tracks nothing.
    @Test func failedCopyLeavesNothing() async throws {
        let opened = OpenedFiles(in: copiesFolder)
        opened.copyItem = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let model = makeModel(openedFiles: opened)
        defer { close(model) }
        await #expect(throws: CocoaError.self) { try await model.copyForOpening("readme.md") }
        #expect(copyFolders().isEmpty)
        #expect(opened.files.isEmpty)
    }

    @Test func eachOpenIsItsOwnCopy() async throws {
        let model = makeModel()
        defer { close(model) }
        let first = try await model.copyForOpening("readme.md")
        let second = try await model.copyForOpening("readme.md")
        #expect(first != second)
        #expect(first.lastPathComponent == "readme.md" && second.lastPathComponent == "readme.md")
    }

    @Test func folderIsNotOpenedAsACopy() async throws {
        let model = makeModel()
        defer { close(model) }
        await #expect(throws: (any Error).self) { try await model.copyForOpening("docs") }
    }

    @Test func onlyChangedCopiesAreReportedInOpeningOrder() async throws {
        let model = makeModel()
        defer { close(model) }
        let notes = try await model.copyForOpening("docs/notes.txt")
        let readme = try await model.copyForOpening("readme.md")
        let unchanged = try await model.copyForOpening("readme.md")
        #expect(model.changedOpenedFiles().isEmpty)
        try edit(readme, to: "new readme")
        try edit(notes, to: "new notes")
        #expect(model.changedOpenedFiles().map(\.url) == [notes, readme])
        #expect(model.changedOpenedFiles().map(\.path) == ["docs/notes.txt", "readme.md"])
        #expect(!model.changedOpenedFiles().map(\.url).contains(unchanged))
    }

    /// A same-size change with only a new date counts; so does a new size with the same date.
    @Test func sizeOrDateChangeCounts() async throws {
        let model = makeModel()
        defer { close(model) }
        let byDate = try await model.copyForOpening("readme.md")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: byDate.path)
        let bySize = try await model.copyForOpening("docs/notes.txt")
        let date = try FileManager.default.attributesOfItem(atPath: bySize.path)[.modificationDate] as? Date
        try Data("much longer contents".utf8).write(to: bySize)
        try FileManager.default.setAttributes([.modificationDate: date as Any], ofItemAtPath: bySize.path)
        #expect(Set(model.changedOpenedFiles().map(\.url)) == [byDate, bySize])
    }

    @Test func deletedCopyIsNotReported() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        try FileManager.default.removeItem(at: url)
        #expect(model.changedOpenedFiles().isEmpty)
    }

    /// Another app's Export or Save As into the copy's folder: offered as an addition beside the
    /// copy's item, never deleted on close without a question.
    @Test func fileSavedNextToTheCopyIsOfferedAsAnAddition() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("docs/notes.txt")
        let exported = url.deletingLastPathComponent().appendingPathComponent("notes.pdf")
        try Data("export".utf8).write(to: exported)
        let changed = model.changedOpenedFiles()
        #expect(changed.map(\.url) == [exported])
        #expect(changed.map(\.path) == ["docs/notes.pdf"])

        #expect(await model.update(from: try #require(changed.first)))
        #expect(model.item(at: "docs/notes.pdf")?.isPendingAddition == true)
        #expect(model.item(at: "docs/notes.txt")?.isPendingAddition == false)
        #expect(model.changedOpenedFiles().isEmpty)
        // Tracked from now on: a later change is offered again.
        try edit(exported, to: "export 2")
        #expect(model.changedOpenedFiles().map(\.url) == [exported])
    }

    /// A renamed copy is offered under its new name; the old name, gone, has nothing to update.
    @Test func renamedCopyIsOfferedUnderItsNewName() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        let renamed = url.deletingLastPathComponent().appendingPathComponent("readme edited.md")
        try edit(url, to: "edited")
        try FileManager.default.moveItem(at: url, to: renamed)
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(model.changedOpenedFiles().count == 1)
        #expect(changed.url == renamed && changed.path == "readme edited.md")
        // Don't Update: not offered again until it changes again.
        model.markSeen(changed)
        #expect(model.changedOpenedFiles().isEmpty)
        try edit(renamed, to: "edited again")
        #expect(model.changedOpenedFiles().map(\.url) == [renamed])
    }

    /// Probe: an export next to a copy at the archive's top level is offered, as a new item,
    /// and only the document's close deletes it.
    @Test func siblingSavedNextToTheCopyIsReportedNotDeleted() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        let exported = url.deletingLastPathComponent().appendingPathComponent("readme.pdf")
        try Data("user's export".utf8).write(to: exported)
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(changed.url == exported && changed.path == "readme.pdf")
        #expect(!model.openedFiles.isTracked(changed))
        model.removeTemporaryFiles()
        #expect(FileManager.default.fileExists(atPath: exported.path))
        #expect(model.changedOpenedFiles().map(\.url) == [exported])
    }

    /// Probe: a copy renamed after an edit is offered under its new name, and only the
    /// document's close deletes it.
    @Test func renamedCopyIsReportedNotDeleted() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        let renamed = url.deletingLastPathComponent().appendingPathComponent("readme edited.md")
        try Data("edited".utf8).write(to: url)
        try FileManager.default.moveItem(at: url, to: renamed)
        #expect(model.changedOpenedFiles().map(\.url) == [renamed])
        model.removeTemporaryFiles()
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(model.changedOpenedFiles().map(\.url) == [renamed])
    }

    /// Only items in the copies' own folders are taken on: anything else is never tracked.
    @Test func markSeenIgnoresAFileOutsideTheCopyFolders() async throws {
        let model = makeModel()
        defer { close(model) }
        _ = try await model.copyForOpening("readme.md")
        let outside = copiesFolder.appendingPathComponent("elsewhere.txt")
        try Data("x".utf8).write(to: outside)
        model.markSeen(OpenedFiles.File(path: "elsewhere.txt", url: outside, size: 1, modified: nil))
        #expect(model.openedFiles.files.map(\.path) == ["readme.md"])
    }

    /// Changed copies come first, in opening order; then each copy folder's new items, by name.
    @Test func changedCopiesComeBeforeNewItems() async throws {
        let model = makeModel()
        defer { close(model) }
        let notes = try await model.copyForOpening("docs/notes.txt")
        let readme = try await model.copyForOpening("readme.md")
        try Data("b".utf8).write(to: notes.deletingLastPathComponent().appendingPathComponent("b.txt"))
        try Data("a".utf8).write(to: notes.deletingLastPathComponent().appendingPathComponent("a.txt"))
        try edit(readme, to: "edited")
        #expect(model.changedOpenedFiles().map(\.path) == ["readme.md", "docs/a.txt", "docs/b.txt"])
        #expect(model.changedOpenedFiles().map { model.openedFiles.isTracked($0) } == [true, false, false])
    }

    /// Finder's .DS_Store (Show in Finder) and editors' hidden lock or swap files aren't offered.
    @Test func hiddenItemsNextToTheCopyAreNotOffered() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        let folder = url.deletingLastPathComponent()
        try Data("x".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        try Data("x".utf8).write(to: folder.appendingPathComponent(".readme.md.swp"))
        var hidden = folder.appendingPathComponent("~$readme.md")
        try Data("x".utf8).write(to: hidden)
        var values = URLResourceValues()
        values.isHidden = true
        try hidden.setResourceValues(values)
        #expect(model.changedOpenedFiles().isEmpty)
    }

    /// A folder saved next to the copy (a package, say) is offered too, and goes in whole.
    @Test func folderSavedNextToTheCopyIsOffered() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        let package = url.deletingLastPathComponent().appendingPathComponent("readme.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("text".utf8).write(to: package.appendingPathComponent("TXT.rtf"))
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(changed.path == "readme.rtfd")
        #expect(await model.update(from: changed))
        #expect(model.item(at: "readme.rtfd/TXT.rtf")?.isPendingAddition == true)
    }

    @Test func updatePutsTheChangedCopyInPlaceAndUndoes() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let model = makeModel(undoManager: undoManager)
        defer { close(model) }
        let url = try await model.copyForOpening("docs/notes.txt")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)

        undoManager.beginUndoGrouping()
        #expect(await model.update(from: changed))
        undoManager.endUndoGrouping()
        let item = try #require(model.item(at: "docs/notes.txt"))
        #expect(item.isPendingAddition)
        // A snapshot of the copy goes in, not the copy the other app still has open.
        let added = try await model.localFileURL(for: "docs/notes.txt")
        #expect(added != url && added.lastPathComponent == "notes.txt")
        #expect(String(decoding: try Data(contentsOf: added), as: UTF8.self) == "edited")
        #expect(model.changedOpenedFiles().isEmpty)
        #expect(undoManager.undoActionName == String(localized: "Update", table: "Shared"))

        undoManager.undo()
        #expect(model.item(at: "docs/notes.txt")?.isPendingAddition == false)
    }

    @Test func dontUpdateStopsReportingIt() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        model.markSeen(changed)
        #expect(model.changedOpenedFiles().isEmpty)
        #expect(model.item(at: "readme.md")?.isPendingAddition == false)
        // A later change is reported again.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)],
                                              ofItemAtPath: url.path)
        #expect(model.changedOpenedFiles().map(\.url) == [url])
    }

    @Test func updateDoesNothingToAReadOnlyArchive() async throws {
        let model = makeModel(format: .rar)
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(await model.update(from: changed) == false)
        #expect(model.item(at: "readme.md")?.isPendingAddition == false)
        #expect(model.changedOpenedFiles().map(\.url) == [url])
        #expect(copyFolders().count == 1)
    }

    /// The archive gets the bytes the user said Update to, not whatever the other app writes to
    /// the copy later; that later write is offered again.
    @Test func updateAddsASnapshotNotTheLiveCopy() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        try edit(url, to: "edited")
        #expect(await model.update(from: try #require(model.changedOpenedFiles().first)))
        try Data("edited later, and longer".utf8).write(to: url)
        let added = try await model.localFileURL(for: "readme.md")
        #expect(String(decoding: try Data(contentsOf: added), as: UTF8.self) == "edited")
        // The snapshot's folder isn't a copy's: nothing in it is offered.
        #expect(model.changedOpenedFiles().map(\.url) == [url])
        #expect(copyFolders().count == 2)
        model.openedFiles.close()
        #expect(copyFolders().isEmpty)
    }

    /// The other app writes while the snapshot is cloned: it's cloned once more, and what that
    /// clone started from is what's seen.
    @Test func copyChangedDuringTheSnapshotIsClonedAgain() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        let calls = Calls()
        model.openedFiles.copyItem = { source, destination in
            if calls.next() == 1 { try Self.write("saved meanwhile", to: source, later: 120) }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        #expect(await model.update(from: changed))
        #expect(calls.count == 2)
        let added = try await model.localFileURL(for: "readme.md")
        #expect(String(decoding: try Data(contentsOf: added), as: UTF8.self) == "saved meanwhile")
        let seen = try #require(model.openedFiles.files.first)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(seen.size == (attributes[.size] as? NSNumber)?.int64Value)
        #expect(seen.modified == attributes[.modificationDate] as? Date)
        #expect(model.changedOpenedFiles().isEmpty)
    }

    /// Still changing on the second clone: nothing goes in, the snapshot is deleted, and the copy
    /// is still offered.
    @Test func copyStillChangingAfterARetryIsNotUpdated() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        let calls = Calls()
        model.openedFiles.copyItem = { source, destination in
            let call = calls.next()
            try Self.write("save \(call)", to: source, later: 120 * Double(call))
            try FileManager.default.copyItem(at: source, to: destination)
        }
        #expect(await model.update(from: changed) == false)
        #expect(calls.count == 2)
        #expect(model.item(at: "readme.md")?.isPendingAddition == false)
        #expect(model.changedOpenedFiles().map(\.url) == [url])
        #expect(copyFolders().count == 1)
    }

    /// Don't Update takes what the alert showed as seen; a save made while it was up is offered
    /// again.
    @Test func dontUpdateCoversOnlyWhatTheAlertShowed() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        try edit(url, to: "edited")
        let shown = try #require(model.changedOpenedFiles().first)
        #expect(shown.size == 6)
        try Self.write("edited while the alert was up", to: url, later: 120)
        model.markSeen(shown)
        #expect(model.changedOpenedFiles().map(\.url) == [url])
        #expect(model.changedOpenedFiles().first?.size == 29)
    }

    /// Probe: an item the archive spells in NFD is replaced, not joined by an NFC twin.
    @Test func nfdNameUpdatesInPlace() async throws {
        let nfd = "cafe\u{301}.txt"
        let entries = [ArchiveEntry(path: nfd, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)]
        let model = ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil,
                                 openedFiles: OpenedFiles(in: copiesFolder))
        defer { close(model) }
        let url = try await model.copyForOpening(nfd)
        try edit(url, to: "edited")
        #expect(await model.update(from: try #require(model.changedOpenedFiles().first)))
        #expect(model.children(of: "").count == 1)
        #expect(model.changes.removedPaths.count == 1)
        #expect(model.changes.additions.count == 1)
    }

    /// A name behind a hidden "/" (a mark or ZWJ after it, a Prepend scalar before it) is snapshotted under its
    /// own name, right in its `Kernir-<UUID>` folder, not cloned into a subfolder named after its parent.
    @Test(arguments: [("a/\u{301}b", "a", "\u{301}b"), ("a/\u{200D}b", "a", "\u{200D}b"),
                      ("a\u{600}/b", "a\u{600}", "b")])
    func aNameBehindAHiddenSlashUpdates(_ path: String, _ folder: String, _ name: String) async throws {
        let model = makeModel(entries: [Self.folder(folder)])
        defer { close(model) }
        try FileManager.default.createDirectory(at: ownFolder, withIntermediateDirectories: true)
        let url = ownFolder.appendingPathComponent("own.txt")
        try Data("edited".utf8).write(to: url)
        #expect(await model.update(from: OpenedFiles.File(path: path, url: url, size: nil, modified: nil)))
        #expect(try #require(model.item(at: path)).isPendingAddition)
        let added = try await model.localFileURL(for: path)
        #expect(added.lastPathComponent.unicodeScalars.elementsEqual(name.unicodeScalars))
        #expect(added.deletingLastPathComponent().deletingLastPathComponent().path == copiesFolder.path)
        #expect(String(decoding: try Data(contentsOf: added), as: UTF8.self) == "edited")
    }

    /// A file now where the copy's archive folder was: nothing goes in, and it's still offered.
    @Test func updateRefusedByAFileAtTheFolderReturnsFalse() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("docs/notes.txt")
        try edit(url, to: "edited")
        try replaceDocsWithAFile(in: model)
        #expect(await model.update(from: try #require(model.changedOpenedFiles().first)) == false)
        #expect(model.item(at: "docs/notes.txt") == nil)
        #expect(model.changedOpenedFiles().map(\.url) == [url])
        #expect(copyFolders().count == 1)
    }

    @Test func updateOfAGoneCopyReturnsFalse() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        try FileManager.default.removeItem(at: url)
        #expect(await model.update(from: changed) == false)
        #expect(model.item(at: "readme.md")?.isPendingAddition == false)
        #expect(copyFolders().count == 1)
    }

    /// The archive changes while the snapshot is made: closed, the update cancelled, or a file now
    /// where the item's folder was. Nothing goes in and, unless closed, the copy is still offered.
    /// A snapshot that was made and refused by `add` is deleted, not kept until the close.
    enum Interruption: CaseIterable { case close, cancel, fileAtTheFolder }

    @Test(.timeLimit(.minutes(1)), arguments: Interruption.allCases)
    func updateInterruptedDuringTheSnapshotReturnsFalse(by interruption: Interruption) async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("docs/notes.txt")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        let started = AsyncStream<Void>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        model.openedFiles.copyItem = { source, destination in
            started.continuation.yield()
            gate.wait()
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let task = Task { await model.update(from: changed) }
        for await _ in started.stream { break }
        switch interruption {
        case .close: model.openedFiles.close()
        case .cancel: task.cancel()
        case .fileAtTheFolder: try replaceDocsWithAFile(in: model)
        }
        gate.signal()
        #expect(await task.value == false)
        #expect(model.item(at: "docs/notes.txt")?.isPendingAddition != true)
        #expect(model.changedOpenedFiles().map(\.url) == (interruption == .close ? [] : [url]))
        let folders: [Interruption: Int] = [.close: 0, .cancel: 1, .fileAtTheFolder: 1]
        #expect(copyFolders().count == folders[interruption])
    }

    /// A pending addition is the user's own file: opening hands out a copy, never the file itself.
    @Test func pendingAdditionIsCopiedNotHandedOut() async throws {
        let own = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenedFileModelTests-mine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: own) }
        let mine = own.appendingPathComponent("mine.txt")
        try Data("mine".utf8).write(to: mine)
        let model = makeModel()
        defer { close(model) }
        model.add([mine], to: "")
        let url = try await model.copyForOpening("mine.txt")
        #expect(url != mine)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "mine")
    }

    // MARK: - Names already in the archive

    private static let photos = [file("photo.png"), file("photo.jpg")]

    /// Opens photo.png and saves "photo.jpg" next to the copy, as Preview's File > Export would.
    private func exportNamedLikeASibling(in model: ArchiveModel) async throws -> OpenedFiles.File {
        let url = try await model.copyForOpening("photo.png")
        try Data("exported".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("photo.jpg"))
        let changed = model.changedOpenedFiles()
        try #require(changed.count == 1)
        return changed[0]
    }

    private func contents(of path: String, in model: ArchiveModel) async throws -> String {
        String(decoding: try Data(contentsOf: try await model.localFileURL(for: path)), as: UTF8.self)
    }

    /// Probe: a new item named like a different archive item never replaces it unasked.
    @Test func newItemNamedLikeAnItemIsntPutInUnasked() async throws {
        let model = makeModel(entries: Self.photos)
        defer { close(model) }
        let export = try await exportNamedLikeASibling(in: model)
        #expect(export.path == "photo.jpg" && !model.openedFiles.isTracked(export))
        #expect(model.wouldReplace(export))
        #expect(await model.update(from: export) == false)
        #expect(model.item(at: "photo.jpg")?.isPendingAddition == false)
        #expect(model.changes.removedPaths.isEmpty)
        #expect(model.changedOpenedFiles() == [export])
    }

    /// Keep Both puts it in under the next free Finder-style name. From then on it is that item,
    /// so a later change updates "photo 3.jpg" without asking, and never the original.
    @Test func keepBothPutsItInUnderAFreeName() async throws {
        let model = makeModel(entries: Self.photos + [Self.file("photo 2.jpg")])
        defer { close(model) }
        let export = try await exportNamedLikeASibling(in: model)
        #expect(await model.update(from: export, ifNameIsTaken: .keepBoth))
        #expect(model.item(at: "photo 3.jpg")?.isPendingAddition == true)
        #expect(model.item(at: "photo.jpg")?.isPendingAddition == false)
        #expect(model.item(at: "photo 2.jpg")?.isPendingAddition == false)
        #expect(model.changes.removedPaths.isEmpty)
        #expect(try await contents(of: "photo 3.jpg", in: model) == "exported")
        #expect(model.changedOpenedFiles().isEmpty)

        try edit(export.url, to: "exported again")
        let again = try #require(model.changedOpenedFiles().first)
        #expect(again.path == "photo 3.jpg" && !model.wouldReplace(again))
        #expect(await model.update(from: again))
        #expect(try await contents(of: "photo 3.jpg", in: model) == "exported again")
        #expect(model.item(at: "photo.jpg")?.isPendingAddition == false)
        #expect(model.item(at: "photo 4.jpg") == nil)
    }

    /// Replace is the user's choice; the item is then the archive's "photo.jpg", and a later
    /// change updates it without asking again.
    @Test func replaceIsAChoiceThenTheItemIsThatItem() async throws {
        let model = makeModel(entries: Self.photos)
        defer { close(model) }
        let export = try await exportNamedLikeASibling(in: model)
        #expect(await model.update(from: export, ifNameIsTaken: .replace))
        #expect(model.item(at: "photo.jpg")?.isPendingAddition == true)
        #expect(model.item(at: "photo 2.jpg") == nil)
        #expect(try await contents(of: "photo.jpg", in: model) == "exported")
        try edit(export.url, to: "exported again")
        let again = try #require(model.changedOpenedFiles().first)
        #expect(!model.wouldReplace(again))
        #expect(await model.update(from: again))
        #expect(try await contents(of: "photo.jpg", in: model) == "exported again")
    }

    /// Don't Update only marks it seen: when it changes again, putting it in still takes a choice.
    @Test func dontUpdateStillAsksNextTime() async throws {
        let model = makeModel(entries: Self.photos)
        defer { close(model) }
        let export = try await exportNamedLikeASibling(in: model)
        model.markSeen(export)
        #expect(model.openedFiles.isTracked(export))
        try edit(export.url, to: "exported again")
        let again = try #require(model.changedOpenedFiles().first)
        #expect(model.wouldReplace(again))
        #expect(await model.update(from: again) == false)
        #expect(model.changes.removedPaths.isEmpty)
    }

    /// A copy renamed to a sibling's name is a new item named like that sibling.
    @Test func copyRenamedToASiblingsNameIsntPutInUnasked() async throws {
        let model = makeModel(entries: Self.photos)
        defer { close(model) }
        let url = try await model.copyForOpening("photo.png")
        try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("photo.jpg"))
        let renamed = try #require(model.changedOpenedFiles().first)
        #expect(model.wouldReplace(renamed))
        #expect(await model.update(from: renamed) == false)
        #expect(model.changes.removedPaths.isEmpty)
    }

    /// A copy goes back over its own item, and a new item with a free name goes in, unasked.
    @Test func ownItemAndAFreeNameNeedNoChoice() async throws {
        let model = makeModel(entries: Self.photos)
        defer { close(model) }
        let url = try await model.copyForOpening("photo.png")
        try edit(url, to: "edited")
        try Data("pdf".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("photo.pdf"))
        let changed = model.changedOpenedFiles()
        #expect(changed.map(\.path) == ["photo.png", "photo.pdf"])
        #expect(!changed.contains { model.wouldReplace($0) })
        for file in changed { #expect(await model.update(from: file)) }
        #expect(model.item(at: "photo.png")?.isPendingAddition == true)
        #expect(model.item(at: "photo.pdf")?.isPendingAddition == true)
        #expect(model.item(at: "photo.jpg")?.isPendingAddition == false)
    }

    /// The archive can take the name while the snapshot is made (the user adds a file of that
    /// name): then nothing goes in, the user's file stays, and the item is still offered.
    @Test(.timeLimit(.minutes(1)), arguments: [
        (UpdateConflictResolution?.none, "photo.pdf", "photo.pdf"),
        (UpdateConflictResolution?.some(.keepBoth), "photo.jpg", "photo 2.jpg"),
    ])
    func nameTakenDuringTheSnapshotIsntReplaced(choice: UpdateConflictResolution?, saved: String,
                                                takenMeanwhile: String) async throws {
        let opened = OpenedFiles(in: copiesFolder)
        let model = makeModel(entries: Self.photos, openedFiles: opened)
        defer { close(model) }
        let url = try await model.copyForOpening("photo.png")
        try Data("saved".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent(saved))
        let file = try #require(model.changedOpenedFiles().first)
        #expect(file.path == saved)
        let started = AsyncStream<Void>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        opened.copyItem = { source, destination in
            started.continuation.yield()
            gate.wait()
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let update = Task { await model.update(from: file, ifNameIsTaken: choice) }
        for await _ in started.stream { break }
        try FileManager.default.createDirectory(at: ownFolder, withIntermediateDirectories: true)
        let mine = ownFolder.appendingPathComponent(takenMeanwhile)
        try Data("mine".utf8).write(to: mine)
        model.add([mine], to: "")
        gate.signal()
        #expect(await update.value == false)
        #expect(try await contents(of: takenMeanwhile, in: model) == "mine")
        #expect(model.changes.removedPaths.isEmpty)
        #expect(model.changedOpenedFiles().map(\.path) == [saved])
    }

    // MARK: - The item at the path is its own

    /// The user's own file, outside the copies' folders.
    private func ownFile(_ name: String, _ contents: String = "mine") throws -> URL {
        try FileManager.default.createDirectory(at: ownFolder, withIntermediateDirectories: true)
        let url = ownFolder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Keep Both put "photo 2.jpg" in, then the Update was undone and the user added their own
    /// "photo 2.jpg": a later change of the export takes a choice, and the user's file stays.
    @Test func keptBothItemDoesntReplaceTheUsersFileAfterUndo() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let model = makeModel(entries: Self.photos, undoManager: undoManager)
        defer { close(model) }
        let export = try await exportNamedLikeASibling(in: model)
        undoManager.beginUndoGrouping()
        #expect(await model.update(from: export, ifNameIsTaken: .keepBoth))
        undoManager.endUndoGrouping()
        undoManager.undo()
        #expect(model.item(at: "photo 2.jpg") == nil)
        let mine = try ownFile("photo 2.jpg")
        undoManager.beginUndoGrouping()
        model.add([mine], to: "")
        undoManager.endUndoGrouping()

        try edit(export.url, to: "exported again")
        let again = try #require(model.changedOpenedFiles().first)
        #expect(again.path == "photo 2.jpg")
        #expect(model.wouldReplace(again))
        undoManager.beginUndoGrouping()
        #expect(await model.update(from: again) == false)
        undoManager.endUndoGrouping()
        #expect(try await model.localFileURL(for: "photo 2.jpg") == mine)
        #expect(model.changes.removedPaths.isEmpty)
    }

    /// Keep Both took "photo 2.jpg" because the user had deleted the saved one; Revert to Saved
    /// (a new model on the same copies) brings it back. A later change of the export takes a choice.
    @Test func keptBothItemDoesntReplaceASavedItemAfterRevert() async throws {
        let saved = Self.photos + [Self.file("photo 2.jpg")]
        let model = makeModel(entries: saved)
        defer { close(model) }
        model.remove(["photo 2.jpg"])
        let export = try await exportNamedLikeASibling(in: model)
        #expect(await model.update(from: export, ifNameIsTaken: .keepBoth))
        #expect(model.item(at: "photo 2.jpg")?.isPendingAddition == true)
        let reverted = makeModel(entries: saved, openedFiles: model.openedFiles)

        try edit(export.url, to: "exported again")
        let again = try #require(reverted.changedOpenedFiles().first)
        #expect(again.path == "photo 2.jpg")
        #expect(reverted.wouldReplace(again))
        #expect(await reverted.update(from: again) == false)
        #expect(reverted.item(at: "photo 2.jpg")?.isPendingAddition == false)
        #expect(reverted.changes.removedPaths.isEmpty)
    }

    /// The copy's item was deleted and a folder of that name added: the copy is no longer that
    /// item, so putting it back takes a choice, and the folder stays.
    @Test func copyDoesntReplaceAFolderThatTookItsPath() async throws {
        let model = makeModel(entries: [Self.file("notes")])
        defer { close(model) }
        let url = try await model.copyForOpening("notes")
        model.remove(["notes"])
        let folder = ownFolder.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("keep.txt"))
        model.add([folder], to: "")

        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(changed.path == "notes")
        #expect(model.wouldReplace(changed))
        #expect(await model.update(from: changed) == false)
        #expect(model.item(at: "notes")?.isDirectory == true)
        #expect(model.item(at: "notes/keep.txt")?.isPendingAddition == true)
    }

    /// The copy's item was deleted and a file added into a new folder of that name: that folder
    /// is no item of the copy's either.
    @Test func copyDoesntReplaceAFolderMadeForAnAddition() async throws {
        let model = makeModel(entries: [Self.file("notes")])
        defer { close(model) }
        let url = try await model.copyForOpening("notes")
        model.remove(["notes"])
        model.add([try ownFile("keep.txt")], to: "notes")
        #expect(model.item(at: "notes")?.isDirectory == true)

        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(model.wouldReplace(changed))
        #expect(await model.update(from: changed) == false)
        #expect(model.item(at: "notes/keep.txt")?.isPendingAddition == true)
    }

    /// The copy's item was deleted and nothing took its name: the copy simply goes back in.
    @Test func copyOfAGoneItemGoesInUnasked() async throws {
        let model = makeModel()
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        model.remove(["readme.md"])
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(!model.wouldReplace(changed))
        #expect(await model.update(from: changed))
        #expect(try await contents(of: "readme.md", in: model) == "edited")
    }

    /// A save keeps what an Update put in as that item: later changes go in without asking.
    @Test func updatedItemsNeedNoChoiceAfterASave() async throws {
        let model = makeModel(entries: Self.photos)
        defer { close(model) }
        let export = try await exportNamedLikeASibling(in: model)
        let copy = try #require(model.openedFiles.files.first)
        try edit(copy.url, to: "edited")
        let changed = model.changedOpenedFiles()
        #expect(changed.map(\.path) == ["photo.png", "photo.jpg"])
        #expect(await model.update(from: changed[0]))
        #expect(await model.update(from: changed[1], ifNameIsTaken: .keepBoth))
        model.didSave(reader: FakeReader(entries: Self.photos + [Self.file("photo 2.jpg")]))

        try edit(copy.url, to: "edited again")
        try edit(export.url, to: "exported again")
        let again = model.changedOpenedFiles()
        #expect(again.map(\.path) == ["photo.png", "photo 2.jpg"])
        #expect(!again.contains { model.wouldReplace($0) })
        for file in again { #expect(await model.update(from: file)) }
        #expect(try await contents(of: "photo.png", in: model) == "edited again")
        #expect(try await contents(of: "photo 2.jpg", in: model) == "exported again")
        #expect(model.changes.removedPaths == ["photo.png", "photo 2.jpg"])
        #expect(model.item(at: "photo.jpg")?.isPendingAddition == false)
    }

    /// A save of a different item at the copy's path doesn't make it the copy's item.
    @Test func copyOfAnItemReplacedBeforeASaveIsAsked() async throws {
        let model = makeModel(entries: [Self.file("notes")])
        defer { close(model) }
        let url = try await model.copyForOpening("notes")
        model.remove(["notes"])
        model.add([try ownFile("notes")], to: "")
        model.didSave(reader: FakeReader(entries: [Self.file("notes")]))

        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(model.wouldReplace(changed))
        #expect(await model.update(from: changed) == false)
        #expect(model.item(at: "notes")?.isPendingAddition == false)
    }

    /// Don't Update, then Keep Both: from then on it is "photo 2.jpg", and later changes go
    /// there without asking (`markSeen` keeps the whole record).
    @Test func dontUpdateThenKeepBothTakesTheNewName() async throws {
        let model = makeModel(entries: Self.photos)
        defer { close(model) }
        let export = try await exportNamedLikeASibling(in: model)
        model.markSeen(export)
        try edit(export.url, to: "exported again")
        let again = try #require(model.changedOpenedFiles().first)
        #expect(await model.update(from: again, ifNameIsTaken: .keepBoth))

        try edit(export.url, to: "third")
        let third = try #require(model.changedOpenedFiles().first)
        #expect(third.path == "photo 2.jpg")
        #expect(!model.wouldReplace(third))
        #expect(await model.update(from: third))
        #expect(try await contents(of: "photo 2.jpg", in: model) == "third")
        #expect(model.item(at: "photo.jpg")?.isPendingAddition == false)
    }

    /// Update, then Undo: the copy's own item is back, and a later change goes in over it unasked.
    @Test func undoneUpdateLeavesTheCopysOwnItem() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let model = makeModel(undoManager: undoManager)
        defer { close(model) }
        let url = try await model.copyForOpening("readme.md")
        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        undoManager.beginUndoGrouping()
        #expect(await model.update(from: changed))
        undoManager.endUndoGrouping()
        undoManager.undo()
        #expect(model.item(at: "readme.md")?.isPendingAddition == false)

        try edit(url, to: "edited again")
        let again = try #require(model.changedOpenedFiles().first)
        #expect(!model.wouldReplace(again))
        undoManager.beginUndoGrouping()
        #expect(await model.update(from: again))
        undoManager.endUndoGrouping()
        #expect(try await contents(of: "readme.md", in: model) == "edited again")
    }

    // MARK: - A saved item is the one the copy was made from

    private static func file(_ path: String, size: Int64, modified: Date? = nil) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: size, compressedSize: size, modificationDate: modified)
    }

    /// Another app rewrote the archive, then Revert to Saved: the copy's item at that path is now
    /// a different one, so putting the copy back takes a choice.
    @Test func copyOfAnItemFromADifferentSavedArchiveIsAsked() async throws {
        let model = makeModel(entries: [Self.file("notes", size: 1)])
        defer { close(model) }
        let url = try await model.copyForOpening("notes")
        let reverted = makeModel(entries: [Self.file("notes", size: 2)], openedFiles: model.openedFiles)

        try edit(url, to: "edited")
        let changed = try #require(reverted.changedOpenedFiles().first)
        #expect(reverted.wouldReplace(changed))
        #expect(await reverted.update(from: changed) == false)
        #expect(reverted.item(at: "notes")?.isPendingAddition == false)
        #expect(reverted.changes.removedPaths.isEmpty)
    }

    /// Revert to Saved of an archive nobody else changed: the copy's item is still its own.
    @Test func copyAfterARevertOfTheSameArchiveGoesInUnasked() async throws {
        let entries = [Self.file("notes", size: 1, modified: Date(timeIntervalSince1970: 1_000))]
        let model = makeModel(entries: entries)
        defer { close(model) }
        let url = try await model.copyForOpening("notes")
        let reverted = makeModel(entries: entries, openedFiles: model.openedFiles)

        try edit(url, to: "edited")
        let changed = try #require(reverted.changedOpenedFiles().first)
        #expect(!reverted.wouldReplace(changed))
        #expect(await reverted.update(from: changed))
        #expect(try await contents(of: "notes", in: reverted) == "edited")
    }

    /// A save writes the updated item anew (new size, new date): it is still the copy's item.
    @Test func savedUpdateStaysTheCopysItemWithItsNewMetadata() async throws {
        let model = makeModel(entries: [Self.file("notes", size: 1)])
        defer { close(model) }
        let url = try await model.copyForOpening("notes")
        try edit(url, to: "edited")
        #expect(await model.update(from: try #require(model.changedOpenedFiles().first)))
        model.didSave(reader: FakeReader(entries: [Self.file("notes", size: 6, modified: Date())]))

        try edit(url, to: "edited again")
        let again = try #require(model.changedOpenedFiles().first)
        #expect(!model.wouldReplace(again))
        #expect(await model.update(from: again))
    }

    /// While a big copy is still being made, the user deletes the item, adds their own file of
    /// that name and saves: the copy finished after the save stands for no item, so putting it
    /// back takes a choice and the user's file stays.
    @Test(.timeLimit(.minutes(1)))
    func saveDuringTheCopyThatReplacedTheItemIsAsked() async throws {
        let model = makeModel(entries: [Self.file("notes", size: 1)])
        defer { close(model) }
        let started = AsyncStream<Void>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        model.openedFiles.copyItem = { source, destination in
            started.continuation.yield()
            gate.wait()
            try FileManager.default.copyItem(at: source, to: destination)
        }
        let mine = try ownFile("notes")
        let task = Task { try await model.copyForOpening("notes") }
        for await _ in started.stream { break }
        model.remove(["notes"])
        model.add([mine], to: "")
        // The saved archive's "notes" is the user's file, with the same metadata as the old one.
        model.didSave(reader: FakeReader(entries: [Self.file("notes", size: 1)]))
        gate.signal()
        let url = try await task.value
        model.openedFiles.copyItem = { try FileManager.default.copyItem(at: $0, to: $1) }

        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(model.wouldReplace(changed))
        #expect(await model.update(from: changed) == false)
        #expect(model.item(at: "notes")?.isPendingAddition == false)
    }

    /// Another app rewrote the archive with an item of the same size but a later date, then Revert
    /// to Saved: a different item, so putting the copy back takes a choice.
    @Test func copyOfAnItemWithTheSameSizeAndALaterDateIsAsked() async throws {
        let model = makeModel(entries: [Self.file("notes", size: 5, modified: Date(timeIntervalSince1970: 1_000))])
        defer { close(model) }
        let url = try await model.copyForOpening("notes")
        let reverted = makeModel(entries: [Self.file("notes", size: 5, modified: Date(timeIntervalSince1970: 1_002))],
                                 openedFiles: model.openedFiles)

        try edit(url, to: "edited")
        let changed = try #require(reverted.changedOpenedFiles().first)
        #expect(reverted.wouldReplace(changed))
        #expect(await reverted.update(from: changed) == false)
        #expect(reverted.changes.removedPaths.isEmpty)
    }

    /// Revert to an archive that has a folder at the copy's path, of the same size and date as the
    /// file was: a different item, so putting the copy back takes a choice and the folder stays.
    @Test func copyOfAFileWhereTheSavedArchiveHasAFolderIsAsked() async throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let model = makeModel(entries: [Self.file("notes", size: 1, modified: date)])
        defer { close(model) }
        let url = try await model.copyForOpening("notes")
        let folder = ArchiveEntry(path: "notes", isDirectory: true, size: nil, compressedSize: nil, modificationDate: date)
        let reverted = makeModel(entries: [folder, Self.file("notes/inner", size: 1)], openedFiles: model.openedFiles)
        // The folder's size is its contents': the same as the file's.
        #expect(reverted.item(at: "notes")?.size == 1)

        try edit(url, to: "edited")
        let changed = try #require(reverted.changedOpenedFiles().first)
        #expect(reverted.wouldReplace(changed))
        #expect(await reverted.update(from: changed) == false)
        #expect(reverted.item(at: "notes/inner") != nil)
        #expect(reverted.changes.removedPaths.isEmpty)
    }

    /// While the item is still being extracted for the copy, the user deletes it, adds their own
    /// file of that name and saves: the copy stands for no item, so putting it back takes a choice
    /// and the user's file stays.
    @Test(.timeLimit(.minutes(1)))
    func saveDuringTheExtractionThatReplacedTheItemIsAsked() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let reader = ExtractionGateReader(base: FakeReader(entries: [Self.file("notes", size: 1)]),
                                          started: started.continuation, release: release.stream)
        let model = ArchiveModel(reader: reader, undoManager: nil, openedFiles: OpenedFiles(in: copiesFolder))
        defer { close(model) }
        let task = Task { try await model.copyForOpening("notes") }
        for await _ in started.stream { break }
        model.remove(["notes"])
        model.add([try ownFile("notes")], to: "")
        // The saved archive's "notes" is the user's file, with the same metadata as the old one.
        model.didSave(reader: FakeReader(entries: [Self.file("notes", size: 1)]))
        release.continuation.yield()
        let url = try await task.value

        try edit(url, to: "edited")
        let changed = try #require(model.changedOpenedFiles().first)
        #expect(model.wouldReplace(changed))
        #expect(await model.update(from: changed) == false)
        #expect(model.item(at: "notes")?.isPendingAddition == false)
    }

    // MARK: - View > Text Encoding

    /// A store in a defaults suite of its own (`makeTestDefaults`), so a reopen never writes the app's
    /// choices. The caller removes the suite with `removeTestDefaults`.
    private static func scratchStore() -> (store: ArchiveNameEncodingStore, defaults: UserDefaults, suite: String) {
        let (defaults, suite) = makeTestDefaults("OpenedFileModelTests")
        return (ArchiveNameEncodingStore(defaults: defaults), defaults, suite)
    }

    /// `path`, a CP1251 name, as a CP866 reading shows its bytes.
    private static func cp866Reading(of path: String) -> String {
        String(data: path.data(using: .windowsCP1251)!, encoding: .testCP866)!.precomposedStringWithCanonicalMapping
    }

    /// M-1: a copy opened before View > Text Encoding renamed its item stands for that item under the new
    /// name. A change goes back over it, not in next to it under the old reading, and a new item left next to
    /// the copy goes in the renamed folder.
    @Test func copyFollowsItsItemThroughATextEncodingSwitch() async throws {
        let zip = try LegacyZip.write(["Папка/", "Папка/Отчёт.txt", "readme.txt"], as: .windowsCP1251)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let (store, defaults, suite) = Self.scratchStore()
        defer { removeTestDefaults(defaults, suite: suite) }
        let model = ArchiveModel(reader: try await Archive.open(at: zip), undoManager: nil,
                                 openedFiles: OpenedFiles(in: copiesFolder))
        model.nameEncodingStore = store
        defer { close(model) }
        let url = try await model.copyForOpening("Папка/Отчёт.txt")
        let readme = try await model.copyForOpening("readme.txt")

        try await model.reopen(nameEncoding: .specific(.testCP866))

        let folder = Self.cp866Reading(of: "Папка")
        let renamed = Self.cp866Reading(of: "Папка/Отчёт.txt")
        #expect(model.item(at: renamed) != nil && model.item(at: "Папка/Отчёт.txt") == nil)
        #expect(model.openedFiles.files.map(\.path) == [renamed, "readme.txt"])
        try edit(url, to: "edited")
        try edit(readme, to: "readme edited")
        let exported = url.deletingLastPathComponent().appendingPathComponent("Отчёт.pdf")
        try Data("export".utf8).write(to: exported)
        let changed = model.changedOpenedFiles()
        #expect(changed.map(\.path) == [renamed, "readme.txt", folder + "/Отчёт.pdf"])
        #expect(!changed.contains(where: model.wouldReplace))

        for file in changed { #expect(await model.update(from: file)) }

        // Replaced in place: no second item under the old reading, in a folder of its own.
        #expect(model.children(of: "").map(\.name).sorted() == [folder, "readme.txt"].sorted())
        #expect(model.children(of: folder).map(\.name).sorted()
                == ["Отчёт.pdf", Self.cp866Reading(of: "Отчёт.txt")].sorted())
        #expect(try await contents(of: renamed, in: model) == "edited")
    }

    /// M-1 fallback: when the two listings don't line up entry by entry (here one entry's size differs),
    /// no item can be paired, so a copy stands for none and keeps its path, as after any save.
    @Test func copyOfAnItemTheSwitchCantPairStandsForNone() async throws {
        let (store, defaults, suite) = Self.scratchStore()
        defer { removeTestDefaults(defaults, suite: suite) }
        let model = makeModel(entries: [Self.file("a", size: 1), Self.file("b", size: 2)])
        model.nameEncodingStore = store
        defer { close(model) }
        _ = try await model.copyForOpening("a")
        let relisted = FakeReader(entries: [Self.file("x", size: 1), Self.file("y", size: 3)],
                                  nameEncoding: .specific(.testCP866))

        try await model.reopen(nameEncoding: .specific(.testCP866)) { _, _, _ in relisted }

        #expect(model.openedFiles.files.map(\.path) == ["a"])
        #expect(model.openedFiles.files.map(\.itsItems) == [[]])
    }

    /// M-1: listings pair up only entry by entry with their folders paired too; a real folder entry
    /// may come after its children.
    @Test func switchPairsEntriesOnlyWithTheirFolders() {
        let pairs = ArchiveModel.renamedPaths(from: [Self.file("A/b", size: 1), Self.folder("A"), Self.file("c")],
                                              to: [Self.file("X/b", size: 1), Self.folder("X"), Self.file("c")])
        #expect(pairs == ["A/b": "X/b", "A": "X"])
        // A name split at a "/" lands in another folder: nothing pairs.
        #expect(ArchiveModel.renamedPaths(from: [Self.folder("A"), Self.file("A/b", size: 1)],
                                          to: [Self.folder("X"), Self.file("Y/b", size: 1)]).isEmpty)
        // Two names merged into one path: nothing pairs.
        #expect(ArchiveModel.renamedPaths(from: [Self.file("a"), Self.file("b")],
                                          to: [Self.file("x"), Self.file("x")]).isEmpty)
        // One path read from two names (NFC and NFD spellings): nothing pairs.
        #expect(ArchiveModel.renamedPaths(from: [Self.file("\u{E9}"), Self.file("e\u{301}")],
                                          to: [Self.file("x"), Self.file("y")]).isEmpty)
        // A different number of entries: nothing pairs, not even the first ones.
        #expect(ArchiveModel.renamedPaths(from: [Self.file("a", size: 1), Self.file("b", size: 1)],
                                          to: [Self.file("x", size: 1)]).isEmpty)
        // A folder and a file with the same size and date: nothing pairs.
        let sizeless = ArchiveEntry(path: "x", isDirectory: false, size: nil, compressedSize: nil, modificationDate: nil)
        #expect(ArchiveModel.renamedPaths(from: [Self.folder("A")], to: [sizeless]).isEmpty)
        // Another date: nothing pairs.
        let date = Date(timeIntervalSinceReferenceDate: 0)
        #expect(ArchiveModel.renamedPaths(from: [Self.file("a", size: 1, modified: date)],
                                          to: [Self.file("x", size: 1, modified: date + 2)]).isEmpty)
        // The same entries with each other's names pair up (the checks themselves leave a match alone).
        #expect(ArchiveModel.renamedPaths(from: [Self.file("a", size: 1, modified: date)],
                                          to: [Self.file("x", size: 1, modified: date)]) == ["a": "x"])
    }

    /// M-1: a new item tracked next to a copy (an export the user chose Don't Update for) is no archive
    /// entry; it follows its folder to the new name, so a later change goes in the renamed folder.
    @Test func trackedNewItemFollowsItsFolderThroughATextEncodingSwitch() async throws {
        let zip = try LegacyZip.write(["Папка/", "Папка/Отчёт.txt"], as: .windowsCP1251)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let (store, defaults, suite) = Self.scratchStore()
        defer { removeTestDefaults(defaults, suite: suite) }
        let model = ArchiveModel(reader: try await Archive.open(at: zip), undoManager: nil,
                                 openedFiles: OpenedFiles(in: copiesFolder))
        model.nameEncodingStore = store
        defer { close(model) }
        let url = try await model.copyForOpening("Папка/Отчёт.txt")
        let exported = url.deletingLastPathComponent().appendingPathComponent("Отчёт.pdf")
        try Data("export".utf8).write(to: exported)
        let export = try #require(model.changedOpenedFiles().first { $0.path == "Папка/Отчёт.pdf" })
        model.markSeen(export)
        #expect(model.openedFiles.files.map(\.path) == ["Папка/Отчёт.txt", "Папка/Отчёт.pdf"])

        try await model.reopen(nameEncoding: .specific(.testCP866))

        let folder = Self.cp866Reading(of: "Папка")
        #expect(model.openedFiles.files.map(\.path) == [Self.cp866Reading(of: "Папка/Отчёт.txt"), folder + "/Отчёт.pdf"])
        try Data("export, changed".utf8).write(to: exported)
        #expect(model.changedOpenedFiles().map(\.path) == [folder + "/Отчёт.pdf"])
    }

    /// A tracked new item whose name starts with a combining mark or a ZWJ keeps its whole name as it
    /// follows its renamed folder: after "/" such a scalar makes one Character with the "/", so the name
    /// is cut from the path by Unicode scalars, never by Characters.
    @Test(arguments: ["\u{301}x.pdf", "\u{200D}\u{1F468}\u{200D}\u{1F469}.pdf"])
    func trackedNewItemKeepsALeadingMarkThroughATextEncodingSwitch(name: String) async throws {
        let (defaults, suite) = makeTestDefaults("OpenedFileModelTests")
        defer { removeTestDefaults(defaults, suite: suite) }
        let model = makeModel(entries: [Self.folder("A"), Self.file("A/b")])
        model.nameEncodingStore = ArchiveNameEncodingStore(defaults: defaults)
        defer { close(model) }
        let url = try await model.copyForOpening("A/b")
        try Data("export".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent(name))
        let export = try #require(model.changedOpenedFiles().first {
            Array($0.path.unicodeScalars) == Array(("A/" + name).unicodeScalars)
        })
        model.markSeen(export)
        let relisted = FakeReader(entries: [Self.folder("X"), Self.file("X/b")], nameEncoding: .specific(.testCP866))

        try await model.reopen(nameEncoding: .specific(.testCP866)) { _, _, _ in relisted }

        let paths = model.openedFiles.files.map { Array($0.path.unicodeScalars) }
        #expect(paths == ["X/b", "X/" + name].map { Array($0.unicodeScalars) })
    }
}

/// A `FakeReader` whose `extractToTemporaryFile` signals `started`, then waits for `release`.
private struct ExtractionGateReader: ArchiveReading {
    let base: FakeReader
    let started: AsyncStream<Void>.Continuation
    let release: AsyncStream<Void>

    var url: URL { base.url }
    var format: ArchiveFormat { base.format }
    var entries: [ArchiveEntry] { base.entries }
    var isEncrypted: Bool { base.isEncrypted }

    func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
        try await base.extract(paths, to: directory, progress: progress)
    }

    func extractToTemporaryFile(_ path: String) async throws -> URL {
        started.yield()
        for await _ in release { break }
        return try await base.extractToTemporaryFile(path)
    }
}

/// Counts calls from `@Sendable` closures.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    /// Counts one more call and returns its number, from 1.
    func next() -> Int {
        lock.withLock {
            calls += 1
            return calls
        }
    }
}
