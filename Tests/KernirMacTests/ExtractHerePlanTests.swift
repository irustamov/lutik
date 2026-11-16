import Testing
import Foundation
@testable import Kernir
import KernirCore

// MARK: - Helpers

private let file = ExtractHereListings.file
private let folder = ExtractHereListings.folder

private let downloads = URL(fileURLWithPath: "/Users/someone/Downloads", isDirectory: true)

@MainActor
private func makeModel(_ entries: [ArchiveEntry], archive name: String = "project.zip",
                       volumes: [String]? = nil) -> ArchiveModel {
    let url = downloads.appendingPathComponent(name)
    let reader = FakeReader(entries: entries, url: url,
                            volumeURLs: volumes.map { $0.map { downloads.appendingPathComponent($0) } })
    return ArchiveModel(reader: reader, undoManager: nil)
}

@MainActor
private func plan(_ paths: [String]?, _ model: ArchiveModel, archive name: String = "project.zip") -> ExtractHerePlan? {
    ExtractHerePlan.make(paths, in: model, archiveURL: downloads.appendingPathComponent(name))
}

// MARK: - Whole archive

@MainActor @Test func oneFileStaysAsItIs() {
    let model = makeModel([file("report.pdf")])
    #expect(plan(nil, model) == .single(path: "report.pdf", name: "report.pdf", isDirectory: false))
}

@MainActor @Test func oneFolderStaysAsItIs() {
    let model = makeModel([folder("Project"), file("Project/a.txt"), file("Project/b/c.txt")])
    #expect(plan(nil, model) == .single(path: "Project", name: "Project", isDirectory: true))
}

@MainActor @Test func manyItemsGoInAFolderNamedAfterTheArchive() {
    let model = makeModel(ExtractHereListings.project, archive: "project.tar.gz")
    #expect(plan(nil, model, archive: "project.tar.gz")
                == .wrapped(folderName: "project", paths: ["assets", "src", "brief.pdf", "cover.png",
                                                           "LICENSE", "README.md"]))
}

@MainActor @Test func finderMetadataDoesNotCount() {
    let model = makeModel(ExtractHereListings.macOSFinder, archive: "macos-finder.zip")
    #expect(plan(nil, model, archive: "macos-finder.zip") == .single(path: "Project", name: "Project", isDirectory: true))
}

@MainActor @Test func aSingleStreamGivesItsFile() {
    let model = makeModel(ExtractHereListings.singleStream, archive: "hello.txt.gz")
    #expect(plan(nil, model, archive: "hello.txt.gz") == .single(path: "hello.txt", name: "hello.txt", isDirectory: false))
}

@MainActor @Test func aVolumeSetsFolderIsTheSetsName() {
    let model = makeModel([file("a.jpg"), file("b.jpg")], archive: "Photos.part1.rar",
                          volumes: ["Photos.part1.rar", "Photos.part2.rar"])
    #expect(plan(nil, model, archive: "Photos.part1.rar") == .wrapped(folderName: "Photos", paths: ["a.jpg", "b.jpg"]))
}

@MainActor @Test func pendingAdditionsCountAsTheUserSeesThem() throws {
    let model = makeModel([file("report.pdf")])
    let added = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).txt")
    try Data("new".utf8).write(to: added)
    defer { try? FileManager.default.removeItem(at: added) }
    model.add([added], to: "")
    #expect(plan(nil, model) == .wrapped(folderName: "project", paths: [added.lastPathComponent, "report.pdf"]))
}

@MainActor @Test func nothingToExtractHasNoPlan() {
    #expect(plan(nil, makeModel([])) == nil)
    // Metadata alone is nothing the user sees.
    #expect(plan(nil, makeModel([folder("__MACOSX"), file("__MACOSX/._x")])) == nil)
}

// MARK: - Selection

@MainActor @Test func twoSelectedSiblingsAreWrapped() {
    let model = makeModel(ExtractHereListings.project)
    #expect(plan(["README.md", "src"], model) == .wrapped(folderName: "project", paths: ["README.md", "src"]))
}

@MainActor @Test func aFolderAndItsChildAreTheFolder() {
    let model = makeModel(ExtractHereListings.project)
    #expect(plan(["src", "src/main.swift"], model) == .single(path: "src", name: "src", isDirectory: true))
    #expect(plan(["src/main.swift", "src"], model) == .single(path: "src", name: "src", isDirectory: true))
}

