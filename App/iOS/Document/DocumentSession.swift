import Foundation
import KernirCore
import Observation

/// What the document's UI shows: the open phase and save state.
@MainActor @Observable
final class DocumentSession {
    enum Phase {
        case loading
        /// Needs a password; `error` explains why the last one was rejected.
        case locked(error: String?)
        case ready(ArchiveModel)
        /// A multi-volume set with a missing or unreadable part; the document stays open.
        case volume(ArchiveVolumeError)
        case failed(String)
    }

    var phase: Phase = .loading {
        didSet {
            if case .ready(let old) = oldValue, old === model { return }
            modelDidChange?()
        }
    }
    /// Called when `phase` changes and its model isn't the one before (read again, replaced, gone).
    @ObservationIgnored var modelDidChange: (@MainActor () -> Void)?
    /// Non-nil while saving.
    var saveFraction: Double? {
        didSet { if oldValue == nil, saveFraction != nil { saveDidStart?() } }
    }
    /// Called when a save starts (`saveFraction` stops being nil).
    @ObservationIgnored var saveDidStart: (@MainActor () -> Void)?
    /// True while a folder grant's retry loop runs; a second grant is ignored meanwhile.
    var isGrantingFolder = false
    /// Set when a save fails; the UI shows it in an alert.
    var saveError: String?
    /// The file's answer to "Remove Mac metadata?": true is Remove, false is Keep.
    /// Remembered for the file (`MacMetadataChoiceStore`) or given at a Save; nil while unanswered.
    /// What a plain save does with it: `plainSaveChoice(for:)`.
    var macMetadataChoice: Bool?
    /// Whether the archive as read (its source entries, not the additions) holds `__MACOSX` or `._*`
    /// metadata (`MacMetadataDetection`). Found once per reader, `detectMacMetadata(in:)`, never per edit.
    var sourceHasMacMetadata = false

    /// The model of a `.ready` document.
    var model: ArchiveModel? {
        if case .ready(let model) = phase { model } else { nil }
    }

    /// Nonisolated so the document can create it in `init(fileURL:)`.
    nonisolated init() {}
}
