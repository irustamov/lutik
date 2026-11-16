import Foundation
import Testing
@testable import Kernir

@MainActor
private final class RecordingRevealer: FinderRevealing {
    var selected: [[URL]] = []
    var opened: [URL] = []
    func select(_ urls: [URL]) { selected.append(urls) }
    func open(_ folder: URL) { opened.append(folder) }
}

@MainActor
@Suite struct ExtractionRevealTests {
    private let downloads = URL(fileURLWithPath: "/Users/someone/Downloads", isDirectory: true)

    @Test func oneFolderIsSelectedInsideTheDestination() {
        let folder = downloads.appendingPathComponent("project", isDirectory: true)
        let placed = [folder, folder.appendingPathComponent("a.txt"), folder.appendingPathComponent("src/b.txt")]
        let revealer = RecordingRevealer()
        ExtractionReveal.reveal(placed: placed, in: downloads, using: revealer)
        #expect(revealer.selected == [[folder]])
        #expect(revealer.opened.isEmpty)
    }

    @Test func severalItemsAreAllSelected() {
        let a = downloads.appendingPathComponent("a.txt"), b = downloads.appendingPathComponent("docs", isDirectory: true)
        let revealer = RecordingRevealer()
        ExtractionReveal.reveal(placed: [a, b, b.appendingPathComponent("c.txt"), a], in: downloads, using: revealer)
        #expect(revealer.selected == [[a, b]])
        #expect(revealer.opened.isEmpty)
    }

    @Test func nothingPlacedOpensTheDestination() {
        let revealer = RecordingRevealer()
        ExtractionReveal.reveal(placed: [], in: downloads, using: revealer)
        #expect(revealer.opened == [downloads])
        #expect(revealer.selected.isEmpty)
    }

    @Test func aFileFromInsideAFolderSelectsTheFolderItLandedIn() {
        let deep = downloads.appendingPathComponent("docs/sub/c.txt")
        #expect(ExtractionReveal.topLevelItems(placed: [deep], in: downloads)
                == [downloads.appendingPathComponent("docs", isDirectory: true)])
    }

    @Test func itemsOutsideTheDestinationAreIgnored() {
        let elsewhere = URL(fileURLWithPath: "/Users/someone/Desktop/x.txt")
        let sibling = URL(fileURLWithPath: "/Users/someone/Downloads2/y.txt")
        #expect(ExtractionReveal.topLevelItems(placed: [elsewhere, sibling], in: downloads).isEmpty)
    }

    @Test func aDotSegmentInAPlacedURLStillMatches() {
        let a = URL(fileURLWithPath: "/Users/someone/Downloads/./a.txt")
        #expect(ExtractionReveal.topLevelItems(placed: [a], in: downloads).map(\.standardizedFileURL.path)
                == ["/Users/someone/Downloads/a.txt"])
    }
}
