import Testing
import AppKit
import Foundation
@testable import Kernir
import KernirCore

/// Files opened from an archive window: copies owned until close, offered back when changed in
/// another app, inner archives as untitled copies, temp paths out of Open Recent.
@MainActor
struct OpenedFilesTests {
    @Test func changedFileAlertForAnEditableArchive() {
        let alert = ArchiveDocument.openedFileChangedAlert(name: "notes.txt", canUpdate: true)
        #expect(alert.messageText.contains("“notes.txt”"))
        #expect(alert.buttons.map(\.title) == [String(localized: "Update"), String(localized: "Don't Update"),
                                               String(localized: "Show in Finder")])
        #expect(alert.buttons.map { $0.accessibilityIdentifier() } ==
                ["openedFileChanged.update", "openedFileChanged.dontUpdate", "openedFileChanged.showInFinder"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
        #expect(ArchiveDocument.answer(to: .alertFirstButtonReturn, canUpdate: true) == .update)
        #expect(ArchiveDocument.answer(to: .alertSecondButtonReturn, canUpdate: true) == .dontUpdate)
        #expect(ArchiveDocument.answer(to: .alertThirdButtonReturn, canUpdate: true) == .showInFinder)
    }

    /// Return must never lose the edits when the archive can't take them.
    @Test func changedFileAlertForAReadOnlyArchive() {
        let alert = ArchiveDocument.openedFileChangedAlert(name: "notes.txt", canUpdate: false)
        #expect(alert.buttons.map { $0.accessibilityIdentifier() } ==
                ["openedFileChanged.showInFinder", "openedFileChanged.dontUpdate"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
        #expect(ArchiveDocument.answer(to: .alertFirstButtonReturn, canUpdate: false) == .showInFinder)
        #expect(ArchiveDocument.answer(to: .alertSecondButtonReturn, canUpdate: false) == .dontUpdate)
    }

    /// An item another app saved next to a copy wasn't opened by the user: the message says where
    /// it came from, and letting it go takes a click on Delete, never Return or Esc.
    @Test func newItemAlertForAnEditableArchive() {
        let name = "notes.pdf"
        let alert = ArchiveDocument.openedFileChangedAlert(name: name, canUpdate: true, isNew: true)
        #expect(alert.messageText == String(localized: "“\(name)” was saved in the folder of a file opened from this archive. Update the archive?"))
        #expect(alert.informativeText == String(localized: "Unless you update the archive with it or move it, it's deleted when the archive closes."))
        #expect(alert.buttons.map(\.title) == [String(localized: "Update"), String(localized: "Show in Finder"),
                                               String(localized: "Delete")])
        #expect(alert.buttons.map { $0.accessibilityIdentifier() } ==
                ["openedFileChanged.update", "openedFileChanged.showInFinder", "openedFileChanged.delete"])
        #expect(alert.buttons.map(\.keyEquivalent) == ["\r", "\u{1b}", ""])
        #expect(alert.buttons.map(\.hasDestructiveAction) == [false, false, true])
    }

    @Test func newItemAlertForAReadOnlyArchive() {
        let name = "notes.pdf"
        let alert = ArchiveDocument.openedFileChangedAlert(name: name, canUpdate: false, isNew: true)
        #expect(alert.messageText == String(localized: "“\(name)” was saved in the folder of a file opened from this archive, but this archive can't be updated."))
        #expect(alert.informativeText == String(localized: "Show it in Finder to keep it. Unless you move it, it's deleted when the archive closes."))
        #expect(alert.buttons.map(\.title) == [String(localized: "Show in Finder"), String(localized: "Delete")])
        #expect(alert.buttons.map { $0.accessibilityIdentifier() } ==
                ["openedFileChanged.showInFinder", "openedFileChanged.delete"])
        #expect(alert.buttons.map(\.keyEquivalent) == ["\r", ""])
        #expect(alert.buttons.map(\.hasDestructiveAction) == [false, true])
    }

    /// Updating a copy would replace a different archive item: Update becomes Keep Both (Return)
    /// and Replace, as when extracting onto an existing name.
    @Test func takenNameAlertForAChangedFile() {
        let name = "notes.txt"
        let alert = ArchiveDocument.openedFileChangedAlert(name: name, canUpdate: true, nameTaken: true)
        #expect(alert.messageText == String(localized: "“\(name)” was changed in another app, and the archive already has a different item with that name."))
        #expect(alert.informativeText == String(localized: "Keep Both adds it under a new name."))
        #expect(alert.buttons.map(\.title) == [String(localized: "Keep Both"), String(localized: "Replace"),
                                               String(localized: "Don't Update"), String(localized: "Show in Finder")])
        #expect(alert.buttons.map { $0.accessibilityIdentifier() } ==
                ["openedFileChanged.keepBoth", "openedFileChanged.replace", "openedFileChanged.dontUpdate",
                 "openedFileChanged.showInFinder"])
        #expect(alert.buttons.map(\.keyEquivalent) == ["\r", "", "\u{1b}", ""])
        #expect(alert.buttons.map(\.hasDestructiveAction) == [false, true, false, false])
    }

    /// A new item named like a different archive item: Keep Both or Replace puts it in, and
    /// letting it go still takes a click on Delete.
    @Test func takenNameAlertForANewItem() {
        let name = "notes.pdf"
        let alert = ArchiveDocument.openedFileChangedAlert(name: name, canUpdate: true, isNew: true, nameTaken: true)
        #expect(alert.messageText == String(localized: "“\(name)” was saved in the folder of a file opened from this archive, and the archive already has an item with that name."))
        #expect(alert.informativeText == String(localized: "Keep Both adds it under a new name. Unless you update the archive with it or move it, it's deleted when the archive closes."))
        #expect(alert.buttons.map(\.title) == [String(localized: "Keep Both"), String(localized: "Replace"),
                                               String(localized: "Show in Finder"), String(localized: "Delete")])
        #expect(alert.buttons.map { $0.accessibilityIdentifier() } ==
                ["openedFileChanged.keepBoth", "openedFileChanged.replace", "openedFileChanged.showInFinder",
                 "openedFileChanged.delete"])
        #expect(alert.buttons.map(\.keyEquivalent) == ["\r", "", "\u{1b}", ""])
        #expect(alert.buttons.map(\.hasDestructiveAction) == [false, true, false, true])
    }

    /// Each button answers what its identifier says, in every variant; a response that is no
    /// button (a sheet ended from outside) keeps the item and cancels the close.
    @Test(arguments: [(true, false, false), (false, false, false), (true, true, false), (false, true, false),
                      (true, false, true), (true, true, true)])
    func answersMatchTheButtons(canUpdate: Bool, isNew: Bool, nameTaken: Bool) {
        let alert = ArchiveDocument.openedFileChangedAlert(name: "notes.txt", canUpdate: canUpdate, isNew: isNew,
                                                           nameTaken: nameTaken)
        let identifiers: [OpenedFilesReview.Answer: String] = [
            .update: "openedFileChanged.update", .keepBoth: "openedFileChanged.keepBoth",
            .replace: "openedFileChanged.replace", .dontUpdate: "openedFileChanged.dontUpdate",
            .showInFinder: "openedFileChanged.showInFinder", .delete: "openedFileChanged.delete",
        ]
        let fourth = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1)
        let responses: [NSApplication.ModalResponse] = [.alertFirstButtonReturn, .alertSecondButtonReturn,
                                                        .alertThirdButtonReturn, fourth]
        let answers = responses.prefix(alert.buttons.count).map {
            ArchiveDocument.answer(to: $0, canUpdate: canUpdate, isNew: isNew, nameTaken: nameTaken)
        }
        #expect(answers.map { identifiers[$0] } == alert.buttons.map { $0.accessibilityIdentifier() })
        #expect(answers == ArchiveDocument.openedFileAnswers(canUpdate: canUpdate, isNew: isNew, nameTaken: nameTaken))
        #expect(answers.contains(.update) == (canUpdate && !nameTaken))
        #expect(answers.contains(.keepBoth) == nameTaken)
        #expect(answers.contains(.replace) == nameTaken)
        #expect(answers.contains(.delete) == isNew)
        #expect(answers.contains(.dontUpdate) != isNew)
        var others: [NSApplication.ModalResponse] = [.cancel, .abort, .stop]
        others += responses.dropFirst(alert.buttons.count)
        others.append(NSApplication.ModalResponse(rawValue: fourth.rawValue + 1))
        for response in others {
            #expect(ArchiveDocument.answer(to: response, canUpdate: canUpdate, isNew: isNew,
                                           nameTaken: nameTaken) == .showInFinder)
        }
    }

    @Test func appUsesKernirDocumentController() {
        #expect(NSDocumentController.shared is KernirDocumentController)
    }

    @Test func temporaryURLsStayOutOfOpenRecent() {
        let temporary = FileManager.default.temporaryDirectory
        #expect(KernirDocumentController.isTemporary(temporary.appendingPathComponent("Kernir-1/inner.zip")))
        #expect(!KernirDocumentController.isTemporary(temporary))
        #expect(!KernirDocumentController.isTemporary(URL(fileURLWithPath: "/Users/someone/Downloads/a.zip")))
        #expect(!KernirDocumentController.isTemporary(
            URL(fileURLWithPath: "/private/var/folders/ab/xyzz/a.zip"),
            temporaryDirectory: URL(fileURLWithPath: "/private/var/folders/ab/xyz", isDirectory: true)))
    }

    /// A path that doesn't exist (a copy already deleted) can't be resolved: /var, /tmp and /etc
    /// still match /private/… either way round.
    @Test(arguments: ["/var/folders/ab/xyz/T", "/tmp/xyz", "/etc/xyz"])
    func temporaryPathsMatchWithOrWithoutPrivate(base: String) {
        let privateBase = "/private" + base
        for (file, folder) in [(base, privateBase), (privateBase, base), (base, base), (privateBase, privateBase)] {
            #expect(KernirDocumentController.isTemporary(
                URL(fileURLWithPath: file + "/Kernir-1/inner.zip"),
                temporaryDirectory: URL(fileURLWithPath: folder, isDirectory: true)))
        }
        #expect(!KernirDocumentController.isTemporary(
            URL(fileURLWithPath: "/private" + base + "z/a.zip"),
            temporaryDirectory: URL(fileURLWithPath: base, isDirectory: true)))
    }

    /// `folder/inner.zip` holding one file, hello.txt.
    private static func makeZip(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: file)
        let zip = folder.appendingPathComponent("inner.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", file.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        try #require(ditto.terminationStatus == 0)
        return zip
    }

    /// An inner archive opens untitled, named after itself, from a copy it deletes on close.
    @Test func innerArchiveOpensAsAnUntitledCopy() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenedFilesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try Self.makeZip(in: folder)

        let document = try await ArchiveActions.openAsUntitledCopy(of: zip)
        let owned = try #require(document.ownedTemporaryDirectory)
        #expect(document.fileURL == nil)
        #expect(document.displayName == "inner")
        #expect(document.model?.items.map(\.path) == ["hello.txt"])
        #expect(FileManager.default.fileExists(atPath: owned.appendingPathComponent("inner.zip").path))
        #expect(!NSDocumentController.shared.recentDocumentURLs.contains { $0.path.hasPrefix(owned.path) })
        document.close()
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        // The original is untouched.
        #expect(FileManager.default.fileExists(atPath: zip.path))
    }

    /// An inner archive is as downloaded as the archive it came out of: its copy gets the outer archive's
    /// quarantine, so what is extracted from it does too; an inner archive of a clean one has only the
    /// sandbox's own mark, which is never carried over (`QuarantinePropagation.isOwnSandboxMark`).
    @Test(arguments: [true, false])
    func innerArchiveIsQuarantinedLikeTheOuterOne(_ downloaded: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenedFilesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try Self.makeZip(in: folder)
        let outer = try await writeQuarantineSample(in: folder, quarantined: downloaded)

        let document = try await ArchiveActions.openAsUntitledCopy(of: zip, quarantinedLike: [outer])
        defer { document.close() }
        let owned = try #require(document.ownedTemporaryDirectory)
        let sources = try #require(document.model?.quarantineSources)

        #expect(try quarantineEvent(of: owned.appendingPathComponent("inner.zip")) == (downloaded ? sampleQuarantineEvent : nil))
        let carried = QuarantinePropagation.properties(of: sources)
        #expect(carried?["LSQuarantineEventIdentifier"] as? String == (downloaded ? sampleQuarantineEvent : nil))
        #expect((carried == nil) == !downloaded)
    }

    /// Revert to Saved reads the file into a new model: copies opened before stay the document's,
    /// are still offered back, and go on close.
    @Test func openedCopiesOutliveARevert() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenedFilesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = try Self.makeZip(in: folder)
        let document = try await ArchiveActions.openAsUntitledCopy(of: zip)
        let owned = try #require(document.ownedTemporaryDirectory)
        let first = try #require(document.model)
        #expect(first.openedFiles === document.openedFiles)
        let copy = try await first.copyForOpening("hello.txt")

        try document.read(from: owned.appendingPathComponent("inner.zip"), ofType: "public.zip-archive")
        let second = try #require(document.model)
        #expect(second !== first)
        #expect(second.openedFiles === document.openedFiles)
        try Data("edited".utf8).write(to: copy)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: copy.path)
        #expect(document.hasChangedOpenedFiles)
        #expect(second.changedOpenedFiles().map(\.url) == [copy])

        document.close()
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(!document.hasChangedOpenedFiles)
    }

    // MARK: - The review steps, without sheets

    /// One question the review asked.
    private struct Question: Equatable {
        let name: String
        let canUpdate: Bool
        let isNew: Bool
        var nameTaken = false
    }

    /// Answers the review's questions from a script, and records them.
    private final class Script {
        var answers: [OpenedFilesReview.Answer]
        var asked: [Question] = []
        /// Runs while question `asked.count - 1` is up, as another app would.
        var whileAsking: (Int) throws -> Void = { _ in }
        init(_ answers: [OpenedFilesReview.Answer]) { self.answers = answers }
    }

    /// Runs a review of `openedFiles` against `script`; a question past the script's end gets
    /// Show in Finder, which ends the review, so a review that asks too much still ends.
    private func review(_ openedFiles: OpenedFiles, model: ArchiveModel?,
                        _ script: Script) async -> OpenedFilesReview.Outcome {
        let review = OpenedFilesReview(openedFiles: openedFiles, model: model) { file, canUpdate, isNew, nameTaken, answer in
            script.asked.append(Question(name: file.url.lastPathComponent, canUpdate: canUpdate, isNew: isNew,
                                         nameTaken: nameTaken))
            try? script.whileAsking(script.asked.count - 1)
            answer(script.answers.isEmpty ? .showInFinder : script.answers.removeFirst())
        }
        return await withCheckedContinuation { continuation in
            review.run { continuation.resume(returning: $0) }
        }
    }

    private static let entries = [
        ArchiveEntry(path: "docs", isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil),
        ArchiveEntry(path: "docs/notes.txt", isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil),
    ]

    /// A model of `entries` whose copies go into `folder`.
    private static func makeModel(copiesIn folder: URL, entries: [ArchiveEntry] = Self.entries) -> ArchiveModel {
        ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil, openedFiles: OpenedFiles(in: folder))
    }

    /// Changes `url` as another app's save would: new bytes and a later modification date.
    private static func edit(_ url: URL, to contents: String) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: url.path)
    }

    private static func makeFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenedFilesTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func updateThatGoesInIsSaved() async throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = Self.makeModel(copiesIn: folder)
        defer { model.openedFiles.close() }
        let copy = try await model.copyForOpening("docs/notes.txt")
        try Self.edit(copy, to: "edited")

        let script = Script([.update])
        #expect(await review(model.openedFiles, model: model, script) == .finished(updated: true))
        #expect(script.asked == [Question(name: "notes.txt", canUpdate: true, isNew: false)])
        #expect(model.openedFiles.changed().isEmpty)
    }

    /// An Update that doesn't go in is never silent: the same copy is asked about again without
    /// Update, Return there is Show in Finder, and nothing counts as updated.
    @Test(arguments: [OpenedFilesReview.Answer.showInFinder, .dontUpdate])
    func refusedUpdateAsksAgainWithoutUpdate(then second: OpenedFilesReview.Answer) async throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = Self.makeModel(copiesIn: folder)
        defer { model.openedFiles.close() }
        let copy = try await model.copyForOpening("docs/notes.txt")
        try Self.edit(copy, to: "edited")
        // A file where the copy's folder was: the copy can't go back in.
        let own = folder.appendingPathComponent("own", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: own.appendingPathComponent("docs"))
        model.remove(["docs"])
        model.add([own.appendingPathComponent("docs")], to: "")

        let script = Script([.update, second])
        let outcome = await review(model.openedFiles, model: model, script)
        #expect(script.asked == [Question(name: "notes.txt", canUpdate: true, isNew: false),
                                 Question(name: "notes.txt", canUpdate: false, isNew: false)])
        if second == .showInFinder {
            #expect(outcome == .showInFinder(copy))
            #expect(model.openedFiles.changed().map(\.url) == [copy])
        } else {
            #expect(outcome == .finished(updated: false))
            #expect(model.openedFiles.changed().isEmpty)
        }
    }

    /// A new item goes only on Delete, and close then deletes it; Show in Finder keeps it and
    /// cancels the close.
    @Test(arguments: [OpenedFilesReview.Answer.delete, .showInFinder])
    func newItemWithoutAModel(answer: OpenedFilesReview.Answer) async throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("scan.png")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: source)
        let openedFiles = OpenedFiles(in: folder.appendingPathComponent("copies", isDirectory: true))
        let copy = try await openedFiles.copy(source, named: "scan.png", path: "scan.png",
                                              item: .saved(size: nil, modified: nil, isDirectory: false),
                                              asOf: openedFiles.saves)
        let export = copy.deletingLastPathComponent().appendingPathComponent("scan.pdf")
        try Data("pdf".utf8).write(to: export)

        let script = Script([answer])
        let outcome = await review(openedFiles, model: nil, script)
        #expect(script.asked == [Question(name: "scan.pdf", canUpdate: false, isNew: true)])
        if answer == .delete {
            #expect(outcome == .finished(updated: false))
            #expect(openedFiles.changed().isEmpty)
        } else {
            #expect(outcome == .showInFinder(export))
            #expect(openedFiles.changed().map(\.url) == [export])
        }
        openedFiles.close()
        #expect(!FileManager.default.fileExists(atPath: export.path))
    }

    /// What changes while a sheet is up is asked about once the list ends; each item answered
    /// is asked about again only if it changes again.
    @Test func itemsChangedDuringTheReviewAreAskedAbout() async throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = Self.makeModel(copiesIn: folder)
        defer { model.openedFiles.close() }
        let copy = try await model.copyForOpening("docs/notes.txt")
        try Self.edit(copy, to: "edited")
        let export = copy.deletingLastPathComponent().appendingPathComponent("notes.pdf")

        let script = Script([.dontUpdate, .delete])
        script.whileAsking = { index in
            if index == 0 { try Data("pdf".utf8).write(to: export) }
        }
        #expect(await review(model.openedFiles, model: model, script) == .finished(updated: false))
        #expect(script.asked == [Question(name: "notes.txt", canUpdate: true, isNew: false),
                                 Question(name: "notes.pdf", canUpdate: true, isNew: true)])
        #expect(model.openedFiles.changed().isEmpty)
    }

    /// A new item updated into the archive goes in beside the copy's item.
    @Test func newItemUpdatedGoesInBesideTheCopy() async throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = Self.makeModel(copiesIn: folder)
        defer { model.openedFiles.close() }
        let copy = try await model.copyForOpening("docs/notes.txt")
        try Data("pdf".utf8).write(to: copy.deletingLastPathComponent().appendingPathComponent("notes.pdf"))

        let script = Script([.update])
        #expect(await review(model.openedFiles, model: model, script) == .finished(updated: true))
        #expect(script.asked == [Question(name: "notes.pdf", canUpdate: true, isNew: true)])
        #expect(model.item(at: "docs/notes.pdf")?.isPendingAddition == true)
    }

    /// A new item named like a different archive item is asked about with Keep Both and Replace:
    /// Keep Both puts it in under a new name and leaves the item, Replace replaces the item.
    @Test(arguments: [OpenedFilesReview.Answer.keepBoth, .replace])
    func newItemNamedLikeAnItemAsksKeepBothOrReplace(answer: OpenedFilesReview.Answer) async throws {
        let folder = Self.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = ArchiveEntry(path: "docs/notes.pdf", isDirectory: false, size: 1, compressedSize: 1,
                               modificationDate: nil)
        let model = Self.makeModel(copiesIn: folder, entries: Self.entries + [pdf])
        defer { model.openedFiles.close() }
        let copy = try await model.copyForOpening("docs/notes.txt")
        try Data("pdf".utf8).write(to: copy.deletingLastPathComponent().appendingPathComponent("notes.pdf"))

        let script = Script([answer])
        #expect(await review(model.openedFiles, model: model, script) == .finished(updated: true))
        #expect(script.asked == [Question(name: "notes.pdf", canUpdate: true, isNew: true, nameTaken: true)])
        #expect(model.openedFiles.changed().isEmpty)
        if answer == .keepBoth {
            #expect(model.item(at: "docs/notes 2.pdf")?.isPendingAddition == true)
            #expect(model.item(at: "docs/notes.pdf")?.isPendingAddition == false)
        } else {
            #expect(model.item(at: "docs/notes.pdf")?.isPendingAddition == true)
            #expect(model.item(at: "docs/notes 2.pdf") == nil)
        }
    }
}
