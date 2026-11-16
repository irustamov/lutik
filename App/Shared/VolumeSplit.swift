import Foundation
import KernirCore

/// The volume size the save options offer for a split archive, as the user chose it: no split,
/// a preset, or a typed amount. Sizes are decimal, like Finder's (1 MB = 1 000 000 bytes).
/// It knows no formats; which formats can split is up to the settings that hold it.
enum VolumeSplit: Hashable, Sendable {
    enum Preset: Hashable, Sendable, CaseIterable {
        case mb25, mb100, mb700, fat32

        var bytes: Int64 {
            switch self {
            case .mb25: 25_000_000
            case .mb100: 100_000_000
            case .mb700: 700_000_000
            // 4 GiB − 1: the largest file FAT32 can hold.
            case .fat32: 4_294_967_295
            }
        }
    }

    enum Unit: Hashable, Sendable, CaseIterable {
        case mb, gb

        var bytes: Int64 {
            switch self {
            case .mb: 1_000_000
            case .gb: 1_000_000_000
            }
        }
    }

    enum Problem: Hashable, Sendable {
        /// Smaller than `minimumBytes`.
        case tooSmall
        /// The typed amount is no positive number.
        case invalidSize
        /// The estimated archive needs more than `maximumVolumes` volumes.
        case tooManyVolumes
    }

    case none
    case preset(Preset)
    /// `amount` as typed, in the user's locale ("1,5" in Russian).
    case custom(amount: String, unit: Unit)

    /// The smallest volume the engine writes (`ArchiveWriteOptions.minimumVolumeSize`, 1 000 000 bytes).
    static let minimumBytes: Int64 = ArchiveWriteOptions.minimumVolumeSize
    /// The most volumes the engine writes, .001 … .999 (`ArchiveWriteOptions.maximumVolumeCount`).
    static let maximumVolumes = ArchiveWriteOptions.maximumVolumeCount

    /// The volume size in bytes, the typed amount read in the current locale; nil when not
    /// splitting or when the amount is no positive number.
    var bytes: Int64? { bytes(locale: .current) }

    /// The volume size in bytes, a typed amount read in `locale`. A fraction of a byte rounds up.
    func bytes(locale: Locale) -> Int64? {
        switch self {
        case .none: return nil
        case .preset(let preset): return preset.bytes
        case .custom(let amount, let unit):
            guard let value = Self.amount(amount, locale: locale), value > 0 else { return nil }
            var product = value * Decimal(unit.bytes)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &product, 0, .up)
            guard rounded <= Decimal(Int64.max) else { return nil }
            return NSDecimalNumber(decimal: rounded).int64Value
        }
    }

    /// Why the split can't be saved, if it can't: an invalid or too small size first, then too
    /// many volumes for `estimatedSize` (unknown: no check).
    func problem(estimatedSize: Int64?, locale: Locale = .current) -> Problem? {
        if case .none = self { return nil }
        guard let bytes = bytes(locale: locale) else { return .invalidSize }
        if bytes < Self.minimumBytes { return .tooSmall }
        if let estimatedSize, estimatedSize > 0 {
            let volumes = estimatedSize / bytes + (estimatedSize % bytes == 0 ? 0 : 1)
            if volumes > Int64(Self.maximumVolumes) { return .tooManyVolumes }
        }
        return nil
    }

    /// A typed amount: ASCII digits with at most one decimal separator, the locale's or ".",
    /// unless "." groups thousands there. No signs, exponents or grouping. Nil when it is none.
    private static func amount(_ text: String, locale: Locale) -> Decimal? {
        var text = text.trimmingCharacters(in: .whitespaces)
        let separator = locale.decimalSeparator ?? "."
        if separator != "." {
            guard locale.groupingSeparator != "." || !text.contains(".") else { return nil }
            text = text.replacingOccurrences(of: separator, with: ".")
        }
        guard text.wholeMatch(of: #/[0-9]+(\.[0-9]*)?|\.[0-9]+/#) != nil else { return nil }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }
}
