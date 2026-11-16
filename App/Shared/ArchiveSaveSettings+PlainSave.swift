import KernirCore

extension ArchiveSaveSettings {
    /// The options a save writes with. A save from
    /// the save panel or sheet: `panelOptions`, as they are. A plain save (⌘S, or Save when closing)
    /// with no panel: the options a panel last saved the document with, which keep their "Exclude
    /// Mac metadata" choice; else, when `defaultExcludesMacMetadata` is on, explicit options
    /// that strip Mac metadata, from the archive and from the added files, and otherwise carry what
    /// nil options would (`sourceOptions(of:password:excludesMacMetadata:)`): the source's method and
    /// encryption and the document's password (`ArchiveWriteOptions.excludesMacMetadata`: the engine
    /// strips only through explicit options). Default off: nil, which keeps the source's settings and
    /// never strips.
    ///
    /// `targetFormat` is the format the save writes; nil means the source's own. Saved into another
    /// format, an encryption the target can't carry is converted as nil options would convert it
    /// (`ArchiveFormat.encryption(carrying:)`): a ZipCrypto zip saved as 7z gets AES-256. One the
    /// target has no scheme for stays, so the save refuses (`unsupportedEncryption`) where nil options
    /// would write it unencrypted: an encrypted zip saved as tar, say.
    ///
    /// `defaultExcludesMacMetadata` is the app's setting, `excludesMacMetadataByDefault`, except in
    /// tests. Both apps call this: macOS in `ArchiveDocument.save(to:ofType:for:completionHandler:)`
    /// with the panel's options and the format of the type it saves as, iOS with none for its plain save.
    /// A split panel save on macOS doesn't: it goes to `saveSplit`, which writes with `settings.options`.
    /// iOS's `PlainSaveChoice` passes the file's Mac metadata choice, when set, as
    /// `defaultExcludesMacMetadata` and sets it on saved options too; nil options stay nil (keep).
    @MainActor static func writeOptions(
        for model: ArchiveModel, panelOptions: ArchiveWriteOptions? = nil, targetFormat: ArchiveFormat? = nil,
        defaultExcludesMacMetadata: Bool = ArchiveSaveSettings.excludesMacMetadataByDefault
    ) -> ArchiveWriteOptions? {
        if let panelOptions { return panelOptions }
        if let saved = model.saveOptions { return saved }
        guard defaultExcludesMacMetadata else { return nil }
        guard let reader = model.reader else { return ArchiveWriteOptions(excludesMacMetadata: true) }
        var options = sourceOptions(of: reader, password: model.password, excludesMacMetadata: true)
        // Same format: as it is, which nil options keep or refuse alike (`ResolvedWriteOptions`).
        if let target = targetFormat, target != reader.format,
           let carried = target.encryption(carrying: options.encryption) {
            options.encryption = carried
        }
        return options
    }

    /// What a nil-options save keeps of `reader`, as explicit options: its method and encryption, and
    /// `password` only when it is encrypted. Shared by `init(model:)` and a plain save's `writeOptions`.
    static func sourceOptions(of reader: any ArchiveReading, password: String?,
                              excludesMacMetadata: Bool) -> ArchiveWriteOptions {
        ArchiveWriteOptions(method: reader.compressionMethod, encryption: reader.encryption,
                            password: reader.encryption == .none ? nil : password,
                            excludesMacMetadata: excludesMacMetadata)
    }
}
