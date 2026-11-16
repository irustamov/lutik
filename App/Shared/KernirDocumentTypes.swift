import Foundation
import UniformTypeIdentifiers
import KernirCore

/// Archive content types Lutik opens (readable) and can save (writable).
enum KernirDocumentTypes {
    static let identifiers: [String] = [
        "public.zip-archive", "org.7-zip.7-zip-archive", "com.rarlab.rar-archive",
        "public.tar-archive", "org.gnu.gnu-tar-archive", "org.gnu.gnu-zip-archive",
        "org.gnu.gnu-zip-tar-archive", "public.bzip2-archive", "public.tar-bzip2-archive",
        "org.tukaani.xz-archive", "org.tukaani.tar-xz-archive", "com.facebook.zst-archive",
        "public.iso-image", "public.cpio-archive", "com.apple.xar-archive",
        "com.microsoft.cab", "cx.c3.lha-archive", volumeSetIdentifier,
    ]

    /// One part of a split archive (`.001`…`.999`, `.z01`…`.z99`). Declared only by the app's
    /// imported declarations. Viewer only: a set is read-only, Save As writes an ordinary archive.
    static let volumeSetIdentifier = "com.kernir.archive-volume"

    /// Every identifier as a type. rar, zst and lha are declared by no OS, only by the app's
    /// imported declarations (Info.plist), so fall back to importedAs like `packageTypes`.
    static let readable: [UTType] = identifiers.map { UTType($0) ?? UTType(importedAs: $0) }

    static let writable: [UTType] = ArchiveFormat.writable.map { utType(for: $0) }

    /// Zip-based developer packages Lutik opens as a viewer only: never writable,
    /// so saving one goes through Save As. Their content is ZIP, so reading detects ZIP.
    /// jar and war are declared by the system; the others are imported in the app's Info.plist.
    static let packageTypes: [UTType] = [
        "com.sun.java-archive", "com.sun.web-application-archive", "com.sun.enterprise-archive",
        "com.android.package-archive", "com.android.app-bundle", "org.mozilla.xpinstall",
        "org.python.wheel", "org.nuget.package", "com.microsoft.vsix",
    ].map { identifier in UTType(identifier) ?? UTType(importedAs: identifier, conformingTo: .zip) }

    static func utType(for format: ArchiveFormat) -> UTType {
        let id = identifier(for: format)
        return UTType(id) ?? UTType(importedAs: id)
    }

    /// The save panel's allowed types for `format`: its own type first (a name without an
    /// extension gets that type's), plus the type of its extension's last part. NSSavePanel
    /// judges a name by its last extension only, so "x.tar.gz" is plain gzip ("gz"), and with
    /// only tar.gz's type allowed it would append "tgz".
    static func savePanelTypes(for format: ArchiveFormat) -> [UTType] {
        let type = utType(for: format)
        let last = ("x." + format.fileExtension as NSString).pathExtension
        guard let lastType = UTType(filenameExtension: last), !lastType.conforms(to: type) else { return [type] }
        return [type, lastType]
    }

    /// The format whose preferred type has this identifier; writable formats win. nil for unknown identifiers.
    static func format(forTypeIdentifier identifier: String) -> ArchiveFormat? {
        let ordered = ArchiveFormat.writable + ArchiveFormat.allCases.filter { !$0.isWritable }
        if let exact = ordered.first(where: { self.identifier(for: $0) == identifier }) { return exact }
        return identifier == "org.gnu.gnu-tar-archive" ? .tar : nil
    }

    private static func identifier(for format: ArchiveFormat) -> String {
        switch format {
        case .zip: "public.zip-archive"
        case .sevenZip: "org.7-zip.7-zip-archive"
        case .rar: "com.rarlab.rar-archive"
        case .tar: "public.tar-archive"
        case .tarGzip: "org.gnu.gnu-zip-tar-archive"
        case .tarBzip2: "public.tar-bzip2-archive"
        case .tarXz: "org.tukaani.tar-xz-archive"
        case .tarZstd, .zstd: "com.facebook.zst-archive"
        case .gzip: "org.gnu.gnu-zip-archive"
        case .bzip2: "public.bzip2-archive"
        case .xz: "org.tukaani.xz-archive"
        case .iso: "public.iso-image"
        case .cpio: "public.cpio-archive"
        case .xar: "com.apple.xar-archive"
        case .lha: "cx.c3.lha-archive"
        case .cab: "com.microsoft.cab"
        }
    }
}
