import Testing
import Foundation
@testable import Kernir

/// What Copy or Cut puts on the pasteboard besides files (`ArchiveClipboard`, pasteboard-free) and
/// what a paste does with it (`ArchivePaste.plan`, `ArchivePaste.destination`). Pure: no model, no pasteboard.
@Suite struct ArchivePasteTests {
    private static let here = UUID()
    private static let elsewhere = UUID()
    private static let existing: Set<String> = ["docs", "docs/a.txt", "docs/sub", "docs/sub/d.txt", "other",
                                                "other/b.txt", "README"]

    private static func exists(_ path: String) -> Bool {
        existing.contains(path.precomposedStringWithCanonicalMapping)
    }

    private func plan(_ clipboard: ArchiveClipboard?, hasFiles: Bool = false, here: UUID = Self.here,
                      into folder: String, exists: (String) -> Bool = Self.exists) -> PastePlan? {
        ArchivePaste.plan(clipboard, hasFiles: hasFiles, here: here, into: folder, exists: exists)
    }

    private func cut(_ paths: [String], from source: UUID = Self.here) -> ArchiveClipboard {
        ArchiveClipboard(source: source, operation: .cut, paths: paths)
    }

    private func copy(_ paths: [String], from source: UUID = Self.here) -> ArchiveClipboard {
        ArchiveClipboard(source: source, operation: .copy, paths: paths)
    }

    // MARK: - Codec

    @Test func codecRoundTrip() {
        for clipboard in [cut(["docs/a.txt", "other"]), copy(["e\u{301}t\u{e9}/x", "README"], from: Self.elsewhere)] {
            #expect(ArchiveClipboard.decoded(clipboard.encoded()) == clipboard)
        }
        #expect(ArchiveClipboard.typeIdentifier == "com.kernir.app.archive-items")
    }

    @Test func garbageDecodesNil() throws {
        #expect(ArchiveClipboard.decoded(Data()) == nil)
        #expect(ArchiveClipboard.decoded(Data("not a plist".utf8)) == nil)
        // A plist of another shape, and one of another version.
        let other = try PropertyListSerialization.data(fromPropertyList: ["paths": ["a"]], format: .binary, options: 0)
        #expect(ArchiveClipboard.decoded(other) == nil)
        let encoded = cut(["docs"]).encoded()
        var plist = try #require(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        plist["version"] = 99
        let future = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        #expect(ArchiveClipboard.decoded(future) == nil)
    }

    @Test func onlyThePayloadIsCodable() {
        // Decoding goes through `decoded(_:)` only: its version check and the ancestor-wins trim.
        #expect(!((cut(["docs"]) as Any) is any Decodable))
        #expect(!((cut(["docs"]) as Any) is any Encodable))
    }

    @Test func ancestorWinsInInit() {
        #expect(cut(["docs/a.txt", "other", "docs", "docs/sub/d.txt", "other"]).paths == ["other", "docs"])
    }

    // MARK: - Files only

    @Test func filesOnlyAdd() {
        #expect(plan(nil, hasFiles: true, into: "docs") == .add(into: "docs"))
        #expect(plan(nil, hasFiles: true, into: "") == .add(into: ""))
    }

    @Test func nothingIsNil() {
        #expect(plan(nil, into: "docs") == nil)
    }

    // MARK: - Cut

    @Test func cutHereMoves() {
        #expect(plan(cut(["docs/a.txt", "other/b.txt"]), into: "") == .move(["docs/a.txt", "other/b.txt"], into: ""))
        #expect(plan(cut(["other"]), into: "docs/sub") == .move(["other"], into: "docs/sub"))
    }

    @Test func cutHereSomeGoneMovesRest() {
        #expect(plan(cut(["docs/gone.txt", "other/b.txt"]), into: "docs") == .move(["other/b.txt"], into: "docs"))
    }

    @Test func cutAllGone() {
        #expect(plan(cut(["docs/gone.txt", "nowhere"]), into: "docs") == .refuse(.gone))
        // Files on the pasteboard don't turn a gone cut into an add.
        #expect(plan(cut(["nowhere"]), hasFiles: true, into: "") == .refuse(.gone))
    }

    @Test func cutIntoItself() {
        #expect(plan(cut(["docs"]), into: "docs") == .refuse(.move(.intoItself)))
        #expect(plan(cut(["docs", "other"]), into: "docs/sub") == .refuse(.move(.intoItself)))
    }

    @Test func cutAlreadyThereIsNoop() {
        #expect(plan(cut(["docs/a.txt", "docs/sub"]), into: "docs") == .move([], into: "docs"))
        #expect(plan(cut(["docs/a.txt", "other/b.txt"]), into: "docs") == .move(["other/b.txt"], into: "docs"))
    }

    @Test func cutElsewhereRefused() {
        #expect(plan(cut(["docs/a.txt"], from: Self.elsewhere), into: "") == .refuse(.cutElsewhere))
        #expect(plan(cut(["docs/a.txt"], from: Self.elsewhere), hasFiles: true, into: "") == .refuse(.cutElsewhere))
    }

    @Test func cutUnknownSourceRefused() {
        // A cut from a previous run: its source names no open document.
        #expect(plan(cut(["docs/a.txt"], from: UUID()), into: "other") == .refuse(.cutElsewhere))
    }

