import Foundation
import os
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
import KernirCore
@testable import Kernir

/// Drag and drop (iPad): rows drag out as lazily extracted files, and items dropped on the
/// list or a folder row are added like ＋ adds them. Real `NSItemProvider`s, in process: the same
/// providers UIKit hands the drop delegate (cross-app drops can't be scripted in XCUITest).
/// Serialized: `ArchiveDocument.engine` is a process-wide test seam.
@MainActor @Suite(.serialized) final class DragDropTests {
    /// Archive entries with names unique to this suite, so files the fake reader extracts can be
    /// found (and removed) without touching other suites' temporary files.
    private var uniqueNames: [String] = []

    deinit {
        let names = uniqueNames
        for file in extractedCopies(named: names) {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
    }

    /// Opens `fixture` (copied, optionally renamed) with a fake engine listing `reader`'s entries.
    private func open(_ fixture: String = "zip/deflate.zip", as name: String? = nil,
                      reader: FakeReader = FakeReader(entries: SampleArchive().entries)) async throws -> ScreenState {
        let url = try Fixture.copy(fixture, as: name)
        ArchiveDocument.engine = FakeEngine(reader: { url in
            FakeReader(entries: reader.entries, format: reader.format, url: url, isEncrypted: reader.isEncrypted,
                       failure: reader.failure, extractDelay: reader.extractDelay)
        }).engine
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        #expect(document.session.model != nil)
        return ScreenState(document: document)
    }

    /// A reader with one file of a name no other test uses; its extracted copy holds the path.
    private func uniqueFileReader(_ ext: String = "txt", format: ArchiveFormat = .zip,
                                  failure: ArchiveError? = nil,
                                  extractDelay: Duration = .zero) -> (FakeReader, String) {
        let name = "dragged-\(UUID().uuidString).\(ext)"
        uniqueNames.append(name)
        let entries = SampleArchive().entries + [
            ArchiveEntry(path: name, isDirectory: false, size: Int64(name.utf8.count),
                         compressedSize: Int64(name.utf8.count), modificationDate: nil),
        ]
        return (FakeReader(entries: entries, format: format, failure: failure, extractDelay: extractDelay), name)
    }

    /// A file to drop, in a fresh temporary folder (as Files would hand it over).
    private func sourceFile(_ name: String, contents: String = "dropped") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropSource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A dropped file's provider as a Files drag hands it over: typed by the file and named. On
    /// iOS 26 `init(contentsOf:)` leaves `suggestedName` nil, and the file then arrives under a
    /// generic name ("text.txt", "Markdown content.md"), so the name is set here.
    private func fileProvider(_ url: URL) throws -> NSItemProvider {
        let provider = try #require(NSItemProvider(contentsOf: url))
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    /// A dropped folder's provider as a Files drag hands it over: a named `public.folder`. On
    /// iOS 26 `init(contentsOf:)` types a folder without an extension as `dyn.*` only.
    private func folderProvider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = url.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: UTType.folder.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    /// A dropped plain-text file's provider, named, that counts the loads asked of it in `loads`.
    private func countingProvider(_ url: URL, loads: OSAllocatedUnfairLock<Int>) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = url.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            loads.withLock { $0 += 1 }
            completion(url, false, nil)
            return nil
        }
        return provider
    }

