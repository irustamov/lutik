import Testing
import Foundation
import UniformTypeIdentifiers
@testable import Kernir
import KernirCore

/// The listings `ExtractHerePlanTests` feeds a `FakeReader`, as the real fixtures have them. The
/// tests below open the fixtures and check that the two still agree.
enum ExtractHereListings {
    /// `zip/macos-finder.zip`: one folder plus Finder's `__MACOSX` metadata.
    static let macOSFinder: [ArchiveEntry] = [
        folder("Project"), folder("Project/docs"), file("Project/docs/readme.md"), folder("__MACOSX"),
        folder("__MACOSX/Project"), folder("__MACOSX/Project/docs"), file("__MACOSX/Project/docs/._readme.md"),
        file("__MACOSX/Project/._docs"), file("Project/hello.txt"), file("__MACOSX/Project/._hello.txt"),
    ]

    /// `showcase/project.zip`: many top-level items.
    static let project: [ArchiveEntry] = [
        file("LICENSE"), file("README.md"), folder("assets"), file("assets/icon.png"), file("assets/logo.svg"),
        file("brief.pdf"), file("cover.png"), folder("src"), file("src/main.swift"), file("src/utils.swift"),
    ]

    /// `single/hello.txt.gz`: a single-stream gzip, one file.
    static let singleStream: [ArchiveEntry] = [file("hello.txt")]

    static func file(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
    }

    static func folder(_ path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
    }
}

/// Paths and kinds, in a stable order: what the plan depends on.
private func shape(_ entries: [ArchiveEntry]) -> [String] {
    entries.map { ($0.isDirectory ? "d " : "f ") + $0.path }.sorted()
}

@Test(.enabled(if: Fixture.isReadable), arguments: [
    ("zip/macos-finder.zip", ExtractHereListings.macOSFinder),
    ("showcase/project.zip", ExtractHereListings.project),
    ("single/hello.txt.gz", ExtractHereListings.singleStream),
])
func fakeListingsMatchTheFixtures(_ fixture: String, _ listing: [ArchiveEntry]) async throws {
    let url = try Fixture.copy(fixture)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let reader = try await Archive.open(at: url)
    #expect(shape(reader.entries) == shape(listing))
}

@MainActor @Test(.enabled(if: Fixture.isReadable), arguments: [
    ("zip/macos-finder.zip", ExtractHerePlan.single(path: "Project", name: "Project", isDirectory: true)),
    ("showcase/project.zip", ExtractHerePlan.wrapped(folderName: "project",
                                                     paths: ["assets", "src", "brief.pdf", "cover.png",
                                                             "LICENSE", "README.md"])),
    ("single/hello.txt.gz", ExtractHerePlan.single(path: "hello.txt", name: "hello.txt", isDirectory: false)),
])
func fixturesPlanAsTheIssueSays(_ fixture: String, _ expected: ExtractHerePlan) async throws {
    let url = try Fixture.copy(fixture)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let model = ArchiveModel(reader: try await Archive.open(at: url), undoManager: nil)
    #expect(ExtractHerePlan.make(nil, in: model, archiveURL: url) == expected)
}

/// Extract Here takes `.whl` and `.jar`. Kernir opens them as the ZIP
/// they are (`KernirDocumentTypes.packageTypes`), and Extract Here then works as for any ZIP:
/// project.zip renamed to each comes out as one folder named after the package.
@MainActor @Test(.enabled(if: Fixture.isReadable), arguments: [
    "tool-1.0-py3-none-any.whl", "app.jar",
])
func zipPackagesExtractHereAsTheZipTheyAre(_ name: String) async throws {
    let url = try Fixture.copy("showcase/project.zip", as: name)
    let folder = url.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: folder) }
    let base = (name as NSString).deletingPathExtension
    let model = ArchiveModel(reader: try await Archive.open(at: url), undoManager: nil)
    let plan = try #require(ExtractHerePlan.make(nil, in: model, archiveURL: url))
    #expect(plan == .wrapped(folderName: base, paths: ["assets", "src", "brief.pdf", "cover.png", "LICENSE", "README.md"]))
    let placed = try await ExtractHereService.extract(plan, from: model, nextTo: url, progress: nil)
    #expect(placed.lastPathComponent == base)
    #expect(FileManager.default.fileExists(atPath: placed.appendingPathComponent("src/main.swift").path))
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(names == [base, name].sorted())
}

/// The types Kernir opens a package as: `.whl` and `.jar` are among them and are ZIP.
@Test func wheelAndJarAreZipPackagesKernirOpens() {
    let identifiers = KernirDocumentTypes.packageTypes.map(\.identifier)
    #expect(identifiers.contains("org.python.wheel"))
    #expect(identifiers.contains("com.sun.java-archive"))
    for type in KernirDocumentTypes.packageTypes where ["org.python.wheel", "com.sun.java-archive"].contains(type.identifier) {
        #expect(type.conforms(to: .zip))
    }
}
