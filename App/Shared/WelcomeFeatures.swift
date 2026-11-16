import SwiftUI
import KernirCore

/// One row of the Welcome screen's feature list: an SF Symbol, a title and one line of detail.
/// The Mac window and the iOS sheet each pick their rows (`mac`, `iOS`).
struct WelcomeFeature: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case quickLook, openAndExtract, browseAndExtract, edit, formats
    }

    let id: ID
    let systemImage: String
    let title: String
    let detail: String

    /// The Mac window's rows.
    static var mac: [WelcomeFeature] { mac(locale: .current) }

    /// The iOS sheet's rows.
    static var iOS: [WelcomeFeature] { iOS(locale: .current) }

    /// The Mac window's rows, their lists of formats in `locale`'s list format (tests fix one).
    static func mac(locale: Locale) -> [WelcomeFeature] {
        [quickLook, openAndExtract, edit(locale: locale), formats(locale: locale)]
    }

    /// The iOS sheet's rows, their lists of formats in `locale`'s list format.
    static func iOS(locale: Locale) -> [WelcomeFeature] {
        [browseAndExtract, edit(locale: locale), formats(locale: locale)]
    }

    /// "Welcome to <app>", the screen's title.
    static func welcomeTitle(appName: String) -> String {
        String(localized: "Welcome to \(appName)", table: "Shared",
               comment: "Title of the Welcome screen (Mac window, iOS first-run sheet). %@ = the app’s name.")
    }

    /// Formats the formats row names: some the app opens, a short list.
    static let listedFormats: [ArchiveFormat] = [.zip, .sevenZip, .rar, .tar, .gzip, .xz, .iso]
    /// Formats the edit row names: the writable ones, TAR standing for its compressed kinds too.
    static let editableFormats: [ArchiveFormat] = [.zip, .sevenZip, .tar]

    static var quickLook: WelcomeFeature {
        WelcomeFeature(
            id: .quickLook, systemImage: "eye",
            title: String(localized: "Preview in Finder", table: "Shared",
                          comment: "Mac Welcome window: title of the feature row about the Quick Look preview of archives in Finder."),
            detail: String(localized: "Select an archive in Finder and press the Space bar to see what’s inside.", table: "Shared",
                           comment: "Mac Welcome window: detail of the “Preview in Finder” feature row (Quick Look shows the archive’s file list)."))
    }

    static var openAndExtract: WelcomeFeature {
        WelcomeFeature(
            id: .openAndExtract, systemImage: "archivebox",
            title: String(localized: "Open and Extract", table: "Shared",
                          comment: "Mac Welcome window: title of the feature row about opening archives and extracting files."),
            detail: String(localized: "Look inside an archive, then drag files out or extract them all.", table: "Shared",
                           comment: "Mac Welcome window: detail of the “Open and Extract” feature row."))
    }

    static var browseAndExtract: WelcomeFeature {
        WelcomeFeature(
            id: .browseAndExtract, systemImage: "archivebox",
            title: String(localized: "Browse and Extract", table: "Shared",
                          comment: "iOS Welcome sheet: title of the feature row about browsing archives and extracting files."),
            detail: String(localized: "Look inside an archive and save just the files you need.", table: "Shared",
                           comment: "iOS Welcome sheet: detail of the “Browse and Extract” feature row."))
    }

    static func edit(locale: Locale) -> WelcomeFeature {
        let formats = editableFormats.map(\.displayName).formatted(.list(type: .and).locale(locale))
        return WelcomeFeature(
            id: .edit, systemImage: "pencil",
            title: String(localized: "Edit Archives", table: "Shared",
                          comment: "Welcome screen (Mac window, iOS sheet): title of the feature row about editing archives."),
            detail: String(localized: "Add, rename, move, and delete files in \(formats) archives without unpacking them.", table: "Shared",
                           comment: "Welcome screen: detail of the “Edit Archives” feature row. %@ = a list of format names, e.g. “ZIP, 7z, and TAR”."))
    }

    static func formats(locale: Locale) -> WelcomeFeature {
        // The locale's list format supplies the separators and the "and"; "more" is its last item.
        let more = String(localized: "more", table: "Shared",
                          comment: "Welcome screen: the last item of the list of formats in the “Common Formats” row, e.g. “ZIP, 7z, and more”. The list format adds the separators and “and”.")
        let names = (listedFormats.map(\.displayName) + [more]).formatted(.list(type: .and).locale(locale))
        return WelcomeFeature(
            id: .formats, systemImage: "doc.zipper",
            title: String(localized: "Common Formats", table: "Shared",
                          comment: "Welcome screen (Mac window, iOS sheet): title of the feature row about the archive formats the app opens."),
            detail: String(localized: "Opens \(names).", table: "Shared",
                           comment: "Welcome screen: detail of the “Common Formats” feature row. %@ = a list of format names ending in “more”, e.g. “ZIP, 7z, RAR, TAR, GZ, XZ, ISO, and more”."))
    }
}

/// The Welcome screen's feature rows, stock: a tinted SF Symbol, a headline and a secondary line.
struct WelcomeFeatureList: View {
    let features: [WelcomeFeature]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(features) { feature in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: feature.systemImage)
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.title)
                            .font(.headline)
                        Text(feature.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
