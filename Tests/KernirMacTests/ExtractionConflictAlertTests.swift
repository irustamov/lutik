import Testing
import AppKit
@testable import Kernir

/// Extract… into a folder where a name is taken asks Finder's question.
@MainActor
struct ExtractionConflictAlertTests {
    @Test func buttonsInFinderOrder() throws {
        let alert = ArchiveActions.extractionConflictAlert(name: "hello.txt", showsApplyToAll: false)
        // NSAlert lays buttons out right to left: Replace, Stop, then Keep Both on the left.
        #expect(alert.buttons.map(\.title) == [String(localized: "Replace"), String(localized: "Stop"),
                                               String(localized: "Keep Both")])
        #expect(alert.buttons.map { $0.accessibilityIdentifier() } ==
                ["extractConflict.replace", "extractConflict.stop", "extractConflict.keepBoth"])
        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
        #expect(alert.messageText.contains("“hello.txt”"))
        #expect(!alert.showsSuppressionButton)
    }

    @Test func applyToAllOnlyWithMoreToAsk() throws {
        let alert = ArchiveActions.extractionConflictAlert(name: "docs", showsApplyToAll: true)
        #expect(alert.showsSuppressionButton)
        #expect(alert.suppressionButton?.title == String(localized: "Apply to All"))
        #expect(alert.suppressionButton?.accessibilityIdentifier() == "extractConflict.applyToAll")
        #expect(alert.suppressionButton?.state == .off)
    }

    /// A case-only twin from the same archive is not on disk yet, so its title names both items; the
    /// buttons and Apply to All stay Finder's.
    @Test func caseTwinNamesBothItems() throws {
        let alert = ArchiveActions.extractionConflictAlert(name: "Readme", showsApplyToAll: true, earlierTwin: "README")
        #expect(alert.messageText == "“Readme” and “README” would get the same name in this location. "
                + "Do you want to replace “README” with “Readme”?")
        #expect(alert.buttons.map { $0.accessibilityIdentifier() } ==
                ["extractConflict.replace", "extractConflict.stop", "extractConflict.keepBoth"])
        #expect(alert.showsSuppressionButton)

        let onDisk = ArchiveActions.extractionConflictAlert(name: "Readme", showsApplyToAll: false)
        #expect(onDisk.messageText == "An item named “Readme” already exists in this location. "
                + "Do you want to replace it with the one you're extracting?")
    }

    private static func twin(_ path: String, of earlier: String) -> CaseTwinScan.Twin {
        CaseTwinScan.Twin(path: path, earlierPath: earlier, mixesFileAndFolder: false)
    }

    /// With three twins on one name, the question names the twin that holds the name after the
    /// answers so far, as extract replaces it: Readme after Replace on Readme, README after Keep Both or Skip.
    @Test func thirdTwinNamesTheTwinHoldingTheName() throws {
        let scan = ExtractionConflictScan(conflicts: ["Readme", "readme"],
                                          laterTwins: [Self.twin("Readme", of: "README"), Self.twin("readme", of: "README")],
                                          askedAsTwins: ["Readme", "readme"])
        let first = ArchiveActions.extractionConflictAlert(for: "Readme", in: scan, resolved: [:], showsApplyToAll: true)
        #expect(first.messageText == "“Readme” and “README” would get the same name in this location. "
                + "Do you want to replace “README” with “Readme”?")

        let afterReplace = ArchiveActions.extractionConflictAlert(for: "readme", in: scan, resolved: ["Readme": .replace],
                                                                  showsApplyToAll: false)
        #expect(afterReplace.messageText == "“readme” and “Readme” would get the same name in this location. "
                + "Do you want to replace “Readme” with “readme”?")

        for answer in [ExtractionConflictResolution.keepBoth, .skip] {
            let alert = ArchiveActions.extractionConflictAlert(for: "readme", in: scan, resolved: ["Readme": answer],
                                                               showsApplyToAll: false)
            #expect(alert.messageText == "“readme” and “README” would get the same name in this location. "
                    + "Do you want to replace “README” with “readme”?")
        }
    }

    /// Twins whose names alone read the same (d/x and D/x, folders merged) are named by their
    /// paths; a conflict that is not asked about as a twin keeps the "already exists" question.
    @Test func twinsWithTheSameNameAreNamedByTheirPaths() throws {
        let scan = ExtractionConflictScan(conflicts: ["notes.txt", "d/x"], laterTwins: [Self.twin("d/x", of: "D/x")],
                                          askedAsTwins: ["d/x"])
        let alert = ArchiveActions.extractionConflictAlert(for: "d/x", in: scan, resolved: [:], showsApplyToAll: false)
        #expect(alert.messageText == "“d/x” and “D/x” would get the same name in this location. "
                + "Do you want to replace “D/x” with “d/x”?")

        let onDisk = ArchiveActions.extractionConflictAlert(for: "notes.txt", in: scan, resolved: [:],
                                                            showsApplyToAll: true)
        #expect(onDisk.messageText == "An item named “notes.txt” already exists in this location. "
                + "Do you want to replace it with the one you're extracting?")
    }
}
