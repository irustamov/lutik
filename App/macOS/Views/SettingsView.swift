import SwiftUI

/// The Settings window's content: the default app for each archive format (General), and help
/// for turning off other apps' archive previews (Quick Look).
struct SettingsView: View {
    static let quickLookSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview")!

    let defaultApp: DefaultAppModel

    var body: some View {
        Form {
            DefaultAppSection(model: defaultApp)
            Section("Quick Look") {
                Text("If another app shows archive previews when you press Space, turn it off in Login Items & Extensions → Quick Look.")
                Text("In Extensions, click ⓘ next to Quick Look and turn off other archive apps.")
                    .foregroundStyle(.secondary)
                    // VoiceOver would read ⓘ as a letter.
                    .accessibilityLabel(Text("In Extensions, click the Info button next to Quick Look and turn off other archive apps."))
                Button("Open Login Items & Extensions…") {
                    NSWorkspace.shared.open(Self.quickLookSettingsURL)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings > General: "Default App for Archives", a row per format group with whether the app
/// opens it and Make Default, and Make Default for All.
struct DefaultAppSection: View {
    let model: DefaultAppModel

    var body: some View {
        Section {
            ForEach(model.rows) { row in
                LabeledContent(row.title) {
                    if row.isDefault {
                        Label(String(localized: "Default",
                                     comment: "Settings > Default App for Archives: a format row's state when the app opens that format by default."),
                              systemImage: "checkmark")
                            .foregroundStyle(.secondary)
                    } else {
                        Button(String(localized: "Make Default",
                                      comment: "Settings > Default App for Archives: a format row's button; makes the app the default app for that format.")) {
                            Task { await model.makeDefault(groupID: row.id) }
                        }
                        .disabled(model.isWorking)
                        .accessibilityLabel(Text("Make Default for \(row.title)",
                                                 comment: "VoiceOver label of a Settings format row's Make Default button. The value is the row's format names, e.g. “ZIP” or “TAR, TAR.GZ”."))
                    }
                }
            }
            HStack {
                if model.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                if let message = model.problemMessage(pointsToSettings: false) {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(String(localized: "Make Default for All",
                              comment: "Settings > Default App for Archives: button that makes the app the default app for every archive format listed except ISO (disk images keep mounting in Finder).")) {
                    Task { await model.makeDefaultForAll() }
                }
                .disabled(model.isWorking || model.isDefaultForAll)
            }
        } header: {
            Text("Default App for Archives",
                 comment: "Settings: header of the section listing archive formats and whether the app opens them by default.")
        } footer: {
            Text("Formats marked Default open in \(model.appName) when you double-click them in Finder. Make Default for All skips ISO, so Finder keeps mounting disk images.",
                 comment: "Settings > Default App for Archives: footer under the format rows. “Default” is the state shown on a format row when the app already opens it (the “Default” label). “Make Default for All” is the button above; ISO is a format row of its own. %@ = the app’s name.")
                .foregroundStyle(.secondary)
        }
    }
}
