import Foundation
import Testing
@testable import Kernir

struct CaseTwinScanTests {
    private typealias Entry = CaseTwinScan.Entry
    private typealias Twin = CaseTwinScan.Twin

    private static func file(_ path: String) -> Entry { Entry(path: path, isDirectory: false) }
    private static func folder(_ path: String) -> Entry { Entry(path: path, isDirectory: true) }

    // MARK: - laterTwins

    @Test func fileTwinsReportTheLaterOne() {
        let twins = CaseTwinScan.laterTwins(in: [Self.file("a.txt"), Self.file("A.txt")], requested: nil)
        #expect(twins == [Twin(path: "A.txt", earlierPath: "a.txt", mixesFileAndFolder: false)])
    }

    @Test func writeOrderDecidesWhichIsLater() {
        let twins = CaseTwinScan.laterTwins(in: [Self.file("A.txt"), Self.file("a.txt")], requested: nil)
        #expect(twins == [Twin(path: "a.txt", earlierPath: "A.txt", mixesFileAndFolder: false)])
    }

    @Test func differentNamesAreNotTwins() {
        #expect(CaseTwinScan.laterTwins(in: [Self.file("a.txt"), Self.file("b.txt")], requested: nil).isEmpty)
    }

    /// The fold matches case-insensitive APFS (probed on a live volume, 2026-11-11): full case folding, NFC,
    /// never the Turkish dotless i, never width or compatibility forms.
    @Test(arguments: [
        ("stra\u{DF}e", "STRASSE"), ("STRA\u{1E9E}E", "strasse"), ("\u{FB00}", "FF"), ("\u{FB03}", "ffi"),
        ("\u{3C2}", "\u{3A3}"), ("\u{212A}", "k"), ("\u{212B}", "\u{E5}"), ("A\u{30A}", "\u{E5}"),
        ("\u{130}", "i\u{307}"), ("\u{17F}", "S"), ("\u{1C80}", "\u{412}"), ("\u{1C88}", "\u{A64A}"),
        ("\u{FF21}", "\u{FF41}"), ("\u{10400}", "\u{10428}"), ("D/x.txt", "d/X.TXT"),
        // Sequences: the fold runs on NFD. On NFC, U+0345 composes into its base
        // and the fold's ι lands before the other mark; Foundation's NFC drops a Deseret base to 16 bits.
        ("\u{1FB7}", "\u{391}\u{342}\u{345}"), ("\u{1FB2}\u{301}", "\u{1FBA}\u{345}\u{301}"),
        ("\u{1FB3}\u{342}", "\u{1FBC}\u{342}"), ("\u{1FF7}.txt", "\u{3A9}\u{342}\u{345}.txt"),
        ("\u{10403}\u{308}", "\u{1042B}\u{308}"), ("\u{10415}\u{306}", "\u{1043D}\u{306}"),
    ])
    func theFoldJoinsWhatAPFSPutsOnOneName(_ a: String, _ b: String) {
        #expect(NameFold.key(a) == NameFold.key(b))
    }

    @Test(arguments: [
        ("\u{131}", "i"), ("\u{131}", "I"), ("\u{130}", "i"), ("\u{130}", "I"), ("\u{FF21}", "A"),
        ("\u{E9}", "e"), ("\u{2163}", "IV"), ("x\u{200B}", "x"), ("\u{1D400}", "A"),
        // APFS keeps these apart, and so did NFC + lowercased: ι after the circumflex is a starter there.
        ("\u{1F80}\u{302}", "\u{1F00}\u{3B9}\u{302}"),
        // Foundation's NFC turns U+1042B U+0308 into U+04F8; APFS keeps the Deseret name and the Cyrillic apart.
        ("\u{1042B}\u{308}", "\u{4F8}"),
    ])
    func theFoldKeepsApartWhatAPFSKeepsApart(_ a: String, _ b: String) {
        #expect(NameFold.key(a) != NameFold.key(b))
    }

    @Test func fullCaseFoldingTwinsAreTwins() {
        let twins = CaseTwinScan.laterTwins(in: [Self.file("stra\u{DF}e"), Self.file("STRASSE")], requested: nil)
        #expect(twins == [Twin(path: "STRASSE", earlierPath: "stra\u{DF}e", mixesFileAndFolder: false)])
    }

