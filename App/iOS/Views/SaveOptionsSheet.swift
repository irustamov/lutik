import SwiftUI
import KernirCore

/// What the save options form shows for some settings. Every choice comes from the format's
/// capabilities in KernirCore (`ArchiveFormat`); nothing here lists formats or schemes itself.
enum SaveOptionsLayout {
    enum Section: Equatable {
        /// The format picker, over `formats`.
        case format
        /// The compression level picker; only when the format has a level range.
        case level(ClosedRange<Int>)
        /// Encrypt toggle, password, verify and scheme; only when the format can encrypt.
        case encryption([ArchiveEncryption])
        /// The "Exclude Mac metadata" toggle; every writable format.
        case metadata
        /// The Advanced disclosure: a method picker (more than one method) and a Solid toggle.
        case advanced(methods: [ArchiveCompressionMethod], solid: Bool)

        /// Which section this is, whatever it holds: a section keeps its identity (and its
        /// animations) when a format change changes what it offers.
        var kind: Int {
            switch self {
            case .format: 0
            case .level: 1
            case .encryption: 2
            case .advanced: 3
            case .metadata: 4
            }
        }
    }

    /// The formats the picker offers: only writable ones, whatever the source archive is.
    static var formats: [ArchiveFormat] { ArchiveFormat.writable }

    static func sections(for settings: ArchiveSaveSettings) -> [Section] {
        let format = settings.format
        var sections: [Section] = [.format]
        if let range = format.compressionLevelRange {
            sections.append(.level(range))
        }
        if format.supportedEncryptions.count > 1 {
            sections.append(.encryption(format.supportedEncryptions))
        }
        sections.append(.metadata)
        if format.supportedMethods.count > 1 || format.supportsSolid {
            sections.append(.advanced(methods: format.supportedMethods.count > 1 ? format.supportedMethods : [],
                                      solid: format.supportsSolid))
        }
        return sections
    }

    /// What the format picker does: fits the other options to the new `format` (`formatDidChange`).
    /// "Exclude Mac metadata" isn't format-specific, so it keeps its value.
    static func choose(_ format: ArchiveFormat, in settings: inout ArchiveSaveSettings) {
        settings.format = format
        settings.formatDidChange()
    }

    /// The Mac's label and help text, from the "Shared" table; the help is the section footer.
    static var metadataLabel: String {
        String(localized: "Exclude Mac metadata (.DS_Store, __MACOSX, ._ files)", table: "Shared",
               comment: "Save options sheet (New Archive, Save As Copy): the switch that leaves Finder's metadata files out of the saved archive. .DS_Store, __MACOSX and ._ are file names: do not translate them.")
    }

    static var metadataFooter: String {
        String(localized: "Resource forks and extended attributes are never stored.", table: "Shared",
               comment: "Save options sheet: footer under the Exclude Mac metadata switch. Resource forks and extended attributes are macOS file data that archives never keep.")
    }

    /// The schemes the Encryption picker offers once Encrypt is on, strongest (the default) first.
    static func encryptionChoices(for format: ArchiveFormat) -> [ArchiveEncryption] {
        format.supportedEncryptions.filter { $0 != .none }
    }

    /// As on the Mac: a weak scheme says so.
    static func encryptionName(_ encryption: ArchiveEncryption) -> String {
        encryption.isWeak
            ? String(localized: "\(encryption.displayName) (compatible, weak)",
                                comment: "Label of an encryption scheme in the Encryption picker of the save options sheet when the scheme is old and weak but opens in more apps. %@ = the scheme's name (e.g. ZipCrypto), not translated.")
            : encryption.displayName
    }

    /// As on the Mac: "Fastest (0)", "Normal (6)", "Best (9)", plain numbers in between.
    static func levelName(_ level: Int, in range: ClosedRange<Int>, format: ArchiveFormat) -> String {
        if level == range.lowerBound {
            return String(localized: "Fastest (\(level))",
                          comment: "Compression level of a ZIP or 7z archive in the Compression picker: the lowest level, fastest and largest result. %lld = the level number (e.g. 0). Keep the number in parentheses.")
        }
        if level == range.upperBound {
            return String(localized: "Best (\(level))",
                          comment: "Compression level of a ZIP or 7z archive in the Compression picker: the highest level, slowest and smallest result. %lld = the level number (e.g. 9). Keep the number in parentheses.")
        }
        if level == format.defaultCompressionLevel {
            return String(localized: "Normal (\(level))",
                          comment: "Compression level of a ZIP or 7z archive in the Compression picker: the default level. %lld = the level number (e.g. 6). Keep the number in parentheses.")
        }
        return level.formatted()
    }
}

