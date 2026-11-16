import Testing
import Foundation
@testable import Kernir

/// The decision; by default everything is in favour of the Trash.
private func decide(enabled: Bool = true, outcome: ExtractHereTrashDecision.Outcome = .completed,
                    extractedAll: Bool = true, hasUnsavedChanges: Bool = false, isVolumeSet: Bool = false,
                    hasFileURL: Bool = true) -> ExtractHereTrashDecision {
    ExtractHereTrashDecision.decide(enabled: enabled, outcome: outcome, extractedAll: extractedAll,
                                    hasUnsavedChanges: hasUnsavedChanges, isVolumeSet: isVolumeSet,
                                    hasFileURL: hasFileURL)
}

@Test func offKeepsTheArchive() {
    #expect(decide(enabled: false) == .keep(nil))
}

@Test func aCompleteExtractionOfACleanArchiveMovesItToTheTrash() {
    #expect(decide() == .moveToTrash)
}

@Test(arguments: [ExtractHereTrashDecision.Outcome.cancelled, .failed])
func aCancelledOrFailedExtractionKeepsItWithoutAWord(_ outcome: ExtractHereTrashDecision.Outcome) {
    #expect(decide(outcome: outcome) == .keep(nil))
    #expect(decide(outcome: outcome, hasUnsavedChanges: true) == .keep(nil))
}

@Test func unsavedChangesKeepItAndSayWhy() throws {
    #expect(decide(hasUnsavedChanges: true) == .keep(.unsavedChanges))
    let message = ExtractHereTrashDecision.KeepReason.unsavedChanges.message
    #expect(!message.isEmpty)
    #expect(!message.contains("\n"))
    // Off: nothing to explain.
    #expect(decide(enabled: false, hasUnsavedChanges: true) == .keep(nil))
}

/// Extract Here on a selection leaves the other items only in the archive: it stays, without a
/// word (the user asked for part of it), unsaved changes or not.
@Test func aPartialExtractionKeepsTheArchive() {
    #expect(decide(extractedAll: false) == .keep(nil))
    #expect(decide(extractedAll: false, hasUnsavedChanges: true) == .keep(nil))
}

@Test func aVolumeSetIsKept() {
    #expect(decide(isVolumeSet: true) == .keep(nil))
}

@Test func anUntitledCopyIsKept() {
    #expect(decide(hasFileURL: false) == .keep(nil))
}

@Test func theSettingIsOffUntilTurnedOn() {
    let (defaults, suite) = makeTestDefaults("ExtractHereTrashDecisionTests")
    defer { removeTestDefaults(defaults, suite: suite) }
    let settings = ExtractHereSettings(defaults: defaults)
    #expect(settings.movesArchiveToTrash == false)

    settings.movesArchiveToTrash = true

    #expect(ExtractHereSettings(defaults: defaults).movesArchiveToTrash)
    #expect(defaults.bool(forKey: ExtractHereSettings.movesArchiveToTrashKey))
}
