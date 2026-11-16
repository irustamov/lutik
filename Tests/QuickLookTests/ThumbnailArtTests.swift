import CoreGraphics
import CryptoKit
import Foundation
import Testing

/// Thumbnails: file name → bundled picture (Extensions/ThumbnailShared/ThumbnailArt.swift).
/// Pure string tests plus reads of the thumbnail plists and the asset catalog from the repo;
/// no Quick Look, no bundle. Runs in a scratch SwiftPM package as well.
struct ThumbnailArtTests {
    private static let root = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let catalog = root.appendingPathComponent("Extensions/ThumbnailAssets/Thumbnails.xcassets")

    /// The expected art for every type (the delivered art table, which
    /// stays off git). A new delivery of art changes one line here, one row and the manifest.
    private static let expectedArt: [String: String] = [
        "com.kernir.archive-volume": "other",
        "public.zip-archive": "zip",
        "org.7-zip.7-zip-archive": "7z",
        "com.rarlab.rar-archive": "rar",
        "public.tar-archive": "tar",
        "org.gnu.gnu-tar-archive": "tar",
        "org.gnu.gnu-zip-archive": "gz",
        "org.gnu.gnu-zip-tar-archive": "tar-gz",
        "public.bzip2-archive": "bz2",
        "public.tar-bzip2-archive": "tar-bz2",
        "org.tukaani.xz-archive": "xz",
        "org.tukaani.tar-xz-archive": "tar-xz",
        "com.facebook.zst-archive": "tar-zst",
        "public.iso-image": "iso",
        "public.cpio-archive": "cpio",
        "com.apple.xar-archive": "other",
        "com.microsoft.cab": "cab",
        "cx.c3.lha-archive": "other",
        "com.sun.java-archive": "jar",
        "com.sun.web-application-archive": "jar",
        "com.sun.enterprise-archive": "jar",
        "com.android.package-archive": "apk",
        "com.android.app-bundle": "apk",
        "org.mozilla.xpinstall": "xpi",
        "org.python.wheel": "whl",
        "org.nuget.package": "nupkg",
        "com.microsoft.vsix": "vsix",
    ]

    /// SHA-256 of the 21 approved masters (kept off
    /// git), copied byte for byte into the catalog. A re-encoded or swapped PNG fails here.
    private static let masterSHA256: [String: String] = [
        "7z": "be3816a0fb8720fe06b9168b604fe57369f76e3d41e2647819f62b0b9edd144f",
        "apk": "3cdb6d2bba5baa1d65bca25e10274dcbf969bb263931d0545500451b455fd153",
        "bz2": "8e64d279f490ed2c6d8f238d7f363231844bc4897c80ad57f72c7d1b111f47d7",
        "cab": "3058b9478fa3d9f53d64ba8686682666a98680c8540dc7ce3c880af36e6149e1",
        "cpio": "e1fc5f2ef27e16962486a9042e6fb05db3920e11ff9a9418f7ab0ff7a5c3f028",
        "gz": "cccfa174ddefc872663c09f0714f12691b4139f77afc7c2797d2269d32ce673a",
        "iso": "1ebb2f3439eae6a28721b0a0ae2d74c4d3442d10beb8f38828414a91c3c78257",
        "jar": "172d80df054eb89e56590c1fd52fc7142f9e1ed40976474cd16196537d2447f6",
        "nupkg": "fa335206d579d7cfd7625585528c66145841c1508d8efda98032399dbeb2baf1",
        "other": "f363b70b6b569978a3899213c5ea56aa386be56df3ee4f34fa17f8ed6cca581e",
        "rar": "ea99501eb81c8d9f58099b9daf860f53ffa51723b66b7b57cf1afc368d6d312d",
        "tar": "ce4e41d85ec3d7e0d78b8bdd62c784d3126697ffcdd9b648e55d4785a364f7d0",
        "tar-bz2": "0e9907d89d390340e4ad6bfbf2c038279b67c03e8e3e6472e6bb4433a887013d",
        "tar-gz": "71dad21c4a7239b7e794947105894254ee70527c3d574ba248e472f57d6cafaa",
        "tar-xz": "52efee37ee9517844348baaafea6869c15339cbd76afc1f15bf3f13c34ad5323",
        "tar-zst": "774b5e4eb379f533a862555072a8aeded2a98a440eae7dd57596ca4b36b05457",
        "vsix": "c7434721032a1858dc8f20364dd23ce048086dbf1e526ff8eda8157a18cf3285",
        "whl": "b560b1e10c8b0f9a0961873b2197d141f06972e64a81d85c80a4b2a866456100",
        "xpi": "b1cfd0df1a996efdce494935e58f32caee9a3dc7fcd1a05ff7089cf831c0fcc3",
        "xz": "483cb309f1739f0295960f57ac7f9c8fe6d58fde3846f73f4e02982e78096da6",
        "zip": "de72a01d6b3646847ffb8fc30070a99b62e863200ae97819ed96d00dfe47bb6c",
    ]