    /// A dropped plain-text file's provider, named, whose file UIKit asks for at once but which
    /// `held` hands over only when the test says so.
    private func heldProvider(_ url: URL, held: HeldFile) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = url.lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: [],
                                            visibility: .all) { completion in
            held.hold(url, completion)
            return nil
        }
        return provider
    }

    /// Polls until `condition` holds, for up to about five seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Drag out

    /// Nothing is extracted when the drag starts; the drop's request extracts the entry.
    @Test func dragProviderExtractsLazily() async throws {
        let (reader, name) = uniqueFileReader()
        let state = try await open(reader: reader)

        let provider = state.dragProvider(for: name)
        #expect(provider.suggestedName == name)
        #expect(provider.registeredTypeIdentifiers.first == UTType.plainText.identifier)
        // Time for an eager extraction to show up, if the provider started one.
        try await Task.sleep(for: .milliseconds(200))
        #expect(extractedCopies(named: [name]).isEmpty)

        let file = try await loadFile(provider, type: UTType.plainText.identifier)
        #expect(!file.isDirectory)
        // FakeReader writes an entry's path as its contents.
        #expect(file.data == Data(name.utf8))
        #expect(extractedCopies(named: [name]).count == 1)
        await state.document.closeOnMain()
    }

    /// A folder drags as a folder; a file without an extension as plain data.
    @Test func dragProviderForFolderIsFolderType() async throws {
        let state = try await open()

        let folder = state.dragProvider(for: "src")
        #expect(folder.suggestedName == "src")
        #expect(folder.registeredTypeIdentifiers.first == UTType.folder.identifier)
        #expect(!folder.registeredTypeIdentifiers.contains(UTType.data.identifier))

        let pdf = state.dragProvider(for: "brief.pdf")
        #expect(pdf.registeredTypeIdentifiers.first == UTType.pdf.identifier)
        await state.document.closeOnMain()
    }

    /// The `.ownProcess` marker names the document the drag came from, so a drop back onto it is
    /// refused while one from another window's archive isn't.
    @Test func dragProviderCarriesDocumentMarker() async throws {
        let state = try await open()
        let other = try await open()
        #expect(state.dragSourceID != other.dragSourceID)

        let provider = state.dragProvider(for: "README.md")
        let marker = state.dragMarkerType
        #expect(provider.registeredTypeIdentifiers.contains(marker))
        let data = try await loadData(provider, type: marker)
        #expect(String(decoding: data, as: UTF8.self) == "README.md", "the row's path (in-archive move)")

        #expect(state.isFromThisDocument([provider]))
        #expect(!other.isFromThisDocument([provider]))
        await state.document.closeOnMain()
        await other.document.closeOnMain()
    }

    /// Read-only formats can't take drops, but their entries drag out.
    @Test func readOnlyArchiveStillDragsOut() async throws {
        let (reader, name) = uniqueFileReader(format: .rar)
        let state = try await open(reader: reader)
        #expect(!state.canEdit)

        let file = try await loadFile(state.dragProvider(for: name), type: UTType.plainText.identifier)
        #expect(file.data == Data(name.utf8))
        await state.document.closeOnMain()
    }

    /// An extraction that fails reaches the drop as an error, not an empty file.
    @Test func dragProviderReportsExtractionFailure() async throws {
        let (reader, name) = uniqueFileReader(failure: .corrupted("bad block"))
        let state = try await open(reader: reader)

        await #expect(throws: (any Error).self) {
            try await loadFile(state.dragProvider(for: name), type: UTType.plainText.identifier)
        }
        await state.document.closeOnMain()
    }

    /// An item listed behind a marked "/" drags under its own name, as the core splits it (on the "/"
    /// scalar): no "/" scalar in the suggested name, and its type from that name's extension.
    @Test func dragProviderNamesAnItemBehindAMarkedSlash() async throws {
        let id = UUID().uuidString
        let path = "marked/\u{301}x-\(id).pdf"
        let entries = SampleArchive().entries + [
            ArchiveEntry(path: "marked", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil),
            ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
        ]
        let state = try await open(reader: FakeReader(entries: entries))
        let provider = state.dragProvider(for: path)
        let suggested = try #require(provider.suggestedName)
        #expect(!suggested.unicodeScalars.contains("/"))
        #expect(suggested.unicodeScalars.elementsEqual("\u{301}x-\(id).pdf".unicodeScalars))
        #expect(provider.registeredTypeIdentifiers.first == UTType.pdf.identifier)
        await state.document.closeOnMain()
    }

    // MARK: - Drop in

    /// A dropped file is copied into staging and added as a pending addition; the source can go.
    @Test func droppedFileIsStagedAndAdded() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let source = try sourceFile("dropped.txt", contents: "hello drop")
        let provider = try fileProvider(source)

        #expect(state.dropProposal(isFromThisDocument: state.isFromThisDocument([provider])).operation == .copy)
        await state.addDropped([provider], to: "")

        #expect(model.item(at: "dropped.txt")?.isPendingAddition == true)
        #expect(state.alert == nil)
        #expect(state.pendingReplacement == nil)
        let added = try #require(model.changes.additions.first?.sourceURL)
        #expect(added != source)
        #expect(added.path.hasPrefix(FileManager.default.temporaryDirectory.appendingPathComponent("Staging").path))
        try FileManager.default.removeItem(at: source.deletingLastPathComponent())
        #expect(FileManager.default.contents(atPath: added.path) == Data("hello drop".utf8))
        await state.document.closeOnMain()
    }

    /// A dropped folder arrives with everything inside it, in place.
    @Test func droppedFolderKeepsLayout() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropSource-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("2026"),
                                                withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("2026/a.txt"))
        try Data("b".utf8).write(to: folder.appendingPathComponent("b.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        await state.addDropped([folderProvider(folder)], to: "src")

        #expect(state.alert == nil)
        #expect(model.item(at: "src/Photos")?.isDirectory == true)
        #expect(model.item(at: "src/Photos/2026")?.isDirectory == true)
        #expect(model.item(at: "src/Photos/2026/a.txt")?.isPendingAddition == true)
        #expect(model.item(at: "src/Photos/b.txt")?.isPendingAddition == true)
        await state.document.closeOnMain()
    }

    /// A drop on a folder row adds into that folder, not the level on screen.
    @Test func dropOnFolderRowTargetsThatFolder() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let first = try sourceFile("one.txt")
        let second = try sourceFile("two.txt")

        await state.addDropped([try fileProvider(first),
                                try fileProvider(second)], to: "assets")

        #expect(model.item(at: "assets/one.txt")?.isPendingAddition == true)
        #expect(model.item(at: "assets/two.txt")?.isPendingAddition == true)
        #expect(model.item(at: "one.txt") == nil)
        #expect(model.item(at: "two.txt") == nil)
        await state.document.closeOnMain()
    }

    /// A same-named drop asks before replacing, as ＋ does.
    @Test func dropConflictAsksToReplace() async throws {
        let state = try await open()
        let model = try #require(state.model)

        await state.addDropped([try fileProvider(try sourceFile("README.md"))], to: "")

        let replacement = try #require(state.pendingReplacement)
        #expect(replacement.title == "Replace “README.md”?")
        #expect(model.item(at: "README.md")?.isPendingAddition == false)
        state.confirmReplacement()
        #expect(model.item(at: "README.md")?.isPendingAddition == true)
        await state.document.closeOnMain()
    }

    /// Read-only formats and developer packages show the forbidden badge and take nothing.
    @Test func dropRefusedOnReadOnly() async throws {
        let rar = try await open(reader: FakeReader(entries: SampleArchive().entries, format: .rar))
        let apk = try await open(as: "app.apk")
        #expect(apk.model?.isEditable == true)
        for state in [rar, apk] {
            #expect(!state.canAdd)
            #expect(state.dropProposal(isFromThisDocument: false).operation == .forbidden)
            await state.addDropped([try fileProvider(try sourceFile("new.txt"))], to: "")
            #expect(state.model?.item(at: "new.txt") == nil)
            #expect(state.model?.hasChanges == false)
            await state.document.closeOnMain()
        }
    }

    /// While a save writes the archive, a drop is refused, and one that lands anyway says why.
    @Test func dropRefusedWhileSaving() async throws {
        let state = try await open()
        let model = try #require(state.model)
        #expect(state.dropProposal(isFromThisDocument: false).operation == .copy)

        state.session.saveFraction = 0.5
        #expect(!state.canAdd)
        #expect(state.dropProposal(isFromThisDocument: false).operation == .forbidden)
        await state.addDropped([try fileProvider(try sourceFile("new.txt"))], to: "")

        #expect(model.item(at: "new.txt") == nil)
        let alert = try #require(state.alert)
        #expect(alert.message == "The archive is being saved. Try again.")
        state.session.saveFraction = nil
        await state.document.closeOnMain()
    }

    /// A save that starts while the dropped files are still arriving: nothing is added (the save
    /// would lose it) and the user is told, as for ＋.
    @Test func saveStartingDuringDropTellsUser() async throws {
        let before = droppedCopies()
        let (slow, name) = uniqueFileReader(extractDelay: .milliseconds(500))
        let source = try await open(reader: slow)
        let state = try await open()
        let model = try #require(state.model)

        let drop = Task { await state.addDropped([source.dragProvider(for: name)], to: "") }
        try await Task.sleep(for: .milliseconds(100))
        state.session.saveFraction = 0.5
        await drop.value

        #expect(model.item(at: name) == nil)
        #expect(state.alert?.message == "The archive is being saved. Try again.")
        #expect(droppedCopies() == before)
        state.session.saveFraction = nil
        await state.document.closeOnMain()
        await source.document.closeOnMain()
    }

    /// An Extract that starts while the dropped files are still arriving, and asks its
    /// conflict questions. Once they arrive nothing is added and nothing is said, as for a drop
    /// begun then (the target is off: forbidden, and refused before anything loads), and the
    /// question stays.
    @Test func extractStartingDuringDropAddsNothing() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let source = try sourceFile("new.txt")
        let later = try sourceFile("later.txt")
        let folder = try sourceFile("README.md", contents: "mine").deletingLastPathComponent()
        defer {
            for url in [source.deletingLastPathComponent(), later.deletingLastPathComponent(), folder] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let held = HeldFile()
        let drop = Task { await state.addDropped([heldProvider(source, held: held)], to: "") }
        try await waitUntil { held.isHeld }
        try #require(held.isHeld, "UIKit asked for the dropped file")
        await state.extract(["README.md"], to: folder)
        #expect(state.extractionQuestion?.index == 0)
        #expect(state.dropProposal(isFromThisDocument: false).operation == .forbidden)
        let loads = OSAllocatedUnfairLock(initialState: 0)
        await state.addDropped([countingProvider(later, loads: loads)], to: "")
        #expect(loads.withLock { $0 } == 0, "refused before loading")

        held.deliver()
        await drop.value
        #expect(model.item(at: "new.txt") == nil)
        #expect(model.item(at: "later.txt") == nil)
        #expect(!model.hasChanges)
        #expect(state.alert == nil)
        #expect(state.pendingReplacement == nil)
        #expect(state.extractionQuestion?.index == 0)
        state.stopExtraction()
        await state.document.closeOnMain()
    }

    /// While Text Encoding reads the archive again, a drop is refused before anything loads, and
    /// one that lands anyway says why: the new listing would drop it. The
    /// reopen is held inside the engine, so it is still running whatever the drop awaits.
    @Test func dropRefusedWhileReadingAgain() async throws {
        let url = try Fixture.copy("zip/deflate.zip")
        let fake = FakeEngine(reader: { FakeReader.sample(url: $0, legacyNameEncoding: .windowsCP1251) })
        let document: ArchiveDocument
        do {
            // Swapped and reset with no await between: the document keeps the engine it was made with.
            ArchiveDocument.engine = fake.engine
            defer { ArchiveDocument.engine = .live }
            document = ArchiveDocument(fileURL: url)
        }
        #expect(await document.openOnMain())
        let state = ScreenState(document: document)
        let model = try #require(state.model)
        #expect(state.canChooseNameEncoding)
        #expect(state.dropProposal(isFromThisDocument: false).operation == .copy)
        let source = try sourceFile("new.txt")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let provider = countingProvider(source, loads: loads)

        let gate = OpenGate()
        fake.gate = gate
        state.chooseNameEncoding(.specific(.isoLatin1))
        let task = try #require(state.nameEncodingTask)
        #expect(!state.isSaving)
        #expect(!state.canAdd)
        #expect(state.dropProposal(isFromThisDocument: false).operation == .forbidden)
        await state.addDropped([provider], to: "")

        #expect(loads.withLock { $0 } == 0, "refused before loading")
        #expect(model.item(at: "new.txt") == nil)
        #expect(model.hasChanges == false)
        #expect(state.alert?.title == "Couldn't add 1 item")
        #expect(state.alert?.message == "The archive is being read again. Try again.")

        // Stopped before it adopts or remembers anything (no store of the app's is written). Nothing
        // between its start and here throws, so the gate always opens and the reopen always ends.
        state.cancelNameEncoding()
        gate.open()
        await task.value
        #expect(state.nameEncodingTask == nil)
        #expect(state.nameEncoding == .automatic)

        // Once the reopen has ended, the same drop loads and is added.
        state.alert = nil
        await state.addDropped([provider], to: "")
        #expect(loads.withLock { $0 } == 1)
        #expect(model.item(at: "new.txt")?.isPendingAddition == true)
        #expect(state.alert == nil)
        await document.closeOnMain()
    }

    /// An encrypted archive that isn't unlocked yet takes no drops.
    @Test func dropRefusedWhenLocked() async throws {
        let url = try Fixture.copy("zip/deflate.zip")
        ArchiveDocument.engine = FakeEngine(password: "kernir", listsWithoutPassword: true).engine
        defer { ArchiveDocument.engine = .live }
        let document = ArchiveDocument(fileURL: url)
        #expect(await document.openOnMain())
        let state = ScreenState(document: document)
        #expect(state.isLocked)

        #expect(!state.canAdd)
        #expect(state.dropProposal(isFromThisDocument: false).operation == .forbidden)
        await state.addDropped([try fileProvider(try sourceFile("new.txt"))], to: "")
        #expect(state.alert == nil)
        #expect(state.model == nil)

        await state.unlock(password: "kernir", remember: false)
        #expect(!state.isLocked)
        #expect(state.dropProposal(isFromThisDocument: false).operation == .copy)
        await document.closeOnMain()
    }

    /// An entry dragged out of this archive is never added back into it (a move takes it instead).
    @Test func dropFromSameDocumentRefused() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let provider = state.dragProvider(for: "README.md")

        #expect(state.isFromThisDocument([provider]))
        #expect(state.dropProposal(isFromThisDocument: true).operation == .forbidden)
        await state.addDropped([provider], to: "src")

        #expect(model.item(at: "src/README.md") == nil)
        #expect(!model.hasChanges)
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    /// An entry dragged from another window's archive is extracted there and added here.
    @Test func dropFromOtherDocumentAccepted() async throws {
        let before = droppedCopies()
        let (reader, name) = uniqueFileReader()
        let other = try await open(reader: reader)
        let state = try await open()
        let model = try #require(state.model)
        let provider = other.dragProvider(for: name)

        #expect(!state.isFromThisDocument([provider]))
        #expect(state.dropProposal(isFromThisDocument: false).operation == .copy)
        await state.addDropped([provider], to: "src")

        #expect(state.alert == nil)
        #expect(model.item(at: "src/\(name)")?.isPendingAddition == true)
        let added = try #require(model.changes.additions.first?.sourceURL)
        #expect(FileManager.default.contents(atPath: added.path) == Data(name.utf8))
        #expect(droppedCopies() == before)
        await state.document.closeOnMain()
        await other.document.closeOnMain()
    }

    /// The file is loaded by its content type, even when a URL or a private type comes first.
    @Test func droppedItemLoadsContentType() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { _ in nil }
        provider.registerDataRepresentation(forTypeIdentifier: "com.example.private-node", visibility: .all) { _ in nil }
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { _ in nil }
        #expect(DroppedItem.fileType(of: provider) == UTType.pdf.identifier)

        let marked = NSItemProvider()
        marked.registerDataRepresentation(forTypeIdentifier: ScreenState.dragMarkerPrefix + UUID().uuidString,
                                          visibility: .ownProcess) { _ in nil }
        #expect(DroppedItem.fileType(of: marked) == nil)
        #expect(DroppedItem.name(suggested: "Report", received: URL(fileURLWithPath: "/tmp/x/Report.pdf"))
                    == "Report.pdf")
        #expect(DroppedItem.name(suggested: "a/b.txt", received: URL(fileURLWithPath: "/tmp/x/b.txt")) == "a-b.txt")
        #expect(DroppedItem.name(suggested: nil, received: URL(fileURLWithPath: "/tmp/x/c.txt")) == "c.txt")
    }

    /// An item that offers no file is left out and the user told; the rest is added.
    @Test func droppedItemWithoutFileIsReported() async throws {
        let state = try await open()
        let model = try #require(state.model)

        await state.addDropped([NSItemProvider(), try fileProvider(try sourceFile("kept.txt"))],
                               to: "")

        #expect(model.item(at: "kept.txt")?.isPendingAddition == true)
        let alert = try #require(state.alert)
        #expect(alert.title == "Couldn't add 1 item")
        #expect(alert.message == "The dropped item didn't provide a file to copy.")
        await state.document.closeOnMain()
    }

    /// Two items without a file: the plural message counts them.
    @Test func droppedItemsWithoutFileAreReported() async throws {
        let state = try await open()
        let model = try #require(state.model)

        await state.addDropped([NSItemProvider(), NSItemProvider(),
                                try fileProvider(try sourceFile("kept.txt"))],
                               to: "")

        #expect(model.item(at: "kept.txt")?.isPendingAddition == true)
        let alert = try #require(state.alert)
        #expect(alert.title == "Couldn't add 2 items")
        #expect(alert.message == "2 dropped items didn't provide files to copy.")
        await state.document.closeOnMain()
    }
    /// Names that can't be a file name map to the received file's name.
    @Test func droppedItemNameFallsBack() {
        let received = URL(fileURLWithPath: "/tmp/x/real.txt")
        for suggested in ["..", ".", "", nil] as [String?] {
            #expect(DroppedItem.name(suggested: suggested, received: received) == "real.txt")
        }
    }

    /// Every "/" scalar in a suggested name is replaced, also one a combining mark or a joiner
    /// follows or a prepended mark precedes (one character with the "/").
    @Test func droppedItemNameReplacesEverySlashScalar() {
        let received = URL(fileURLWithPath: "/tmp/x/real.txt")
        for suggested in ["../\u{301}x", "a/\u{301}b", "a/\u{200D}b", "a\u{600}/b"] {
            let name = DroppedItem.name(suggested: suggested, received: received)
            #expect(!name.unicodeScalars.contains("/"), "\(Array(suggested.unicodeScalars))")
        }
    }

    /// A dropped item whose suggested name starts "../" with a combining mark after the "/" is
    /// copied into its own folder, and nothing lands beside that folder. The name is passed to
    /// the item, not set on the provider: NSItemProvider names its own temporary copy by
    /// `suggestedName`, keeps a "/" a mark follows, and fails the load ("Cannot create a
    /// temporary file") before the item sees the file.
    @Test func droppedItemStaysInItsFolder() async throws {
        let source = try sourceFile("source.txt", contents: "kept inside")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let tail = "\u{301}x-\(UUID().uuidString).txt"
        let provider = try fileProvider(source)
        let item = DroppedItem(provider, type: try #require(DroppedItem.fileType(of: provider)),
                               suggestedName: "../" + tail)
        defer { item.discard() }
        let parent = item.folder.deletingLastPathComponent()
        let stray = parent.appendingPathComponent(tail)
        defer { try? FileManager.default.removeItem(at: stray) }

        let copy = try await item.url()

        let inside = try FileManager.default.contentsOfDirectory(atPath: item.folder.path)
        #expect(inside.count == 1)
        #expect(FileManager.default.contents(atPath: item.folder.appendingPathComponent(try #require(inside.first)).path)
                    == Data("kept inside".utf8))
        #expect(copy.standardizedFileURL.deletingLastPathComponent().path == item.folder.standardizedFileURL.path)
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        let beside = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        #expect(!beside.contains { $0.unicodeScalars.elementsEqual(tail.unicodeScalars) })
    }

    /// A link or a text snippet isn't a file: it is skipped, and the files dropped with it are added.
    @Test func droppedLinkIsSkippedAndFilesAreAdded() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let link = NSItemProvider()
        link.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
            completion(Data("https://example.com".utf8), nil)
            return nil
        }
        let snippet = NSItemProvider()
        snippet.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier,
                                           visibility: .all) { completion in
            completion(Data("text".utf8), nil)
            return nil
        }
        #expect(DroppedItem.fileType(of: link) == nil)
        #expect(DroppedItem.fileType(of: snippet) == nil)

        await state.addDropped([link, try fileProvider(try sourceFile("kept.txt")), snippet],
                               to: "")

        #expect(model.item(at: "kept.txt")?.isPendingAddition == true)
        #expect(state.alert?.title == "Couldn't add 2 items")
        await state.document.closeOnMain()
    }

    /// A drop with no file or folder in it (a link only) is refused up front.
    @Test func dropOfOnlyALinkIsRefused() async throws {
        let state = try await open()
        let link = NSItemProvider()
        link.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { _ in nil }
        let file = try fileProvider(try sourceFile("a.txt"))

        #expect(!ScreenState.offersFile([link]))
        #expect(ScreenState.offersFile([link, file]))
        #expect(state.dropProposal(isFromThisDocument: false, offersFile: false).operation == .forbidden)
        #expect(state.dropProposal(isFromThisDocument: false, offersFile: true).operation == .copy)
        await state.document.closeOnMain()
    }

    // MARK: Drops from another app, and on the list itself

    /// `DropInfo.hasItemsConforming(to:)` as UIKit answers it for `providers`: a registered type
    /// that is, or conforms to, one of `types`.
    private func conforming(_ providers: [NSItemProvider]) -> ([UTType]) -> Bool {
        let registered = providers.flatMap(\.registeredTypeIdentifiers)
        return { types in
            types.contains { type in
                registered.contains { $0 == type.identifier || UTType($0)?.conforms(to: type) == true }
            }
        }
    }

    /// While a drag from another app (Files) hovers, SwiftUI hands out no item providers (they are
    /// valid only in `performDrop`): the proposal goes by the types the drag offers, so a zip, a
    /// photo or a folder from Files is copied, not refused.
    @Test func hoveringDropFromAnotherAppIsCopied() async throws {
        let state = try await open()
        let zip = try fileProvider(try sourceFile("Files.zip"))
        let photo = try fileProvider(try sourceFile("Photo.jpg"))
        let folder = folderProvider(try sourceFile("Folder").deletingLastPathComponent())
        for provider in [zip, photo, folder] {
            let proposal = state.dropProposal(hovering: [], conforms: conforming([provider]))
            #expect(proposal.operation == .copy, "\(provider.registeredTypeIdentifiers)")
        }
        // With the providers at hand (a drag from this app), they decide, as before.
        #expect(state.dropProposal(hovering: [zip], conforms: { _ in false }).operation == .copy)
        await state.document.closeOnMain()
    }

    /// While hovering without providers, this archive's own entries, a drag with no file type and
    /// a read-only archive are still refused.
    @Test func hoveringDropWithoutProvidersKeepsTheGates() async throws {
        let state = try await open()
        let own = state.dragProvider(for: "README.md")
        #expect(state.dropProposal(hovering: [], conforms: conforming([own])).operation == .forbidden)
        #expect(state.dropProposal(hovering: [own], conforms: { _ in true }).operation == .forbidden)
        #expect(state.dropProposal(hovering: [], conforms: { _ in false }).operation == .forbidden)

        let rar = try await open(reader: FakeReader(entries: SampleArchive().entries, format: .rar))
        let zip = try fileProvider(try sourceFile("Files.zip"))
        #expect(rar.dropProposal(hovering: [], conforms: conforming([zip])).operation == .forbidden)
        await state.document.closeOnMain()
        await rar.document.closeOnMain()
    }

    /// A drop the list takes itself (below the rows, or between them) and a folder
    /// row's `performDrop` both go through `acceptDrop`: another archive's entry and a Files zip
    /// are added to the folder on screen.
    @Test func dropOnTheListAddsToTheFolderOnScreen() async throws {
        let (reader, name) = uniqueFileReader()
        let other = try await open(reader: reader)
        let state = try await open()
        let model = try #require(state.model)
        let zip = try fileProvider(try sourceFile("Files.zip"))

        #expect(state.acceptDrop([other.dragProvider(for: name), zip], to: "src"))
        try await waitUntil { model.item(at: "src/Files.zip") != nil && model.item(at: "src/\(name)") != nil }

        #expect(state.alert == nil)
        #expect(model.item(at: "src/\(name)")?.isPendingAddition == true)
        #expect(model.item(at: "src/Files.zip")?.isPendingAddition == true)
        await state.document.closeOnMain()
        await other.document.closeOnMain()
    }

    /// `acceptDrop` refuses what the proposal forbids: this archive's own entry, a link only, or
    /// anything while the archive is read-only.
    @Test func dropOnTheListKeepsTheGates() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let link = NSItemProvider()
        link.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { _ in nil }
        #expect(!state.acceptDrop([state.dragProvider(for: "README.md")], to: "src"))
        #expect(!state.acceptDrop([link], to: ""))

        let rar = try await open(reader: FakeReader(entries: SampleArchive().entries, format: .rar))
        #expect(!rar.acceptDrop([try fileProvider(try sourceFile("new.txt"))], to: ""))
        #expect(!model.hasChanges)
        #expect(rar.model?.hasChanges == false)
        await state.document.closeOnMain()
        await rar.document.closeOnMain()
    }

    /// An empty folder (or a new, empty archive) has no row to drop on: the layer
    /// over its empty state drops through `FolderDropDelegate`, i.e. `acceptDrop` on the same gates.
    @Test func dropIntoAnEmptyFolderIsAccepted() async throws {
        let state = try await open(reader: FakeReader(entries: []))
        let model = try #require(state.model)
        #expect(model.children(of: "", matching: "").isEmpty)
        let zip = try fileProvider(try sourceFile("Files.zip"))

        #expect(state.dropProposal(hovering: [], conforms: conforming([zip])).operation == .copy)
        #expect(state.acceptDrop([zip], to: ""))
        try await waitUntil { model.item(at: "Files.zip") != nil }

        #expect(model.item(at: "Files.zip")?.isPendingAddition == true)
        #expect(!state.acceptDrop([state.dragProvider(for: "Files.zip")], to: ""))
        await state.document.closeOnMain()
    }

    /// The tests from here on (`acceptDrop`, `dropDirectory(forRow:in:)` called directly) cover the target-directory
    /// logic only, not UIKit's routing of a drop to a row's or the List's `.onDrop`; that routing is covered by
    /// the device check and `DragDropUITests`.
    ///
    /// The iPad bug: the first drop into an empty archive went in through the layer over its empty
    /// state, which goes once that item is listed; later drops then had only the list's `onInsert`
    /// (removed) and didn't go in. Every row takes a drop now, through the same delegate as that layer: a
    /// folder row into itself, a file row into the level it is listed in. The second and third
    /// drop, on the first item's row, go in, from Files (no providers while hovering) as well.
    @Test func dropsAfterTheFirstIntoAnEmptyRootGoIn() async throws {
        let state = try await open(reader: FakeReader(entries: []))
        let model = try #require(state.model)
        #expect(state.acceptDrop([try fileProvider(try sourceFile("first.zip"))], to: ""))
        try await waitUntil { model.item(at: "first.zip") != nil }
        let firstRow = try #require(model.item(at: "first.zip"))
        #expect(state.dropDirectory(forRow: firstRow, in: "") == "")

        for name in ["second.zip", "third.txt"] {
            let provider = try fileProvider(try sourceFile(name))
            let directory = state.dropDirectory(forRow: firstRow, in: "")
            #expect(state.dropProposal(hovering: [], conforms: conforming([provider])).operation == .copy, "\(name)")
            #expect(state.acceptDrop([provider], to: directory), "\(name)")
            try await waitUntil { model.item(at: name) != nil }
        }

        #expect(Set(model.children(of: "").map(\.path)) == ["first.zip", "second.zip", "third.txt"])
        #expect(model.children(of: "").allSatisfy { $0.isPendingAddition })
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    /// The space below the rows of a level that lists items (its layer, `ArchiveDropLayerBelowRows`) drops into
    /// the folder on screen, through `FolderDropDelegate` like the rows: each drop adds its file
    /// once (no second target, such as the `onInsert` the list had, adds it again).
    @Test func listAreaDropsIntoTheShownLevelOnce() async throws {
        let state = try await open()
        let model = try #require(state.model)
        #expect(!model.children(of: "src").isEmpty)

        for (index, name) in ["below.zip", "again.txt"].enumerated() {
            let provider = try fileProvider(try sourceFile(name))
            #expect(state.dropProposal(hovering: [], conforms: conforming([provider])).operation == .copy, "\(name)")
            #expect(state.acceptDrop([provider], to: "src"), "\(name)")
            try await waitUntil { model.item(at: "src/\(name)") != nil }
            #expect(model.changes.additions.count == index + 1, "\(name)")
        }

        #expect(model.item(at: "below.zip") == nil)
        #expect(model.children(of: "src").filter(\.isPendingAddition).map(\.name).sorted() == ["again.txt", "below.zip"])
        #expect(state.alert == nil)
        await state.document.closeOnMain()
    }

    /// A drop while a search hides the new name clears the search, as New Folder does: the item is
    /// added, and listed.
    @Test func dropWhileSearchHidesTheNewNameClearsTheSearch() async throws {
        let state = try await open()
        let model = try #require(state.model)
        state.searchText = "readme"
        let provider = try fileProvider(try sourceFile("zzz-dropped.zip"))
        #expect(state.acceptDrop([provider], to: ""))
        try await waitUntil { model.item(at: "zzz-dropped.zip") != nil }

        #expect(state.searchText.isEmpty)
        #expect(model.children(of: "", matching: state.searchText).contains { $0.path == "zzz-dropped.zip" })
        await state.document.closeOnMain()
    }

    /// A drop whose name the search shows leaves the search as it is.
    @Test func dropWhileSearchShowsTheNewNameKeepsTheSearch() async throws {
        let state = try await open()
        let model = try #require(state.model)
        state.searchText = "readme"
        let provider = try fileProvider(try sourceFile("readme-copy.zip"))
        #expect(state.acceptDrop([provider], to: ""))
        try await waitUntil { model.item(at: "readme-copy.zip") != nil }

        #expect(state.searchText == "readme")
        await state.document.closeOnMain()
    }

    /// A folder row takes drops into that folder, a file row into the level it is listed in.
    @Test func rowDropGoesIntoAFolderRowOrTheFileRowsLevel() async throws {
        let state = try await open()
        let model = try #require(state.model)
        let folder = try #require(model.item(at: "src"))
        let nested = try #require(model.item(at: "src/main.swift"))
        let file = try #require(model.item(at: "README.md"))

        #expect(state.dropDirectory(forRow: folder, in: "") == "src")
        #expect(state.dropDirectory(forRow: nested, in: "src") == "src")
        #expect(state.dropDirectory(forRow: file, in: "") == "")
        await state.document.closeOnMain()
    }

    /// The iPad bug (r2): once a level lists rows, a drop on the empty space below them was refused
    /// (the List's UICollectionView takes it, and the List's `.onDrop` never sees it). A layer over
    /// that space takes it into the folder on screen; it starts just below the lowest row on
    /// screen, so it never covers a row, and goes when the gap is shorter than a row.
    @Test func dropLayerCoversTheSpaceBelowTheLowestRow() {
        let list = CGRect(x: 0, y: 100, width: 400, height: 600)
        let inset = ArchiveRowBottoms.rowBottomInset

        #expect(ArchiveRowBottoms.dropLayerHeight(lowestRowBottom: 250, in: list) == 600 - (150 + inset))
        // No row on screen: none (an empty level has its own layer).
        #expect(ArchiveRowBottoms.dropLayerHeight(lowestRowBottom: nil, in: list) == nil)
        // The rows reach the bottom (more below, scrolled), or leave less than a row's height: none.
        #expect(ArchiveRowBottoms.dropLayerHeight(lowestRowBottom: 750, in: list) == nil)
        #expect(ArchiveRowBottoms.dropLayerHeight(lowestRowBottom: 700 - ArchiveRowBottoms.minimumLayerHeight,
                                                in: list) == nil)
        // The lowest row above the list's top (scrolled under the bars): the whole list.
        #expect(ArchiveRowBottoms.dropLayerHeight(lowestRowBottom: 40, in: list) == 600)
    }

    /// The layer follows the lowest row on screen: rows report their bottom edges while listed and
    /// drop out when they go (scrolled away, deleted, hidden by a search).
    @Test func rowBottomsTrackTheLowestRowOnScreen() {
        let bottoms = ArchiveRowBottoms()
        #expect(bottoms.lowestRowBottom == nil)

        bottoms.set("a", 200)
        bottoms.set("b", 320)
        #expect(bottoms.lowestRowBottom == 320)
        bottoms.set("b", 300)
        #expect(bottoms.lowestRowBottom == 300)
        bottoms.set("b", nil)
        #expect(bottoms.lowestRowBottom == 200)
        bottoms.set("a", nil)
        #expect(bottoms.lowestRowBottom == nil)
    }

    /// Pushing a subfolder (or a full-screen preview) makes the level's rows disappear;
    /// back on the level they reappear unmoved, so no geometry change reports them again. Each row
    /// reports its last bottom edge on appear (what `archiveRowBottom` does), so the layer is back.
    @Test func rowBottomsComeBackWhenTheRowsReappear() {
        let bottoms = ArchiveRowBottoms()
        // The rows lay out: geometry changes report them (the modifier keeps each as its last).
        let laidOut: [(String, CGFloat)] = [("a", 200), ("b", 320)]
        var last: [String: CGFloat] = [:]
        for (id, bottom) in laidOut {
            last[id] = bottom
            bottoms.set(id, bottom)
        }
        #expect(bottoms.lowestRowBottom == 320)

        // A subfolder is pushed: every row disappears.
        for id in last.keys { bottoms.set(id, nil) }
        #expect(bottoms.lowestRowBottom == nil)

        // Back on the level: the rows appear again with no geometry change, each with its last.
        for (id, bottom) in last { bottoms.set(id, bottom) }
        #expect(bottoms.lowestRowBottom == 320)
        #expect(ArchiveRowBottoms.dropLayerHeight(lowestRowBottom: bottoms.lowestRowBottom,
                                                  in: CGRect(x: 0, y: 0, width: 400, height: 800)) != nil)
    }

    /// A web link hovering (no providers, types only) is refused: `public.url` conforms to
    /// `public.data`, but it is no file. A link carrying a file URL, as a file drag may, is not.
    @Test func hoveringLinkIsRefusedButFileDragIsNot() async throws {
        let state = try await open()
        let link = NSItemProvider()
        link.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { _ in nil }
        let linkWithText = NSItemProvider()
        for type in [UTType.url, .utf8PlainText] {
            linkWithText.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { _ in nil }
        }
        #expect(state.dropProposal(hovering: [], conforms: conforming([link])).operation == .forbidden)
        #expect(state.dropProposal(hovering: [], conforms: conforming([linkWithText])).operation == .forbidden)

        let zip = try fileProvider(try sourceFile("Files.zip"))
        let zipWithURL = try fileProvider(try sourceFile("More.zip"))
        zipWithURL.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { _ in nil }
        let folder = folderProvider(try sourceFile("Folder").deletingLastPathComponent())
        let note = NSItemProvider()
        note.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { _ in nil }
        note.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { _ in nil }
        for provider in [zip, zipWithURL, folder, note] {
            #expect(state.dropProposal(hovering: [], conforms: conforming([provider])).operation == .copy,
                    "\(provider.registeredTypeIdentifiers)")
        }
        #expect(state.dragMarkerUTType.identifier == state.dragMarkerType)
        await state.document.closeOnMain()
    }

    /// A drag with file content beside a link and no file URL is not a bare web link: an image
    /// dragged out of Safari (image data plus its URL) and a Files zip dragged with a web link are
    /// copied, as `acceptDrop` takes them; a link alone or with text stays refused.
    @Test func hoveringFileContentWithLinkIsCopied() async throws {
        let state = try await open()
        func offering(_ types: [UTType]) -> NSItemProvider {
            let provider = NSItemProvider()
            for type in types {
                provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { _ in nil }
            }
            return provider
        }
        let safariImage = offering([.jpeg, .url])
        let zipWithLink = offering([.zip, .url])
        let link = offering([.url])
        let linkWithText = offering([.url, .utf8PlainText])
        for provider in [safariImage, zipWithLink] {
            #expect(state.dropProposal(hovering: [], conforms: conforming([provider])).operation == .copy,
                    "\(provider.registeredTypeIdentifiers)")
        }
        // Several items in one drag: the types of all of them count.
        #expect(state.dropProposal(hovering: [], conforms: conforming([offering([.zip]), link])).operation == .copy)
        for provider in [link, linkWithText] {
            #expect(state.dropProposal(hovering: [], conforms: conforming([provider])).operation == .forbidden,
                    "\(provider.registeredTypeIdentifiers)")
        }
        await state.document.closeOnMain()
    }
}

