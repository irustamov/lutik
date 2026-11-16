import Foundation
import KernirCore
import os

/// Puts one small sample archive into the app's Documents on the first launch of an install.
///
/// iOS hides an app's folder from Files (On My iPad) and from the document browser's locations while
/// the app's Documents is empty, so a new install would show no way to its own folder. The sample
/// (a zip with a short read-me) makes the folder appear and says how to open archives. It is made
/// once: the flag is set when it is written, or when Documents already holds something the user
/// can see, and a user who deletes the sample never gets it back. Failures are logged only.
enum SampleArchiveSeeder {
    private static let logger = Logger(subsystem: "com.kernir.app", category: "sample-seed")

    /// The `UserDefaults` flag: set once the sample was written or Documents had content of its own.
    static let seededKey = "SampleArchiveSeeded"

    /// Seeds the app's real Documents, off the main thread, unless a test drives the launch.
    static func seedAtLaunch() {
        let info = ProcessInfo.processInfo
        if isTestLaunch(arguments: info.arguments, environment: info.environment) { return }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let appName = Self.appName
        Task.detached(priority: .utility) {
            await seedIfNeeded(documents: documents, defaults: .standard, appName: appName)
        }
    }

    /// True when a test launched the app: the DEBUG fixture hook (it sets Documents up itself), a
    /// unit-test host (XCTest's environment), or a launch by Xcode's build tool, which is what runs
    /// every XCUITest on the simulator (xcodebuild exports `XCODE_SCHEME_NAME` and
    /// `__XCODE_BUILT_PRODUCTS_DIR_PATHS` to the app; a launch from the Home Screen or `simctl launch`
    /// has neither), so screenshots and UI tests see the same Documents as without the sample. The
    /// test manager's `TESTMANAGERD_*` variables are no marker: the simulator exports them to every app.
    static func isTestLaunch(arguments: [String], environment: [String: String]) -> Bool {
        arguments.contains("-KernirOpenFixture")
            || environment.keys.contains {
                $0.hasPrefix("XCTest") || $0 == "XCODE_SCHEME_NAME" || $0 == "__XCODE_BUILT_PRODUCTS_DIR_PATHS"
            }
    }

    /// The display name shown under the app's icon.
    static var appName: String {
        let info = Bundle.main
        return (info.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (info.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    /// Writes the sample into `documents` when `defaults` has no flag and `documents` holds no visible
    /// item other than "Inbox". Returns the sample's URL when it wrote one.
    @discardableResult
    static func seedIfNeeded(documents: URL, defaults: UserDefaults, appName: String) async -> URL? {
        guard !defaults.bool(forKey: seededKey) else { return nil }
        do {
            let items = try FileManager.default.contentsOfDirectory(
                at: documents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            if items.contains(where: { $0.lastPathComponent != "Inbox" }) {
                defaults.set(true, forKey: seededKey)
                return nil
            }
            let url = documents.appendingPathComponent(sampleName + ".zip")
            try await writeSample(to: url, appName: appName)
            defaults.set(true, forKey: seededKey)
            logger.info("Seeded \(url.lastPathComponent, privacy: .public)")
            return url
        } catch {
            logger.error("Cannot seed the sample: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The sample's name without the extension.
    static var sampleName: String {
        String(localized: "SampleArchive.name", defaultValue: "Sample Archive",
               comment: "File name of the sample archive put into the app's folder on first launch, without the extension (it becomes “Sample Archive.zip”). Avoid “/” and “:”.")
    }

    /// The read-me's name inside the sample, without the extension.
    static var readMeName: String {
        String(localized: "SampleArchive.readMeName", defaultValue: "Read Me",
               comment: "Name of the text file inside the sample archive, without the extension (it becomes “Read Me.txt”). Avoid “/” and “:”.")
    }

    /// The read-me's text: how to open an archive here.
    static func readMeText(appName: String) -> String {
        let lines = [
            String(format: String(localized: "SampleArchive.line1 %@", defaultValue: "Welcome to %@.",
                                  comment: "First line of the sample archive's read-me. %@ = the app's name."), appName),
            String(format: String(localized: "SampleArchive.line2 %@",
                                  defaultValue: "In Files, touch and hold an archive, then tap Share and choose %@.",
                                  comment: "Second line of the sample archive's read-me. %@ = the app's name."), appName),
            String(format: String(localized: "SampleArchive.line3 %@",
                                  defaultValue: "Or open %@ and browse to the archive.",
                                  comment: "Third line of the sample archive's read-me. %@ = the app's name."), appName)]
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the zip in a temporary folder, then moves it into place, so Files never lists a
    /// half-written sample.
    private static func writeSample(to url: URL, appName: String) async throws {
        let fileManager = FileManager.default
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("SampleArchive-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }
        let readMe = work.appendingPathComponent("readme.txt")
        try Data(readMeText(appName: appName).utf8).write(to: readMe)
        let changes = ArchiveChangeSet(additions: [
            .init(sourceURL: readMe, destinationDirectory: "",
                  archiveName: readMeName + ".txt")])
        let staged = work.appendingPathComponent("sample.zip")
        try await ArchiveWriter.write(source: nil, changes: changes, format: .zip, to: staged)
        try fileManager.moveItem(at: staged, to: url)
    }
}
