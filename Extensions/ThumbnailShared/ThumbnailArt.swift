import Foundation

/// Which bundled picture a Quick Look thumbnail shows, chosen from the file name alone.
///
/// The provider gets only the file URL (no content type), and Quick Look sends `x.tar.gz` as plain
/// gzip, so the name decides. Rules, in order:
/// 1. A split part (`.001`–`.999`, `.z01`–`.z99`, the extensions of `com.kernir.archive-volume`)
///    shows its inner format's art: `x.7z.001` → 7z, `x.zip.001` and `x.z01` → zip. A part whose
///    inner format is unknown (`x.001`, `movie.mkv.001`, `x.001.002`) uses the part row ("other").
///    RAR's `.r00`–`.r99` belong to the RAR type (project.yml `&rarExtensions`): rar by rule 3.
/// 2. Compound tar suffixes (`.tar.gz`, `.taz`, `.tar.bz2`, `.tb2`, `.tar.xz`, `.tar.zst`).
/// 3. The last extension, looked up in `rows`.
/// 4. Only for an extension `rows` does not list: the caller's conformance chain (the type for that
///    extension, then its supertypes, most specific first); the first identifier with a row wins.
///    An exact extension match always beats it, so a package never falls to its zip supertype here.
/// 5. Otherwise `fallbackType` (the part row, "other").
///
/// Every type has an approved picture (21 files for 27 types). Changing art is data only: add or swap one image set in
/// `Extensions/ThumbnailAssets/Thumbnails.xcassets` and edit the type's row (and the SHA-256
/// manifest in ThumbnailArtTests).
enum ThumbnailArt {
    struct Row: Sendable {
        /// The UTType identifier, as in `QLSupportedContentTypes` (project.yml `&qlTypes`).
        let type: String
        /// Lower-case file name extensions that mean this type.
        let extensions: [String]
        /// The image set name in Thumbnails.xcassets.
        let art: String

        init(_ type: String, _ extensions: [String], art: String) {
            self.type = type
            self.extensions = extensions
            self.art = art
        }
    }

    static let volumeType = "com.kernir.archive-volume"

    /// What an unmatched name gets. Quick Look only asks for the 27 archive types, so the file is an
    /// archive whose name we did not recognise: it gets the neutral "other" picture of the part row.
    static let fallbackType = volumeType

    /// One row per supported type, in `&qlTypes` order.
    static let rows: [Row] = [
        Row(volumeType, (1...999).map { String(format: "%03d", $0) } + (1...99).map { String(format: "z%02d", $0) },
            art: "other"),
        Row("public.zip-archive", ["zip"], art: "zip"),
        Row("org.7-zip.7-zip-archive", ["7z"], art: "7z"),
        Row("com.rarlab.rar-archive", ["rar"] + (0...99).map { String(format: "r%02d", $0) }, art: "rar"),
        Row("public.tar-archive", ["tar"], art: "tar"),
        Row("org.gnu.gnu-tar-archive", ["gtar"], art: "tar"),
        Row("org.gnu.gnu-zip-archive", ["gz", "gzip"], art: "gz"),
        Row("org.gnu.gnu-zip-tar-archive", ["tgz"], art: "tar-gz"),
        Row("public.bzip2-archive", ["bz2"], art: "bz2"),
        Row("public.tar-bzip2-archive", ["tbz2", "tbz"], art: "tar-bz2"),
        Row("org.tukaani.xz-archive", ["xz"], art: "xz"),
        Row("org.tukaani.tar-xz-archive", ["txz"], art: "tar-xz"),
        Row("com.facebook.zst-archive", ["zst", "tzst"], art: "tar-zst"),
        Row("public.iso-image", ["iso"], art: "iso"),
        Row("public.cpio-archive", ["cpio"], art: "cpio"),
        Row("com.apple.xar-archive", ["xar"], art: "other"),
        Row("com.microsoft.cab", ["cab"], art: "cab"),
        Row("cx.c3.lha-archive", ["lha", "lzh"], art: "other"),
        Row("com.sun.java-archive", ["jar"], art: "jar"),
        Row("com.sun.web-application-archive", ["war"], art: "jar"),
        Row("com.sun.enterprise-archive", ["ear"], art: "jar"),
        Row("com.android.package-archive", ["apk"], art: "apk"),
        Row("com.android.app-bundle", ["aab"], art: "apk"),
        Row("org.mozilla.xpinstall", ["xpi"], art: "xpi"),
        Row("org.python.wheel", ["whl"], art: "whl"),
        Row("org.nuget.package", ["nupkg"], art: "nupkg"),
        Row("com.microsoft.vsix", ["vsix"], art: "vsix"),
    ]