// MARK: - Loading providers

// Main actor, as the providers aren't Sendable; the callbacks are `@Sendable`, so they aren't
// main-actor closures (UIKit calls them off the main thread).

/// A dropped file UIKit has asked for, delivered only once the test calls `deliver`.
private final class HeldFile: @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`.
    private var held: (url: URL, completion: (URL?, Bool, (any Error)?) -> Void)?

    var isHeld: Bool { lock.withLock { held != nil } }

    func hold(_ url: URL, _ completion: @escaping (URL?, Bool, (any Error)?) -> Void) {
        lock.withLock { held = (url, completion) }
    }

    func deliver() {
        guard let (url, completion) = lock.withLock({ held }) else { return }
        completion(url, false, nil)
    }
}

private struct LoadedFile: Sendable {
    var data: Data?
    var isDirectory: Bool
}

/// Loads `provider`'s file for `type` and reads it inside the callback, before it is deleted.
@MainActor private func loadFile(_ provider: NSItemProvider, type: String) async throws -> LoadedFile {
    try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadFileRepresentation(forTypeIdentifier: type) { @Sendable url, error in
            guard let url else { return continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            continuation.resume(returning: LoadedFile(
                data: isDirectory.boolValue ? nil : try? Data(contentsOf: url), isDirectory: isDirectory.boolValue))
        }
    }
}

@MainActor private func loadData(_ provider: NSItemProvider, type: String) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        _ = provider.loadDataRepresentation(forTypeIdentifier: type) { @Sendable data, error in
            if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
            }
        }
    }
}

/// The files the fake reader extracted under `names` (its "FakeReader-…" temporary folders).
private func extractedCopies(named names: [String]) -> [URL] {
    let fileManager = FileManager.default
    let tmp = fileManager.temporaryDirectory
    let folders = (try? fileManager.contentsOfDirectory(atPath: tmp.path)) ?? []
    return folders.filter { $0.hasPrefix(FakeReader.temporaryFolderPrefix) }.flatMap { folder in
        names.map { tmp.appendingPathComponent(folder).appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }
}

/// The folders dropped files are received into before staging. A test compares the set before
/// and after its drop, so leftovers of an earlier run don't matter.
private func droppedCopies() -> Set<String> {
    let tmp = FileManager.default.temporaryDirectory
    return Set(((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
        .filter { $0.hasPrefix(DroppedItem.folderPrefix) })
}
