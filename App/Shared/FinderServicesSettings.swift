import Foundation
import KernirCore

/// Settings > Finder: what "Compress with Lutik" writes. Kept apart from `ArchiveSaveSettings`,
/// which is the save options form's. Stored in the app's defaults.
struct FinderServicesSettings: Equatable, Sendable {
    static let compressFormatKey = "KernirServicesCompressFormat"
    static let excludesMacMetadataKey = "KernirServicesExcludesMacMetadata"

    /// A writable format; anything else reads and saves as ZIP.
    var compressFormat: ArchiveFormat = .zip
    /// Leave AppleDouble `._` files and `__MACOSX` out of the archive. Stored now; Compress honors
    /// it once the engine's write option lands.
    var excludesMacMetadata = true

    init(defaults: UserDefaults = .standard) {
        if let raw = defaults.string(forKey: Self.compressFormatKey), let format = ArchiveFormat(rawValue: raw) {
            compressFormat = Self.writable(format)
        }
        if defaults.object(forKey: Self.excludesMacMetadataKey) != nil {
            excludesMacMetadata = defaults.bool(forKey: Self.excludesMacMetadataKey)
        }
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Self.writable(compressFormat).rawValue, forKey: Self.compressFormatKey)
        defaults.set(excludesMacMetadata, forKey: Self.excludesMacMetadataKey)
    }

    private static func writable(_ format: ArchiveFormat) -> ArchiveFormat {
        format.isWritable ? format : .zip
    }
}
