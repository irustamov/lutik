import Testing
import AppKit
import KernirCore
@testable import Kernir

/// Finder Services: `ServicesProvider` reads the file URLs a Service sends, sorts
/// them with `ServicesRequest` and hands each job on. Each test uses a pasteboard of its own
/// (never the general one), released at the end. Runs without the app; only
/// `theAppRegistersTheProviderAtLaunch` needs Lutik.app as the test host.
@MainActor
struct ServicesProviderTests {
    @MainActor private final class Jobs {
        var submitted: [ServicesJob] = []
    }

    @MainActor private final class Setting {
        var format = ArchiveFormat.zip
    }

    private let jobs = Jobs()

    private func provider(format: ArchiveFormat = .zip) -> ServicesProvider {
        let jobs = jobs
        return ServicesProvider(compressFormat: { format }, submit: { jobs.submitted.append($0) })
    }

    /// A pasteboard of its own holding `objects`, released after `body`.
    private func withPasteboard(_ objects: [any NSPasteboardWriting], _ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        if !objects.isEmpty { #expect(pasteboard.writeObjects(objects)) }
        try body(pasteboard)
    }

    /// Plain files `names` in a fresh folder, removed after `body`.
    private func withFiles(_ names: [String], _ body: ([URL]) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServicesProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try names.map { name in
            let file = folder.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            return file
        }
        try body(files)
    }

    private static func paths(_ urls: [URL]) -> [String] { urls.map(\.standardizedFileURL.path) }

    private static func paths(_ job: ServicesJob) -> [String] {
        switch job {
        case let .extractHere(archive): paths([archive])
        case let .compress(items, _): paths(items)
        }
    }

    // MARK: The NSServices messages

    @Test func theMessagesAreTheTwoServices() {
        #expect(ServicesProvider.messages == ["extractHere", "compress"])
    }

    // MARK: Reading the pasteboard

    /// File URLs only, in order: a web link and plain text on the pasteboard are ignored.
    @Test func readsTheFileURLsOnly() throws {
        try withFiles(["a.txt", "b.txt"]) { files in
            let text = NSPasteboardItem()
            text.setString("/etc/hosts", forType: .string)
            let objects: [any NSPasteboardWriting] = [files[0] as NSURL, URL(string: "https://kernir.app/x.zip")! as NSURL,
                                                       text, files[1] as NSURL]
            withPasteboard(objects) { pasteboard in
                #expect(Self.paths(ServicesProvider.fileURLs(on: pasteboard)) == Self.paths(files))
            }
        }
    }

    /// Finder may send file-reference URLs (`file:///.file/id=…`): they come back as path URLs,
    /// so the archive is recognized by its extension and the right job is made.
    @Test(.enabled(if: Fixture.isReadable))
    func fileReferenceURLsBecomePathURLs() throws {
        let archive = try Fixture.copy("showcase/project.zip")
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        // Through the selector: Swift's `fileReferenceURL()` bridges back to a path URL.
        let reference = try #require((archive as NSURL).perform(#selector(NSURL.fileReferenceURL))?
            .takeUnretainedValue() as? NSURL)
        #expect(reference.isFileReferenceURL())
        #expect(reference.absoluteString?.hasPrefix("file:///.file/id=") == true)
        try withPasteboard([reference]) { pasteboard in
            // The board holds the reference itself, as Finder may send it.
            #expect(pasteboard.string(forType: .fileURL)?.hasPrefix("file:///.file/id=") == true)
            let urls = ServicesProvider.fileURLs(on: pasteboard)
            try #require(urls.count == 1)
            #expect(urls[0].pathExtension == "zip")
            #expect(!urls[0].path.hasPrefix("/.file/"))
            #expect(Self.paths(urls) == Self.paths([archive]))
            var error: NSString?
            provider().extractHere(pasteboard, userData: nil, error: &error)
            #expect(error == nil)
            #expect(jobs.submitted.map(Self.paths) == [Self.paths([archive])])
        }
    }

    // MARK: Extract Here

