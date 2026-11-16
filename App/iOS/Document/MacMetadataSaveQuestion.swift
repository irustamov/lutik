import Foundation

/// The Save button's question "Remove Mac metadata?": only an
/// explicit Save (the bar button, ⌘S) asks, and only about edits to an unanswered archive whose source
/// holds `__MACOSX` or `._*`. Close and background never ask: they write the implicit keep
/// (`DocumentSession.plainSaveChoice(for:)`), also while the question is up. `ScreenState` adopts it and
/// shows the question; UIKit-free, so a SwiftPM package on macOS can test it.
@MainActor protocol MacMetadataSaveQuestion: AnyObject {
    var session: DocumentSession { get }
    /// Edits are allowed now (`ScreenState.allowsEditing`).
    var allowsEditing: Bool { get }
    /// The archive has edits that aren't saved yet.
    var hasChanges: Bool { get }
    /// A Save waits for the answer: the question is up while this is true.
    var macMetadataQuestion: Bool { get set }
    /// Records the answer, true is Remove (`ArchiveDocument.setMacMetadataChoice(_:)`).
    func setMacMetadataChoice(_ strips: Bool)
    /// Writes pending edits in place (`ArchiveDocument.commitSave()`).
    func commitSave() async -> Bool
}

extension MacMetadataSaveQuestion {
    /// A Save now would ask first: edits to write, and the archive's question is still open.
    var needsMacMetadataAnswer: Bool {
        guard allowsEditing, hasChanges, let model = session.model else { return false }
        return session.needsMacMetadataAnswer(for: model)
    }

    /// The Save button: asks first when `needsMacMetadataAnswer`, else writes pending edits in place.
    func saveOrAskAboutMacMetadata() async {
        if needsMacMetadataAnswer {
            macMetadataQuestion = true
        } else {
            _ = await commitSave()
        }
    }

    /// Keep or Remove, taken in the alert button's action: the question goes down and the answer is
    /// recorded at once, so the alert can't show again before the save runs (the others on the screen
    /// clear in their actions too). Returns whether the save should follow: false with no question up (a
    /// second answer) or once edits went off meanwhile: a background save that is writing already
    /// kept the metadata, and the answer applies to the next save.
    func takeMacMetadataAnswer(remove: Bool) -> Bool {
        guard macMetadataQuestion else { return false }
        macMetadataQuestion = false
        setMacMetadataChoice(remove)
        return allowsEditing
    }

    /// Keep or Remove: `takeMacMetadataAnswer(remove:)`, then the save it allows.
    func answerMacMetadataQuestion(remove: Bool) async {
        guard takeMacMetadataAnswer(remove: remove) else { return }
        _ = await commitSave()
    }

    /// Cancel: nothing saved, nothing recorded; the next Save asks again.
    func cancelMacMetadataQuestion() {
        macMetadataQuestion = false
    }
}

extension DocumentSession {
    /// An explicit Save asks about Mac metadata: the source holds `__MACOSX` or `._*` (a `.DS_Store`
    /// alone doesn't count, Q-c4), nothing is answered for the file, and no sheet saved options (a new
    /// archive's creation flag already says what to do).
    func needsMacMetadataAnswer(for model: ArchiveModel) -> Bool {
        macMetadataChoice == nil && model.saveOptions == nil && sourceHasMacMetadata
    }
}