    // MARK: - Coverage

    @Test(arguments: ["ThumbnailMac", "ThumbnailIOS"])
    func everySupportedTypeHasExactlyOneRow(appex: String) throws {
        let url = Self.root.appendingPathComponent("Extensions/\(appex)/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let attributes = (plist["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
        let supported = try #require(attributes?["QLSupportedContentTypes"] as? [String])
        #expect(supported.count == 27)
        #expect(ThumbnailArt.rows.map(\.type) == supported, "rows must follow &qlTypes, one per type")
    }

    /// Every extension each appex imports (UTImportedTypeDeclarations) resolves to the row of the
    /// type that declares it, so the plists and the table cannot drift apart.
    @Test(arguments: ["ThumbnailMac", "ThumbnailIOS"])
    func everyImportedExtensionResolvesToItsDeclaringType(appex: String) throws {
        let url = Self.root.appendingPathComponent("Extensions/\(appex)/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let imports = try #require(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        #expect(!imports.isEmpty)
        for declaration in imports {
            let id = try #require(declaration["UTTypeIdentifier"] as? String)
            let row = try #require(ThumbnailArt.row(forType: id), "\(appex) imports \(id), which has no row")
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            let extensions = try #require(tags?["public.filename-extension"] as? [String], "\(appex) \(id)")
            #expect(!extensions.isEmpty, "\(appex) \(id)")
            for ext in extensions {
                let name = "x.\(ext)"
                let resolved = ThumbnailArt.resolve(fileName: name)
                if id == ThumbnailArt.volumeType, ext.hasPrefix("z") {
                    // The parts of a spanned ZIP show ZIP (rule 1), not the bare-part art.
                    #expect(resolved == .init(art: "zip", type: "public.zip-archive", rule: .part), "\(appex) \(name)")
                } else {
                    #expect(resolved.type == id && resolved.art == row.art, "\(appex) \(name) -> \(resolved)")
                }
            }
        }
    }

    @Test func eachTypeGetsItsExpectedArt() {
        #expect(Set(ThumbnailArt.rows.map(\.type)) == Set(Self.expectedArt.keys))
        for row in ThumbnailArt.rows {
            #expect(row.art == Self.expectedArt[row.type], "\(row.type)")
        }
    }

    /// Every type shows one of the 21 pictures, and every picture is used.
    @Test func everyTypeShowsOneOfTheApprovedPictures() {
        #expect(Self.masterSHA256.count == 21)
        #expect(Set(ThumbnailArt.rows.map(\.art)) == Set(Self.masterSHA256.keys))
    }

    @Test func everyTypeTheRulesNameHasARow() {
        let named = ThumbnailArt.compoundSuffixes.map(\.type) + [ThumbnailArt.volumeType, ThumbnailArt.fallbackType]
        for type in named { #expect(ThumbnailArt.row(forType: type) != nil, "\(type)") }
    }

    @Test func noExtensionIsClaimedTwice() {
        let all = ThumbnailArt.rows.flatMap(\.extensions)
        #expect(all.count == Set(all).count)
        #expect(all.allSatisfy { $0 == $0.lowercased() && !$0.hasPrefix(".") })
    }

    // MARK: - Asset catalog

    @Test func everyArtIsAnImageSetWithOneImage() throws {
        for art in Set(ThumbnailArt.rows.map(\.art)) {
            let set = Self.catalog.appendingPathComponent("\(art).imageset")
            let data = try Data(contentsOf: set.appendingPathComponent("Contents.json"))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let images = try #require(json["images"] as? [[String: Any]])
            #expect(images.count == 1, "\(art)")
            let file = try #require(images.first?["filename"] as? String)
            #expect(FileManager.default.fileExists(atPath: set.appendingPathComponent(file).path), "\(art)/\(file)")
        }
    }

    @Test func catalogArtMatchesTheOwnerMasters() throws {
        let sets = try FileManager.default.contentsOfDirectory(atPath: Self.catalog.path)
            .filter { $0.hasSuffix(".imageset") }
        #expect(Set(sets) == Set(Self.masterSHA256.keys.map { "\($0).imageset" }), "catalog has exactly the 21 sets")
        for (art, expected) in Self.masterSHA256 {
            let data = try Data(contentsOf: Self.catalog.appendingPathComponent("\(art).imageset/\(art)-1024.png"))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(digest == expected, "\(art) is not the approved master")
        }
    }

    // MARK: - Names

    @Test func everyListedExtensionResolvesToItsRowInAnyCase() {
        for row in ThumbnailArt.rows where row.type != ThumbnailArt.volumeType {
            for ext in row.extensions {
                for name in ["x.\(ext)", "X.\(ext.uppercased())", "My File.v2.\(ext)"] {
                    let resolved = ThumbnailArt.resolve(fileName: name)
                    #expect(resolved == .init(art: row.art, type: row.type, rule: .fileExtension), "\(name)")
                }
            }
        }
    }

    @Test(arguments: [
        ("x.tar.gz", "tar-gz", "org.gnu.gnu-zip-tar-archive", ThumbnailArt.Resolution.Rule.compoundSuffix),
        ("X.TAR.GZ", "tar-gz", "org.gnu.gnu-zip-tar-archive", .compoundSuffix),
        ("x.taz", "tar-gz", "org.gnu.gnu-zip-tar-archive", .compoundSuffix),
        ("x.tgz", "tar-gz", "org.gnu.gnu-zip-tar-archive", .fileExtension),
        ("x.tar.bz2", "tar-bz2", "public.tar-bzip2-archive", .compoundSuffix),
        ("x.tb2", "tar-bz2", "public.tar-bzip2-archive", .compoundSuffix),
        ("x.tbz", "tar-bz2", "public.tar-bzip2-archive", .fileExtension),
        ("x.tar.xz", "tar-xz", "org.tukaani.tar-xz-archive", .compoundSuffix),
        ("x.tar.zst", "tar-zst", "com.facebook.zst-archive", .compoundSuffix),
        ("x.zst", "tar-zst", "com.facebook.zst-archive", .fileExtension),
        ("readme.txt.gz", "gz", "org.gnu.gnu-zip-archive", .fileExtension),
        ("x.gzip", "gz", "org.gnu.gnu-zip-archive", .fileExtension),
        ("x.bz2", "bz2", "public.bzip2-archive", .fileExtension),
        ("x.xz", "xz", "org.tukaani.xz-archive", .fileExtension),
        ("x.txz", "tar-xz", "org.tukaani.tar-xz-archive", .fileExtension),
        ("x.tzst", "tar-zst", "com.facebook.zst-archive", .fileExtension),
        ("x.gtar", "tar", "org.gnu.gnu-tar-archive", .fileExtension),
        ("x.r00", "rar", "com.rarlab.rar-archive", .fileExtension),
        ("x.part1.rar", "rar", "com.rarlab.rar-archive", .fileExtension),
        ("x.R99", "rar", "com.rarlab.rar-archive", .fileExtension),
        ("x.ear", "jar", "com.sun.enterprise-archive", .fileExtension),
        ("x.war", "jar", "com.sun.web-application-archive", .fileExtension),
        ("x.aab", "apk", "com.android.app-bundle", .fileExtension),
        ("x.LZH", "other", "cx.c3.lha-archive", .fileExtension),
        ("x.xar", "other", "com.apple.xar-archive", .fileExtension),
        // A dotfile: ".tar.gz" has no base name, so it is not the compound; its last extension
        // (gz) shows plain gzip.
        (".tar.gz", "gz", "org.gnu.gnu-zip-archive", .fileExtension),
    ])
    func compoundAndSpecialNames(name: String, art: String, type: String, rule: ThumbnailArt.Resolution.Rule) {
        #expect(ThumbnailArt.resolve(fileName: name) == .init(art: art, type: type, rule: rule))
    }

    /// A split part shows its inner format's picture; "other" only when
    /// the name gives no inner format.
    @Test(arguments: [
        ("x.7z.001", "7z", "org.7-zip.7-zip-archive"),
        ("X.7Z.002", "7z", "org.7-zip.7-zip-archive"),
        ("x.zip.001", "zip", "public.zip-archive"),
        ("sz.zip.001", "zip", "public.zip-archive"),
        ("x.z01", "zip", "public.zip-archive"),
        ("X.Z99", "zip", "public.zip-archive"),
        ("x.rar.001", "rar", "com.rarlab.rar-archive"),
        ("x.tar.gz.001", "tar-gz", "org.gnu.gnu-zip-tar-archive"),
        ("x.tar.zst.001", "tar-zst", "com.facebook.zst-archive"),
        ("x.TGZ.001", "tar-gz", "org.gnu.gnu-zip-tar-archive"),
        ("x.gz.001", "gz", "org.gnu.gnu-zip-archive"),
        ("x.iso.999", "iso", "public.iso-image"),
        ("x.apk.003", "apk", "com.android.package-archive"),
        ("x.jar.001", "jar", "com.sun.java-archive"),
        ("x.lzh.001", "other", "cx.c3.lha-archive"),
        ("x.001", "other", "com.kernir.archive-volume"),
        ("movie.mkv.001", "other", "com.kernir.archive-volume"),
        ("x.001.002", "other", "com.kernir.archive-volume"),
    ])
    func splitPartsShowTheInnerFormat(name: String, art: String, type: String) {
        #expect(ThumbnailArt.resolve(fileName: name) == .init(art: art, type: type, rule: .part), "\(name)")
    }

    @Test(arguments: ["001", "x.foo", "x.000", "x.z00", "x.z1", "x.0001", "noextension", ".zip", "x.", ""])
    func unknownNamesFallBackToThePartPicture(name: String) {
        #expect(ThumbnailArt.fallbackType == ThumbnailArt.volumeType)
        #expect(ThumbnailArt.resolve(fileName: name) == .init(art: "other", type: ThumbnailArt.fallbackType, rule: .fallback))
    }

    // MARK: - Conformance (rule 4)

    @Test func conformanceCoversUnlistedExtensions() {
        let chain = { (ext: String) -> [String] in
            ext == "ipk" ? ["com.example.ipk", "public.zip-archive", "public.archive", "public.data"] : []
        }
        #expect(ThumbnailArt.resolve(fileName: "x.ipk", conformance: chain)
                == .init(art: "zip", type: "public.zip-archive", rule: .conformance))
        #expect(ThumbnailArt.resolve(fileName: "x.gzip2", conformance: { _ in ["org.gnu.gnu-zip-archive"] })
                == .init(art: "gz", type: "org.gnu.gnu-zip-archive", rule: .conformance))
        #expect(ThumbnailArt.resolve(fileName: "x.sar", conformance: { _ in ["com.example.sar", "com.sun.java-archive"] })
                == .init(art: "jar", type: "com.sun.java-archive", rule: .conformance))
        #expect(ThumbnailArt.resolve(fileName: "x.foo", conformance: { _ in ["public.archive", "public.data"] }).rule == .fallback)
        #expect(ThumbnailArt.resolve(fileName: "x.ipk.001", conformance: chain) == .init(art: "zip", type: "public.zip-archive", rule: .part))
    }

