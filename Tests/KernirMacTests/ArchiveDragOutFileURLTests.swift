import AppKit
import Testing
import Foundation
import os
@testable import Kernir
import KernirCore

// The plain files a drag out offers beside its promises (`ArchiveDragOutFiles`), for receivers that don't
// take promises: all rows or none declare `.fileURL`, written at once (not promised) once every file was
// extracted off the main thread within the wait; a cap, an ineligible row, a symlink, a failure or the wait
// running out leaves the whole drag promises only. The folders stay for slow receivers and go by age, at quit,
// and at launch (`ArchiveDragOutFolders`).

private func file(_ path: String, size: Int64 = 1) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: false, size: size, compressedSize: size, modificationDate: nil)
}

private func folder(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
}

private let entries: [ArchiveEntry] = [
    file("README.md"), folder("docs"), file("docs/report.pdf"), file("Makefile"),
    file("big.bin", size: ArchiveDragOut.maxBytes + 1),
]

/// A fresh folder of the test's own; the caller removes it.
private func makeFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveDragOutFileURLTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func row(_ path: String, size: Int64 = 1) -> ArchiveDragOutFiles.Row {
    ArchiveDragOutFiles.Row(path: path, readerPath: path, name: ArchiveEntry.name(of: path), size: size)
}

/// Writes the entry's path as its contents at `<directory>/<path>`, as `FakeReader.extract` does.
private let writePath: ArchiveDragOutFiles.Extract = { path, directory in
    let target = directory.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(path.utf8).write(to: target)
}

/// The promise of the row at `path` in `model`, offering `files`.
@MainActor
private func provider(_ path: String, in model: ArchiveModel, files: ArchiveDragOutFiles) throws -> ArchiveFilePromiseProvider {
    let provider = try #require(ArchiveFilePromiseDelegate.provider(path: path, model: model) as? ArchiveFilePromiseProvider)
    provider.dragOutFiles = files
    return provider
}

private func isRegularFile(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
}

private func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

/// The `Kernir-DragOut-*` folders directly in `directory`.
private func dragOutFolders(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
        .filter { $0.hasPrefix(ArchiveDragOut.dragOutFolderPrefix) }
}

/// Records where the stub extraction ran.
private final class ThreadLog: Sendable {
    private let onMain = OSAllocatedUnfairLock<[Bool]>(initialState: [])
    func record() { let main = pthread_main_np() != 0; onMain.withLock { $0.append(main) } }
    var values: [Bool] { onMain.withLock { $0 } }
}

@MainActor
@Suite struct ArchiveDragOutFileURLTests {
    @Test func theCapsAreNamedConstants() {
        #expect(ArchiveDragOut.maxBytes == 32 * 1024 * 1024)
        #expect(ArchiveDragOut.maxEntries == 16)
        #expect(ArchiveDragOut.fileURLWait == 1)
        #expect(ArchiveDragOut.dragOutFolderMaxAge == 600)
    }

