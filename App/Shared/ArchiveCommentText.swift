import Foundation
import KernirCore

/// Rules for an archive comment the user typed (0.1.0: ZIP only). An unchanged comment is written
/// back as its original bytes elsewhere; this covers only edited text.
enum ArchiveCommentText {
    /// Upper bound for a comment Lutik writes. libarchive's seekable ZIP reader looks for the
    /// end-of-central-directory record in the last 16 KiB only, so a longer comment would hide it.
    /// Counts UTF-8 bytes, as the engine's API does.
    static let maxBytes = ArchiveComment.maximumWritableLength

    /// Whether Lutik shows and edits an archive comment for this format: ZIP only in 0.1.0
    /// (RAR and gzip later).
    static func supportsComments(_ format: ArchiveFormat?) -> Bool {
        format?.supportsComments ?? false
    }

    /// The bytes an edited comment is written as: UTF-8, so ASCII stays ASCII. No BOM.
    static func bytes(for text: String) -> [UInt8] {
        Array(text.utf8)
    }

    /// True when the edited text doesn't fit in a ZIP comment Lutik writes.
    static func isTooLong(_ text: String) -> Bool {
        text.utf8.count > maxBytes
    }

    /// Shown under the comment field and when Save is refused.
    static var tooLongMessage: String {
        String(localized: "Too long for a ZIP comment.", table: "Shared")
    }

    /// ZIP end-record signatures the engine refuses in `.set` text (the engine's contract on
    /// `CommentChange.set`; KernirCore doesn't export them): end of central directory, Zip64 end
    /// record, Zip64 locator. In the comment, the file's last field, they make readers list the zip as empty.
    static let endRecordSignatures: [[UInt8]] = [
        [0x50, 0x4B, 0x05, 0x06], [0x50, 0x4B, 0x06, 0x06], [0x50, 0x4B, 0x06, 0x07],
    ]

    /// True when the edited text's UTF-8 bytes hold a ZIP end-record signature anywhere.
    static func hasEndRecordSignature(_ text: String) -> Bool {
        let bytes = bytes(for: text)
        return bytes.indices.contains { i in
            endRecordSignatures.contains { bytes[i...].starts(with: $0) }
        }
    }

    /// Shown under the comment field and when Save is refused; same wording as the engine's `.io` error.
    static var endRecordSignatureMessage: String {
        String(localized: "The comment contains bytes a ZIP archive cannot hold", table: "Shared")
    }

    /// The message for edited text Lutik won't write, or nil when it can be saved. Checks length
    /// first, then signatures (the engine's order), so text failing both gets `tooLongMessage`.
    static func validationMessage(for text: String) -> String? {
        if isTooLong(text) { return tooLongMessage }
        if hasEndRecordSignature(text) { return endRecordSignatureMessage }
        return nil
    }
}