    // MARK: - Copy

    @Test func copyHereOtherFolderAdds() {
        #expect(plan(copy(["docs/a.txt"]), hasFiles: true, into: "other") == .add(into: "other"))
        #expect(plan(copy(["docs/sub"]), hasFiles: true, into: "") == .add(into: ""))
    }

    @Test func copyHereSameFolderRefused() {
        #expect(plan(copy(["docs/a.txt"]), hasFiles: true, into: "docs") == .refuse(.sameFolder(["docs/a.txt"])))
        #expect(plan(copy(["docs/a.txt", "docs/sub", "other/b.txt"]), hasFiles: true, into: "docs")
                == .refuse(.sameFolder(["docs/a.txt", "docs/sub"])))
        // A copied item since gone from the folder is no longer in the way.
        #expect(plan(copy(["docs/gone.txt"]), hasFiles: true, into: "docs") == .add(into: "docs"))
    }

    @Test func copyHereIntoOwnSubfolderAdds() {
        #expect(plan(copy(["docs"]), hasFiles: true, into: "docs/sub") == .add(into: "docs/sub"))
        #expect(plan(copy(["docs"]), hasFiles: true, into: "docs") == .add(into: "docs"))
    }

    @Test func copyElsewhereAdds() {
        // Another archive: its own folder of the same name is no reason to refuse (Add asks Replace / Stop).
        #expect(plan(copy(["docs/a.txt"], from: Self.elsewhere), hasFiles: true, into: "docs") == .add(into: "docs"))
        #expect(plan(copy(["docs/a.txt"], from: UUID()), hasFiles: true, into: "") == .add(into: ""))
    }

    @Test func copyWithoutFilesIsNil() {
        #expect(plan(copy(["docs/a.txt"]), into: "other") == nil)
        #expect(plan(copy(["docs/a.txt"], from: Self.elsewhere), into: "other") == nil)
    }

    // MARK: - Destination

    private func destination(_ selectedFolder: String, _ clipboard: ArchiveClipboard?,
                             here: UUID = Self.here) -> String {
        ArchivePaste.destination(selectedFolder: selectedFolder, clipboard: clipboard, here: here)
    }

    @Test func destinationParentWhenSelectedIsCopied() {
        #expect(destination("docs/sub", copy(["docs/sub"])) == "docs")
        #expect(destination("docs", cut(["docs", "other"])) == "")
        #expect(destination("docs", copy(["other"])) == "docs")
        #expect(destination("docs", nil) == "docs")
        #expect(destination("", copy(["docs"])) == "")
    }

    @Test func destinationKeepsFolderOfSameNameInAnotherArchive() {
        // "docs" copied in archive A; B's own "docs" selected in B: into it, not B's root.
        #expect(destination("docs", copy(["docs"], from: Self.elsewhere)) == "docs")
        #expect(destination("docs/sub", copy(["docs/sub"], from: UUID())) == "docs/sub")
        #expect(destination("docs", cut(["docs"], from: Self.elsewhere)) == "docs")
        #expect(plan(copy(["docs"], from: Self.elsewhere), hasFiles: true,
                     into: destination("docs", copy(["docs"], from: Self.elsewhere))) == .add(into: "docs"))
    }

    @Test func copySelectedFolderHereIsSameFolder() {
        // Copy the selected folder and paste with it still selected: the target goes up to the folder it came
        // from, so the paste is always refused as same-folder (no "x copy" in 0.1.0), never added into itself.
        for (folder, parent) in [("docs", ""), ("docs/sub", "docs")] {
            let clipboard = copy([folder])
            let target = destination(folder, clipboard)
            #expect(target == parent)
            #expect(plan(clipboard, hasFiles: true, into: target) == .refuse(.sameFolder([folder])))
        }
    }

    @Test func nfcPaths() {
        let nfd = "caf\u{65}\u{301}", nfc = "caf\u{e9}"
        let existing: (String) -> Bool = { $0.precomposedStringWithCanonicalMapping == "\(nfc)/x" }
        #expect(plan(cut(["\(nfd)/x"]), into: nfc, exists: existing) == .move([], into: nfc))
        #expect(plan(copy(["\(nfd)/x"]), hasFiles: true, into: nfc, exists: existing)
                == .refuse(.sameFolder(["\(nfd)/x"])))
        #expect(destination(nfc, copy([nfd])) == "")
        // The slash is a scalar: "d/\u{301}x" is beneath "d".
        #expect(plan(cut(["d"]), into: "d/\u{301}x", exists: { _ in true }) == .refuse(.move(.intoItself)))
    }

    // MARK: - Messages

    @Test func messages() {
        #expect(ArchivePaste.message(for: .sameFolder(["docs/a.txt"])) == "“a.txt” is already in this folder.")
        #expect(ArchivePaste.message(for: .sameFolder(["docs/a.txt", "docs/sub"]))
                == "2 of the copied items are already in this folder.")
        #expect(ArchivePaste.message(for: .move(.intoItself)) == MovePlanning.message(for: .intoItself))
        #expect(!ArchivePaste.message(for: .cutElsewhere).isEmpty)
        #expect(!ArchivePaste.message(for: .gone).isEmpty)
    }
}
