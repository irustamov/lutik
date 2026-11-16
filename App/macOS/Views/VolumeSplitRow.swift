import SwiftUI

/// The save options' split row: Don't Split, a preset size, or a typed one. Shown only for
/// formats that can split; `showsZipNote` adds the line saying who can open a split ZIP.
/// Stock controls only, like the rest of `SaveOptionsView`. Its strings are in the Shared table, which
/// iOS uses too.
struct VolumeSplitRow: View {
    @Binding var split: VolumeSplit
    let showsZipNote: Bool

    /// What the picker shows: a typed size is one choice, whatever was typed.
    private enum Choice: Hashable {
        case none, preset(VolumeSplit.Preset), custom
    }

    var body: some View {
        Picker(String(localized: "Split into volumes", table: "Shared"), selection: choice) {
            Text("Don't Split", tableName: "Shared").tag(Choice.none)
            ForEach(VolumeSplit.Preset.allCases, id: \.self) { preset in
                Text(KernirFormat.volumeSplitPresetName(preset)).tag(Choice.preset(preset))
            }
            Text("Custom…", tableName: "Shared").tag(Choice.custom)
        }
        .accessibilityIdentifier("saveSplit")
        if case .custom(let amount, let unit) = split {
            // LabeledContent keeps "Volume size" in the form's label column; the field and the
            // unit picker hide their own labels (still read by VoiceOver).
            LabeledContent(String(localized: "Volume size", table: "Shared")) {
                HStack {
                    TextField(String(localized: "Volume size", table: "Shared"), text: Binding {
                        amount
                    } set: { amount in
                        split = .custom(amount: amount, unit: unit)
                    })
                    .labelsHidden()
                    .accessibilityIdentifier("saveSplitCustom")
                    Picker(String(localized: "Unit", table: "Shared"), selection: Binding {
                        unit
                    } set: { unit in
                        split = .custom(amount: amount, unit: unit)
                    }) {
                        ForEach(VolumeSplit.Unit.allCases, id: \.self) { unit in
                            Text(KernirFormat.volumeUnitName(unit)).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("saveSplitUnit")
                }
            }
        }
        if showsZipNote, split != .none {
            // One line in English at the accessory's 420 pt (VolumeSplitRowTests
            // measures it); a longer translation wraps.
            Text("Opens in Lutik and 7-Zip, not Archive Utility or Windows.", tableName: "Shared")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("saveSplitZipNote")
        }
    }

    private var choice: Binding<Choice> {
        Binding {
            switch split {
            case .none: .none
            case .preset(let preset): .preset(preset)
            case .custom: .custom
            }
        } set: { choice in
            switch choice {
            case .none: split = .none
            case .preset(let preset): split = .preset(preset)
            case .custom: split = Self.customStart(from: split)
            }
        }
    }

    /// The typed size Custom starts from: the one already typed, else the preset's amount as
    /// its label shows it ("700" MB, "4" GB), else nothing.
    static func customStart(from split: VolumeSplit) -> VolumeSplit {
        switch split {
        case .none: .custom(amount: "", unit: .mb)
        case .custom: split
        case .preset(let preset):
            switch preset {
            case .mb25: .custom(amount: "25", unit: .mb)
            case .mb100: .custom(amount: "100", unit: .mb)
            case .mb700: .custom(amount: "700", unit: .mb)
            case .fat32: .custom(amount: "4", unit: .gb)
            }
        }
    }
}
