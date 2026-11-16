import Foundation
import Testing
import KernirCore
@testable import Kernir

/// The Save button's Mac metadata question: an explicit Save of
/// edits to an unanswered archive whose source holds `__MACOSX` or `._*` asks before it writes; the answer
/// is recorded and the save goes on while edits are still allowed; Cancel saves and records nothing. A
/// stand-in for `ScreenState` (`QuestionHost`) records the saves. No document or engine seam: runs in
/// parallel, and in the macOS SwiftPM mirror. Time-limited: `untilSaving(_:)` waits without a bound.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MacMetadataSaveQuestionTests {
    private static func entry(_ path: String, isDirectory: Bool = false) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: isDirectory, size: isDirectory ? nil : 1,
                     compressedSize: isDirectory ? nil : 1, modificationDate: nil)
    }

    /// As Finder zips a folder: the files plus a `__MACOSX` tree of `._*` companions.
    private static let finderEntries = FakeReader.sample().entries + [
        entry("__MACOSX", isDirectory: true),
        entry("__MACOSX/._README.md"),
    ]

    /// Only Finder view state: no `__MACOSX`, no `._*`.
    private static let dsStoreOnlyEntries = FakeReader.sample().entries + [
        entry(".DS_Store"),
        entry("src/.DS_Store"),
    ]

    /// `ScreenState`'s part in the question: the editing gate, the pending question, and the document's
    /// answer and save, recorded.
    @MainActor final class QuestionHost: MacMetadataSaveQuestion {
        let session = DocumentSession()
        let model: ArchiveModel
        let fixture: ChoiceStoreFixture
        var allowsEditing = true
        var hasChanges: Bool { model.hasChanges }
        var macMetadataQuestion = false
        /// The session's choice at each save: what that save wrote with.
        private(set) var saves: [Bool?] = []

        /// A ready archive over `entries`, detected as a document does on open, with README.md removed.
        init(_ entries: [ArchiveEntry], edited: Bool = true) throws {
            fixture = try ChoiceStoreFixture()
            model = ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil)
            session.phase = .ready(model)
            session.detectMacMetadata(in: model.reader)
            if edited { model.remove(["README.md"]) }
        }

        func setMacMetadataChoice(_ strips: Bool) {
            session.answerMacMetadataQuestion(strips: strips, for: fixture.archive, in: fixture.store)
        }

        /// True: the next save stops once it has recorded, until `finishSave()`, as a document save
        /// writing off the main actor does. Only one is held; a save meanwhile records and returns.
        var holdsSaves = false
        private var heldSave: CheckedContinuation<Void, Never>?
        var isSaving: Bool { heldSave != nil }
        /// `untilSaving(_:)`'s wait: resumed once, when a save holds or the awaited task ends.
        private var savingWaiter: CheckedContinuation<Void, Never>?

        func commitSave() async -> Bool {
            saves.append(session.plainSaveChoice(for: model))
            if holdsSaves, heldSave == nil {
                await withCheckedContinuation {
                    heldSave = $0
                    endSavingWait()
                }
            }
            return true
        }

        func finishSave() {
            heldSave?.resume()
            heldSave = nil
        }

        /// Waits until a save holds, or until `task` (the one that should save) has ended without one
        /// holding: no spin with a bound to run out, so a held save is never left behind by a wait that
        /// gave up before it held. Everything here runs on the main actor, one wait at a time.
        func untilSaving(_ task: Task<Void, Never>) async {
            guard !isSaving else { return }
            Task { @MainActor in
                await task.value
                self.endSavingWait()
            }
            await withCheckedContinuation { savingWaiter = $0 }
        }

        private func endSavingWait() {
            savingWaiter?.resume()
            savingWaiter = nil
        }

        /// Nothing answered: neither this session nor the file's record has a choice.
        var isUnanswered: Bool { session.macMetadataChoice == nil && fixture.isEmpty }
    }

    // MARK: - Save asks (Q-c3)

    @Test func saveAsksFirstWhenTheSourceHasMacMetadata() async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }

        await host.saveOrAskAboutMacMetadata()

        #expect(host.macMetadataQuestion)
        #expect(host.saves.isEmpty)
        #expect(host.isUnanswered)
    }

    /// The question is up and the scene goes to the background (or the document closes): that save can't
    /// ask, so it keeps, records nothing, and the question stays for the answer.
    @Test(arguments: [false, true]) func implicitSaveWhileAskingKeeps(_ defaultExcludes: Bool) async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }
        await host.saveOrAskAboutMacMetadata()

        #expect(host.session.plainSaveOptions(for: host.model, default: defaultExcludes) == nil)
        #expect(host.macMetadataQuestion)
        #expect(host.isUnanswered)
    }

    // MARK: - Save writes at once, as before (c)

    @Test func archiveWithoutMacMetadataSavesAtOnce() async throws {
        let host = try QuestionHost(FakeReader.sample().entries)
        defer { host.fixture.cleanUp() }

        await host.saveOrAskAboutMacMetadata()

        #expect(!host.macMetadataQuestion)
        #expect(host.saves == [nil])
    }

    /// Q-c4: `.DS_Store` alone is not asked about; the default strip removes it.
    @Test func dsStoreOnlyArchiveSavesAtOnce() async throws {
        let host = try QuestionHost(Self.dsStoreOnlyEntries)
        defer { host.fixture.cleanUp() }

        await host.saveOrAskAboutMacMetadata()

        #expect(!host.macMetadataQuestion)
        #expect(host.saves == [nil])
        #expect(host.isUnanswered)
    }

    /// Answered before (remembered for the file, or earlier in this session): no second question.
    @Test(arguments: [false, true]) func answeredArchiveSavesAtOnce(_ strips: Bool) async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }
        host.session.adoptRememberedMacMetadataChoice(strips)

        await host.saveOrAskAboutMacMetadata()

        #expect(!host.macMetadataQuestion)
        #expect(host.saves == [strips])
    }

    /// A new archive (Part B): the options its sheet saved already say what to do with Mac metadata.
    @Test func archiveWithSavedOptionsSavesAtOnce() async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }
        host.model.apply(ArchiveSaveSettings(format: .zip, options: ArchiveWriteOptions(excludesMacMetadata: true)))

        await host.saveOrAskAboutMacMetadata()

        #expect(!host.macMetadataQuestion)
        #expect(host.saves == [nil])
        #expect(host.isUnanswered)
    }

    /// Nothing to write, or edits are off (saving, Text Encoding's reopen, a read-only archive): no
    /// question; the save goes to the document, which writes nothing, as before (c).
    @Test(arguments: [false, true]) func noQuestionWithoutAnEditableChange(_ edited: Bool) async throws {
        let host = try QuestionHost(Self.finderEntries, edited: edited)
        defer { host.fixture.cleanUp() }
        host.allowsEditing = !edited

        await host.saveOrAskAboutMacMetadata()

        #expect(!host.macMetadataQuestion)
        #expect(host.saves.count == 1)
        #expect(host.isUnanswered)
    }

    // MARK: - The answer

    /// Keep or Remove: recorded (this session and the file's record), then the save writes with it.
    @Test(arguments: [false, true]) func answerIsRecordedThenSaved(_ remove: Bool) async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }
        await host.saveOrAskAboutMacMetadata()

        await host.answerMacMetadataQuestion(remove: remove)

        #expect(!host.macMetadataQuestion)
        #expect(host.session.macMetadataChoice == remove)
        #expect(host.fixture.store.choice(for: host.fixture.archive) == remove)
        #expect(host.saves == [remove])
    }

    /// Edits went off while the question was up (a background save is writing): the answer is
    /// recorded for the next save, but this one doesn't start.
    @Test(arguments: [false, true]) func answerSavesOnlyWhileEditsAreAllowed(_ remove: Bool) async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }
        await host.saveOrAskAboutMacMetadata()
        host.allowsEditing = false

        await host.answerMacMetadataQuestion(remove: remove)

        #expect(!host.macMetadataQuestion)
        #expect(host.session.macMetadataChoice == remove)
        #expect(host.fixture.store.choice(for: host.fixture.archive) == remove)
        #expect(host.saves.isEmpty)
    }

    /// While the answer's save writes, the question is down already: the alert doesn't come back over
    /// the save, and a second answer (a double tap) records nothing and doesn't save again.
    @Test(arguments: [false, true]) func questionIsDownWhileTheAnswerSaves(_ remove: Bool) async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }
        await host.saveOrAskAboutMacMetadata()
        host.holdsSaves = true
        defer { host.finishSave() }

        let answering = Task { await host.answerMacMetadataQuestion(remove: remove) }
        await host.untilSaving(answering)
        try #require(host.isSaving)

        #expect(!host.macMetadataQuestion)
        await host.answerMacMetadataQuestion(remove: !remove)
        #expect(host.session.macMetadataChoice == remove)
        #expect(host.fixture.store.choice(for: host.fixture.archive) == remove)
        #expect(host.saves == [remove])

        host.finishSave()
        await answering.value
        #expect(!host.macMetadataQuestion)
        #expect(host.saves == [remove])
    }

    /// The alert's Keep and Remove: the question goes down and the answer is recorded at
    /// once, in the button's action, so the alert can't show again before the save's `Task` runs; it
    /// returns whether that save should follow. A second answer is taken by nobody.
    @Test(arguments: [false, true]) func takingTheAnswerClearsAndRecordsAtOnce(_ remove: Bool) async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }
        await host.saveOrAskAboutMacMetadata()

        #expect(host.takeMacMetadataAnswer(remove: remove))

        #expect(!host.macMetadataQuestion)
        #expect(host.session.macMetadataChoice == remove)
        #expect(host.fixture.store.choice(for: host.fixture.archive) == remove)
        #expect(host.saves.isEmpty)
        #expect(!host.takeMacMetadataAnswer(remove: !remove))
        #expect(host.session.macMetadataChoice == remove)
        #expect(host.saves.isEmpty)
    }

    /// For the button: edits went off while the question was up: the answer is taken and recorded,
    /// but no save follows.
    @Test(arguments: [false, true]) func takingTheAnswerWithEditsOffRecordsWithoutASave(_ remove: Bool) async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }
        await host.saveOrAskAboutMacMetadata()
        host.allowsEditing = false

        #expect(!host.takeMacMetadataAnswer(remove: remove))

        #expect(!host.macMetadataQuestion)
        #expect(host.session.macMetadataChoice == remove)
        #expect(host.fixture.store.choice(for: host.fixture.archive) == remove)
        #expect(host.saves.isEmpty)
    }

    @Test func takingAnAnswerWithoutAQuestionDoesNothing() async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }

        #expect(!host.takeMacMetadataAnswer(remove: true))

        #expect(!host.macMetadataQuestion)
        #expect(host.saves.isEmpty)
        #expect(host.isUnanswered)
    }

    @Test func cancelSavesNothingAndRecordsNothing() async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }
        await host.saveOrAskAboutMacMetadata()

        host.cancelMacMetadataQuestion()

        #expect(!host.macMetadataQuestion)
        #expect(host.saves.isEmpty)
        #expect(host.isUnanswered)
        // The next Save asks again.
        await host.saveOrAskAboutMacMetadata()
        #expect(host.macMetadataQuestion)
        #expect(host.saves.isEmpty)
    }

    /// No question up (a second tap on an answer, or none asked): nothing recorded, nothing saved.
    @Test func answerWithoutAQuestionDoesNothing() async throws {
        let host = try QuestionHost(Self.finderEntries)
        defer { host.fixture.cleanUp() }

        await host.answerMacMetadataQuestion(remove: true)

        #expect(host.saves.isEmpty)
        #expect(host.isUnanswered)
    }
}
