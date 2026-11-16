import Testing
import Foundation
@testable import Kernir
import KernirCore

/// The ZIP archive comment through the real engine (KernirCore's `Archive.open` and
/// `ArchiveWriter.write`, as `ArchiveEngine.live` calls them), no UI. A model edits the
/// comment of one of the comment fixtures, the save writes `model.saveChanges(as: .zip)` as the document
/// does, and the reopened archive holds the expected comment bytes. Skipped where the repository's
/// `Fixtures` folder can't be read (a sandboxed hosted run); the shared harness points `KERNIR_FIXTURES` at it.
@MainActor @Suite(.enabled(if: Fixture.isReadable))
struct ArchiveModelCommentLiveTests {
    /// The UTF-8 comment of `zip/comment-utf8.zip` (Fixtures/manifest.json).
    private static let utf8Comment = "Привет из Kernir 🎉\nКомментарий архива в UTF-8, без BOM.\n"
    /// The comment of the split set `multivolume/sz-comment.zip.00x`, in its last part.
    private static let splitComment = "Kernir split-volume fixture.\nThis comment lives in the last part."

    /// A fixture copied into a fresh folder of its own (removed by `cleanUp`), opened by the real engine.
    @MainActor private struct Opened {
        let directory: URL
        let reader: any ArchiveReading
        let model: ArchiveModel

