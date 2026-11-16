import Foundation

/// Reads an archive's comment and turns its bytes into `ArchiveComment.text`. A ZIP end-of-central-directory
/// comment has no charset flag (bit 11 covers entry names and entry comments only), so the rule is: valid UTF-8 is
/// UTF-8, with one leading BOM left out of the text; anything else decodes as the archive's undeclared names do
/// (`NameDecoding`): the caller's `.specific` choice, else the names' legacy encoding, else CP437. Bytes that are not
/// valid in that encoding fall back to CP437, which maps every byte (`NameEncodingDetector.decode`).
enum ArchiveCommentDecoder {
    private static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The archive comment of the zip in `parts` (in read order, read as one file: the end record and its comment
    /// may span the last parts), decoded with `decoding`; nil for other formats (0.1.0 reads ZIP only: RAR and gzip
    /// later) and for a zip without one. The end record taken is `VolumeProbe.zipComment(parts:)`'s, whose comment
    /// reaches the end, the same one a save keeps.
    /// Writable when the archive is a single file. The comment is never encrypted, so no password is involved.
    static func comment(format: ArchiveFormat, parts: [URL], decoding: NameDecoding) throws(ArchiveError)
        -> ArchiveComment? {
        guard format == .zip, !parts.isEmpty,
              let bytes = try VolumeProbe.zipComment(parts: parts), !bytes.isEmpty else { return nil }
        return ArchiveComment(bytes: bytes, text: text(of: bytes, decoding: decoding),
                              isWritable: format.supportsComments && parts.count == 1)
    }

    /// `bytes` for display. Valid UTF-8 keeps its scalars as stored (no NFC: a comment is text, not a path); the
    /// legacy reading is NFC, as names are.
    static func text(of bytes: [UInt8], decoding d: NameDecoding) -> String {
        let utf8 = String(decoding: bytes, as: UTF8.self)
        if utf8.utf8.elementsEqual(bytes) {
            return bytes.starts(with: bom) ? String(decoding: bytes.dropFirst(bom.count), as: UTF8.self) : utf8
        }
        let encoding: String.Encoding
        if case .specific(let chosen) = d.requested {
            encoding = chosen
        } else {
            encoding = d.legacy ?? .cp437
        }
        return NameEncodingDetector.decode(bytes, as: encoding)
    }
}