    /// The scan keys a path as spelled, never after Foundation's NFC, which rewrites `\u{1042B}\u{308}` to
    /// U+04F8 and would key it apart from its other case `\u{10403}\u{308}`.
    @Test func sequenceTwinsAreTwins() {
        let twins = CaseTwinScan.laterTwins(in: [Self.file("\u{10403}\u{308}"), Self.file("\u{1042B}\u{308}"),
                                                 Self.file("\u{1FB7}"), Self.file("\u{391}\u{342}\u{345}")],
                                            requested: nil)
        #expect(twins == [Twin(path: "\u{1042B}\u{308}", earlierPath: "\u{10403}\u{308}", mixesFileAndFolder: false),
                          Twin(path: "\u{391}\u{342}\u{345}", earlierPath: "\u{1FB7}", mixesFileAndFolder: false)])
    }

    @Test func folderTwinsMerge() {
        let entries = [Self.folder("D"), Self.file("D/x.txt"), Self.folder("d"), Self.file("d/y.txt")]
        #expect(CaseTwinScan.laterTwins(in: entries, requested: nil).isEmpty)
    }

    @Test func filesCollideInsideMergedFolders() {
        // No folder headers: the folders are implicit, and still merge on a case-insensitive volume.
        let twins = CaseTwinScan.laterTwins(in: [Self.file("D/x.txt"), Self.file("d/X.txt")], requested: nil)
        #expect(twins == [Twin(path: "d/X.txt", earlierPath: "D/x.txt", mixesFileAndFolder: false)])
    }

    @Test func fileThenImplicitFolderReportsTheFolderOnce() {
        let entries = [Self.file("D"), Self.file("d/x.txt"), Self.file("d/y.txt")]
        #expect(CaseTwinScan.laterTwins(in: entries, requested: nil)
            == [Twin(path: "d", earlierPath: "D", mixesFileAndFolder: true)])
    }

    @Test func folderThenFileReportsTheFile() {
        let entries = [Self.folder("d"), Self.file("d/x.txt"), Self.file("D")]
        #expect(CaseTwinScan.laterTwins(in: entries, requested: nil)
            == [Twin(path: "D", earlierPath: "d", mixesFileAndFolder: true)])
    }

    @Test func implicitFolderAppearsWithItsFirstChild() {
        // The folder `d` comes into being with `d/x.txt`, before the file `D`.
        let entries = [Self.file("d/x.txt"), Self.file("D"), Self.folder("d")]
        #expect(CaseTwinScan.laterTwins(in: entries, requested: nil)
            == [Twin(path: "D", earlierPath: "d", mixesFileAndFolder: true)])
    }

    @Test func comparesAfterNFC() {
        let nfc = "Caf\u{E9}.txt", nfdUpper = "CAFE\u{301}.TXT"
        let twins = CaseTwinScan.laterTwins(in: [Self.file(nfc), Self.file(nfdUpper)], requested: nil)
        #expect(twins == [Twin(path: nfdUpper, earlierPath: nfc, mixesFileAndFolder: false)])
    }

    @Test func sameNameIsNotACaseTwin() {
        // An exact duplicate, or an NFC/NFD pair, is one item to the model: not a case-only twin.
        let entries = [Self.file("a.txt"), Self.file("a.txt"), Self.file("Caf\u{E9}"), Self.file("Cafe\u{301}")]
        #expect(CaseTwinScan.laterTwins(in: entries, requested: nil).isEmpty)
    }

    @Test func everyLaterTwinIsReportedAgainstTheFirst() {
        let entries = [Self.file("a.txt"), Self.file("A.txt"), Self.file("a.TXT")]
        #expect(CaseTwinScan.laterTwins(in: entries, requested: nil) == [
            Twin(path: "A.txt", earlierPath: "a.txt", mixesFileAndFolder: false),
            Twin(path: "a.TXT", earlierPath: "a.txt", mixesFileAndFolder: false),
        ])
    }

    @Test func requestedItemsAndDescendantsOnly() {
        let entries = [Self.file("docs/a.txt"), Self.file("docs/A.txt"), Self.file("x.txt"), Self.file("X.txt")]
        #expect(CaseTwinScan.laterTwins(in: entries, requested: ["docs"])
            == [Twin(path: "docs/A.txt", earlierPath: "docs/a.txt", mixesFileAndFolder: false)])
    }

    @Test func unrequestedTwinIsNotWrittenSoNotAConflict() {
        let entries = [Self.file("a.txt"), Self.file("A.txt")]
        #expect(CaseTwinScan.laterTwins(in: entries, requested: ["A.txt"]).isEmpty)
    }

    @Test func requestedPathIsAPathPrefixNotAStringPrefix() {
        let entries = [Self.file("doc/a.txt"), Self.file("docs/a.txt"), Self.file("docs/A.txt")]
        #expect(CaseTwinScan.laterTwins(in: entries, requested: ["doc"]).isEmpty)
    }

    @Test func requestedTwinFoldersBothScanned() {
        let entries = [Self.file("D/x.txt"), Self.file("d/X.txt")]
        #expect(CaseTwinScan.laterTwins(in: entries, requested: ["D", "d"])
            == [Twin(path: "d/X.txt", earlierPath: "D/x.txt", mixesFileAndFolder: false)])
    }

    @Test func requestedMatchesAfterNFC() {
        let entries = [Self.file("Caf\u{E9}/a"), Self.file("Caf\u{E9}/A")]
        #expect(CaseTwinScan.laterTwins(in: entries, requested: ["Cafe\u{301}"]).count == 1)
    }

    /// "/" with a combining mark after it is one Character that is not "/": the scan splits on the scalar, so
    /// `d/\u{301}x` makes the folder `d`, and the file `D` is its twin.
    @Test func aHiddenSlashStillMakesTheFolder() {
        let twins = CaseTwinScan.laterTwins(in: [Self.file("d/\u{301}x"), Self.file("D")], requested: nil)
        #expect(twins == [Twin(path: "D", earlierPath: "d", mixesFileAndFolder: true)])
    }

    @Test func aRequestedFolderCoversItemsBehindAHiddenSlash() {
        let entries = [Self.file("d/\u{301}a"), Self.file("d/\u{301}A")]
        let twins = CaseTwinScan.laterTwins(in: entries, requested: ["d"])
        #expect(twins.map { Array($0.path.unicodeScalars) } == [Array("d/\u{301}A".unicodeScalars)])
    }

    // MARK: - entries(of:writeOrder:)

    private static func item(_ path: String, children: [ArchiveItem]? = nil) -> ArchiveItem {
        ArchiveItem(path: path, name: String(path.split(separator: "/").last ?? ""), isDirectory: children != nil,
                    size: nil, kind: "", modificationDate: nil, isPendingAddition: false, children: children)
    }

    @Test func entriesFollowWriteOrderThenTreeOrder() {
        let items = [Self.item("D", children: [Self.item("D/x")]), Self.item("a.txt"), Self.item("A.txt")]
        let entries = CaseTwinScan.entries(of: items, writeOrder: ["A.txt", "D/x", "a.txt"])
        #expect(entries == [Self.file("A.txt"), Self.file("D/x"), Self.file("a.txt"), Self.folder("D")])
        #expect(CaseTwinScan.laterTwins(in: entries, requested: nil)
            == [Twin(path: "a.txt", earlierPath: "A.txt", mixesFileAndFolder: false)])
    }

    @Test func writeOrderMatchesAfterNFC() {
        let items = [Self.item("Caf\u{E9}"), Self.item("b")]
        let entries = CaseTwinScan.entries(of: items, writeOrder: ["b", "Cafe\u{301}"])
        #expect(entries.map(\.path) == ["b", "Caf\u{E9}"])
    }

    // MARK: - DestinationCaseSensitivity

    private static func sensitivity(existing: [String: Bool?]) -> DestinationCaseSensitivity {
        DestinationCaseSensitivity(
            exists: { existing.keys.contains($0.standardizedFileURL.path) },
            supportsCaseSensitiveNames: { existing[$0.standardizedFileURL.path] ?? nil })
    }

    @Test func existingDestinationAnswers() {
        let insensitive = Self.sensitivity(existing: ["/": false, "/out": false])
        let sensitive = Self.sensitivity(existing: ["/": false, "/out": true])
        #expect(insensitive.isCaseInsensitive(URL(fileURLWithPath: "/out")))
        #expect(!sensitive.isCaseInsensitive(URL(fileURLWithPath: "/out")))
    }

    @Test func missingDestinationAsksNearestExistingAncestor() {
        let check = Self.sensitivity(existing: ["/": false, "/Volumes/CS": true])
        #expect(!check.isCaseInsensitive(URL(fileURLWithPath: "/Volumes/CS/new/deeper")))
        #expect(check.isCaseInsensitive(URL(fileURLWithPath: "/Users/new")))
    }

    @Test func unknownCountsAsCaseInsensitive() {
        let unknown = Self.sensitivity(existing: ["/": false, "/out": nil])
        #expect(unknown.isCaseInsensitive(URL(fileURLWithPath: "/out")))
        let nothing = Self.sensitivity(existing: [:])
        #expect(nothing.isCaseInsensitive(URL(fileURLWithPath: "/a/b")))
    }

    /// moveStaged folds names only where the volume says it folds case: unknown is not case-insensitive
    /// there, though the twin question still counts it so.
    @Test func onlyAVolumeThatSaysSoIsKnownToFoldCase() {
        let insensitive = Self.sensitivity(existing: ["/": false, "/out": false])
        let sensitive = Self.sensitivity(existing: ["/": false, "/out": true])
        let unknown = Self.sensitivity(existing: ["/": false, "/out": nil])
        let nothing = Self.sensitivity(existing: [:])
        let out = URL(fileURLWithPath: "/out")
        #expect(insensitive.isKnownCaseInsensitive(out))
        #expect(!sensitive.isKnownCaseInsensitive(out))
        #expect(!unknown.isKnownCaseInsensitive(out))
        #expect(!nothing.isKnownCaseInsensitive(URL(fileURLWithPath: "/a/b")))
        // A missing destination asks its nearest existing ancestor, as isCaseInsensitive does.
        #expect(insensitive.isKnownCaseInsensitive(URL(fileURLWithPath: "/out/new/deeper")))
        #expect(!sensitive.isKnownCaseInsensitive(URL(fileURLWithPath: "/out/new/deeper")))
    }

    @Test func liveMissingFolderAnswersLikeItsParent() {
        let parent = FileManager.default.temporaryDirectory
        let missing = parent.appendingPathComponent("CaseTwinScanTests-\(UUID().uuidString)/x")
        #expect(DestinationCaseSensitivity.live.isCaseInsensitive(missing)
            == DestinationCaseSensitivity.live.isCaseInsensitive(parent))
    }
}
