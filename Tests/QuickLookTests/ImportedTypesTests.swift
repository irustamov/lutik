import Foundation
import Testing

/// A clean macOS 26 / iOS 26 declares neither com.rarlab.rar-archive nor cx.c3.lha-archive
/// nor com.facebook.zst-archive (the dev Mac only has them from VLC and The Unarchiver).
/// Each Quick Look extension lists them in QLSupportedContentTypes, so it must import them.
struct ImportedTypesTests {
    private static let extensions = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Extensions")

    private static let required: [String: [String]] = [
        "com.rarlab.rar-archive": ["rar"] + (0...99).map { String(format: "r%02d", $0) },
        "cx.c3.lha-archive": ["lha", "lzh"],
        "com.facebook.zst-archive": ["zst", "tzst"],
        // The parts of a split archive (7z/zip .001…, spanned zip .z01…): Quick Look shows a placeholder.
        "com.kernir.archive-volume": (1...999).map { String(format: "%03d", $0) }
            + (1...99).map { String(format: "z%02d", $0) },
    ]

    @Test(arguments: ["QuickLookMac", "QuickLookIOS", "ThumbnailMac", "ThumbnailIOS"])
    func importsTheTypesAPlainSystemLacks(appex: String) throws {
        let url = Self.extensions.appendingPathComponent("\(appex)/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let imports = try #require(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        let attributes = (plist["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
        let supported = try #require(attributes?["QLSupportedContentTypes"] as? [String])

        for (id, filenameExtensions) in Self.required {
            #expect(supported.contains(id), "\(appex) no longer lists \(id)")
            let declaration = try #require(imports.first { $0["UTTypeIdentifier"] as? String == id },
                                           "\(appex) does not import \(id)")
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            #expect(tags?["public.filename-extension"] as? [String] == filenameExtensions)
            #expect((declaration["UTTypeConformsTo"] as? [String])?.contains("public.archive") == true)
        }
    }
}
