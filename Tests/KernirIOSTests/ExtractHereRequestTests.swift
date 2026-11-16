import Foundation
import Testing
@testable import Kernir

/// An answer on Extract Here's alert (OK, Choose Another Folder…) takes the
/// alert away at once, and the picker step it leads to only once the alert has gone, so the Files
/// picker isn't asked for while the alert is still on its way out. Foundation only: runs in the
/// macOS SwiftPM mirror. The ScreenState side is in ExtractHereTests.
/// Mutants it kills: the answer moving to the picker step at once (a stuck request); a dismissal
/// without an answer moving on; OK on a picker step doing anything; the read-only answer
/// leading to the archive folder's picker, or the other one to any folder's.
struct ExtractHereRequestTests {
    private let folder = URL(fileURLWithPath: "/tmp/kernir-q10-request", isDirectory: true)

    private func request(_ step: ExtractHereRequest.Step) -> ExtractHereRequest {
        ExtractHereRequest(step: step, paths: ["a"], folder: folder)
    }

    /// OK on "That folder doesn't contain …": the question goes, the step stays until the alert has
    /// gone, then it is the picker for the archive's folder again.
    @Test func okWaitsForTheAlertToGoBeforeThePicker() {
        var request = request(.notContaining)
        #expect(request.asksQuestion)
        #expect(!request.waitsOnPicker)

        request.answer()
        #expect(!request.asksQuestion)
        #expect(!request.waitsOnPicker)
        #expect(request.step == .notContaining)

        request.alertDidDismiss()
        #expect(request == ExtractHereRequest(step: .grant, paths: ["a"], folder: folder))
        #expect(request.waitsOnPicker)
        #expect(!request.asksQuestion)
    }

    /// Choose Another Folder… on the read-only alert: the same, ending at the picker for any folder.
    @Test func chooseAnotherFolderWaitsForTheAlertToGoBeforeThePicker() {
        var request = request(.readOnly)
        #expect(request.asksQuestion)

        request.answer()
        #expect(!request.asksQuestion)
        #expect(!request.waitsOnPicker)
        #expect(request.step == .readOnly)

        request.alertDidDismiss()
        #expect(request == ExtractHereRequest(step: .otherFolder, paths: ["a"], folder: folder))
        #expect(request.waitsOnPicker)
    }

    /// The alert went without an answer (something else took the screen): the question stays, so
    /// its alert comes back.
    @Test(arguments: [ExtractHereRequest.Step.notContaining, .readOnly])
    func dismissalWithoutAnAnswerKeepsTheQuestion(_ step: ExtractHereRequest.Step) {
        var request = request(step)
        request.alertDidDismiss()
        #expect(request == self.request(step))
        #expect(request.asksQuestion)
    }

    /// The picker steps have no alert: an answer or a dismissal leaves them as they are.
    @Test(arguments: [ExtractHereRequest.Step.grant, .otherFolder])
    func pickerStepsIgnoreAlertAnswers(_ step: ExtractHereRequest.Step) {
        var request = request(step)
        #expect(request.waitsOnPicker)
        #expect(!request.asksQuestion)
        request.answer()
        request.alertDidDismiss()
        #expect(request == self.request(step))
    }
}
