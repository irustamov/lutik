import KernirCore

/// The user's own Mac metadata choice for a file, over the shared plain-save options.
/// `choice` is "strip Mac metadata": true strips the `__MACOSX` tree, `._*` files and
/// `.DS_Store`, already in the archive and added; false keeps them; nil means no choice, so the save
/// is the shared plain save unchanged. UIKit-free, so a SwiftPM package on macOS can test it.
enum PlainSaveChoice {
    /// What a plain save writes with:
    /// - nil choice: `ArchiveSaveSettings.writeOptions(for:defaultExcludesMacMetadata:)`, as it is.
    /// - With saved options (a new archive's): those, with their flag set to the choice; their
    ///   method, encryption and password stay.
    /// - Without: strip gives explicit options with the source's settings; keep gives nil, which keeps
    ///   the source's settings (its encryption and the reader's password) and never strips.
    @MainActor static func plainSaveOptions(for model: ArchiveModel, choice: Bool?,
                                            default defaultExcludes: Bool) -> ArchiveWriteOptions? {
        var options = ArchiveSaveSettings.writeOptions(for: model,
                                                       defaultExcludesMacMetadata: choice ?? defaultExcludes)
        // A later choice beats the flag a sheet saved; nil options stay nil.
        if let choice { options?.excludesMacMetadata = choice }
        return options
    }

    /// Whether that save strips Mac metadata: nil options never do. The one value a UI shows, so it
    /// can't disagree with what is written.
    @MainActor static func effectiveExcludes(for model: ArchiveModel, choice: Bool?,
                                             default defaultExcludes: Bool) -> Bool {
        plainSaveOptions(for: model, choice: choice, default: defaultExcludes)?.excludesMacMetadata ?? false
    }
}