    /// Through the pasteboard: the row's file URL is written at once (no `.promised` option), named as the
    /// entry, a regular file with its bytes, in a `Kernir-DragOut-` folder that a drop back ignores.
    @Test func anEligibleFileRowWritesItsExtractedFileURLAtOnce() throws {
        let folders = ArchiveDragOutFolders()
        defer { folders.removeAll() }
        let reader = FakeReader(entries: entries)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        let files = ArchiveDragOutFiles(reader: reader, folders: folders)
        files.add(ArchiveActions.dragOutRow(for: "docs/report.pdf", in: model))
        let promise = try provider("docs/report.pdf", in: model, files: files)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.kernir.tests.dragOutURL.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(promise.writableTypes(for: pasteboard).contains(.fileURL))
        #expect(promise.writingOptions(forType: .fileURL, pasteboard: pasteboard) == [])

        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([promise]))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let url = try #require(urls.first)
        #expect(urls.count == 1)
        #expect(url.lastPathComponent == "report.pdf")
        #expect(isRegularFile(url))
        #expect(try Data(contentsOf: url) == Data("docs/report.pdf".utf8))
        // <tmp>/Kernir-DragOut-<UUID>/0/report.pdf, registered for the later sweep.
        let batch = url.deletingLastPathComponent().deletingLastPathComponent()
        #expect(batch.lastPathComponent.hasPrefix(ArchiveDragOut.dragOutFolderPrefix))
        #expect(folders.registered == [batch])
        #expect(ArchiveActions.isOwnTemporaryFile(url))
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: batch.path)) == ["0", ArchiveDragOut.dragOutManifestName])
    }

    /// One row that may not come out as a file (a folder, an addition, a renamed file, one over the cap)
    /// leaves every row of the drag promises only, the eligible ones too.
    @Test func anIneligibleRowLeavesTheWholeDragPromisesOnly() throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let added = scratch.appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: added)
        let reader = FakeReader(entries: entries)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        model.add([added], to: "")
        _ = model.rename("Makefile", to: "Build")
        _ = model.rename("docs", to: "papers")
        try #require(model.item(at: "added.txt")?.isPendingAddition == true)
        try #require(model.item(at: "Build") != nil)

        for path in ["docs", "papers", "added.txt", "Build", "big.bin"] {
            #expect(ArchiveActions.dragOutRow(for: path, in: model) == nil, "\(path)")
        }
        // Inside a renamed folder a file keeps its name: it comes from its old path.
        #expect(ArchiveActions.dragOutRow(for: "papers/report.pdf", in: model)?.readerPath == "docs/report.pdf")
        #expect(ArchiveActions.dragOutRow(for: "README.md", in: model)?.name == "README.md")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.kernir.tests.dragOutURL.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        for ineligible in ["papers", "added.txt", "Build", "big.bin"] {
            let folders = ArchiveDragOutFolders()
            let files = ArchiveDragOutFiles(reader: reader, temporaryDirectory: scratch, folders: folders)
            for path in ["README.md", ineligible] { files.add(ArchiveActions.dragOutRow(for: path, in: model)) }
            for path in ["README.md", ineligible] {
                #expect(try !provider(path, in: model, files: files).writableTypes(for: pasteboard).contains(.fileURL),
                        "\(path) beside \(ineligible)")
            }
            #expect(folders.registered.isEmpty)
        }
        #expect(dragOutFolders(in: scratch).isEmpty)
    }

    @Test func aDragOverTheByteOrRowCapDeclaresNoFileURL() async throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folders = ArchiveDragOutFolders()
        func files() -> ArchiveDragOutFiles {
            ArchiveDragOutFiles(extract: writePath, temporaryDirectory: scratch, folders: folders)
        }
        let heavy = files()
        heavy.add(row("a", size: ArchiveDragOut.maxBytes / 2 + 1))
        heavy.add(row("b", size: ArchiveDragOut.maxBytes / 2 + 1))
        #expect(!heavy.offersFileURL(for: "a"))
        #expect(!heavy.offersFileURL(for: "b"))

        let many = files()
        for index in 0...ArchiveDragOut.maxEntries { many.add(row("f\(index)")) }
        #expect(!many.offersFileURL(for: "f0"))
        #expect(dragOutFolders(in: scratch).isEmpty)

        let atCap = files()
        for index in 0..<ArchiveDragOut.maxEntries { atCap.add(row("f\(index)")) }
        for index in 0..<ArchiveDragOut.maxEntries {
            #expect(atCap.offersFileURL(for: "f\(index)"), "f\(index)")
            #expect(atCap.fileURL(for: "f\(index)")?.lastPathComponent == "f\(index)")
        }

        // A row added after the drag was written stays a promise only.
        let late = files()
        late.add(row("a"))
        #expect(late.offersFileURL(for: "a"))
        late.add(row("b"))
        #expect(!late.offersFileURL(for: "b"))
        #expect(late.fileURL(for: "b") == nil)
        await atCap.extractionEnded()
        await late.extractionEnded()
        #expect(folders.registered.count == 2)
    }

    /// The start of the drag waits for the extraction, which runs off the main thread; afterwards the file is
    /// there without waiting, at `<folder>/<i>/<name>`, its staging folder gone.
    @Test func theDragsStartWaitsForTheExtractionOffTheMainThread() async throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let log = ThreadLog()
        let files = ArchiveDragOutFiles(extract: { path, directory in
            log.record()
            try await Task.sleep(for: .milliseconds(300))
            try await writePath(path, directory)
        }, wait: 10, temporaryDirectory: scratch, folders: ArchiveDragOutFolders())
        files.add(row("a.txt"))
        files.add(row("sub/b.txt"))
        let start = Date()
        // The main thread blocks here; the extraction runs off it.
        #expect(files.offersFileURL(for: "a.txt"))
        #expect(Date().timeIntervalSince(start) >= 0.5)
        #expect(log.values == [false, false])
        let a = try #require(files.fileURL(for: "a.txt"))
        let b = try #require(files.fileURL(for: "sub/b.txt"))
        #expect(a.deletingLastPathComponent().lastPathComponent == "0")
        #expect(b.deletingLastPathComponent().lastPathComponent == "1")
        #expect(b.lastPathComponent == "b.txt")
        #expect(try Data(contentsOf: b) == Data("sub/b.txt".utf8))
        let batch = a.deletingLastPathComponent().deletingLastPathComponent()
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: batch.path)) == ["0", "1", ArchiveDragOut.dragOutManifestName])
        await files.extractionEnded()
        #expect(exists(a) && exists(b))
    }

    /// An extraction slower than the wait: promises only, at once after the wait, and its folder goes when
    /// the (cancelled) task ends.
    @Test func aSlowExtractionTimesOutToPromisesOnlyAndItsFolderGoes() async throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folders = ArchiveDragOutFolders()
        let files = ArchiveDragOutFiles(extract: { path, directory in
            try await Task.sleep(for: .seconds(20))
            try await writePath(path, directory)
        }, wait: 0.2, temporaryDirectory: scratch, folders: folders)
        files.add(row("a"))
        files.add(row("b"))
        let start = Date()
        #expect(!files.offersFileURL(for: "a"))
        #expect(!files.offersFileURL(for: "b"))
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(files.fileURL(for: "a") == nil)
        await files.extractionEnded()
        #expect(dragOutFolders(in: scratch).isEmpty)
        #expect(folders.registered.isEmpty)
    }

    /// An extraction that gives a symlink (the archive's link lands as one), a folder, or fails, for any row:
    /// the whole drag stays promises only and its folder goes.
    @Test func aSymlinkFolderOrFailureFromTheExtractionLeavesTheDragPromisesOnly() async throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let symlink: ArchiveDragOutFiles.Extract = { path, directory in
            guard path == "link.txt" else { return try await writePath(path, directory) }
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(path),
                                                       withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        }
        let folderOnly: ArchiveDragOutFiles.Extract = { path, directory in
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
        let failing: ArchiveDragOutFiles.Extract = { path, _ in throw ArchiveError.entryNotFound(path) }
        for (name, extract) in [("symlink", symlink), ("folder", folderOnly), ("failure", failing)] {
            let folders = ArchiveDragOutFolders()
            let files = ArchiveDragOutFiles(extract: extract, wait: 10, temporaryDirectory: scratch, folders: folders)
            files.add(row("a.txt"))
            files.add(row("link.txt"))
            #expect(!files.offersFileURL(for: "a.txt"), "\(name)")
            #expect(!files.offersFileURL(for: "link.txt"), "\(name)")
            await files.extractionEnded()
            #expect(dragOutFolders(in: scratch).isEmpty, "\(name)")
            #expect(folders.registered.isEmpty, "\(name)")
        }
    }

    /// A new drag deletes only the folders older than the age; quit deletes every registered one; launch
    /// deletes old `Kernir-DragOut-*` folders of the temporary folder and nothing else.
    @Test func foldersGoByAgeAtQuitAndAtLaunch() throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fileManager = FileManager.default
        func make(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: url.appendingPathComponent("0"), withIntermediateDirectories: true)
            return url
        }
        let now = Date()
        let folders = ArchiveDragOutFolders()
        let old = try make("Kernir-DragOut-old")
        let recent = try make("Kernir-DragOut-recent")
        folders.register(old, at: now.addingTimeInterval(-ArchiveDragOut.dragOutFolderMaxAge - 1))
        folders.register(recent, at: now.addingTimeInterval(-60))
        folders.removeOlder(now: now)
        #expect(!exists(old))
        #expect(exists(recent))
        #expect(folders.registered == [recent])
        folders.removeAll()
        #expect(!exists(recent))
        #expect(folders.registered.isEmpty)

        let stale = try make("Kernir-DragOut-stale")
        let fresh = try make("Kernir-DragOut-fresh")
        let other = try make("Kernir-Other-stale")
        let long = now.addingTimeInterval(-ArchiveDragOut.dragOutFolderMaxAge - 60)
        for url in [stale, other] { try fileManager.setAttributes([.modificationDate: long], ofItemAtPath: url.path) }
        ArchiveDragOutFolders.removeLeftovers(in: scratch, now: now)
        #expect(!exists(stale))
        #expect(exists(fresh))
        #expect(exists(other))
    }

    /// The extracted files are made readable and user-writable whatever mode the archive stored (0444, 0000):
    /// receivers must read them, and a receiver that copies the plain file URL keeps its mode. The sweeps
    /// still delete them.
    @Test func theExtractedFilesAreMadeReadableAndUserWritable() async throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folders = ArchiveDragOutFolders()
        let stored: [String: Int] = ["a.txt": 0o444, "sub/b.txt": 0o000, "c.txt": 0o755]
        let files = ArchiveDragOutFiles(extract: { path, directory in
            try await writePath(path, directory)
            try FileManager.default.setAttributes([.posixPermissions: stored[path] ?? 0o644],
                                                  ofItemAtPath: directory.appendingPathComponent(path).path)
        }, wait: 10, temporaryDirectory: scratch, folders: folders)
        for path in stored.keys.sorted() { files.add(row(path)) }
        #expect(files.offersFileURL(for: "a.txt"))
        await files.extractionEnded()
        let expected = ["a.txt": 0o644, "sub/b.txt": 0o600, "c.txt": 0o755]
        for (path, mode) in expected {
            let url = try #require(files.fileURL(for: path), "\(path)")
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.posixPermissions] as? Int == mode, "\(path)")
            #expect(FileManager.default.isWritableFile(atPath: url.path), "\(path)")
            #expect(try Data(contentsOf: url) == Data(path.utf8), "\(path)")
        }
        folders.removeAll()
        #expect(dragOutFolders(in: scratch).isEmpty)
    }

    /// A file the extraction gives with another hard link (nlink 2, as `ExportLinkSweep` refuses) leaves the
    /// drag promises only: the other name could change the offered file. Its folder goes.
    @Test func aHardLinkedFileFromTheExtractionLeavesTheDragPromisesOnly() async throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folders = ArchiveDragOutFolders()
        let linked: ArchiveDragOutFiles.Extract = { path, directory in
            try await writePath(path, directory)
            guard path == "b.txt" else { return }
            try FileManager.default.linkItem(at: directory.appendingPathComponent(path),
                                             to: scratch.appendingPathComponent("other-name-\(UUID().uuidString)"))
        }
        let files = ArchiveDragOutFiles(extract: linked, wait: 10, temporaryDirectory: scratch, folders: folders)
        files.add(row("a.txt"))
        files.add(row("b.txt"))
        #expect(!files.offersFileURL(for: "a.txt"))
        #expect(!files.offersFileURL(for: "b.txt"))
        await files.extractionEnded()
        #expect(dragOutFolders(in: scratch).isEmpty)
        #expect(folders.registered.isEmpty)
    }

    /// Finder's `.DS_Store` (the folder opened in Finder, before or after the record was written) is no change
    /// to the files: the sweeps still delete the folder.
    @Test func aFinderDSStoreDoesNotKeepAFolderFromTheSweeps() async throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folders = ArchiveDragOutFolders()
        // One already there when the record is written (in the drag's folder), removed afterwards.
        let withDSStore: ArchiveDragOutFiles.Extract = { path, directory in
            try await writePath(path, directory)
            try Data("ds".utf8).write(to: directory.deletingLastPathComponent().appendingPathComponent(".DS_Store"))
        }
        let files = ArchiveDragOutFiles(extract: withDSStore, wait: 10, temporaryDirectory: scratch,
                                        folders: folders)
        files.add(row("a.txt"))
        #expect(files.offersFileURL(for: "a.txt"))
        await files.extractionEnded()
        let file = try #require(files.fileURL(for: "a.txt"))
        let batch = file.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.removeItem(at: batch.appendingPathComponent(".DS_Store"))
        // Ones added after, beside the file and in the drag's folder.
        try Data("ds".utf8).write(to: file.deletingLastPathComponent().appendingPathComponent(".DS_Store"))
        try Data("ds".utf8).write(to: batch.appendingPathComponent(".DS_Store"))
        #expect(ArchiveDragOutFolders.mayRemove(batch))
        folders.removeOlder(now: Date().addingTimeInterval(ArchiveDragOut.dragOutFolderMaxAge * 10))
        #expect(!exists(batch))
    }

    /// Through a real KernirCore reader (a zip), at the drag's real wait: the files are offered in time, so the
    /// engine's extraction never needs the main thread the start of the drag holds.
    @Test func aRealZipReaderOffersItsFilesWithinTheWait() async throws {
        let zip = try LegacyZip.write(["docs/", "docs/report.txt", "README.md"], as: .utf8)
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let reader = try await Archive.open(at: zip)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        let folders = ArchiveDragOutFolders()
        let files = ArchiveDragOutFiles(reader: reader, temporaryDirectory: scratch, folders: folders)
        for path in ["docs/report.txt", "README.md"] {
            files.add(try #require(ArchiveActions.dragOutRow(for: path, in: model), "\(path)"))
        }
        #expect(files.offersFileURL(for: "docs/report.txt"))
        let report = try #require(files.fileURL(for: "docs/report.txt"))
        #expect(report.lastPathComponent == "report.txt")
        #expect(try Data(contentsOf: report) == Data("docs/report.txt".utf8))
        #expect(try files.fileURL(for: "README.md").map { try Data(contentsOf: $0) } == Data("README.md".utf8))
        await files.extractionEnded()
        folders.removeAll()
        #expect(dragOutFolders(in: scratch).isEmpty)
    }

    /// A window's new drag (a new drop id) deletes the drag folders older than the age; its later rows (the same
    /// drop id) don't sweep again.
    @Test func aNewDragOfAWindowSweepsTheOldFolders() throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil)
        let document = try ArchiveDocument(type: "public.zip-archive")
        document.state.model = model
        let actions = ArchiveActions(document: document)
        let own = ArchiveDragOutFolders()
        defer { own.removeAll() }
        actions.makeDragOutFiles = { reader in ArchiveDragOutFiles(reader: reader, folders: own) }
        func oldFolder(_ name: String) throws -> URL {
            let url = scratch.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("0"),
                                                    withIntermediateDirectories: true)
            ArchiveDragOutFolders.shared.register(url,
                                                  at: Date(timeIntervalSinceNow: -ArchiveDragOut.dragOutFolderMaxAge - 60))
            return url
        }
        let first = try oldFolder("Kernir-DragOut-first")
        let drop = UUID()
        let files = try #require(actions.dragOutFiles(for: "README.md", drop: drop))
        #expect(!exists(first))
        #expect(!ArchiveDragOutFolders.shared.registered.contains(first))

        let second = try oldFolder("Kernir-DragOut-second")
        defer { ArchiveDragOutFolders.shared.remove(second) }
        #expect(actions.dragOutFiles(for: "Makefile", drop: drop) === files)
        #expect(exists(second))
        _ = actions.dragOutFiles(for: "README.md", drop: UUID())
        #expect(!exists(second))
    }

    /// A folder whose files changed after the extraction (one edited and saved, one added, one removed) is
    /// someone's work now: no sweep deletes it (age, quit, launch); an untouched one goes.
    @Test func noSweepDeletesAFolderWhoseFilesChanged() async throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fileManager = FileManager.default
        let folders = ArchiveDragOutFolders()
        func extracted() async throws -> (folder: URL, file: URL) {
            let files = ArchiveDragOutFiles(extract: writePath, wait: 10, temporaryDirectory: scratch, folders: folders)
            files.add(row("a.txt"))
            #expect(files.offersFileURL(for: "a.txt"))
            await files.extractionEnded()
            let file = try #require(files.fileURL(for: "a.txt"))
            return (file.deletingLastPathComponent().deletingLastPathComponent(), file)
        }
        func edit(_ file: URL) throws {
            try Data("edited".utf8).write(to: file, options: .atomic)
        }
        func added(_ file: URL) throws {
            try Data("x".utf8).write(to: file.deletingLastPathComponent().appendingPathComponent("a.txt.sb-autosave"))
        }
        func removed(_ file: URL) throws { try fileManager.removeItem(at: file) }
        func touched(_ file: URL) throws {
            // Same size, other modification date (an in-place save of the same length).
            try fileManager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
        }
        let later = Date().addingTimeInterval(ArchiveDragOut.dragOutFolderMaxAge * 10)
        let changes: [(String, (URL) throws -> Void)] = [("edit", edit), ("add", added), ("remove", removed),
                                                          ("touch", touched)]
        for (name, change) in changes {
            // By age, at quit, and at launch (after a crash, with nothing registered).
            let aged = try await extracted()
            let quit = try await extracted()
            let launch = try await extracted()
            let untouched = try await extracted()
            for changed in [aged, quit, launch] { try change(changed.file) }
            folders.removeOlder(now: later)
            #expect(exists(aged.folder), "\(name)")
            #expect(!exists(untouched.folder), "\(name)")
            folders.removeAll()
            #expect(exists(quit.folder), "\(name)")
            ArchiveDragOutFolders.removeLeftovers(in: scratch, now: later)
            #expect(exists(launch.folder), "\(name)")
            for folder in [aged.folder, quit.folder, launch.folder] { try? fileManager.removeItem(at: folder) }
        }
        // Untouched folders go at quit and at launch.
        let quit = try await extracted()
        folders.removeAll()
        #expect(!exists(quit.folder))
        let launch = try await extracted()
        ArchiveDragOutFolders.removeLeftovers(in: scratch, now: later)
        #expect(!exists(launch.folder))
    }

    /// The row cap counts rows, not writer calls: a row asked for twice counts once.
    @Test func aRowAskedForTwiceCountsOnceTowardTheRowCap() async throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let files = ArchiveDragOutFiles(extract: writePath, wait: 10, temporaryDirectory: scratch,
                                        folders: ArchiveDragOutFolders())
        for _ in 0..<2 {
            for index in 0..<ArchiveDragOut.maxEntries { files.add(row("f\(index)")) }
        }
        #expect(files.offersFileURL(for: "f0"))
        await files.extractionEnded()
    }

    /// The byte cap holds for the files as extracted, not only their stated sizes: an entry that comes out
    /// larger than stated, past the cap, leaves the drag promises only and its folder goes.
    @Test func aFileLargerThanStatedPastTheByteCapLeavesTheDragPromisesOnly() async throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folders = ArchiveDragOutFolders()
        let large: ArchiveDragOutFiles.Extract = { path, directory in
            try Data(count: 11).write(to: directory.appendingPathComponent(path))
        }
        let files = ArchiveDragOutFiles(extract: large, maxBytes: 20, wait: 10, temporaryDirectory: scratch,
                                        folders: folders)
        files.add(row("a", size: 1))
        files.add(row("b", size: 1))
        #expect(!files.offersFileURL(for: "a"))
        #expect(!files.offersFileURL(for: "b"))
        await files.extractionEnded()
        #expect(dragOutFolders(in: scratch).isEmpty)
        #expect(folders.registered.isEmpty)

        let within = ArchiveDragOutFiles(extract: large, maxBytes: 22, wait: 10, temporaryDirectory: scratch,
                                         folders: folders)
        within.add(row("a", size: 1))
        within.add(row("b", size: 1))
        #expect(within.offersFileURL(for: "a"))
        await within.extractionEnded()
        folders.removeAll()
    }

    /// Through a reader: a file inside a renamed folder comes from its old path under its shown name.
    @Test func aFileInARenamedFolderComesFromItsOldPathUnderItsName() async throws {
        let scratch = try makeFolder()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let reader = FakeReader(entries: entries)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        _ = model.rename("docs", to: "papers")
        let files = ArchiveDragOutFiles(reader: reader, temporaryDirectory: scratch, folders: ArchiveDragOutFolders())
        files.add(ArchiveActions.dragOutRow(for: "papers/report.pdf", in: model))
        files.add(ArchiveActions.dragOutRow(for: "README.md", in: model))
        #expect(files.offersFileURL(for: "papers/report.pdf"))
        let url = try #require(files.fileURL(for: "papers/report.pdf"))
        #expect(url.lastPathComponent == "report.pdf")
        #expect(try Data(contentsOf: url) == Data("docs/report.pdf".utf8))
        #expect(try files.fileURL(for: "README.md").map { try Data(contentsOf: $0) } == Data("README.md".utf8))
        await files.extractionEnded()
    }
}
