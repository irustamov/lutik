import CLibArchive

/// Maps libarchive's format and filter codes to a Kernir `ArchiveFormat`. Nil means unsupported.
func mapArchiveFormat(formatCode: Int32, filterCodes: [Int32]) -> ArchiveFormat? {
    let base = formatCode & Int32(ARCHIVE_FORMAT_BASE_MASK)
    let filter = filterCodes.first

    switch base {
    case Int32(ARCHIVE_FORMAT_ZIP): return .zip
    case Int32(ARCHIVE_FORMAT_7ZIP): return .sevenZip
    case Int32(ARCHIVE_FORMAT_RAR), Int32(ARCHIVE_FORMAT_RAR_V5): return .rar
    case Int32(ARCHIVE_FORMAT_ISO9660): return .iso
    case Int32(ARCHIVE_FORMAT_CPIO): return .cpio
    case Int32(ARCHIVE_FORMAT_XAR): return .xar
    case Int32(ARCHIVE_FORMAT_LHA): return .lha
    case Int32(ARCHIVE_FORMAT_CAB): return .cab
    case Int32(ARCHIVE_FORMAT_TAR):
        guard let filter else { return .tar }
        switch filter {
        case ARCHIVE_FILTER_GZIP: return .tarGzip
        case ARCHIVE_FILTER_BZIP2: return .tarBzip2
        case ARCHIVE_FILTER_XZ: return .tarXz
        case ARCHIVE_FILTER_ZSTD: return .tarZstd
        default: return nil
        }
    case Int32(ARCHIVE_FORMAT_RAW):
        switch filter {
        case ARCHIVE_FILTER_GZIP: return .gzip
        case ARCHIVE_FILTER_BZIP2: return .bzip2
        case ARCHIVE_FILTER_XZ: return .xz
        case ARCHIVE_FILTER_ZSTD: return .zstd
        default: return nil
        }
    default:
        return nil
    }
}

/// The error for an encrypted entry that could not be read: no password or a wrong one. RAR encryption
/// cannot be decrypted at all, so it is `.unsupportedEncryption(.rar)` either way.
func encryptionError(format: ArchiveFormat, hasPassphrase: Bool) -> ArchiveError {
    switch format {
    case .rar: .unsupportedEncryption(format)
    default: hasPassphrase ? .wrongPassword : .passwordRequired
    }
}

/// The error for encrypted data the engine cannot decrypt at all, whatever the password: RAR encryption
/// and PKWARE strong encryption in zip. Nil when a password can decrypt it (7z AES-256 included).
func undecryptableError(format: ArchiveFormat, zipStrongEncryption: Bool) -> ArchiveError? {
    switch format {
    case .rar: .unsupportedEncryption(format)
    case .zip where zipStrongEncryption: .unsupportedEncryption(.zip)
    default: nil
    }
}

/// 7z coder failures that no password changes, checked before any password rule on both the data and the
/// header path: a crypto coder other than 7zAES ("Crypto codec not supported yet") or an AES folder past the
/// supported coder graph ("Unsupported form of 7zAES streams") cannot be decrypted, and malformed or
/// unsupported-cost 7zAES properties ("... AES coder properties") are damage. Nil for any other message.
func sevenZipCoderFailure(_ error: ArchiveError, message: String) -> ArchiveError? {
    let m = message.lowercased()
    if m.contains("crypto codec not supported") || m.contains("unsupported form of 7zaes streams") {
        return .unsupportedEncryption(.sevenZip)
    }
    if m.contains("aes coder properties") { return error }
    return nil
}

/// The one mapping for a failed libarchive read (a header or a data block) on a possibly encrypted
/// archive. `.io` stays `.io`; encrypted data that cannot be decrypted at all is `.unsupportedEncryption`
/// (7z: see `sevenZipCoderFailure`); a password error only when libarchive says so (its messages name the
/// passphrase: "Passphrase required for this entry", "Incorrect passphrase", "Too many incorrect
/// passphrases", "Failed to process passphrase"); everything else (truncation, damaged headers, unsupported
/// methods, CRC or authentication failures) is corruption, so a damaged archive never asks for a password
/// again. A 7z wrong password shows up only as CRC or decompression errors, so open verifies it
/// (`LibArchiveReader.verifySevenZipPassword`) and later failures stay `.corrupted`.
func readFailure(_ error: ArchiveError, format: ArchiveFormat, encrypted: Bool, hasPassphrase: Bool,
                 zipStrongEncryption: Bool) -> ArchiveError {
    guard case .corrupted(let message) = error else { return error }
    if format == .sevenZip, let coder = sevenZipCoderFailure(error, message: message) { return coder }
    if encrypted, let unsupported = undecryptableError(format: format, zipStrongEncryption: zipStrongEncryption) {
        return unsupported
    }
    if message.lowercased().contains("passphrase") {
        return encryptionError(format: format, hasPassphrase: hasPassphrase)
    }
    return error
}

/// A failed 7z header read in the listing walk. The coder checks of `readFailure` come first. A
/// failure with no encrypted folder in sight (and no message naming encryption or the passphrase) is the
/// error itself. Otherwise, without a passphrase it is `.passwordRequired`. With one:
/// - the decode of a header-encrypted (`-mhe=on`) archive's header (`isEncryptedHeaderDecode`) is
///   `.wrongPassword`: a wrong key turns the header into garbage, and a damaged encrypted header answers
///   the same (7-Zip itself says "Wrong password?");
/// - any later failure (libarchive decodes a folder while it lists, to read a symlink's target) returns
///   nil: the caller arbitrates by decoding the first encrypted entry (`verifySevenZipPassword`), so damage
///   under the right password is `.corrupted` and only a failed verification is `.wrongPassword`. Past an
///   encrypted header the password already decoded, the caller takes it as damage without decoding.
func sevenZipHeaderFailure(_ error: ArchiveError, message: String, isEncryptedHeaderDecode: Bool,
                           hasEncryptedEntries: Bool, hasPassphrase: Bool) -> ArchiveError? {
    if let coder = sevenZipCoderFailure(error, message: message) { return coder }
    let msg = message.lowercased()
    guard hasEncryptedEntries || msg.contains("encrypt") || msg.contains("passphrase") else { return error }
    guard hasPassphrase else { return .passwordRequired }
    return isEncryptedHeaderDecode ? .wrongPassword : nil
}