/// The options for a new archive or a copy: format, compression, encryption, Mac metadata and,
/// under Advanced, the method. A stock form sheet with Cancel and Create or Save.
struct SaveOptionsSheet: View {
    enum Purpose { case newArchive, saveAsCopy }

    let purpose: Purpose
    let onCancel: () -> Void
    let onConfirm: (ArchiveSaveSettings) -> Void
    @State private var settings: ArchiveSaveSettings
    @State private var showsAdvanced = false

    init(purpose: Purpose, settings: ArchiveSaveSettings, onCancel: @escaping () -> Void,
         onConfirm: @escaping (ArchiveSaveSettings) -> Void) {
        self.purpose = purpose
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _settings = State(initialValue: settings)
    }

    /// Create / Save is enabled: a writable format and nothing to fix (a password and its
    /// verification when encrypting).
    static func canConfirm(_ settings: ArchiveSaveSettings) -> Bool {
        settings.format.isWritable && settings.problems.isEmpty
    }

    /// Create / Save draws as the prominent confirm button on iOS 26. The title initializer keeps
    /// the label: the label-less `Button(role:action:)` would draw a checkmark instead.
    static var confirmRole: ButtonRole? {
        if #available(iOS 26.0, *) { .confirm } else { nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(SaveOptionsLayout.sections(for: settings), id: \.kind) { section in
                    view(for: section)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, role: Self.confirmRole) { onConfirm(settings) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!Self.canConfirm(settings))
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var title: String {
        switch purpose {
        case .newArchive: String(localized: "New Archive")
        case .saveAsCopy: String(localized: "Save a Copy")
        }
    }

    private var confirmTitle: String {
        switch purpose {
        case .newArchive: String(localized: "Create",
                                            comment: "Confirm button of the save options sheet when creating a new archive. Verb. Starts the creation.")
        case .saveAsCopy: String(localized: "Save",
                                            comment: "Save the changes made to the archive: the Save menu command (⌘S), the trailing toolbar button and the confirm button of the save options sheet in Save a Copy. Verb.")
        }
    }

    @ViewBuilder private func view(for section: SaveOptionsLayout.Section) -> some View {
        switch section {
        case .format:
            Section {
                Picker("Format", selection: format) {
                    ForEach(SaveOptionsLayout.formats, id: \.self) { format in
                        Text(verbatim: format.displayName).tag(format)
                    }
                }
            }
        case .level(let range):
            Section {
                Picker("Compression", selection: $settings.options.compressionLevel) {
                    ForEach(Array(range), id: \.self) { level in
                        Text(SaveOptionsLayout.levelName(level, in: range, format: settings.format))
                            .tag(Optional(level))
                    }
                }
            }
        case .encryption:
            Section {
                Toggle("Encrypt with password", isOn: $settings.isEncrypting)
                if settings.isEncrypting {
                    SecureField("Password", text: password)
                        .textContentType(.newPassword)
                    SecureField("Verify", text: $settings.verifyPassword)
                        .textContentType(.newPassword)
                    Picker("Encryption", selection: $settings.options.encryption) {
                        ForEach(SaveOptionsLayout.encryptionChoices(for: settings.format), id: \.self) { encryption in
                            Text(SaveOptionsLayout.encryptionName(encryption)).tag(encryption)
                        }
                    }
                }
            } footer: {
                if !settings.problems.isEmpty {
                    Text(settings.problems.map(\.message).joined(separator: "\n"))
                }
            }
        case .metadata:
            Section {
                Toggle(SaveOptionsLayout.metadataLabel, isOn: $settings.options.excludesMacMetadata)
                    .accessibilityIdentifier("saveExcludeMetadata")
            } footer: {
                Text(SaveOptionsLayout.metadataFooter)
            }
        case .advanced(let methods, let solid):
            Section {
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    if !methods.isEmpty {
                        Picker("Method", selection: $settings.options.method) {
                            ForEach(methods, id: \.self) { method in
                                Text(KernirFormat.methodName(method)).tag(Optional(method))
                            }
                        }
                    }
                    if solid {
                        Toggle("Solid archive", isOn: isSolid)
                    }
                }
            }
        }
    }

    /// Changing the format fits the other options to it (`formatDidChange`).
    private var format: Binding<ArchiveFormat> {
        Binding {
            settings.format
        } set: { format in
            SaveOptionsLayout.choose(format, in: &settings)
        }
    }

    private var password: Binding<String> {
        Binding {
            settings.options.password ?? ""
        } set: { password in
            settings.options.password = password
        }
    }

    private var isSolid: Binding<Bool> {
        Binding {
            settings.options.solid ?? false
        } set: { isOn in
            settings.options.solid = isOn
        }
    }
}