    @Test func anExactMatchNeverAsksConformance() {
        var asked: [String] = []
        let chain = { (ext: String) -> [String] in asked.append(ext); return ["public.zip-archive"] }
        let expected = [
            "x.apk": "com.android.package-archive", "x.ear": "com.sun.enterprise-archive",
            "x.vsix": "com.microsoft.vsix", "x.tar.gz": "org.gnu.gnu-zip-tar-archive",
            "x.7z.001": "org.7-zip.7-zip-archive", "x.001": ThumbnailArt.volumeType,
        ]
        for (name, type) in expected {
            #expect(ThumbnailArt.resolve(fileName: name, conformance: chain).type == type, "\(name)")
        }
        #expect(asked.isEmpty)
    }

    // MARK: - Fit

    @Test func fitsTheArtIntoTheRequestedBox() {
        let art = CGSize(width: 1024, height: 1024)
        #expect(ThumbnailArt.fittedSize(art, into: CGSize(width: 256, height: 256)) == CGSize(width: 256, height: 256))
        #expect(ThumbnailArt.fittedSize(art, into: CGSize(width: 300, height: 200)) == CGSize(width: 200, height: 200))
        #expect(ThumbnailArt.fittedSize(art, into: CGSize(width: 16, height: 1000)) == CGSize(width: 16, height: 16))
        #expect(ThumbnailArt.fittedSize(art, into: CGSize(width: 512, height: 512)) == CGSize(width: 512, height: 512))
        #expect(ThumbnailArt.fittedSize(CGSize(width: 200, height: 100), into: CGSize(width: 100, height: 100))
                == CGSize(width: 100, height: 50))
        #expect(ThumbnailArt.fittedSize(art, into: .zero) == nil)
        #expect(ThumbnailArt.fittedSize(.zero, into: CGSize(width: 64, height: 64)) == nil)
    }
}
