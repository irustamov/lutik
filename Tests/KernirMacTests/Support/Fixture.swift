import Foundation

/// Files from the repository's `Fixtures` folder (as in KernirIOSTests), copied so tests never
/// touch the originals. `KERNIR_FIXTURES` overrides the folder: in a package that links this file
/// from elsewhere, `#filePath` is the link's path, not the repository's.
enum Fixture {
    static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["KERNIR_FIXTURES"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // KernirMacTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Fixtures", isDirectory: true)
    }()

    /// The fixtures can be read here. A sandboxed hosted test run can't reach the repository, so
    /// tests that need them are skipped there (`.enabled(if: Fixture.isReadable)`).
    static var isReadable: Bool {
        FileManager.default.isReadableFile(atPath: root.appendingPathComponent("manifest.json").path)
    }

    /// Copies `Fixtures/<relativePath>` into a fresh temporary folder and returns the copy.
    /// `name` renames the copy, for example to give it another file type.
    static func copy(_ relativePath: String, as name: String? = nil) throws -> URL {
        let source = root.appendingPathComponent(relativePath)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(name ?? source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }
}
