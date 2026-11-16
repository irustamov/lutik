import Testing
import AppKit
import UniformTypeIdentifiers
@testable import Kernir
import KernirCore

@Test func everyWritableFormatHasAWritableType() {
    for f in ArchiveFormat.writable {
        let t = KernirDocumentTypes.utType(for: f)
        #expect(KernirDocumentTypes.writable.contains(t))
        #expect(KernirDocumentTypes.format(forTypeIdentifier: t.identifier) == f)
    }
}

@Test func readableIncludesAllOrchestrationTypes() {
    let ids = Set(KernirDocumentTypes.readable.map(\.identifier))
    for id in ["public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive",
               "public.tar-archive", "org.gnu.gnu-zip-archive", "public.iso-image"] {
        #expect(ids.contains(id))
    }
    #expect(!KernirDocumentTypes.writable.contains(KernirDocumentTypes.utType(for: .rar)))
}

/// Tests are hosted in Lutik.app (TEST_HOST), so Bundle.main is the app: its Info.plist carries
/// the imported declarations for types no OS declares.
@Test func typesNoSystemDeclaresAreImportedByTheApp() {
    let imported = (Bundle.main.infoDictionary?["UTImportedTypeDeclarations"] as? [[String: Any]] ?? [])
        .compactMap { $0["UTTypeIdentifier"] as? String }
    for id in ["com.rarlab.rar-archive", "com.facebook.zst-archive", "cx.c3.lha-archive"] {
        #expect(imported.contains(id), "\(id) is not imported by \(Bundle.main.bundleIdentifier ?? "?")")
    }
}

@Test func everyDocumentTypeIdentifierResolves() {
    for id in KernirDocumentTypes.identifiers {
        let type = UTType(id) ?? UTType(importedAs: id)
        #expect(type.conforms(to: .archive) || type.conforms(to: .data), "\(id) is not an archive or data type")
    }
}

@Test func everyFormatMapsToAReadableType() {
    for f in ArchiveFormat.allCases {
        let type = KernirDocumentTypes.utType(for: f)
        #expect(KernirDocumentTypes.readable.contains(type))
        #expect(type != .archive, "\(f) fell back to public.archive")
    }
}

/// NSSavePanel judges a typed name by its last extension only: "x.tar.gz" is "gz", the plain
/// gzip type, which tar.gz's type does not conform to, so the panel appended ".tgz".
@Test func savePanelAcceptsEveryWritableFormatsOwnExtension() {
    for f in ArchiveFormat.writable {
        let types = KernirDocumentTypes.savePanelTypes(for: f)
        #expect(types.first == KernirDocumentTypes.utType(for: f))
        let last = ("x." + f.fileExtension as NSString).pathExtension
        let typed = UTType(filenameExtension: last)
        #expect(types.contains { typed?.conforms(to: $0) == true }, "\(f): the panel rejects .\(f.fileExtension)")
    }
}

/// The panel takes its current type from the proposed name's extension: it must be the format's
/// own type, so a bare name gets that extension ("x" → "x.tgz", not "x.gz").
@Test func savePanelProposalMakesTheFormatsOwnTypeCurrent() {
    for f in ArchiveFormat.writable {
        let ext = ArchiveSaveSettings.savePanelExtension(for: f)
        #expect(!ext.contains("."), "\(f): .\(ext) has more than one part")
        #expect(UTType(filenameExtension: ext) == KernirDocumentTypes.utType(for: f), "\(f): .\(ext)")
    }
}

@Test func volumeSetTypeIsDeclaredAndReadable() {
    let id = "com.kernir.archive-volume"
    #expect(KernirDocumentTypes.identifiers.contains(id))
    #expect(KernirDocumentTypes.readable.contains { $0.identifier == id })
}

/// Hosted: only the app's imported declaration gives the type its conformance.
@Test func volumeSetTypeConformsToArchiveAndData() {
    let type = UTType("com.kernir.archive-volume") ?? UTType(importedAs: "com.kernir.archive-volume")
    #expect(type.conforms(to: .archive))
    #expect(type.conforms(to: .data))
}

