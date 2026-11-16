#if os(macOS)
import Foundation
import Testing

/// Builds .7z fixtures with the 7-Zip command line tool (DataSafetyTests' `Tool.sevenZip`: 7zz first).
enum SevenZip {
    static var tool: URL? { Tool.sevenZip.map { URL(fileURLWithPath: $0) } }

    /// The tool, or nil when it is missing and interop is optional. With KERNIR_REQUIRE_INTEROP=1 a missing
    /// tool is a failure. Callers return early on nil.
    static func required(sourceLocation: SourceLocation = #_sourceLocation) throws -> URL? {
        guard Tool.interopRequired else { return tool }
        let url: URL = try #require(tool, "7-Zip is not installed (KERNIR_REQUIRE_INTEROP=1)",
                                    sourceLocation: sourceLocation)
        return url
    }

    /// Writes `files` (keys ending in "/" are empty directories) into a new temp dir and runs
    /// `7zz a -t7z -bd -y <args> name <top-level names>` there. The locale is UTF-8, so 7-Zip reads
    /// non-ASCII passwords from the arguments as Unicode.
    static func make(_ name: String, files: [String: Data], args: [String]) throws -> URL {
        guard let tool else { throw Fixtures.ToolFailure(description: "7-Zip is not installed") }
        let dir = Fixtures.tempDir()
        Fixtures.makeFiles(files, in: dir)
        let top = Set(files.keys.map { $0.split(separator: "/").first.map(String.init) ?? $0 }).sorted()
        try Fixtures.run(tool.path, ["a", "-t7z", "-bd", "-y"] + args + [name] + top, cwd: dir,
                         env: ["LC_ALL": "en_US.UTF-8"])
        return dir.appendingPathComponent(name)
    }
}
#endif
