import Testing
import Foundation
import AppKit
import UniformTypeIdentifiers
@testable import Kernir

struct ServicesRequestTests {
    /// The repository's Fixtures folder (through a symlinked copy of this file too).
    private static let fixtures = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
    private let folder = URL(fileURLWithPath: "/Users/u/Downloads", isDirectory: true)

    private func urls(_ names: [String]) -> [URL] { names.map { folder.appendingPathComponent($0) } }

    @Test func fixtureZipsAreArchives() throws {
        let zips = [Self.fixtures.appendingPathComponent("showcase/project.zip"),
                    Self.fixtures.appendingPathComponent("zip/macos-finder.zip")]
        for zip in zips { #expect(FileManager.default.fileExists(atPath: zip.path)) }
        let request = ServicesRequest(urls: zips)
        #expect(request.archives == zips)
        #expect(request.items == zips)
    }

    @Test func otherFilesAndFoldersAreOnlyItems() {
        let photos = folder.appendingPathComponent("Photos", isDirectory: true)
        let notes = folder.appendingPathComponent("notes.txt")
        let request = ServicesRequest(urls: [notes, photos])
        #expect(request.archives.isEmpty)
        #expect(request.items == [notes, photos])
    }

    @Test func formatsBeyondZipAreArchives() {
        let names = ["a.7z", "b.tar.gz", "c.tgz", "d.tar", "e.gz", "f.iso"]
        #expect(ServicesRequest(urls: urls(names)).archives == urls(names))
    }

    /// A folder whose name ends in an archive extension is a folder.
    @Test func aFolderNamedLikeAnArchiveIsNotOne() {
        let folder = folder.appendingPathComponent("backup.zip", isDirectory: true)
        #expect(ServicesRequest(urls: [folder]).archives.isEmpty)
    }

    /// A real folder named like an archive, sent without a trailing slash (as a pasteboard may).
    @Test func aFolderOnDiskNamedLikeAnArchiveIsNotOne() throws {
        try withTemporaryFolder { temp in
            let backup = temp.appendingPathComponent("backup.zip", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: false)
            let url = URL(fileURLWithPath: backup.path, isDirectory: false)
            #expect(!url.hasDirectoryPath)
            let request = ServicesRequest(urls: [url])
            #expect(request.archives.isEmpty)
            #expect(request.items == [url])
        }
    }

    /// A symlink is classed by what it points to: a link to a folder is a folder, a link to an
    /// archive is an archive.
    @Test func aSymlinkIsWhatItPointsTo() throws {
        try withTemporaryFolder { temp in
            let folder = temp.appendingPathComponent("Photos", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let zip = temp.appendingPathComponent("real.zip")
            try Data("PK".utf8).write(to: zip)
            let toFolder = temp.appendingPathComponent("link.zip")
            let toZip = temp.appendingPathComponent("other.zip")
            try FileManager.default.createSymbolicLink(at: toFolder, withDestinationURL: folder)
            try FileManager.default.createSymbolicLink(at: toZip, withDestinationURL: zip)
            let request = ServicesRequest(urls: [toFolder, toZip])
            #expect(request.archives == [toZip])
            #expect(request.items == [toFolder, toZip])
        }
    }

    /// A fresh folder, removed when `body` ends.
    private func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServicesRequestTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try body(temp)
    }

    @Test func partsOfASplitArchiveAreOneJob() {
        let request = ServicesRequest(urls: urls(["Photos.zip.002", "Photos.zip.001", "notes.txt"]))
        #expect(request.archives == urls(["Photos.zip.001"]))
        #expect(request.items.count == 3)
    }

    @Test func eachSplitSetIsItsOwnJob() {
        let request = ServicesRequest(urls: urls([
            "s7.7z.003", "s7.7z.001", "span.zip", "span.z02", "span.z01",
            "Movie.part2.rar", "Movie.part1.rar", "Other.7z.001",
        ]))
        #expect(request.archives == urls(["s7.7z.001", "span.z01", "Movie.part1.rar", "Other.7z.001"]))
    }

    /// Part names and set names match ignoring case, as on the default volumes.
    @Test func partsAndSetsMatchIgnoringCase() {
        #expect(ServicesRequest(urls: urls(["Movie.PART2.RAR", "Movie.PART1.RAR"])).archives
            == urls(["Movie.PART1.RAR"]))
        #expect(ServicesRequest(urls: urls(["Photos.zip.002", "photos.ZIP.001"])).archives
            == urls(["photos.ZIP.001"]))
        #expect(ServicesRequest(urls: urls(["Span.ZIP", "span.Z02", "SPAN.z01"])).archives
            == urls(["SPAN.z01"]))
    }

    /// The old RAR scheme: "x.rar" is the first part, then "x.r00", "x.r01"…; one job, at "x.rar".
    @Test func oldStyleRarVolumesAreOneJob() {
        #expect(ServicesRequest(urls: urls(["x.r01", "x.rar", "x.r00", "notes.txt"])).archives == urls(["x.rar"]))
        #expect(ServicesRequest(urls: urls(["y.R00", "Y.RAR"])).archives == urls(["Y.RAR"]))
        // Without "x.rar", the lowest part stands for the set (Kernir opens the set from any part).
        #expect(ServicesRequest(urls: urls(["z.r01", "z.r00"])).archives == urls(["z.r00"]))
        // "x.part1.rar" is not the first part of an old-style "x" set.
        #expect(ServicesRequest(urls: urls(["v.part1.rar", "v.r00"])).archives == urls(["v.part1.rar", "v.r00"]))
    }

    /// Only parts of a split set group: a plain "x.zip" next to "x.zip.001" is its own archive.
    @Test func aPlainArchiveBesideASplitSetStaysSeparate() {
        let request = ServicesRequest(urls: urls(["x.zip", "x.zip.001", "x.zip.002"]))
        #expect(request.archives == urls(["x.zip", "x.zip.001"]))
    }

    /// The same set name in two folders is two sets.
    @Test func setsInDifferentFoldersStaySeparate() {
        let other = URL(fileURLWithPath: "/Users/u/Desktop/Photos.zip.001")
        let request = ServicesRequest(urls: urls(["Photos.zip.001"]) + [other])
        #expect(request.archives == urls(["Photos.zip.001"]) + [other])
    }

    /// Extract Here takes .whl and .jar; the other zip-based packages
    /// open in Kernir, but Extract Here leaves them alone.
    @Test func wheelsAndJarsAreExtractedOtherPackagesAreNot() {
        let names = ["tool.whl", "app.jar", "LIB.JAR", "game.apk", "site.war", "pkg.nupkg", "addon.xpi", "ext.vsix"]
        let request = ServicesRequest(urls: urls(names))
        #expect(request.archives == urls(["tool.whl", "app.jar", "LIB.JAR"]))
        #expect(request.items.count == names.count)
    }

    /// The open routing: every document Kernir opens, packages too (a viewer only), opens;
    /// plain files and folders, even one named like an archive, are compressed. A split part opens
    /// only with a tag Info.plist declares (.r00…r99, .001…999, .z01…z99): NSDocumentController
    /// has no class for ".s01" or ".000", which KernirCore and Extract Here still read as parts.
    @Test func opensInKernirTakesArchivesAndEveryPackage() throws {
        let opened = ["a.zip", "A.ZIP", "b.tar.gz", "c.7z", "d.rar", "Photos.zip.001", "x.part2.rar",
                      "set.7z.999", "span.z01", "span.z99",
                      "tool.whl", "app.jar", "game.apk", "site.war", "pkg.nupkg", "addon.xpi", "ext.vsix"]
        for url in urls(opened) { #expect(ServicesRequest.opensInKernir(url), "\(url.lastPathComponent)") }
        let undeclared = urls(["old.s01", "old.y99", "set.7z.000"])
        for url in undeclared { #expect(!ServicesRequest.opensInKernir(url), "\(url.lastPathComponent)") }
        #expect(ServicesRequest(urls: undeclared).archives.count == 2, "Extract Here takes both sets")
        let plain = urls(["notes.txt", "photo.jpg", "README"])
            + [folder.appendingPathComponent("Photos", isDirectory: true),
               folder.appendingPathComponent("backup.zip", isDirectory: true)]
        for url in plain { #expect(!ServicesRequest.opensInKernir(url), "\(url.lastPathComponent)") }
        // A symlink is what it points to: a link to a folder is a folder, named like an archive or not.
        try withTemporaryFolder { temp in
            let target = temp.appendingPathComponent("Photos", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            for name in ["link.zip", "link"] {
                let link = temp.appendingPathComponent(name)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                #expect(!ServicesRequest.opensInKernir(link), "\(name) -> folder")
            }
        }
    }

    /// A file's own type decides (its content type, a symlink's target's), the extension only
    /// for a URL with no file: an extensionless link to a ZIP opens, a ".zip" link to text doesn't.
    @Test func opensInKernirReadsTheFilesOwnType() throws {
        try withTemporaryFolder { temp in
            let zip = temp.appendingPathComponent("a.zip")
            let text = temp.appendingPathComponent("notes.txt")
            try Data("PK".utf8).write(to: zip)
            try Data("notes".utf8).write(to: text)
            let toZip = temp.appendingPathComponent("link")
            let toText = temp.appendingPathComponent("text-link.zip")
            try FileManager.default.createSymbolicLink(at: toZip, withDestinationURL: zip)
            try FileManager.default.createSymbolicLink(at: toText, withDestinationURL: text)
            #expect(ServicesRequest.opensInKernir(zip))
            #expect(!ServicesRequest.opensInKernir(text))
            #expect(ServicesRequest.opensInKernir(toZip))
            #expect(!ServicesRequest.opensInKernir(toText))
        }
    }

    @Test func nonFileURLsAndDuplicatesAreDropped() throws {
        let zip = folder.appendingPathComponent("a.zip")
        let web = try #require(URL(string: "https://example.com/a.zip"))
        let again = URL(fileURLWithPath: "/Users/u/Downloads/../Downloads/a.zip")
        let request = ServicesRequest(urls: [zip, web, again])
        #expect(request.items == [zip])
        #expect(request.archives == [zip])
    }

    @Test func nothingReceivedIsAnEmptyRequest() {
        let request = ServicesRequest(urls: [])
        #expect(request.items.isEmpty)
        #expect(request.archives.isEmpty)
    }
}

/// Hosted in Lutik.app (Bundle.main is the app, so NSDocumentController knows the Info.plist
/// document types); skipped otherwise. Run with `-only-testing:KernirMacTests/OpensInKernirHostedTests`.
@Suite(.enabled(if: Bundle.main.bundleIdentifier?.hasPrefix("com.kernir.app") == true))
@MainActor struct OpensInKernirHostedTests {
    /// `opensInKernir` is the app's document types as NSDocumentController judges them, whatever
    /// Launch Services makes of each tag: an extension opens exactly when the controller has a
    /// document class for its type (declared split tags open; ".s01", ".000", plain files do not).
    @Test func opensInKernirMatchesTheDocumentControllersClasses() {
        for ext in ["zip", "7z", "rar", "r01", "001", "s01", "000", "txt"] {
            let url = URL(fileURLWithPath: "/Users/u/Downloads/sample.\(ext)")
            let type = UTType(filenameExtension: ext)
            let hasClass = type.flatMap { NSDocumentController.shared.documentClass(forType: $0.identifier) } != nil
            #expect(ServicesRequest.opensInKernir(url) == hasClass, ".\(ext) (\(type?.identifier ?? "no type"))")
        }
    }
}
