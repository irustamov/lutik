import Testing
import Foundation
@testable import Kernir
import KernirCore

/// Rename and New Folder through a real save, per format, with the engine itself (KernirCore's
/// `Archive.open` and `ArchiveWriter.write`) and its fixtures, no UI. `LiveRenameSaveTests` covers a
/// hand-built Finder ZIP with "Exclude Mac metadata" on and off; this adds the same ZIP flow on a fixture and
/// 7z, TAR and TAR.GZ, and a CP866 ZIP. Skipped where the repository's `Fixtures` folder can't be read (a
/// sandboxed hosted run); the shared harness points `KERNIR_FIXTURES` at it.
@MainActor @Suite(.enabled(if: Fixture.isReadable))
struct ArchiveModelRenameLiveTests {
    /// One tree in four containers (Fixtures/manifest.json): folders `docs`, `docs/nested`, `docs/nested/deep`,
    /// `empty-dir`; files `docs/nested/deep/data.bin` (70000), `docs/notes.txt` (20000), `docs/readme.md` (52),
    /// `empty.txt` (0), `hello.txt` (15).
    private static let sourceSizes: [String: Int64] = [
        "docs/nested/deep/data.bin": 70000, "docs/notes.txt": 20000, "docs/readme.md": 52,
        "empty.txt": 0, "hello.txt": 15,
    ]
    private static let sourceFolders: Set<String> = ["docs", "docs/nested", "docs/nested/deep", "empty-dir"]

    /// What the save holds after: `hello.txt` to `greeting.txt`, `docs` to `papers`, a New Folder in the top
    /// level renamed `scratch`, a New Folder in `docs` renamed `fresh` (renamed along with `docs`).
    private static let savedSizes: [String: Int64] = [
        "papers/nested/deep/data.bin": 70000, "papers/notes.txt": 20000, "papers/readme.md": 52,
        "empty.txt": 0, "greeting.txt": 15,
    ]
    private static let savedFolders: Set<String> = [
        "papers", "papers/nested", "papers/nested/deep", "papers/fresh", "empty-dir", "scratch",
    ]

    /// `file` copied into a fresh folder of its own, which the caller removes.
    private func copy(_ file: String) throws -> URL {
        try Fixture.copy(file)
    }