/// Hosted like the test above: the app's Info.plist carries the volume type and the rar parts.
@Test func appImportsTheVolumeTypeAndRarParts() {
    let imported = Bundle.main.infoDictionary?["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []
    func extensions(of id: String) -> [String] {
        let tags = imported.first { $0["UTTypeIdentifier"] as? String == id }?["UTTypeTagSpecification"] as? [String: Any]
        return tags?["public.filename-extension"] as? [String] ?? []
    }
    let volume = extensions(of: "com.kernir.archive-volume")
    for ext in ["001", "999", "z01", "z99"] { #expect(volume.contains(ext), "volume type lacks .\(ext)") }
    let rar = extensions(of: "com.rarlab.rar-archive")
    for ext in ["rar", "r00", "r99"] { #expect(rar.contains(ext), "rar type lacks .\(ext)") }
}

/// The Dock drop type ("File or Folder", public.item, rank None, no NSDocumentClass) in the built
/// app. Hosted in Lutik.app (Bundle.main is the app); skipped otherwise. Run with
/// `-only-testing:KernirMacTests/DropTypeHostedTests`.
/// An extension no app claims ("x.qqzz") is no archive: Kernir neither opens it nor extracts it.
@Test func anUnclaimedExtensionIsNoArchive() {
    let url = URL(fileURLWithPath: "/Users/u/Downloads/x.qqzz")
    #expect(!ServicesRequest.opensInKernir(url))
    #expect(ServicesRequest(urls: [url]).archives.isEmpty)
    #expect(OpenRoute.route([url], opensInKernir: ServicesRequest.opensInKernir) == .newArchive([url]))
}

@Suite(.serialized, .enabled(if: Bundle.main.bundleIdentifier?.hasPrefix("com.kernir.app") == true))
@MainActor struct DropTypeHostedTests {
    /// The type has no document class, so the Open panel and NSDocumentController still take
    /// archives only, with ZIP (the first type) still the default.
    @Test func openPanelStaysArchivesOnly() throws {
        let readable = ArchiveDocument.readableTypes
        #expect(!readable.isEmpty)
        for generic in [UTType.item, .data, .content, .folder, .directory] {
            #expect(!readable.contains(generic.identifier), "ArchiveDocument reads \(generic.identifier)")
        }
        let controller = NSDocumentController.shared
        for generic in [UTType.item, .data, .folder, .plainText] {
            #expect(controller.documentClass(forType: generic.identifier) == nil, "\(generic.identifier)")
        }
        #expect(controller.documentClassNames == [NSStringFromClass(ArchiveDocument.self)])
        #expect(controller.defaultType == UTType.zip.identifier)
        let types = try #require(Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]])
        let unranked = types.filter { $0["LSHandlerRank"] as? String == "None" }
        #expect(unranked.count == 1)
        #expect(unranked.first?["NSDocumentClass"] == nil)
        #expect(unranked.first?["LSItemContentTypes"] as? [String] == [UTType.item.identifier])
    }

    /// Rank None: Launch Services offers Kernir for no plain file or folder, so it is no Open With
    /// choice and no default app for one, and `urlForApplication(toOpen:)` callers (Preview
    /// window's Open With, ArchiveActions' `opensInKernir`) never see Kernir. By bundle identifier
    /// too, so another registered copy of Kernir counts.
    @Test func launchServicesOffersKernirForNoPlainItem() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("DropTypeHostedTests-\(UUID().uuidString)",
                                                                 isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let text = root.appendingPathComponent("notes.txt")
        let bare = root.appendingPathComponent("README")
        let folder = root.appendingPathComponent("Photos", isDirectory: true)
        let zip = root.appendingPathComponent("a.zip")
        // An empty ZIP: just the end-of-central-directory record.
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: zip)
        try Data("notes\n".utf8).write(to: text)
        try Data("read me\n".utf8).write(to: bare)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)

        let me = Bundle.main.bundleURL.standardizedFileURL
        let myID = try #require(Bundle.main.bundleIdentifier)
        func isKernir(_ app: URL) -> Bool {
            app.standardizedFileURL == me || Bundle(url: app)?.bundleIdentifier == myID
        }
        let workspace = NSWorkspace.shared
        // Positive control: the lookup finds Kernir for a ZIP, so the negatives below can't pass
        // merely because Kernir isn't registered or `isKernir` never matches.
        let zipApps = workspace.urlsForApplications(toOpen: zip)
        #expect(zipApps.contains(where: isKernir), "a.zip: \(zipApps.map(\.path))")
        for item in [text, bare, folder] {
            let apps = workspace.urlsForApplications(toOpen: item)
            #expect(!apps.contains(where: isKernir), "\(item.lastPathComponent): \(apps.map(\.path))")
            if let app = workspace.urlForApplication(toOpen: item) {
                #expect(!isKernir(app), "\(item.lastPathComponent) opens in \(app.path)")
            }
        }
    }
}
