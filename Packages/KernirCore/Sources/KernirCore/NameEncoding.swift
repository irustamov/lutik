import CoreFoundation
import Foundation

/// How entry names stored without a declared encoding (e.g. legacy zip, tar, RAR4 OEM) are decoded.
/// Declared names (7z, RAR5, xar, RAR4 names flagged Unicode, zip with bit 11 or the 0x7075 field) are never reinterpreted.
public enum ArchiveNameEncoding: Sendable, Hashable {
    /// One encoding per archive, guessed from all of its undeclared names.
    case automatic
    /// One of `choices`. Other encodings are not supported.
    case specific(String.Encoding)

    /// The encodings the user can choose, in menu order (after Automatic).
    public static let choices: [String.Encoding] = [
        .utf8, .windowsCP1251, .cp866, .koi8R, .cp932, .gb18030, .big5, .cp949, .windowsCP1252, .cp437, .windowsCP1250,
    ]
}

/// Legacy encodings that `String.Encoding` has no member for.
extension String.Encoding {
    static let cp866 = cf(.dosRussian)
    static let koi8R = cf(.KOI8_R)
    static let cp932 = cf(.dosJapanese)
    static let gb18030 = cf(.GB_18030_2000)
    static let big5 = cf(.big5)
    static let cp949 = cf(.dosKorean)
    static let cp437 = cf(.dosLatinUS)

    private static func cf(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}