@MainActor @Test func oneNestedItemIsPlacedAsItIs() {
    let model = makeModel([folder("a"), folder("a/b"), file("a/b/report.pdf"), file("a/other.txt")])
    #expect(plan(["a/b/report.pdf"], model) == .single(path: "a/b/report.pdf", name: "report.pdf", isDirectory: false))
}

@MainActor @Test func nestedItemsFromDifferentFoldersAreWrapped() {
    let model = makeModel(ExtractHereListings.project)
    #expect(plan(["assets/logo.svg", "src/main.swift"], model)
                == .wrapped(folderName: "project", paths: ["assets/logo.svg", "src/main.swift"]))
}

@MainActor @Test func repeatedAndUnknownPathsAreIgnored() {
    let model = makeModel(ExtractHereListings.macOSFinder, archive: "macos-finder.zip")
    #expect(plan(["Project", "Project", "__MACOSX/Project/._docs", "missing"], model, archive: "macos-finder.zip")
                == .single(path: "Project", name: "Project", isDirectory: true))
    #expect(plan([], model, archive: "macos-finder.zip") == nil)
}

// MARK: - Pure planner

@Test func plannerKeepsTheRequestOrderOfTopmostItems() {
    let items: [ExtractHerePlan.Item] = [.init(path: "b", isDirectory: true), .init(path: "b/x", isDirectory: false),
                                         .init(path: "a.txt", isDirectory: false)]
    #expect(ExtractHerePlan.make(items, archiveURL: downloads.appendingPathComponent("set.zip"), isVolumeSet: false)
                == .wrapped(folderName: "set", paths: ["b", "a.txt"]))
    #expect(ExtractHerePlan.make([], archiveURL: downloads.appendingPathComponent("set.zip"), isVolumeSet: false) == nil)
}

// MARK: - A "/" hidden in a Character

// A "/" followed by a combining mark (U+0301) or a ZWJ, or preceded by a Prepend scalar (U+0600), is part of one
// Character that is not "/". Archive paths split on the "/" scalar. Names compare by scalars: String's `==` is
// canonical equivalence.

@Test(arguments: [
    ("d/\u{301}x", "\u{301}x"), ("d/\u{200D}x", "\u{200D}x"), ("d\u{600}/x", "x"), ("d/e/\u{301}x", "\u{301}x"),
])
func aNestedItemBehindAHiddenSlashIsPlacedUnderItsOwnName(path: String, name: String) throws {
    let plan = try #require(ExtractHerePlan.make([.init(path: path, isDirectory: false)],
                                                 archiveURL: downloads.appendingPathComponent("set.zip"),
                                                 isVolumeSet: false))
    guard case let .single(planned, placed, isDirectory) = plan else {
        Issue.record("expected a single item, got \(plan)")
        return
    }
    #expect(Array(planned.unicodeScalars) == Array(path.unicodeScalars))
    #expect(Array(placed.unicodeScalars) == Array(name.unicodeScalars))
    #expect(!isDirectory)
}

@Test(arguments: [("d", "d/\u{301}x"), ("d", "d/\u{200D}x"), ("d\u{600}", "d\u{600}/x")])
func aFolderAndAChildBehindAHiddenSlashAreTheFolder(folder: String, child: String) {
    let archive = downloads.appendingPathComponent("set.zip")
    let parent = ExtractHerePlan.Item(path: folder, isDirectory: true)
    let item = ExtractHerePlan.Item(path: child, isDirectory: false)
    let other = ExtractHerePlan.Item(path: "e", isDirectory: false)
    #expect(ExtractHerePlan.make([parent, item], archiveURL: archive, isVolumeSet: false)
                == .single(path: folder, name: folder, isDirectory: true))
    #expect(ExtractHerePlan.make([item, parent], archiveURL: archive, isVolumeSet: false)
                == .single(path: folder, name: folder, isDirectory: true))
    #expect(ExtractHerePlan.make([parent, item, other], archiveURL: archive, isVolumeSet: false)
                == .wrapped(folderName: "set", paths: [folder, "e"]))
}
