import SwiftUI
import KernirCore

/// The save panel's accessory: format, compression, encryption, Mac metadata and, for a format that
/// can split, volumes. Every choice it offers comes from the format's capabilities in KernirCore.
struct SaveOptionsView: View {
    @Bindable var options: SavePanelOptions

    private var settings: ArchiveSaveSettings { options.settings }
    private var format: ArchiveFormat { settings.format }
    /// Schemes offered when encrypting, in KernirCore's order.
    private var encryptions: [ArchiveEncryption] { format.supportedEncryptions.filter { $0 != .none } }

    var body: some View {
        Form {
            Picker("Format", selection: $options.format) {
                ForEach(ArchiveFormat.writable, id: \.self) { format in
                    Text(verbatim: format.displayName).tag(format)
                }
            }
            .accessibilityIdentifier("saveFormat")
            if let range = format.compressionLevelRange {
                Picker("Compression", selection: $options.settings.options.compressionLevel) {
                    ForEach(Array(range), id: \.self) { level in
                        Text(levelName(level, in: range)).tag(Optional(level))
                    }
                }
                .accessibilityIdentifier("saveCompression")
            }
            if !encryptions.isEmpty {
                Toggle("Encrypt with password", isOn: $options.settings.isEncrypting)
                    .accessibilityIdentifier("saveEncrypt")
                if settings.isEncrypting {
                    SecureField("Password", text: password)
                    SecureField("Verify", text: $options.settings.verifyPassword)
                    Picker("Encryption", selection: $options.settings.options.encryption) {
                        ForEach(encryptions, id: \.self) { encryption in
                            Text(encryptionName(encryption)).tag(encryption)
                        }
                    }
                    .accessibilityIdentifier("saveEncryption")
                }
            }
            // Every writable format. On, the save leaves out metadata already in the archive
            // too, and later saves keep doing so, ⌘S included.
            // String(localized:), not a LocalizedStringKey: Markdown would eat the underscores.
            Toggle(isOn: $options.settings.options.excludesMacMetadata) {
                // The same comments as iOS's SaveOptionsLayout: one key, one comment.
                Text(String(localized: "Exclude Mac metadata (.DS_Store, __MACOSX, ._ files)", table: "Shared",
                            comment: "Save options sheet (New Archive, Save As Copy): the switch that leaves Finder's metadata files out of the saved archive. .DS_Store, __MACOSX and ._ are file names: do not translate them."))
            }
            .help(String(localized: "Resource forks and extended attributes are never stored.", table: "Shared",
                         comment: "Save options sheet: footer under the Exclude Mac metadata switch. Resource forks and extended attributes are macOS file data that archives never keep."))
            .accessibilityIdentifier("saveExcludeMetadata")
            // 7z and ZIP only. Through `options.split`, so the panel turns to a folder.
            if format.supportsVolumes {
                VolumeSplitRow(split: $options.split, showsZipNote: format == .zip)
            }
            if !format.supportedMethods.isEmpty || format.supportsSolid {
                DisclosureGroup("Advanced") {
                    if !format.supportedMethods.isEmpty {
                        Picker("Method", selection: $options.settings.options.method) {
                            ForEach(format.supportedMethods, id: \.self) { method in
                                Text(KernirFormat.methodName(method)).tag(Optional(method))
                            }
                        }
                        .accessibilityIdentifier("saveMethod")
                    }
                    if format.supportsSolid {
                        Toggle("Solid archive", isOn: isSolid)
                    }
                }
            }
            if let note = options.droppedCommentNote {
                Text(note)
                    .foregroundStyle(.secondary)
            }
            if let problem = settings.problems.first {
                Text(problem.message)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        // 420 pt unless a translation needs more; long labels wrap.
        .frame(minWidth: 420, idealWidth: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var password: Binding<String> {
        Binding {
            settings.options.password ?? ""
        } set: { password in
            options.settings.options.password = password
        }
    }

    private var isSolid: Binding<Bool> {
        Binding {
            settings.options.solid ?? false
        } set: { isOn in
            options.settings.options.solid = isOn
        }
    }

    private func levelName(_ level: Int, in range: ClosedRange<Int>) -> String {
        if level == range.lowerBound { return String(localized: "Fastest (\(level))",
                    comment: "Save options, Compression picker: the lowest level. %lld = the level's number (e.g. 1).") }
        if level == range.upperBound { return String(localized: "Best (\(level))",
                    comment: "Save options, Compression picker: the highest level (smallest archive). %lld = the level's number (e.g. 9).") }
        if level == format.defaultCompressionLevel { return String(localized: "Normal (\(level))",
                    comment: "Save options, Compression picker: the format's default level. %lld = the level's number (e.g. 6).") }
        return level.formatted()
    }

    private func encryptionName(_ encryption: ArchiveEncryption) -> String {
        encryption.isWeak
            ? String(localized: "\(encryption.displayName) (compatible, weak)",
                    comment: "Save options, Encryption picker: an encryption every app can open but that is easy to break. %@ = the encryption's name (e.g. “ZipCrypto”): do not translate it.")
            : encryption.displayName
    }
}
