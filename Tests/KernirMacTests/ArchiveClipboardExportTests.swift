import Testing
import Foundation
@testable import Kernir
import KernirCore
import os

/// Copy's file side (`ArchiveClipboard.export`, a real zip through the engine) and the sweep of old
/// export folders (`ArchiveClipboard.removeExports`). Every test works in a temporary folder of its own, never
/// the real temporary folder's `Kernir-Clipboard-*` folders, and removes it (`discard`: this process's export
/// parent there and its lock too).
@MainActor @Suite(.timeLimit(.minutes(1))) struct ArchiveClipboardExportTests {
    /// A test device token, so staging never reads or writes the standard defaults (`.system` does).
    private static let testDeviceToken = "c1b0c1b0c1b0c1b0"
    private static let foldsCase = DestinationCaseSensitivity(exists: { _ in true },
                                                              supportsCaseSensitiveNames: { _ in false })

    /// A fresh empty folder standing for the temporary folder; the caller removes it.
    private func makeTemporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveClipboardExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Releases this process's export parent in `temporary` (`removeAllExports`) and removes the folder.
    private func discard(_ temporary: URL) {
        ArchiveClipboard.removeAllExports(in: temporary)
        try? FileManager.default.removeItem(at: temporary)
    }

    private func makeModel(_ reader: any ArchiveReading) -> ArchiveModel {
        let model = ArchiveModel(reader: reader, undoManager: nil)
        model.extractionFileSystem = ExtractionFileSystem(deviceToken: Self.testDeviceToken) { from, to, flags in
            renamex_np(from, to, flags) == 0 ? 0 : errno
        }
        model.caseSensitivity = Self.foldsCase
        return model
    }

    /// The export folders in this process's parent in `temporary` (none without the parent).
    private func exportFolders(in temporary: URL) throws -> [String] {
        let parent = ArchiveClipboard.exportParent(in: temporary)
        guard FileManager.default.fileExists(atPath: parent.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
    }

    /// An exclusive flock(2) on `folder` through a descriptor of its own (as another instance's sweep takes it).
    private func tryLock(_ folder: URL) -> Int32? {
        let fd = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// How many of this process's descriptors are open on `folder`.
    private func descriptors(on folder: URL) throws -> Int {
        var status = stat()
        try #require(lstat(folder.path, &status) == 0)
        return (0..<getdtablesize()).filter { fd in
            var opened = stat()
            return fstat(fd, &opened) == 0 && opened.st_dev == status.st_dev && opened.st_ino == status.st_ino
        }.count
    }

    private func text(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test func exportsFilesAndFolder() async throws {
        let zip = try LegacyZip.write(["docs/", "docs/a.txt", "docs/sub/", "docs/sub/d.txt", "notes", "other/b.txt"],
                                      as: .utf8)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }

        let export = try await ArchiveClipboard.export(["docs", "notes"], from: model, in: temporary, progress: nil)
        // `<temporary>/Kernir-Clipboard-<process UUID>/<UUID>/`.
        let parent = export.folder.deletingLastPathComponent()
        #expect(parent.standardizedFileURL == ArchiveClipboard.exportParent(in: temporary).standardizedFileURL)
        #expect(parent.deletingLastPathComponent().standardizedFileURL == temporary.standardizedFileURL)
        #expect(parent.lastPathComponent.hasPrefix("Kernir-Clipboard-"))
        #expect(UUID(uuidString: String(parent.lastPathComponent.dropFirst("Kernir-Clipboard-".count))) != nil)
        #expect(UUID(uuidString: export.folder.lastPathComponent) != nil)
        #expect(export.urls.map(\.lastPathComponent) == ["docs", "notes"])
        #expect(export.urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL
                    == export.folder.standardizedFileURL })
        #expect(try text(export.folder.appendingPathComponent("docs/a.txt")) == "docs/a.txt")
        #expect(try text(export.folder.appendingPathComponent("docs/sub/d.txt")) == "docs/sub/d.txt")
        #expect(try text(export.folder.appendingPathComponent("notes")) == "notes")
        let top = try FileManager.default.contentsOfDirectory(atPath: export.folder.path).sorted()
        #expect(top == ["docs", "notes"])

        // A second export goes into a folder of its own.
        let again = try await ArchiveClipboard.export(["other/b.txt"], from: model, in: temporary, progress: nil)
        #expect(again.folder != export.folder)
        #expect(again.urls.map(\.lastPathComponent) == ["b.txt"])
        #expect(try text(again.urls[0]) == "other/b.txt")
        #expect(try exportFolders(in: temporary).count == 2)
    }

    @Test func caseTwinsKeepBoth() async throws {
        let zip = try LegacyZip.write(["README", "Readme"], as: .utf8)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }

        let files = try await ArchiveClipboard.export(["README", "Readme"], from: model, in: temporary, progress: nil)
        #expect(files.urls.count == 2)
        #expect(Set(files.urls.map(\.lastPathComponent)).count == 2)
        #expect(Set(try files.urls.map(text)) == ["README", "Readme"])
    }

    @Test func exportsAncestorOnce() async throws {
        let zip = try LegacyZip.write(["docs/", "docs/a.txt", "docs/sub/", "docs/sub/d.txt", "notes"], as: .utf8)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }

        // A folder and items inside it: the folder goes once, its items with it, not again beside it.
        let export = try await ArchiveClipboard.export(["docs/a.txt", "docs", "docs/sub/d.txt", "notes"],
                                                       from: model, in: temporary, progress: nil)
        #expect(export.urls.map(\.lastPathComponent) == ["docs", "notes"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: export.folder.path).sorted() == ["docs", "notes"])
        #expect(try text(export.folder.appendingPathComponent("docs/sub/d.txt")) == "docs/sub/d.txt")

        // Nothing to export: no folder made.
        let none = try await ArchiveClipboard.export([], from: model, in: temporary, progress: nil)
        #expect(none.urls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: none.folder.path))
        #expect(try exportFolders(in: temporary) == [export.folder.lastPathComponent])
    }

    @Test func onlyHiddenMetadataLeavesNoFolder() async throws {
        let zip = try LegacyZip.write(["__MACOSX/", "__MACOSX/._notes", "__MACOSX/notes", "._notes"], as: .utf8)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }

        // Hidden metadata is never written: nothing is left, so no folder either.
        let export = try await ArchiveClipboard.export(["__MACOSX/._notes", "__MACOSX/notes", "._notes"],
                                                       from: model, in: temporary, progress: nil)
        #expect(export.urls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: export.folder.path))
        #expect(try exportFolders(in: temporary).isEmpty)
    }

    @Test func cancelRemovesFolder() async throws {
        let zip = try LegacyZip.write(["docs/", "docs/a.txt", "notes"], as: .utf8)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }

        // Cancelled before it starts: the main actor runs it only once this test awaits.
        let task = Task { @MainActor in
            try await ArchiveClipboard.export(["docs", "notes"], from: model, in: temporary, progress: nil)
        }
        task.cancel()
        await #expect(throws: ArchiveError.cancelled) { try await task.value }
        #expect(try exportFolders(in: temporary).isEmpty)

        // A failure removes it too.
        await #expect(throws: ArchiveError.entryNotFound("gone.txt")) {
            try await ArchiveClipboard.export(["gone.txt"], from: model, in: temporary, progress: nil)
        }
        #expect(try exportFolders(in: temporary).isEmpty)
    }

    @Test func cancelMidExportRemovesFolder() async throws {
        let names = (1...6).map { "docs/f\($0).txt" }
        let zip = try LegacyZip.write(["docs/"] + names + ["notes"], as: .utf8)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }

        // Cancelled from the first report past 0 and below 1: a file's bytes are written, the rest are not.
        let handle = OSAllocatedUnfairLock<Task<(folder: URL, urls: [URL]), any Error>?>(initialState: nil)
        let reports = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let progress: ArchiveProgressHandler = { fraction, _ in
            reports.withLock { $0.append(fraction) }
            if fraction > 0, fraction < 1 { handle.withLock { $0?.cancel() } }
        }
        let task = Task { @MainActor in
            try await ArchiveClipboard.export(["docs", "notes"], from: model, in: temporary, progress: progress)
        }
        handle.withLock { $0 = task }
        await #expect(throws: ArchiveError.cancelled) { try await task.value }
        let seen = reports.withLock { $0 }
        #expect(seen.contains { $0 > 0 && $0 < 1 })
        #expect(!seen.contains(1))
        #expect(try exportFolders(in: temporary).isEmpty)
        // Only the held parent is left.
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path)
                    == [ArchiveClipboard.exportParent(in: temporary).lastPathComponent])
    }

    /// Every export of this process goes into one parent held through one descriptor, however many Copies.
    @Test func manyExportsHoldOneDescriptor() async throws {
        let zip = try LegacyZip.write(["notes"], as: .utf8)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }

        var folders: [URL] = []
        for _ in 1...8 {
            folders.append(try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil).folder)
        }
        let parent = ArchiveClipboard.exportParent(in: temporary)
        #expect(Set(folders.map { $0.deletingLastPathComponent().standardizedFileURL }) == [parent.standardizedFileURL])
        #expect(try exportFolders(in: temporary).count == 8)
        #expect(try descriptors(on: parent) == 1)
        for folder in folders { #expect(try descriptors(on: folder) == 0) }

        // Released with the parent: the next export makes and locks a new one.
        ArchiveClipboard.removeAllExports(in: temporary)
        #expect(!FileManager.default.fileExists(atPath: parent.path))
        _ = try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil)
        #expect(try descriptors(on: parent) == 1)
        #expect(tryLock(parent) == nil)
    }

    @Test func removeExportsKeepsOneAndSkipsSymlinks() async throws {
        let fileManager = FileManager.default
        let zip = try LegacyZip.write(["notes"], as: .utf8)
        defer { try? fileManager.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }
        func folder(_ name: String, in parent: URL) throws -> URL {
            let url = parent.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("file"))
            return url
        }
        let old = try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil).folder
        let older = try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil).folder
        let kept = try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil).folder
        let parent = ArchiveClipboard.exportParent(in: temporary)
        // A flat export folder of an older Kernir, held by no one.
        let legacy = try folder("Kernir-Clipboard-\(UUID().uuidString)", in: temporary)
        let notAnExport = try folder("Kernir-Clipboard-notes", in: temporary)
        let otherKernir = try folder("Kernir-\(UUID().uuidString)", in: temporary)
        let unrelated = try folder("Other", in: temporary)
        let nested = try folder("Kernir-Clipboard-\(UUID().uuidString)", in: unrelated)
        // A symlink named like an export: removed or not, what it points at stays.
        let target = try folder("Target", in: temporary)
        let link = temporary.appendingPathComponent("Kernir-Clipboard-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        let plainFile = temporary.appendingPathComponent("Kernir-Clipboard-\(UUID().uuidString)")
        try Data("y".utf8).write(to: plainFile)

        ArchiveClipboard.removeExports(in: temporary, keeping: kept)

        #expect(fileManager.fileExists(atPath: kept.appendingPathComponent("notes").path))
        #expect(!fileManager.fileExists(atPath: old.path))
        #expect(!fileManager.fileExists(atPath: older.path))
        #expect(!fileManager.fileExists(atPath: legacy.path))
        for survivor in [notAnExport, otherKernir, nested, target] {
            #expect(fileManager.fileExists(atPath: survivor.appendingPathComponent("file").path), "\(survivor.path)")
        }
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(fileManager.fileExists(atPath: plainFile.path))

        // The parent stays while held, still locked, emptied.
        ArchiveClipboard.removeExports(in: temporary, keeping: nil)
        #expect(!fileManager.fileExists(atPath: kept.path))
        #expect(try exportFolders(in: temporary).isEmpty)
        #expect(fileManager.fileExists(atPath: parent.path))
        #expect(tryLock(parent) == nil)
        #expect(fileManager.fileExists(atPath: target.appendingPathComponent("file").path))
        // A missing temporary folder is no error.
        ArchiveClipboard.removeExports(in: temporary.appendingPathComponent("missing"), keeping: nil)
    }

    /// A live export survives another instance's sweep: the exporting process holds a flock(2) on its parent,
    /// taken before any export folder is made in it, and the sweep skips a parent another holder has locked.
    /// An unheld parent (a crashed or quit instance's) goes. Its own sweep still removes its own exports.
    @Test func removeExportsSkipsParentsAnotherHolderLocked() async throws {
        let fileManager = FileManager.default
        let zip = try LegacyZip.write(["notes"], as: .utf8)
        defer { try? fileManager.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }

        // This process's parent is locked: another instance's sweep (another descriptor) can't take it.
        let export = try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil)
        #expect(fileManager.fileExists(atPath: export.folder.path))
        #expect(tryLock(ArchiveClipboard.exportParent(in: temporary)) == nil)

        // Another instance's parent stays while held, its exports too; an unheld one goes.
        let foreign = temporary.appendingPathComponent("Kernir-Clipboard-\(UUID().uuidString)", isDirectory: true)
        let foreignExport = foreign.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: foreignExport, withIntermediateDirectories: true)
        let unheld = temporary.appendingPathComponent("Kernir-Clipboard-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: unheld.appendingPathComponent(UUID().uuidString),
                                        withIntermediateDirectories: true)
        let held = try #require(tryLock(foreign))
        ArchiveClipboard.removeExports(in: temporary, keeping: nil)
        #expect(fileManager.fileExists(atPath: foreignExport.path))
        #expect(!fileManager.fileExists(atPath: unheld.path))
        // This process's own sweep removes its own export; its parent stays held.
        #expect(!fileManager.fileExists(atPath: export.folder.path))
        #expect(tryLock(ArchiveClipboard.exportParent(in: temporary)) == nil)

        // Released (the instance quit): it goes.
        close(held)
        ArchiveClipboard.removeExports(in: temporary, keeping: nil)
        #expect(!fileManager.fileExists(atPath: foreign.path))
        #expect(try fileManager.contentsOfDirectory(atPath: temporary.path)
                    == [ArchiveClipboard.exportParent(in: temporary).lastPathComponent])
    }

    /// The quit removal takes only this process's parent, exports and all (a read-only folder
    /// too, a symlink as a link), and releases its lock; another instance's parent stays, held or not (its
    /// copies may be pasted; the next launch's sweep takes an unheld one).
    @Test func quitRemovalTakesOnlyThisProcesssParent() async throws {
        let fileManager = FileManager.default
        let zip = try LegacyZip.write(["notes"], as: .utf8)
        defer { try? fileManager.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }
        let first = try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil).folder
        _ = try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil)
        let parent = ArchiveClipboard.exportParent(in: temporary)
        // A read-only folder in an export, and a link out of the parent.
        let readOnly = first.appendingPathComponent("locked/inner", isDirectory: true)
        try fileManager.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: readOnly.appendingPathComponent("file"))
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly.path)
        try fileManager.setAttributes([.posixPermissions: 0o555],
                                      ofItemAtPath: readOnly.deletingLastPathComponent().path)
        let target = temporary.appendingPathComponent("Target", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("t".utf8).write(to: target.appendingPathComponent("file"))
        try fileManager.createSymbolicLink(at: first.appendingPathComponent("link"), withDestinationURL: target)
        func foreignParent() throws -> URL {
            let url = temporary.appendingPathComponent("\(ArchiveClipboard.exportPrefix)\(UUID().uuidString)",
                                                       isDirectory: true)
            try fileManager.createDirectory(at: url.appendingPathComponent(UUID().uuidString),
                                            withIntermediateDirectories: true)
            return url
        }
        let held = try foreignParent()
        let unheld = try foreignParent()
        let lock = try #require(tryLock(held))
        defer { close(lock) }

        #expect(ArchiveClipboard.removeExportParent(in: temporary, before: .now + .seconds(30)))

        #expect(!fileManager.fileExists(atPath: parent.path))
        #expect(fileManager.fileExists(atPath: held.path))
        #expect(fileManager.fileExists(atPath: unheld.path))
        #expect(fileManager.fileExists(atPath: target.appendingPathComponent("file").path))
        // Nothing held there any more: again is a no-op, and the next export makes and locks a new parent.
        #expect(ArchiveClipboard.removeExportParent(in: temporary, before: .now + .seconds(30)))
        _ = try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil)
        #expect(try descriptors(on: parent) == 1)
    }

    /// Out of time, the quit removal stops: false, the parent and its exports stay, still locked (the process's
    /// end releases it for the next launch's sweep). With time it finishes.
    @Test func quitRemovalStopsAtItsDeadline() async throws {
        let fileManager = FileManager.default
        let zip = try LegacyZip.write(["notes"], as: .utf8)
        defer { try? fileManager.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }
        let export = try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil)
        let parent = ArchiveClipboard.exportParent(in: temporary)

        #expect(!ArchiveClipboard.removeExportParent(in: temporary, before: .now - .seconds(1)))

        #expect(fileManager.fileExists(atPath: export.folder.appendingPathComponent("notes").path))
        #expect(tryLock(parent) == nil)
        #expect(try descriptors(on: parent) == 1)

        #expect(ArchiveClipboard.removeExportParent(in: temporary, before: .now + .seconds(30)))
        #expect(!fileManager.fileExists(atPath: parent.path))
    }

    /// A parent that can't be locked (a sweep holds it) or opened (a symlink) fails the export: an error, no
    /// export folder made, nothing followed.
    @Test func aParentThatCantBeLockedFailsTheExport() async throws {
        let fileManager = FileManager.default
        let zip = try LegacyZip.write(["notes"], as: .utf8)
        defer { try? fileManager.removeItem(at: zip.deletingLastPathComponent()) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }

        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let parent = ArchiveClipboard.exportParent(in: temporary)
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let sweep = try #require(tryLock(parent))
        await #expect(throws: POSIXError.self) {
            try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil)
        }
        #expect(try fileManager.contentsOfDirectory(atPath: parent.path).isEmpty)
        close(sweep)

        let linked = try makeTemporary()
        defer { discard(linked) }
        let target = linked.appendingPathComponent("Target", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: ArchiveClipboard.exportParent(in: linked), withDestinationURL: target)
        await #expect(throws: POSIXError.self) {
            try await ArchiveClipboard.export(["notes"], from: model, in: linked, progress: nil)
        }
        #expect(try fileManager.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect((try? fileManager.destinationOfSymbolicLink(atPath: ArchiveClipboard.exportParent(in: linked).path))
                    != nil)
    }

    /// The quit removal opens folders their owner can't read or search (an archive's 0o000, 0o300):
    /// they go with the parent.
    @Test func quitRemovalTakesLockedFolders() async throws {
        let fileManager = FileManager.default
        let zip = try LegacyZip.write(["notes"], as: .utf8)
        defer { try? fileManager.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }
        let export = try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil)
        let parent = ArchiveClipboard.exportParent(in: temporary)
        let locked = [("none", 0o000), ("writeOnly", 0o300)].map { name, mode in
            (export.folder.appendingPathComponent(name, isDirectory: true), mode)
        }
        for (folder, _) in locked {
            try fileManager.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("inner/file"))
            try Data("y".utf8).write(to: folder.appendingPathComponent("file"))
        }
        // Unlocked again for `discard` should the removal fail.
        defer { for (folder, _) in locked { chmod(folder.path, 0o700) } }
        for (folder, mode) in locked { try #require(chmod(folder.path, mode_t(mode)) == 0) }

        #expect(ArchiveClipboard.removeExportParent(in: temporary, before: .now + .seconds(30)))
        #expect(!fileManager.fileExists(atPath: parent.path))
    }

    /// The removal of a folder of many entries stops at the deadline too: false, the parent stays, still locked;
    /// with time the removal finishes.
    @Test func quitRemovalOfAHugeFolderStopsAtItsDeadline() async throws {
        let fileManager = FileManager.default
        let zip = try LegacyZip.write(["notes"], as: .utf8)
        defer { try? fileManager.removeItem(at: zip.deletingLastPathComponent()) }
        let temporary = try makeTemporary()
        defer { discard(temporary) }
        let model = makeModel(try await Archive.open(at: zip))
        defer { model.removeTemporaryFiles() }
        let export = try await ArchiveClipboard.export(["notes"], from: model, in: temporary, progress: nil)
        let parent = ArchiveClipboard.exportParent(in: temporary)
        let huge = export.folder.appendingPathComponent("huge", isDirectory: true)
        try fileManager.createDirectory(at: huge, withIntermediateDirectories: true)
        for index in 0..<5_000 {
            try #require(fileManager.createFile(atPath: huge.appendingPathComponent("f\(index)").path, contents: nil))
        }

        #expect(!ArchiveClipboard.removeExportParent(in: temporary, before: .now + .milliseconds(2)))

        #expect(fileManager.fileExists(atPath: parent.path))
        #expect(try !fileManager.contentsOfDirectory(atPath: huge.path).isEmpty)
        #expect(tryLock(parent) == nil)
        #expect(try descriptors(on: parent) == 1)
        #expect(ArchiveClipboard.removeExportParent(in: temporary, before: .now + .seconds(30)))
        #expect(!fileManager.fileExists(atPath: parent.path))
    }
}
