import Testing
import Foundation
@testable import Kernir
import KernirCore

/// Which archive entries open as nested archives: by the extension's exact type identifier, not by
/// content or conformance. Slot-free (shared harness) and part of KernirIOSTests.
struct NestedArchiveTests {
    @Test(arguments: [
        "inner.zip", "a.7z", "src.tar.gz", "src.tgz", "x.rar", "disk.iso", "UPPER.ZIP", "Mixed.Tar.GZ",
        "logs/day1/inner.zip", "a.tar.bz2", "a.tbz", "a.tbz2", "a.tar.xz", "a.txz", "a.tar.zst", "a.tzst",
        "a.tar", "a.cpio", "a.xar", "a.cab", "a.lha", "a.lzh", "a.gz", "a.zip.gz", "a.bz2", "a.xz", "a.zst",
        "a.gtar", "x.part1.rar", "x.part01.rar", "UPPER.ISO", "Disk.Iso", "UPPER.7Z", "X.PART1.RAR",
        // The nested fixtures' entry names (Fixtures/manifest.json, tag nested)
        "archives/inner.zip", "deeper/level3.zip", "secret/inner.zip",
    ])
    func archiveNamesCount(name: String) {
        #expect(NestedArchive.isArchiveEntry(name: name), "\(name)")
    }

    @Test(arguments: [
        "report.docx", "book.epub", "sheet.xlsx", "slides.pptx", "doc.pages", "notes.txt", "photo.jpg",
        "lib.jar", "app.apk", "site.war", "pkg.whl", "pkg.nupkg", "ext.vsix", "ext.xpi", "app.aab", "app.ear",
        "noext", "", ".zip", "dir/", "x.zip.txt", "x.001", "x.z01", "x.r00",
        // Parts of split sets: the app imports r00…r99 as rar, which must not make them archives
        "x.r99", "x.s01", "x.y99", "x.z99", "x.999", "x.7z.001", "x.zip.002", "x.part2.rar", "x.part10.rar",
        "X.R00", "a/b.part03.rar",
        // Folders, whatever their name
        "dir.zip/", "a/b.tar.gz/", "x.iso/",
        // The nested fixtures' non-archive entries
        "readme.txt", "docs/readme.txt",
        // Outside the static table (no declaration of the app lists pax; bzip2 is no extension anyone declares)
        "x.pax", "x.bzip2",
    ])
    func otherNamesDoNot(name: String) {
        #expect(!NestedArchive.isArchiveEntry(name: name), "\(name)")
    }

    /// `ArchiveEntry.path` has no trailing "/" for a folder: `isDirectory` is what tells a folder named
    /// `backup.zip` from the archive of that name.
    @Test func entriesFollowIsDirectory() {
        func entry(_ path: String, directory: Bool) -> ArchiveEntry {
            ArchiveEntry(path: path, isDirectory: directory, size: directory ? nil : 1, compressedSize: nil,
                         modificationDate: nil)
        }
        #expect(!NestedArchive.isArchiveEntry(entry("x.zip", directory: true)))
        #expect(!NestedArchive.isArchiveEntry(entry("a/b.tar.gz", directory: true)))
        #expect(NestedArchive.isArchiveEntry(entry("archives/inner.zip", directory: false)))
        #expect(!NestedArchive.isArchiveEntry(entry("readme.txt", directory: false)))
    }

    @Test func tableOnlyNamesOwnArchiveTypes() {
        let own = Set(KernirDocumentTypes.identifiers)
        for (ext, id) in NestedArchive.identifierByExtension {
            #expect(own.contains(id), "\(ext)")
            #expect(id != KernirDocumentTypes.volumeSetIdentifier, "\(ext)")
            #expect(ext == ext.lowercased() && !NestedArchive.isVolumePart(lowercasedName: "x." + ext), "\(ext)")
        }
    }

    /// Every archive type of the app but the split-set part (and the packages, which are not in the
    /// identifiers) is reachable from a table extension: no declared type is left to the system's say.
    @Test func everyArchiveTypeHasAnExtension() {
        let reachable = Set(NestedArchive.identifierByExtension.values)
        let wanted = Set(KernirDocumentTypes.identifiers).subtracting([KernirDocumentTypes.volumeSetIdentifier])
        #expect(wanted.subtracting(reachable).isEmpty, "\(wanted.subtracting(reachable))")
        for package in KernirDocumentTypes.packageTypes {
            #expect(!reachable.contains(package.identifier), "\(package.identifier)")
        }
    }
}