    /// Multi-part tar names whose last extension alone would mean the plain stream (`gz`), plus
    /// one-part aliases not in `rows` (same lists as App/Shared/ArchiveSaveSettings.swift).
    static let compoundSuffixes: [(suffix: String, type: String)] = [
        (".tar.gz", "org.gnu.gnu-zip-tar-archive"), (".taz", "org.gnu.gnu-zip-tar-archive"),
        (".tar.bz2", "public.tar-bzip2-archive"), (".tb2", "public.tar-bzip2-archive"),
        (".tar.xz", "org.tukaani.tar-xz-archive"),
        (".tar.zst", "com.facebook.zst-archive"),
    ]

    struct Resolution: Equatable, Sendable {
        enum Rule: String, Sendable {
            case part, compoundSuffix, fileExtension, conformance, fallback
        }

        /// The image set name.
        let art: String
        /// The identifier whose row gave `art`.
        let type: String
        let rule: Rule
    }

    static func row(forType type: String) -> Row? { rowsByType[type] }

    /// - Parameters:
    ///   - fileName: the file's last path component; matched case-insensitively.
    ///   - conformance: for an extension `rows` does not list, its type identifier followed by its
    ///     supertypes, most specific first (empty when unknown). Never asked for listed extensions.
    static func resolve(fileName: String, conformance: (String) -> [String] = { _ in [] }) -> Resolution {
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        if isPart(ext) {
            // .z01… are the parts of a spanned ZIP (the last part is the .zip itself).
            if ext.hasPrefix("z") { return resolution("public.zip-archive", .part) }
            let inner = (name as NSString).deletingPathExtension
            if !isPart((inner as NSString).pathExtension),
               let match = match(name: inner, conformance: conformance) {
                return resolution(match.type, .part)
            }
            return resolution(volumeType, .part)
        }
        if let match = match(name: name, conformance: conformance) { return match }
        return resolution(fallbackType, .fallback)
    }

    /// Aspect-fit `image` into `maximum`; nil when either size is empty.
    static func fittedSize(_ image: CGSize, into maximum: CGSize) -> CGSize? {
        guard image.width > 0, image.height > 0, maximum.width > 0, maximum.height > 0 else { return nil }
        let scale = min(maximum.width / image.width, maximum.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    // MARK: - Private

    private static let rowsByType: [String: Row] = Dictionary(uniqueKeysWithValues: rows.map { ($0.type, $0) })

    private static let typeByExtension: [String: String] = {
        var table: [String: String] = [:]
        for row in rows {
            for ext in row.extensions where table[ext] == nil { table[ext] = row.type }
        }
        return table
    }()

    /// Rules 2–4 for a lower-cased name that is not a part.
    private static func match(name: String, conformance: (String) -> [String]) -> Resolution? {
        if let compound = compoundSuffixes.first(where: { name.hasSuffix($0.suffix) && name.count > $0.suffix.count }) {
            return resolution(compound.type, .compoundSuffix)
        }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        if let type = typeByExtension[ext] { return resolution(type, .fileExtension) }
        if let type = conformance(ext).first(where: { rowsByType[$0] != nil }) {
            return resolution(type, .conformance)
        }
        return nil
    }

    private static func resolution(_ type: String, _ rule: Resolution.Rule) -> Resolution {
        // Every type passed here has a row (rows, compoundSuffixes, volumeType and fallbackType are
        // checked by ThumbnailArtTests).
        Resolution(art: rowsByType[type]?.art ?? "other", type: type, rule: rule)
    }

    /// `001`–`999` or `z01`–`z99`.
    private static func isPart(_ ext: String) -> Bool {
        let chars = Array(ext)
        if chars.count == 3, chars.allSatisfy(\.isASCIIDigit) { return ext != "000" }
        if chars.count == 3, chars[0] == "z", chars[1].isASCIIDigit, chars[2].isASCIIDigit { return ext != "z00" }
        return false
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
