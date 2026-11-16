import Testing
import Foundation
@testable import Kernir
import KernirCore

struct CompressPlanTests {
    private let folder = URL(fileURLWithPath: "/Users/u/Desktop", isDirectory: true)

    private func plan(_ names: [String], format: ArchiveFormat = .zip,
                      existing: Set<String> = []) -> CompressPlan.Destination? {
        CompressPlan.destination(for: names.map { folder.appendingPathComponent($0) }, format: format,
                                 existingNames: existing)
    }

    @Test func oneFileKeepsItsExtension() {
        #expect(plan(["report.pdf"]) == .init(directory: folder, name: "report.pdf.zip"))
    }

    @Test func oneFolderGetsTheArchiveExtension() {
        let photos = folder.appendingPathComponent("Photos", isDirectory: true)
        let destination = CompressPlan.destination(for: [photos], format: .zip, existingNames: [])
        #expect(destination == .init(directory: folder, name: "Photos.zip"))
    }

    @Test func severalItemsMakeArchive() {
        #expect(plan(["a.txt", "Photos"])?.name == "Archive.zip")
    }

    @Test func takenNamesGetANumberBeforeTheExtension() {
        #expect(plan(["a", "b"], existing: ["Archive.zip"])?.name == "Archive 2.zip")
        #expect(plan(["a", "b"], existing: ["Archive.zip", "Archive 2.zip"])?.name == "Archive 3.zip")
        #expect(plan(["report.pdf"], existing: ["report.pdf.zip"])?.name == "report.pdf 2.zip")
    }

    /// The default volumes compare names ignoring case and Unicode normalization.
    @Test func takenNamesCompareLikeTheVolume() {
        #expect(plan(["a", "b"], existing: ["archive.ZIP"])?.name == "Archive 2.zip")
        let nfd = "Cafe\u{301}.zip"
        #expect(plan(["Café"], existing: [nfd])?.name == "Café 2.zip")
    }

    @Test func extensionComesFromTheFormat() {
        #expect(plan(["Photos"], format: .sevenZip)?.name == "Photos.7z")
        #expect(plan(["a", "b"], format: .tarGzip)?.name == "Archive.tar.gz")
        #expect(plan(["a", "b"], format: .tarGzip, existing: ["Archive.tar.gz"])?.name == "Archive 2.tar.gz")
    }

    @Test func destinationIsTheCommonParent() {
        #expect(plan(["a", "b"])?.directory == folder)
    }

    /// Non-Finder callers can send items from different folders; the first item's folder wins.
    @Test func differentParentsUseTheFirstItemsParent() {
        let other = URL(fileURLWithPath: "/Users/u/Documents", isDirectory: true)
        let items = [other.appendingPathComponent("a.txt"), folder.appendingPathComponent("b.txt")]
        let destination = CompressPlan.destination(for: items, format: .zip, existingNames: [])
        #expect(destination == .init(directory: other, name: "Archive.zip"))
    }

    /// An item inside another selected item (Finder's list view can select both): the archive goes
    /// beside the outermost one, never inside an item it archives, whatever the order.
    @Test func nestedItemsGoBesideTheOutermostItem() {
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        let file = sub.appendingPathComponent("deep/a.txt")
        for items in [[file, sub], [sub, file], [sub.appendingPathComponent("a.txt"), sub]] {
            let destination = CompressPlan.destination(for: items, format: .zip, existingNames: [])
            #expect(destination?.directory.standardizedFileURL.path == folder.path)
            #expect(destination?.name == "Archive.zip")
        }
        // A sibling whose name only starts like an item's is not inside it.
        let items = [folder.appendingPathComponent("sub2/a.txt"), sub]
        let destination = CompressPlan.destination(for: items, format: .zip, existingNames: [])
        #expect(destination?.directory.standardizedFileURL.path == folder.appendingPathComponent("sub2").path)
    }

    /// A name longer than a volume takes (255 UTF-8 bytes) loses whole characters from its end,
    /// before the number and the extension, and no dot or space is left dangling there.
    @Test func aLongNameIsTrimmedToFit() throws {
        let cyrillic = String(repeating: "я", count: 125) + ".txt"   // 254 bytes
        let name = try #require(plan([cyrillic])?.name)
        #expect(name == String(repeating: "я", count: 125) + ".zip")   // "…я." would end "..zip"
        let numbered = try #require(plan([cyrillic], existing: [name])?.name)
        #expect(numbered == String(repeating: "я", count: 124) + " 2.zip")
        #expect(numbered.utf8.count <= 255)

        let family = "👨‍👩‍👧‍👦"   // one grapheme, 25 bytes
        let emoji = try #require(plan([String(repeating: family, count: 20)])?.name)
        #expect(emoji == String(repeating: family, count: 10) + ".zip")   // 250 + 4 bytes
        let emoji2 = try #require(plan([String(repeating: family, count: 20)], existing: [emoji])?.name)
        #expect(emoji2 == String(repeating: family, count: 9) + " 2.zip")

        // The whole extension counts: 251 + ".tar.gz" would be 258 bytes.
        let latin = String(repeating: "a", count: 251)
        #expect(plan([latin], format: .tarGzip)?.name == String(repeating: "a", count: 248) + ".tar.gz")
    }

    /// A first character that alone is over the budget ("a" with 126 accents is one 252-byte
    /// grapheme in NFC) leaves nothing to keep: the name falls back to "Archive", never ".zip".
    @Test func aSingleOversizedCharacterFallsBackToArchive() throws {
        let huge = "a" + String(repeating: "\u{301}", count: 126)
        #expect(huge.count == 1)
        #expect(huge.precomposedStringWithCanonicalMapping.utf8.count == 252)
        #expect(plan([huge])?.name == "Archive.zip")
        #expect(plan([huge], existing: ["Archive.zip"])?.name == "Archive 2.zip")
    }

    /// Exactly 255 bytes fits.
    @Test func aNameThatFitsIsNotTrimmed() {
        let name = String(repeating: "a", count: 251)
        #expect(plan([name])?.name == name + ".zip")
    }

    @Test func decomposedNamesComeOutComposed() throws {
        let name = try #require(plan(["Cafe\u{301}.txt"])?.name)
        #expect(name == "Caf\u{E9}.txt.zip")
        #expect(name.unicodeScalars.elementsEqual("Caf\u{E9}.txt.zip".unicodeScalars))
    }

    @Test func dotfileKeepsItsWholeName() {
        #expect(plan([".env"])?.name == ".env.zip")
    }

    @Test func nothingToCompressHasNoPlan() {
        #expect(plan([]) == nil)
    }
}
