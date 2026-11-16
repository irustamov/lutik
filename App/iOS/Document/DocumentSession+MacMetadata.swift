import Foundation
import KernirCore

/// The file's Mac metadata choice on iOS. The question is asked
/// only at an explicit Save; until then a save that can't ask (close, background) keeps the archive's
/// `__MACOSX` and `._*` entries, as stripping them would delete the user's entries unasked. UIKit-free, so
/// a SwiftPM package on macOS can test it.
extension DocumentSession {
    /// The choice a plain save writes with (`PlainSaveChoice`; true strips):
    /// - the file's answer (`macMetadataChoice`);
    /// - else keep (false) when the source holds Mac metadata and no sheet saved options: nil options,
    ///   nothing stripped, and the source's encryption and password kept;
    /// - else nil: the shared plain save. A new archive's saved options keep their flag, and without
    ///   them the app's default applies (it strips added metadata, and a `.DS_Store`-only archive's
    ///   `.DS_Store`, Q-c4).
    func plainSaveChoice(for model: ArchiveModel) -> Bool? {
        macMetadataChoice ?? ((model.saveOptions == nil && sourceHasMacMetadata) ? false : nil)
    }

    /// The options a plain save writes with: `plainSaveChoice(for:)` over the shared plain save, with
    /// `defaultExcludes` as the app's default.
    func plainSaveOptions(for model: ArchiveModel, default defaultExcludes: Bool) -> ArchiveWriteOptions? {
        PlainSaveChoice.plainSaveOptions(for: model, choice: plainSaveChoice(for: model), default: defaultExcludes)
    }

    /// A new reader (open, revert, the reopen after a save or with another name encoding): whether its
    /// entries hold Mac metadata. Once per reader: an edit never scans.
    func detectMacMetadata(in reader: (any ArchiveReading)?) {
        sourceHasMacMetadata = reader.map { MacMetadataDetection.containsMacMetadata($0.entries) } ?? false
    }

    /// Takes an answer remembered for the file; nil changes nothing. A read of the file goes through
    /// `adoptMacMetadataChoice(readWithFile:)`, which drops a Remove the store has nothing for. Tests also
    /// set an answer with it.
    func adoptRememberedMacMetadataChoice(_ remembered: Bool?) {
        if let remembered { macMetadataChoice = remembered }
    }

    /// The file was read (open, or UIDocument's revert after a change from outside) and `remembered` is
    /// what the store has for it. With nothing remembered, a Remove this session holds goes: a read of the
    /// file drops a Remove that the store doesn't back. The store rejected its record (another file now has
    /// the path) or never kept it (no file ID), so nothing says this is the file the user answered for, and
    /// stripping it would delete entries unasked. The next save then keeps the Mac metadata and the next
    /// Save asks. A Keep stays: keeping loses nothing.
    func adoptMacMetadataChoice(readWithFile remembered: Bool?) {
        if remembered == nil, macMetadataChoice == true { macMetadataChoice = nil }
        adoptRememberedMacMetadataChoice(remembered)
    }

    /// The user's answer at a Save (true is Remove): this session's, and remembered for the file at `url`.
    /// Recorded nowhere else: the implicit keep is never an answer.
    func answerMacMetadataQuestion(strips: Bool, for url: URL, in store: MacMetadataChoiceStore) {
        macMetadataChoice = strips
        store.remember(strips, for: url)
    }

    /// After a successful save of the file at `url`, which wrote a file with `savedFileID`: remembers the
    /// answer again, if there is one, so its record has the new file's identity (a safe save swaps in the
    /// written file, a new file ID, which a Remove matches by). When the file at `url` isn't the written one
    /// any more (iCloud or another app replaced it since the swap), a Remove goes, as a revert or a read of
    /// a replaced file drops a Remove that the store doesn't back: the store keeps no record, the next save
    /// keeps the Mac metadata and the next Save asks. A Keep stays and is remembered: keeping loses nothing.
    func rememberMacMetadataChoiceAfterSave(of url: URL, savedFileID: UInt64?, in store: MacMetadataChoiceStore) {
        guard let macMetadataChoice else { return }
        if !store.remember(macMetadataChoice, for: url, savedFileID: savedFileID) { self.macMetadataChoice = nil }
    }

    /// Where Save As Copy's options sheet starts: the archive's settings (`ArchiveSaveSettings(model:)`:
    /// saved options, else the source's with the app's default), the existing "Exclude Mac metadata"
    /// toggle set to the file's answer when there is one (Q-c5a: that toggle is how a copy goes the other
    /// way). The implicit keep is no answer. The copy's toggle applies to the copy only, and records nothing.
    func saveAsCopySettings(for model: ArchiveModel) -> ArchiveSaveSettings {
        var settings = ArchiveSaveSettings(model: model)
        if let macMetadataChoice { settings.options.excludesMacMetadata = macMetadataChoice }
        return settings
    }
}
