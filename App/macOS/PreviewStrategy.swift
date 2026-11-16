import Foundation
import UniformTypeIdentifiers

/// How the Quick Look panel shows one file extracted from an archive .
///
/// Some Quick Look previews are HTML that the panel renders in a WebKit view inside Lutik's own
/// process: Office.qlgenerator (Word, Excel, PowerPoint, CSV), iWork.qlgenerator and
/// Web.qlgenerator (HTML, XHTML, SVG, web archives). WebKit's helpers need
/// `com.apple.security.network.client`, which Lutik's sandbox doesn't have, so they are refused
/// and the panel's spinner never stops. Those types get a stand-in file instead. PDF, images,
/// plain text, RTF and the rest render natively and are shown as they are.
enum PreviewStrategy: Equatable, Sendable {
    /// The file itself.
    case original
    /// A `.txt` copy: the file's source text.
    case textCopy
    /// A page rendered by `QLThumbnailGenerator` (out of process, so its WebKit works), as a
    /// `.png`; `fallback` when that fails.
    case thumbnail(fallback: Fallback)

    enum Fallback: Equatable, Sendable {
        /// A `.txt` copy, for types that are text (e.g. SVG).
        case textCopy
        /// The file's icon, for the rest: never the original, whose preview would hang.
        case icon
    }

    /// Text formats Quick Look renders as a web page: shown as their source text. Their kin
    /// (types that conform to them) too.
    static let textTypes = [
        "public.comma-separated-values-text",
        "public.tab-separated-values-text",
        "public.html",
        "public.xhtml",
    ]

    /// Documents Quick Look renders through WebKit (Office.qlgenerator, iWork.qlgenerator and
    /// the rest of Web.qlgenerator on macOS 26): shown as a rendered page. Their kin too, e.g.
    /// the macro-enabled and template variants that conform to the main types.
    static let renderedTypes = [
        // Word
        "com.microsoft.word.doc",
        "com.microsoft.word.dot",
        "com.microsoft.word.stationery",
        "org.openxmlformats.wordprocessingml.document",
        "org.openxmlformats.wordprocessingml.template",
        "org.openxmlformats.wordprocessingml.document.macroenabled",
        "org.openxmlformats.wordprocessingml.template.macroenabled",
        // Excel
        "com.microsoft.excel.xls",
        "com.microsoft.excel.xlt",
        "org.openxmlformats.spreadsheetml.sheet",
        "org.openxmlformats.spreadsheetml.template",
        "org.openxmlformats.spreadsheetml.sheet.macroenabled",
        "org.openxmlformats.spreadsheetml.template.macroenabled",
        // PowerPoint
        "com.microsoft.powerpoint.ppt",
        "com.microsoft.powerpoint.pot",
        "com.microsoft.powerpoint.pps",
        "org.openxmlformats.presentationml.presentation",
        "org.openxmlformats.presentationml.template",
        "org.openxmlformats.presentationml.slideshow",
        "org.openxmlformats.presentationml.presentation.macroenabled",
        "org.openxmlformats.presentationml.template.macroenabled",
        "org.openxmlformats.presentationml.slideshow.macroenabled",
        // iWork
        "com.apple.iwork.pages.pages",
        "com.apple.iwork.pages.template",
        "com.apple.iwork.pages.sffpages",
        "com.apple.iwork.pages.sfftemplate",
        "com.apple.iwork.numbers.numbers",
        "com.apple.iwork.numbers.template",
        "com.apple.iwork.numbers.sffnumbers",
        "com.apple.iwork.numbers.sfftemplate",
        "com.apple.iwork.keynote.key",
        "com.apple.iwork.keynote.kth",
        "com.apple.iwork.keynote.sffkey",
        "com.apple.iwork.keynote.sffkth",
        "com.apple.keynote.key",
        // Web.qlgenerator's other types
        "public.svg-image",
        "com.apple.webarchive",
    ]

    /// The strategy for a file of `type`; `.original` when the type is unknown.
    init(for type: UTType?) {
        guard let type else {
            self = .original
            return
        }
        if Self.matches(type, Self.textTypes) {
            self = .textCopy
        } else if Self.matches(type, Self.renderedTypes) {
            self = .thumbnail(fallback: type.conforms(to: .text) ? .textCopy : .icon)
        } else {
            self = .original
        }
    }

    /// The strategy for a file named `fileName`, by its extension.
    init(fileName: String) {
        let pathExtension = (fileName as NSString).pathExtension
        self.init(for: pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension))
    }

    /// The strategy for the extracted item at `url`: by its name, but `.original` for anything
    /// that isn't a regular file. A folder (or link) named `x.csv` or `x.html` is shown as what it
    /// is, never copied whole into a stand-in.
    init(fileAt url: URL) {
        let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        self = isRegularFile ? PreviewStrategy(fileName: url.lastPathComponent) : .original
    }

    /// `type` is one of `identifiers` or conforms to one. Identifiers the system doesn't declare
    /// still match by name.
    private static func matches(_ type: UTType, _ identifiers: [String]) -> Bool {
        identifiers.contains { identifier in
            type.identifier == identifier || UTType(identifier).map(type.conforms(to:)) == true
        }
    }

    /// The longest file name APFS and HFS+ accept, in UTF-8 bytes.
    static let maxFileNameBytes = 255

    /// The stand-in's file name: `name` plus `.pathExtension` (`Budget.csv` → `Budget.csv.txt`),
    /// so Quick Look picks the stand-in's type. A long `name` is shortened (whole characters) so
    /// the result fits in `maxFileNameBytes`; an empty one becomes "Preview". The panel still
    /// titles the item with the entry's own name.
    static func standInName(for name: String, pathExtension: String) -> String {
        let suffix = "." + pathExtension
        var base = name.isEmpty ? "Preview" : name
        while !base.isEmpty, base.utf8.count + suffix.utf8.count > maxFileNameBytes {
            base.removeLast()
        }
        return (base.isEmpty ? "Preview" : base) + suffix
    }
}
