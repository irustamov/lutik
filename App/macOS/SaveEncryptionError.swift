import Foundation
import KernirCore

/// A save refused because the format it writes has no scheme for the archive's encryption: ⌘S on
/// an encrypted zip whose file is named .tar, which saves as TAR (`ArchiveSaveSettings.writeOptions`
/// keeps the encryption, so the engine refuses rather than write a plaintext copy). The engine says
/// `ArchiveError.unsupportedEncryption`, whose text is for opening ("Encrypted TAR archives aren't
/// supported yet."); this says what the save can't do, and how Save As can.
/// The panel and the split save never get here: their settings offer only what the format carries.
struct SaveEncryptionError: LocalizedError, Equatable {
    let format: ArchiveFormat

    /// `error` as a save writing `encryption` into `format` reports it: the engine's refusal of that
    /// encryption for that format becomes this error; anything else stays as it is, so an archive
    /// whose own data can't be decrypted while it is repacked keeps the open-side text.
    static func reporting(_ error: any Error, encryption: ArchiveEncryption, format: ArchiveFormat) -> any Error {
        guard case .unsupportedEncryption(let refused)? = error as? ArchiveError, refused == format,
              encryption != .none, !format.supportedEncryptions.contains(encryption) else { return error }
        return SaveEncryptionError(format: format)
    }

    var errorDescription: String? {
        String(localized: "\(format.displayName) archives can't be saved with this encryption.")
    }

    /// The same text, as `ArchiveError` has it: an alert that shows the failure reason (NSDocument's)
    /// shows the save's too.
    var failureReason: String? { errorDescription }

    var recoverySuggestion: String? {
        String(localized: "Use Save As to save it as ZIP or 7z, or without a password.")
    }
}
