import Testing
import AppKit
import SwiftUI
@testable import Kernir

@MainActor
struct VolumeSplitRowTests {
    /// The row in a form laid out like `SaveOptionsView`'s, whose fitting size the save panel
    /// sizes its accessory from.
    private func fittingSize(_ split: VolumeSplit, showsZipNote: Bool) -> NSSize {
        fittingSize { VolumeSplitRow(split: .constant(split), showsZipNote: showsZipNote) }
    }

    private func fittingSize(@ViewBuilder _ content: () -> some View) -> NSSize {
        let view = NSHostingView(rootView: Form { content() }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(minWidth: 420, idealWidth: 420)
            .fixedSize(horizontal: false, vertical: true))
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
    }

    @Test func customGrowsTheRow() {
        let plain = fittingSize(.none, showsZipNote: false)
        let custom = fittingSize(.custom(amount: "2", unit: .gb), showsZipNote: false)
        #expect(plain.width == 420)
        #expect(plain.height > 0)
        #expect(custom.height > plain.height)
    }

    @Test func theZipNoteShowsOnlyWhileSplitting() {
        let preset = fittingSize(.preset(.mb100), showsZipNote: false)
        let note = fittingSize(.preset(.mb100), showsZipNote: true)
        #expect(note.height > preset.height)
        // No split, no note.
        #expect(fittingSize(.none, showsZipNote: true).height == fittingSize(.none, showsZipNote: false).height)
    }

    /// The English ZIP note is one line at the accessory's 420 pt. It adds exactly
    /// as much height as a one-word secondary line does. A translation may wrap, so the
    /// test runs only when the host app shows English.
    @Test(.enabled(if: Bundle.main.preferredLocalizations.first == "en", "the one-line rule is for English"))
    func theZipNoteIsOneLineAt420Points() {
        let split = VolumeSplit.preset(.mb100)
        let withoutNote = fittingSize(split, showsZipNote: false).height
        let note = fittingSize(split, showsZipNote: true).height - withoutNote
        let oneLine = fittingSize {
            VolumeSplitRow(split: .constant(split), showsZipNote: false)
            Text(verbatim: "Kernir").foregroundStyle(.secondary)
        }.height - withoutNote
        #expect(oneLine > 0)
        #expect(note == oneLine)
    }

    @Test func choosingCustomKeepsAPresetsSizeToEdit() {
        #expect(VolumeSplitRow.customStart(from: .preset(.mb700)) == .custom(amount: "700", unit: .mb))
        #expect(VolumeSplitRow.customStart(from: .preset(.fat32)) == .custom(amount: "4", unit: .gb))
        #expect(VolumeSplitRow.customStart(from: .none) == .custom(amount: "", unit: .mb))
        let typed = VolumeSplit.custom(amount: "1,5", unit: .gb)
        #expect(VolumeSplitRow.customStart(from: typed) == typed)
    }
}
