import Testing
import Foundation
@testable import Kernir

struct EntryNameValidationTests {
    private func check(_ proposed: String, current: String? = nil, siblings: [String] = []) -> EntryNameCheck {
        EntryNameValidation.check(proposed, current: current, siblings: siblings)
    }

    @Test func emptyAndWhitespaceOnlyAreRefused() {
        #expect(check("") == .invalid(.empty))
        #expect(check("   ") == .invalid(.empty))
        #expect(check(" \t\n") == .invalid(.empty))
    }

    @Test func slashAndNulAreRefused() {
        #expect(check("a/b") == .invalid(.containsSlash))
        #expect(check("a\u{0}b") == .invalid(.containsSlash))
    }

    /// A combining mark after "/" joins it into one Character; the check must see the scalar.
    @Test func slashFollowedByACombiningMarkIsRefused() {
        #expect(check("a/\u{301}b") == .invalid(.containsSlash))
        #expect(check("/\u{301}") == .invalid(.containsSlash))
    }

    @Test func nulFollowedByACombiningMarkIsRefused() {
        #expect(check("a\u{0}\u{301}b") == .invalid(.containsSlash))
    }

    /// The stored bytes still start with "._", so an extractor would treat the entry as AppleDouble.
    @Test func appleDoublePrefixFollowedByACombiningMarkIsHiddenMetadata() {
        #expect(check("._\u{301}x") == .invalid(.hiddenMetadata))
        #expect(check("._\u{301}") == .invalid(.hiddenMetadata))
    }

    /// "." or ".." plus a combining mark is a different name on disk (no path meaning), so it is allowed.
    @Test func dotFollowedByACombiningMarkIsALegalName() {
        #expect(check(".\u{301}") == .valid(".\u{301}"))
        #expect(check("..\u{301}") == .valid("..\u{301}"))
    }

    @Test func dotAndDotDotAreReserved() {
        #expect(check(".") == .invalid(.reserved))
        #expect(check("..") == .invalid(.reserved))
    }

    @Test func appleDoublePrefixIsHiddenMetadataAtAnyLevel() {
        #expect(check("._x") == .invalid(.hiddenMetadata))
    }

    /// Nested __MACOSX/ folders are stripped and hidden, so the name is refused at any depth,
    /// for a renamed item and for a new folder alike.
    @Test func macosxIsHiddenMetadataAtAnyDepth() {
        #expect(check("__MACOSX") == .invalid(.hiddenMetadata))
        #expect(check("__MACOSX", current: "docs", siblings: ["docs", "notes.txt"]) == .invalid(.hiddenMetadata))
        #expect(check("__MACOSX", current: nil, siblings: ["untitled folder"]) == .invalid(.hiddenMetadata))
    }

    /// The engine drops any entry with a ".DS_Store" path component on save (metadata exclusion, on by default),
    /// so a folder renamed to it would silently vanish. Exact case, as the engine matches it.
    @Test func dsStoreIsHiddenMetadata() {
        #expect(check(".DS_Store") == .invalid(.hiddenMetadata))
        #expect(check(".DS_Store", current: "Photos", siblings: ["Photos"]) == .invalid(.hiddenMetadata))
        #expect(check(".ds_store") == .valid(".ds_store"))
        #expect(check(".DS_Store2") == .valid(".DS_Store2"))
    }

    @Test func nameLongerThan255UTF8BytesIsRefused() {
        let max = String(repeating: "a", count: 255)
        #expect(check(max) == .valid(max))
        #expect(check(String(repeating: "a", count: 256)) == .invalid(.tooLong))
        #expect(check(String(repeating: "é", count: 128)) == .invalid(.tooLong))
    }

    /// The name is stored as typed, so the limit holds for the typed bytes as well as for the NFC form.
    @Test func decomposedNameIsMeasuredAsStored() {
        let atLimit = String(repeating: "e\u{301}", count: 85)    // 255 bytes typed, 170 in NFC
        #expect(check(atLimit) == .valid(atLimit))
        #expect(check(String(repeating: "e\u{301}", count: 86)) == .invalid(.tooLong))  // 258 typed, 172 NFC
    }

    /// U+0958 is a composition exclusion: NFC (U+0915 U+093C) is longer than the typed form.
    @Test func nameLongerInNFCThanTypedIsRefused() {
        #expect(check(String(repeating: "\u{958}", count: 85)) == .invalid(.tooLong))  // 255 typed, 510 NFC
    }

    @Test func exactDuplicateIsTaken() {
        #expect(check("README", siblings: ["README"]) == .invalid(.taken("README")))
    }

    /// Names that differ only in case are allowed.
    @Test func caseOnlyDuplicateIsAllowed() {
        #expect(check("Readme", siblings: ["README"]) == .valid("Readme"))
    }