    @Test(.enabled(if: Fixture.isReadable))
    func extractHereSendsEachArchiveToAJobOfItsOwn() throws {
        let archives = [try Fixture.copy("showcase/project.zip"), try Fixture.copy("zip/macos-finder.zip")]
        defer { for archive in archives { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) } }
        try withPasteboard(archives.map { $0 as NSURL }) { pasteboard in
            var error: NSString?
            provider().extractHere(pasteboard, userData: nil, error: &error)
            #expect(error == nil)
            let submitted = jobs.submitted
            try #require(submitted.count == 2)
            for (job, archive) in zip(submitted, archives) {
                guard case .extractHere = job else { Issue.record("not Extract Here: \(job)"); continue }
                #expect(Self.paths(job) == Self.paths([archive]))
            }
        }
    }

    /// Items that are not archives are left alone; the archives among them are extracted.
    @Test func extractHereSkipsWhatIsNotAnArchive() throws {
        try withFiles(["notes.txt", "photos.zip"]) { files in
            withPasteboard(files.map { $0 as NSURL }) { pasteboard in
                var error: NSString?
                provider().extractHere(pasteboard, userData: nil, error: &error)
                #expect(error == nil)
                #expect(jobs.submitted.map(Self.paths) == [Self.paths([files[1]])])
            }
        }
    }

    @Test func extractHereWithNoArchiveRefusesWithAMessage() throws {
        try withFiles(["notes.txt"]) { files in
            withPasteboard(files.map { $0 as NSURL }) { pasteboard in
                var error: NSString?
                provider().extractHere(pasteboard, userData: nil, error: &error)
                #expect(jobs.submitted.isEmpty)
                #expect((error as String?)?.isEmpty == false)
            }
        }
    }

    /// The parts of a split set are one job: its first part, which opens the whole set.
    @Test func aSplitSetIsOneExtractHereJob() throws {
        let folder = URL(fileURLWithPath: "/Users/u/Downloads", isDirectory: true)
        let parts = ["Photos.zip.002", "Photos.zip.001"].map { folder.appendingPathComponent($0) }
        let jobs = try ServicesProvider.jobs(for: .extractHere, urls: parts, compressFormat: .zip)
        #expect(jobs == [.extractHere(parts[1])])
    }

    // MARK: Compress

    /// Every item goes into one archive, in the format Settings > Finder chose.
    @Test func compressSendsEveryItemToOneJobInTheChosenFormat() throws {
        try withFiles(["a.txt", "b.zip"]) { files in
            withPasteboard(files.map { $0 as NSURL }) { pasteboard in
                var error: NSString?
                provider(format: .sevenZip).compress(pasteboard, userData: nil, error: &error)
                #expect(error == nil)
                let submitted = jobs.submitted
                #expect(submitted.count == 1)
                guard case let .compress(_, format)? = submitted.first else {
                    Issue.record("not Compress: \(submitted)")
                    return
                }
                #expect(format == .sevenZip)
                #expect(submitted.map(Self.paths) == [Self.paths(files)])
            }
        }
    }

    /// The format is read when the Service runs, so a change in Settings counts at once.
    @Test func compressReadsTheFormatEachTime() throws {
        let setting = Setting()
        let jobs = jobs
        let provider = ServicesProvider(compressFormat: { setting.format }, submit: { jobs.submitted.append($0) })
        try withFiles(["a.txt"]) { files in
            try withPasteboard(files.map { $0 as NSURL }) { pasteboard in
                var error: NSString?
                provider.compress(pasteboard, userData: nil, error: &error)
                setting.format = .tarGzip
                provider.compress(pasteboard, userData: nil, error: &error)
                let formats = try jobs.submitted.map { job in
                    guard case let .compress(_, format) = job else { throw Unexpected(job: job) }
                    return format
                }
                #expect(formats == [.zip, .tarGzip])
            }
        }
    }

    private struct Unexpected: Error { let job: ServicesJob }

    // MARK: Nothing usable

    @Test(arguments: ["extractHere", "compress"])
    func anEmptyPasteboardRefusesWithAMessage(message: String) {
        withPasteboard([]) { pasteboard in
            var error: NSString?
            let provider = provider()
            if message == "extractHere" {
                provider.extractHere(pasteboard, userData: nil, error: &error)
            } else {
                provider.compress(pasteboard, userData: nil, error: &error)
            }
            #expect(jobs.submitted.isEmpty)
            #expect((error as String?)?.isEmpty == false)
        }
    }

    @Test func refusalsSayWhatWasMissing() {
        #expect(throws: ServicesProvider.Refusal.noFiles) {
            try ServicesProvider.jobs(for: .compress, urls: [], compressFormat: .zip)
        }
        #expect(throws: ServicesProvider.Refusal.noFiles) {
            try ServicesProvider.jobs(for: .extractHere, urls: [URL(string: "https://kernir.app/x.zip")!],
                                      compressFormat: .zip)
        }
        #expect(throws: ServicesProvider.Refusal.noArchives) {
            try ServicesProvider.jobs(for: .extractHere, urls: [URL(fileURLWithPath: "/tmp/notes.txt")],
                                      compressFormat: .zip)
        }
        #expect(ServicesProvider.Refusal.noFiles.message != ServicesProvider.Refusal.noArchives.message)
    }

    // MARK: Launch

    /// The Services quit rule reads this: a launch only to run a Service is not the default launch.
    @Test func aLaunchIsDefaultUnlessAppKitSaysOtherwise() {
        #expect(ServicesProvider.isDefaultLaunch(nil))
        #expect(ServicesProvider.isDefaultLaunch([:]))
        #expect(ServicesProvider.isDefaultLaunch([NSApplication.launchIsDefaultUserInfoKey: NSNumber(value: true)]))
        #expect(!ServicesProvider.isDefaultLaunch([NSApplication.launchIsDefaultUserInfoKey: NSNumber(value: false)]))
    }

    /// Hosted in Lutik.app (TEST_HOST): the app has registered its provider. Skipped when not
    /// hosted (the scratch SwiftPM run).
    @Test(.enabled(if: Bundle.main.bundleIdentifier?.hasPrefix("com.kernir.app") == true))
    func theAppRegistersTheProviderAtLaunch() {
        #expect(NSApp.servicesProvider is ServicesProvider)
    }
}
