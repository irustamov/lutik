import Foundation

/// Recognises the file name of one volume of a multi-volume archive and derives the names of its
/// siblings. Pure name arithmetic: nothing here touches the file system.
///
/// Four schemes are known: `base.partNN.rar`, the old `base.rar` / `base.r00` chain, plain
/// numbered splits (`base.7z.001`) and spanned zips (`base.z01` ... `base.zip`). Extensions are
/// matched case-insensitively; names produced for sibling volumes follow the case of the opened
/// name (`x.R05` finds `x.RAR`).
struct VolumeNaming: Equatable, Sendable {
    enum Pattern: Equatable, Sendable {
        /// `base.partNN.rar`, NN zero-padded to `width`.
        case rarParts(width: Int)
        /// `base.rar` (part 1), `base.r00` (part 2) ... `base.r99` (part 101), `base.s00` (part 102) ...
        case rarOld
        /// `base.ext.001` ... (7z, zip or anything), NNN zero-padded to `width`.
        case numbered(width: Int)
        /// `base.z01` (part 1) ... `base.zNN`, with `base.zip` as the last part.
        case zipSpanned
    }

    let pattern: Pattern
    let folder: URL
    /// "Photos" for `Photos.part3.rar`, "Photos.7z" for `Photos.7z.002`.
    let base: String
    /// 1-based. A spanned zip opened at its `.zip` is 0: the last part, count unknown.
    let openedPart: Int
    /// The extension letters were upper case in the opened name.
    private let upper: Bool
    /// The "part" word as written in the opened name (`rarParts` only).
    private let partWord: String

    /// Longest digit run accepted as a part number, so `Int` parsing cannot overflow.
    private static let maxDigits = 9

    /// Old-style RAR volume letters: `r` ... `y` (`z` is a spanned zip), 100 volumes per letter.
    private static let rarFirstLetter = UnicodeScalar("r").value
    private static let rarLetterCount: UInt32 = 8

    /// Candidate readings of `url`, most likely first; empty when the name is not a volume name.
    /// More than one candidate only for `rarParts`, where `x.part10.rar` is width 2 or width 1.
    static func match(_ url: URL) -> [VolumeNaming] {
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent()
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return [] }
        let stem = String(name[..<dot])
        let ext = String(name[name.index(after: dot)...])
        let lower = ext.lowercased()
        let upper = ext.first?.isUppercase ?? false

        func make(_ pattern: Pattern, base: String, part: Int, word: String = "") -> VolumeNaming {
            VolumeNaming(pattern: pattern, folder: folder, base: base, openedPart: part, upper: upper, partWord: word)
        }

        if lower == "rar" {
            if let (base, word, digits) = splitPart(stem) {
                guard let n = Int(digits), n >= 1 else { return [] }
                // Leading zeros fix the width; otherwise part 1 may have been padded less.
                let widths = digits.hasPrefix("0") ? [digits.count] : Array((1...digits.count).reversed())
                return widths.map { make(.rarParts(width: $0), base: base, part: n, word: word) }
            }
            // `x.part.rar` is a broken part name, not a single-volume `x.part` archive.
            if stem.lowercased().hasSuffix(".part") { return [] }
            return [make(.rarOld, base: stem, part: 1)]
        }
        if lower == "zip" {
            return [make(.zipSpanned, base: stem, part: 0)]
        }
        // `.r00`-`.r99`, then `.s00`-`.s99`, `.t00` ... (WinRAR); `z` is a spanned zip.
        if lower.count == 3, let letter = lower.unicodeScalars.first?.value,
           letter >= Self.rarFirstLetter, letter < Self.rarFirstLetter + Self.rarLetterCount,
           let n = digitsValue(lower.dropFirst()) {
            return [make(.rarOld, base: stem, part: Int(letter - Self.rarFirstLetter) * 100 + n + 2)]
        }
        if lower.count >= 3, lower.first == "z", let n = digitsValue(lower.dropFirst()), n >= 1 {
            return [make(.zipSpanned, base: stem, part: n)]
        }
        if lower.count >= 3, let n = digitsValue(Substring(lower)), n >= 1 {
            return [make(.numbered(width: lower.count), base: stem, part: n)]
        }
        return []
    }

    /// Floor for the part cap of the digit-run schemes: names widen past their width (`x.7z.1000`).
    private static let minDigitCap = 9999

    /// The highest part number this scheme can name, which bounds every enumeration. Old-style RAR
    /// ends at `.y99` (part 801); the digit-run schemes and spanned zips stop at max(10^width - 1, 9999).
    var maxPart: Int {
        switch pattern {
        case .rarOld:
            return Int(Self.rarLetterCount) * 100 + 1
        case .rarParts(let width), .numbered(let width):
            var cap = 1
            for _ in 0..<min(width, Self.maxDigits) { cap *= 10 }
            return max(cap - 1, Self.minDigitCap)
        case .zipSpanned:
            return Self.minDigitCap
        }
    }

    /// The URL of volume `n` in the opened volume's folder. For a spanned zip, `n >= 1` is
    /// `.z01` ... (width 2, wider past 99); the last part is `lastPartURL()`. Callers stay at
    /// `n <= maxPart + 1` (the +1 only to name the missing part in an error); past `maxPart` a name
    /// never repeats an earlier part's name.
    func url(ofPart n: Int) -> URL {
        let name: String
        switch pattern {
        case .rarParts(let width):
            name = "\(base).\(partWord)\(Self.pad(n, width)).\(upper ? "RAR" : "rar")"
        case .rarOld:
            if n <= 1 {
                name = "\(base).\(upper ? "RAR" : "rar")"
            } else {
                let k = n - 2
                let letter = Character(UnicodeScalar(Self.rarFirstLetter + UInt32(k / 100))!)
                name = "\(base).\(upper ? letter.uppercased() : String(letter))\(Self.pad(k % 100, 2))"
            }
        case .numbered(let width):
            name = "\(base).\(Self.pad(n, width))"
        case .zipSpanned:
            name = "\(base).\(upper ? "Z" : "z")\(Self.pad(n, 2))"
        }
        return folder.appendingPathComponent(name, isDirectory: false)
    }

    /// The `.zip` that closes a spanned zip; nil for the other schemes.
    func lastPartURL() -> URL? {
        guard pattern == .zipSpanned else { return nil }
        return folder.appendingPathComponent("\(base).\(upper ? "ZIP" : "zip")", isDirectory: false)
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// Splits `Photos.part03` into ("Photos", "part", "03"); nil unless the stem ends in
    /// `.part` plus digits and has a non-empty base.
    private static func splitPart(_ stem: String) -> (base: String, word: String, digits: String)? {
        guard let dot = stem.lastIndex(of: "."), dot != stem.startIndex else { return nil }
        let tail = stem[stem.index(after: dot)...]
        guard tail.lowercased().hasPrefix("part") else { return nil }
        let word = tail.prefix(4)
        let digits = tail.dropFirst(4)
        guard digitsValue(digits) != nil else { return nil }
        return (String(stem[..<dot]), String(word), String(digits))
    }

    /// The value of an all-ASCII-digit, non-empty, short-enough string; nil otherwise.
    private static func digitsValue(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.count <= maxDigits, s.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        return Int(s)
    }
}