    @Test func duplicatesCompareAfterNFC() {
        #expect(check("Cafe\u{301}", siblings: ["Caf\u{E9}"]) == .invalid(.taken("Cafe\u{301}")))
    }

    @Test func selfCaseOnlyRenameIsValid() {
        #expect(check("README.md", current: "readme.md", siblings: ["readme.md", "other"]) == .valid("README.md"))
    }

    @Test func sameNameIsUnchanged() {
        #expect(check("readme.md", current: "readme.md", siblings: ["readme.md"]) == .unchanged)
        #expect(check("Cafe\u{301}", current: "Caf\u{E9}", siblings: ["Caf\u{E9}"]) == .unchanged)
    }

    @Test func storedNameIsTheProposedStringAsTyped() {
        #expect(check(" padded ") == .valid(" padded "))
    }

    @Test func leadingDotIsAllowedSilently() {
        #expect(check(".hidden") == .valid(".hidden"))
    }

    @Test func untitledFolderNameCountsUpLikeFinder() {
        #expect(EntryNameValidation.untitledFolderName(siblings: []) == "untitled folder")
        #expect(EntryNameValidation.untitledFolderName(siblings: ["untitled folder", "untitled folder 2"])
            == "untitled folder 3")
        #expect(EntryNameValidation.untitledFolderName(siblings: ["untitled folder 2"]) == "untitled folder")
    }

    /// Case twins are allowed the user types, never one the app picks.
    @Test func untitledFolderNameSkipsCaseTwins() {
        #expect(EntryNameValidation.untitledFolderName(siblings: ["Untitled Folder"]) == "untitled folder 2")
        #expect(EntryNameValidation.untitledFolderName(siblings: ["untitled folder", "UNTITLED FOLDER 2"])
            == "untitled folder 3")
    }

    /// The base name is localized (Finder's "Neuer Ordner"): a capitalized or decomposed translation is
    /// compared by NameFold.key, the fold of the case-twin scan, so the app never picks a twin in any
    /// language: not one with a final sigma, nor "STRASSE" for "straße".
    @Test func untitledFolderNameFoldsALocalizedBase() {
        let base = "Neuer Ordner"
        #expect(EntryNameValidation.untitledFolderName(siblings: [], base: base) == "Neuer Ordner")
        #expect(EntryNameValidation.untitledFolderName(siblings: ["neuer ordner"], base: base) == "Neuer Ordner 2")
        #expect(EntryNameValidation.untitledFolderName(siblings: ["NEUER ORDNER", "neuer ordner 2"], base: base)
            == "Neuer Ordner 3")
        let decomposed = "Nouveau dossier cre\u{301}e\u{301}"
        #expect(EntryNameValidation.untitledFolderName(siblings: ["nouveau dossier créé"], base: decomposed)
            == "Nouveau dossier créé 2")
        #expect(EntryNameValidation.untitledFolderName(siblings: ["νέος φάκελος"], base: "ΝΈΟΣ ΦΆΚΕΛΟΣ")
            == "ΝΈΟΣ ΦΆΚΕΛΟΣ 2")
        #expect(EntryNameValidation.untitledFolderName(siblings: ["STRASSE"], base: "straße") == "straße 2")
        #expect(EntryNameValidation.untitledFolderName(siblings: ["straße", "STRASSE 2"], base: "straße")
            == "straße 3")
    }

    @Test func editableLengthStopsBeforeTheLastExtensionOfAFile() {
        #expect(EntryNameValidation.editableLength(of: "photo.jpeg", isDirectory: false) == 5)
        #expect(EntryNameValidation.editableLength(of: "archive.tar.gz", isDirectory: false) == 11)
        #expect(EntryNameValidation.editableLength(of: ".bashrc", isDirectory: false) == 7)
        #expect(EntryNameValidation.editableLength(of: "notes", isDirectory: false) == 5)
        #expect(EntryNameValidation.editableLength(of: "my.folder", isDirectory: true) == 9)
    }

    @Test func editableLengthCountsUTF16() {
        #expect(EntryNameValidation.editableLength(of: "😀.txt", isDirectory: false) == 2)
    }

    @Test func takenMessageUsesFinderWording() {
        #expect(EntryNameValidation.message(for: .taken("X"))
            == String(localized: "The name “X” is already taken. Please choose a different name.", table: "Shared"))
        #expect(EntryNameValidation.message(for: .containsSlash)
            == String(localized: "Names can't contain “/”.", table: "Shared"))
    }

    /// Rename refused because items were moved out of a deleted folder of that name: Move's save-first message.
    @Test func holdsMovedOutItemsMessageIsMoves() {
        #expect(EntryNameValidation.message(for: .holdsMovedOutItems("d"))
            == MovePlanning.message(for: .holdsMovedOutItems("d")))
    }
}
