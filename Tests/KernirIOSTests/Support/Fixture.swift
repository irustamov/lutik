import Foundation

/// Files from the repository's `Fixtures` folder, copied so tests never touch the originals.
enum Fixture {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // KernirIOSTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("Fixtures", isDirectory: true)

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
