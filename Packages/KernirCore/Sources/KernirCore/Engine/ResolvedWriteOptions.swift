import Foundation

/// Write settings after validation against a format's capabilities.
struct ResolvedWriteOptions: Sendable, Equatable {
    let method: ArchiveCompressionMethod?
    let compressionLevel: Int?
    let encryption: ArchiveEncryption
    let password: String?
    /// `ArchiveWriteOptions.excludesMacMetadata`; false for nil options, which never drop anything.
    var excludesMacMetadata = false

    /// Validates `options` for `format`. nil options keep the source's method and encryption.
    /// With nil options and a same-format save (`sourceFormat == format`), a source encryption the
    /// format cannot carry throws `unsupportedEncryption(format)`, so a plain save never silently
    /// turns an encrypted archive into a plaintext copy of itself. Cross-format, such an
    /// encryption is upgraded to AES-256 when the format has it, else dropped (zip to tar, say):
    /// `ArchiveFormat.encryption(carrying:)`.
    /// `sourceFormat` is nil when there is no source (or it is unknown), which counts as cross-format.
    static func resolve(
        _ options: ArchiveWriteOptions?, format: ArchiveFormat, sourceFormat: ArchiveFormat? = nil,
        sourceEncryption: ArchiveEncryption, sourceMethod: ArchiveCompressionMethod?,
        sourcePassword: String?
    ) throws(ArchiveError) -> ResolvedWriteOptions {
        guard format.isWritable else { throw .readOnlyFormat(format) }

        let method: ArchiveCompressionMethod?
        let level: Int?
        let encryption: ArchiveEncryption
        let password: String?

        if let options {
            if let m = options.method, format.supportedMethods.contains(m) {
                method = m
            } else {
                method = format.defaultMethod
            }
            level = format.compressionLevelRange.map { range in
                min(max(options.compressionLevel ?? format.defaultCompressionLevel ?? range.lowerBound,
                        range.lowerBound), range.upperBound)
            }
            guard format.supportedEncryptions.contains(options.encryption) else {
                throw .unsupportedEncryption(format)
            }
            encryption = options.encryption
            password = options.password
        } else {
            if let m = sourceMethod, format.supportedMethods.contains(m) {
                method = m
            } else {
                method = format.defaultMethod
            }
            level = format.defaultCompressionLevel
            let canCarry = format.supportedEncryptions.contains(sourceEncryption)
            if !canCarry, sourceEncryption != .none, sourceFormat == format {
                throw .unsupportedEncryption(format)
            }
            encryption = format.encryption(carrying: sourceEncryption) ?? .none
            password = sourcePassword
        }

        if encryption != .none, password?.isEmpty ?? true { throw .passwordRequired }
        return ResolvedWriteOptions(method: method, compressionLevel: level,
                                    encryption: encryption,
                                    password: encryption == .none ? nil : password,
                                    excludesMacMetadata: options?.excludesMacMetadata ?? false)
    }
}
