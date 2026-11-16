import CoreFoundation
import Foundation
import KernirCore

extension ArchiveNameEncoding {
    /// View > Text Encoding's title for `encoding`, e.g. "Cyrillic (Windows)" (Mac menu, iOS sheet). Our own
    /// table, in the English of the Mac's `String.localizedName(of:)`: on iOS that returns "" for every
    /// non-Unicode encoding (its CoreFoundation has no names for them). An encoding outside `choices` gets
    /// `systemName`, or a plain description when that is empty or blank, so a title is never "". The app
    /// ships English only: a new localization must translate the 11 Shared.xcstrings keys below, or the Mac
    /// menu and the iOS sheet stay English in it.
    static func title(of encoding: String.Encoding,
                      systemName: (String.Encoding) -> String = String.localizedName(of:)) -> String {
        switch encoding {
        case .utf8:
            String(localized: "Unicode (UTF-8)", table: "Shared", comment: "View > Text Encoding: UTF-8")
        case .windowsCP1251:
            String(localized: "Cyrillic (Windows)", table: "Shared", comment: "View > Text Encoding: Windows-1251")
        case TitledEncoding.cp866:
            String(localized: "Russian (DOS)", table: "Shared", comment: "View > Text Encoding: CP866")
        case TitledEncoding.koi8R:
            String(localized: "Cyrillic (KOI8-R)", table: "Shared", comment: "View > Text Encoding: KOI8-R")
        case TitledEncoding.cp932:
            String(localized: "Japanese (Windows, DOS)", table: "Shared",
                   comment: "View > Text Encoding: CP932 (Shift JIS)")
        case TitledEncoding.gb18030:
            String(localized: "Chinese (GB 18030)", table: "Shared", comment: "View > Text Encoding: GB 18030")
        case TitledEncoding.big5:
            String(localized: "Traditional Chinese (Big 5)", table: "Shared", comment: "View > Text Encoding: Big5")
        case TitledEncoding.cp949:
            String(localized: "Korean (Windows, DOS)", table: "Shared", comment: "View > Text Encoding: CP949")
        case .windowsCP1252:
            String(localized: "Western (Windows Latin 1)", table: "Shared",
                   comment: "View > Text Encoding: Windows-1252")
        case TitledEncoding.cp437:
            String(localized: "Latin-US (DOS)", table: "Shared", comment: "View > Text Encoding: CP437")
        case .windowsCP1250:
            String(localized: "Central European (Windows Latin 2)", table: "Shared",
                   comment: "View > Text Encoding: Windows-1250")
        default:
            fallbackTitle(of: encoding, systemName: systemName)
        }
    }

    private static func fallbackTitle(of encoding: String.Encoding,
                                      systemName: (String.Encoding) -> String) -> String {
        let name = systemName(encoding)
        return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "String.Encoding(rawValue: \(encoding.rawValue))" : name
    }
}

/// The legacy encodings of `ArchiveNameEncoding.choices` that `String.Encoding` has no member for, made as
/// KernirCore makes them (its own constants are internal).
private enum TitledEncoding {
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
