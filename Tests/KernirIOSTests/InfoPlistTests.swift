import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Kernir

@Suite struct InfoPlistTests {
    static let archiveTypes = [
        "public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive",
        "public.tar-archive", "org.gnu.gnu-tar-archive", "org.gnu.gnu-zip-archive",
        "org.gnu.gnu-zip-tar-archive", "public.bzip2-archive", "public.tar-bzip2-archive",
        "org.tukaani.xz-archive", "org.tukaani.tar-xz-archive", "com.facebook.zst-archive",
        "public.iso-image", "public.cpio-archive", "com.apple.xar-archive",
        "com.microsoft.cab", "cx.c3.lha-archive", "com.kernir.archive-volume",
    ]
    static let developerPackageTypes = [
        "com.sun.java-archive", "com.sun.web-application-archive", "com.sun.enterprise-archive",
        "com.android.package-archive", "com.android.app-bundle", "org.mozilla.xpinstall",
        "org.python.wheel", "org.nuget.package", "com.microsoft.vsix",
    ]
    static let writableTypes: Set<String> = [
        "public.zip-archive", "org.7-zip.7-zip-archive", "public.tar-archive",
        "org.gnu.gnu-zip-tar-archive", "public.tar-bzip2-archive", "org.tukaani.tar-xz-archive",
    ]
    static var allTypes: [String] { archiveTypes + developerPackageTypes }

    static var documentTypes: [[String: Any]] {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
    }

    @Test func declaresAllArchiveTypes() {
        let declared = Set(Self.documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        #expect(declared == Set(Self.allTypes))
    }

    private static func extensions(of id: String) -> Set<String> {
        let imported = Bundle.main.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]] ?? []
        let entry = imported.first { $0["UTTypeIdentifier"] as? String == id }
        let tags = entry?["UTTypeTagSpecification"] as? [String: Any]
        return Set(tags?["public.filename-extension"] as? [String] ?? [])
    }

    @Test func importsSplitArchivePartTypes() {
        #expect(Self.extensions(of: "com.kernir.archive-volume").isSuperset(of: ["001", "999", "z01", "z99"]))
        #expect(Self.extensions(of: "com.rarlab.rar-archive").isSuperset(of: ["rar", "r00", "r99"]))
    }

    @Test func archiveDocumentTypeListsSplitArchivePart() {
        let archive = Self.documentTypes.first { $0["CFBundleTypeName"] as? String == "Archive" }
        let types = archive?["LSItemContentTypes"] as? [String] ?? []
        #expect(types.contains("com.kernir.archive-volume"))
    }

    @Test func writableTypesAreEditors() {
        var roles: [String: String] = [:]
        for entry in Self.documentTypes {
            for id in entry["LSItemContentTypes"] as? [String] ?? [] {
                roles[id] = entry["CFBundleTypeRole"] as? String
            }
        }
        for id in Self.allTypes {
            let expected = Self.writableTypes.contains(id) ? "Editor" : "Viewer"
            #expect(roles[id] == expected, "\(id)")
        }
    }

    @Test func everyDocumentTypeHasDocumentClass() {
        #expect(!Self.documentTypes.isEmpty)
        for entry in Self.documentTypes {
            #expect(entry["UIDocumentClass"] as? String == "Kernir.ArchiveDocument")
        }
    }

    @Test(arguments: InfoPlistTests.allTypes)
    func everyTypeResolves(id: String) {
        #expect(UTType(id) != nil, "\(id)")
    }

    @Test(arguments: [
        ("com.android.package-archive", "apk"),
        ("org.python.wheel", "whl"),
        ("com.sun.enterprise-archive", "ear"),
    ])
    func developerPackagesConformToZip(id: String, ext: String) throws {
        let type = try #require(UTType(id))
        #expect(type.conforms(to: .zip))
        #expect(UTType(filenameExtension: ext)?.identifier == id)
    }

    /// The app's Info.plist takes its versions from MARKETING_VERSION and CURRENT_PROJECT_VERSION,
    /// the latter stamped by scripts/build/stamp-version.sh (a commit count: digits only), and the
    /// commit for About from KERNIR_GIT_COMMIT.
    @Test func versionFollowsBuildSettings() throws {
        let app = Bundle(for: ArchiveDocument.self)
        #expect(app.bundleURL.pathExtension == "app")
        #expect(app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "0.1.0")
        let build = try #require(app.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        #expect(!build.isEmpty && build.allSatisfy { $0.isASCII && $0.isNumber })
        let commit = try #require(app.object(forInfoDictionaryKey: AppVersion.commitKey) as? String)
        #expect(!commit.isEmpty && !commit.hasPrefix("$("))
    }

    @Test func opensInPlace() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool == true)
        #expect(Bundle.main.object(forInfoDictionaryKey: "UISupportsDocumentBrowser") as? Bool == true)
    }
}