        func cleanUp() {
            model.removeTemporaryFiles()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func open(_ relativePaths: [String]) async throws -> Opened {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveModelCommentLiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var first: URL?
        for path in relativePaths {
            let source = Fixture.root.appendingPathComponent(path)
            let copy = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: copy)
            first = first ?? copy
        }
        let reader = try await Archive.open(at: try #require(first))
        return Opened(directory: directory, reader: reader, model: ArchiveModel(reader: reader, undoManager: nil))
    }

    private func open(_ relativePath: String) async throws -> Opened {
        try await open([relativePath])
    }

    /// Saves the model's changes as the document does (refused when `saveProblem` says so), reopens the
    /// saved archive and hands it to the model.
    private func saveAndReopen(_ opened: Opened) async throws -> any ArchiveReading {
        #expect(opened.model.saveProblem(as: .zip, split: false) == nil)
        let savedURL = opened.directory.appendingPathComponent("saved.zip")
        try await ArchiveWriter.write(source: opened.reader, changes: opened.model.saveChanges(as: .zip), format: .zip,
                                      to: savedURL, options: opened.model.saveOptions)
        let saved = try await Archive.open(at: savedURL)
        opened.model.didSave(reader: saved)
        return saved
    }

    @Test func setOnAnArchiveWithoutAComment() async throws {
        let opened = try await open("zip/deflate.zip")
        defer { opened.cleanUp() }
        #expect(opened.reader.comment == nil)
        #expect(opened.model.canEditComment)

        opened.model.setComment("Set by Kernir")
        #expect(opened.model.changes.comment == .set("Set by Kernir"))
        let saved = try await saveAndReopen(opened)
        #expect(saved.comment?.bytes == Array("Set by Kernir".utf8))
        #expect(opened.model.changes.comment == .keep)
        #expect(opened.model.commentText == "Set by Kernir")
    }

    @Test func changeAUTF8Comment() async throws {
        let opened = try await open("zip/comment-utf8.zip")
        defer { opened.cleanUp() }
        #expect(opened.reader.comment?.text == Self.utf8Comment)

        let text = "Изменено в Kernir ✓"
        opened.model.setComment(text)
        let saved = try await saveAndReopen(opened)
        #expect(saved.comment?.bytes == Array(text.utf8))
        #expect(saved.comment?.text == text)
        #expect(Set(saved.entries.map(\.path)) == Set(opened.reader.entries.map(\.path)))
    }

    @Test func removeAComment() async throws {
        let opened = try await open("zip/comment-utf8.zip")
        defer { opened.cleanUp() }
        #expect(opened.reader.comment != nil)

        opened.model.setComment("")
        #expect(opened.model.changes.comment == .remove)
        let saved = try await saveAndReopen(opened)
        #expect(saved.comment?.bytes == nil)
        #expect(opened.model.commentText == "")
    }

    /// An untouched comment is `.keep`: the save copies the source's bytes, which for CP437 aren't the
    /// UTF-8 of the text shown, and for the 16 000-byte fixture are the most a save writes.
    @Test(arguments: ["zip/comment-cp437.zip", "zip/comment-16000.zip"])
    func unchangedCommentKeepsItsBytesAfterADelete(_ fixture: String) async throws {
        let opened = try await open(fixture)
        defer { opened.cleanUp() }
        let original = try #require(opened.reader.comment?.bytes)
        if fixture.hasSuffix("cp437.zip") {
            #expect(original != Array(try #require(opened.reader.comment?.text).utf8))
        } else {
            #expect(original.count == ArchiveComment.maximumWritableLength)
        }

        opened.model.remove(["readme.txt"])
        #expect(opened.model.changes.comment == .keep)
        let saved = try await saveAndReopen(opened)
        #expect(saved.comment?.bytes == original)
        #expect(!saved.entries.contains { $0.path == "readme.txt" })
        #expect(saved.entries.contains { $0.path == "docs/plain.txt" })
    }

    @Test func aSixteenThousandByteCommentRoundTrips() async throws {
        let opened = try await open("zip/comment-utf8.zip")
        defer { opened.cleanUp() }
        // 200 numbered lines of 80 bytes, as in comment-16000.zip but with other text.
        let text = (0..<200).map { "Edited line " + String(format: "%04d", $0) + String(repeating: "-", count: 63) + "\n" }
            .joined()
        #expect(text.utf8.count == ArchiveComment.maximumWritableLength)

        opened.model.setComment(text)
        #expect(opened.model.commentProblem == nil)
        let saved = try await saveAndReopen(opened)
        #expect(saved.comment?.bytes == Array(text.utf8))
        #expect(saved.comment?.text == text)
    }

    /// A split set's comment is read from its last part; the model shows it and doesn't offer to edit it.
    @Test func splitZipCommentReadsFromTheLastPart() async throws {
        let opened = try await open(["multivolume/sz-comment.zip.001", "multivolume/sz-comment.zip.002",
                                     "multivolume/sz-comment.zip.003"])
        defer { opened.cleanUp() }
        #expect(opened.reader.volumeURLs.count == 3)
        #expect(opened.reader.comment?.bytes == Array(Self.splitComment.utf8))
        #expect(opened.model.commentText == Self.splitComment)
        #expect(!opened.model.canEditComment)
        // Read-only: an edit changes nothing.
        opened.model.setComment("x")
        #expect(opened.model.changes.comment == .keep)
        #expect(opened.model.commentText == Self.splitComment)
    }

    /// Comment text holding a ZIP end-record signature is refused by the model (`saveProblem`) before the
    /// engine is asked; the engine, if reached, refuses it with the same words and writes nothing.
    @Test(arguments: ["PK\u{5}\u{6}", "PK\u{6}\u{6}", "PK\u{6}\u{7}"])
    func signatureInTheTextIsRefusedBeforeTheEngine(_ signature: String) async throws {
        let opened = try await open("zip/comment-utf8.zip")
        defer { opened.cleanUp() }
        let text = "before " + signature + " after"
        opened.model.setComment(text)
        #expect(opened.model.changes.comment == .set(text))
        #expect(opened.model.saveProblem(as: .zip, split: false) == ArchiveCommentText.endRecordSignatureMessage)

        let savedURL = opened.directory.appendingPathComponent("saved.zip")
        await #expect(throws: ArchiveError.io(ArchiveCommentText.endRecordSignatureMessage)) {
            try await ArchiveWriter.write(source: opened.reader, changes: opened.model.saveChanges(as: .zip),
                                          format: .zip, to: savedURL, options: opened.model.saveOptions)
        }
        #expect(!FileManager.default.fileExists(atPath: savedURL.path))
    }
}
