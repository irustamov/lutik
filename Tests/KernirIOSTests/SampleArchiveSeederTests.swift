import Foundation
import KernirCore
import Testing
@testable import Kernir

/// The sample archive put into an empty Documents on the first launch (iOS hides an empty app folder
/// from Files). Each test passes its own Documents folder and defaults suite, so nothing touches the
/// host app's real Documents. Mutants it kills: no flag check, no flag set, "visible" counting hidden
/// files or Inbox, a zip that lacks the text, a second call that rewrites.
final class SampleArchiveSeederTests {
    private let documents: URL
    private let defaults: UserDefaults
    private let suite: String

    init() throws {
        documents = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernir-seed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        (defaults, suite) = makeTestDefaults("SampleArchiveSeederTests")
    }

    deinit {
        try? FileManager.default.removeItem(at: documents)
        removeTestDefaults(defaults, suite: suite)
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: documents.path).sorted()
    }

    @Test func seedsWhenEmptyAndFlagUnset() async throws {
        let url = await SampleArchiveSeeder.seedIfNeeded(documents: documents, defaults: defaults, appName: "Appy")
        #expect(url?.lastPathComponent == "Sample Archive.zip")
        #expect(try names() == ["Sample Archive.zip"])
        #expect(defaults.bool(forKey: SampleArchiveSeeder.seededKey))
    }

    @Test func notWhenFlagSet() async throws {
        defaults.set(true, forKey: SampleArchiveSeeder.seededKey)
        let url = await SampleArchiveSeeder.seedIfNeeded(documents: documents, defaults: defaults, appName: "Appy")
        #expect(url == nil)
        #expect(try names().isEmpty)
    }

    @Test func notWhenAVisibleFileExists() async throws {
        try Data("x".utf8).write(to: documents.appendingPathComponent("Mine.zip"))
        let url = await SampleArchiveSeeder.seedIfNeeded(documents: documents, defaults: defaults, appName: "Appy")
        #expect(url == nil)
        #expect(try names() == ["Mine.zip"])
        // The user has content of their own: deleting it later must not bring the sample.
        #expect(defaults.bool(forKey: SampleArchiveSeeder.seededKey))
    }

    @Test func hiddenFilesAndInboxDoNotCount() async throws {
        try Data().write(to: documents.appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: documents.appendingPathComponent("Inbox"),
                                                withIntermediateDirectories: true)
        let url = await SampleArchiveSeeder.seedIfNeeded(documents: documents, defaults: defaults, appName: "Appy")
        #expect(url != nil)
        #expect(try names() == [".hidden", "Inbox", "Sample Archive.zip"])
    }

    @Test func zipOpensWithTheReadMe() async throws {
        let url = try #require(
            await SampleArchiveSeeder.seedIfNeeded(documents: documents, defaults: defaults, appName: "Appy"))
        let reader = try await Archive.open(at: url)
        #expect(reader.format == .zip)
        #expect(reader.entries.map(\.path) == ["Read Me.txt"])
        let copy = try await reader.extractToTemporaryFile("Read Me.txt")
        defer { try? FileManager.default.removeItem(at: copy) }
        let text = try String(contentsOf: copy, encoding: .utf8)
        #expect(text == SampleArchiveSeeder.readMeText(appName: "Appy"))
        #expect(text.contains("Appy"))
        #expect(!text.contains("Kernir") && !text.contains("Lutik"))
        #expect(text.split(separator: "\n").count == 3)
    }

    @Test func secondCallDoesNothing() async throws {
        let first = await SampleArchiveSeeder.seedIfNeeded(documents: documents, defaults: defaults, appName: "Appy")
        let before = try Data(contentsOf: try #require(first))
        let second = await SampleArchiveSeeder.seedIfNeeded(documents: documents, defaults: defaults, appName: "Appy")
        #expect(second == nil)
        #expect(try names() == ["Sample Archive.zip"])
        #expect(try Data(contentsOf: documents.appendingPathComponent("Sample Archive.zip")) == before)
    }

    @Test func deletedSampleStaysDeleted() async throws {
        let url = try #require(
            await SampleArchiveSeeder.seedIfNeeded(documents: documents, defaults: defaults, appName: "Appy"))
        try FileManager.default.removeItem(at: url)
        #expect(await SampleArchiveSeeder.seedIfNeeded(documents: documents, defaults: defaults, appName: "Appy") == nil)
        #expect(try names().isEmpty)
    }

    @Test func testLaunchesAreRecognized() {
        #expect(SampleArchiveSeeder.isTestLaunch(arguments: ["Kernir", "-KernirOpenFixture", "/x"], environment: [:]))
        #expect(SampleArchiveSeeder.isTestLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "/x"]))
        #expect(SampleArchiveSeeder.isTestLaunch(arguments: [], environment: ["XCODE_SCHEME_NAME": "KernirIOS"]))
        #expect(SampleArchiveSeeder.isTestLaunch(arguments: [], environment: ["__XCODE_BUILT_PRODUCTS_DIR_PATHS": "/x"]))
        // The simulator exports these to every app, a plain launch included.
        #expect(!SampleArchiveSeeder.isTestLaunch(arguments: [], environment: ["TESTMANAGERD_SIM_SOCK": "/x"]))
        #expect(!SampleArchiveSeeder.isTestLaunch(arguments: ["Kernir"], environment: ["HOME": "/x", "PATH": "/bin"]))
    }
}