    private func cleanUp(_ url: URL, _ model: ArchiveModel? = nil) {
        model?.removeTemporaryFiles()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func listing(_ reader: any ArchiveReading) -> (sizes: [String: Int64], folders: Set<String>) {
        var sizes: [String: Int64] = [:]
        var folders: Set<String> = []
        for entry in reader.entries {
            if entry.isDirectory { folders.insert(entry.path) } else { sizes[entry.path] = entry.size ?? -1 }
        }
        return (sizes, folders)
    }

    private func saveAndReopen(_ reader: any ArchiveReading, _ model: ArchiveModel, as format: ArchiveFormat,
                               in directory: URL, named name: String) async throws -> any ArchiveReading {
        #expect(model.saveProblem(as: format, split: false) == nil)
        let savedURL = directory.appendingPathComponent(name)
        try await ArchiveWriter.write(source: reader, changes: model.saveChanges(as: format), format: format,
                                      to: savedURL, options: model.saveOptions)
        return try await Archive.open(at: savedURL)
    }

    private func contents(of reader: any ArchiveReading, _ path: String, in directory: URL) async throws -> Data? {
        let out = directory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try await reader.extract(nil, to: out, progress: nil)
        return try? Data(contentsOf: out.appendingPathComponent(path))
    }

    @Test(arguments: [
        ("zip/deflate.zip", ArchiveFormat.zip),
        ("7z/lzma2.7z", ArchiveFormat.sevenZip),
        ("tar/basic.tar", ArchiveFormat.tar),
        ("tar/basic.tar.gz", ArchiveFormat.tarGzip),
    ])
    func renameAndNewFolderSurviveARealSave(file: String, format: ArchiveFormat) async throws {
        let url = try copy(file)
        defer { cleanUp(url) }
        let directory = url.deletingLastPathComponent()
        let reader = try await Archive.open(at: url)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        defer { model.removeTemporaryFiles() }
        #expect(reader.format == format)
        let source = Self.listing(reader)
        #expect(source.sizes == Self.sourceSizes)
        #expect(source.folders == Self.sourceFolders)
        let originalHello = try await contents(of: reader, "hello.txt", in: directory)
        #expect(originalHello?.count == 15)

        let nestedNew = try model.newFolder(in: "docs")
        #expect(nestedNew == "docs/untitled folder")
        #expect(model.rename(nestedNew, to: "fresh") == .success("docs/fresh"))
        #expect(model.rename("hello.txt", to: "greeting.txt") == .success("greeting.txt"))
        #expect(model.rename("docs", to: "papers") == .success("papers"))
        let topNew = try model.newFolder(in: "")
        #expect(topNew == "untitled folder")
        #expect(model.rename(topNew, to: "scratch") == .success("scratch"))

        let saved = try await saveAndReopen(reader, model, as: format, in: directory, named: "saved-\(file.split(separator: "/").last!)")
        #expect(saved.format == format)
        let result = Self.listing(saved)
        #expect(result.sizes == Self.savedSizes)
        #expect(result.folders == Self.savedFolders)
        // The bytes follow the name.
        #expect(try await contents(of: saved, "greeting.txt", in: directory) == originalHello)

        // The model takes the saved archive as its source: nothing pending, the new names are plain items.
        model.didSave(reader: saved)
        #expect(model.changes.isEmpty)
        #expect(model.item(at: "greeting.txt")?.isPendingAddition == false)
        #expect(model.item(at: "scratch")?.isDirectory == true)
        #expect(model.item(at: "papers/fresh")?.isDirectory == true)
        #expect(model.item(at: "hello.txt") == nil)
        #expect(model.item(at: "docs") == nil)
    }

    /// DOS Russian; KernirCore keeps its own constant internal.
    private static let cp866 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosRussian.rawValue)))

    /// `zip/cp866.zip` stores its names as CP866 bytes (no UTF-8 flag); the engine reads them as Cyrillic.
    @Test func renamingInACP866ZipKeepsEveryNameReadable() async throws {
        let url = try copy("zip/cp866.zip")
        defer { cleanUp(url) }
        let directory = url.deletingLastPathComponent()
        let reader = try await Archive.open(at: url)
        let model = ArchiveModel(reader: reader, undoManager: nil)
        defer { model.removeTemporaryFiles() }
        let source = Self.listing(reader)
        #expect(source.folders == ["Документы"])
        #expect(source.sizes == ["Документы/отчёт.txt": 7, "Привет.txt": 11])

        #expect(model.rename("Привет.txt", to: "Здравствуй.txt") == .success("Здравствуй.txt"))
        let saved = try await saveAndReopen(reader, model, as: .zip, in: directory, named: "saved.zip")
        let result = Self.listing(saved)
        #expect(result.folders == ["Документы"])
        #expect(result.sizes == ["Документы/отчёт.txt": 7, "Здравствуй.txt": 11])
        #expect(saved.entries.count == 3)
        // The saved zip is mixed: untouched names are CP866 bytes, the renamed one is UTF-8 with the zip's UTF-8
        // flag. Automatic detection settles on CP866 for the undeclared names ...
        #expect(saved.legacyNameEncoding == Self.cp866)
        // ... and a flagged name is not a guess: forcing another legacy encoding (CP1251) misreads the untouched
        // names but leaves the flagged "Здравствуй.txt" intact.
        let savedURL = directory.appendingPathComponent("saved.zip")
        let forced = try await Archive.open(at: savedURL, nameEncoding: .specific(.windowsCP1251))
        #expect(forced.legacyNameEncoding == .windowsCP1251)
        let forcedListing = Self.listing(forced)
        #expect(forcedListing.sizes["Здравствуй.txt"] == 11)
        #expect(forcedListing.folders != ["Документы"])
        #expect(forcedListing.sizes["Привет.txt"] == nil)
        #expect(forced.entries.count == 3)

        // The names are readable through the model that adopts the save, too.
        model.didSave(reader: saved)
        #expect(model.item(at: "Здравствуй.txt")?.size == 11)
        #expect(model.item(at: "Документы/отчёт.txt")?.size == 7)
        #expect(model.item(at: "Привет.txt") == nil)
    }
}
