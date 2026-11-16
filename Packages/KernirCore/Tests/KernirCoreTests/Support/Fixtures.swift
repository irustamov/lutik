import Foundation
import CryptoKit

/// Path of the per-process temp parent, read by the `atexit` handler (a C function pointer cannot capture).
nonisolated(unsafe) private var runRootPath: UnsafeMutablePointer<CChar>?

enum Fixtures {
    struct ToolFailure: Error, CustomStringConvertible {
        let description: String
    }

    /// One parent per test process, `kernir-tests-<run-uuid>`, holding every `tempDir()`. An `atexit` handler
    /// removes it when the process ends, so a passing run leaves nothing and a crash or failing test leaves
    /// at most this one directory. Nothing is removed earlier, so a parallel test or an external tool
    /// (bsdtar, 7zz, unzip) never loses its directory.
    private static let runRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kernir-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        runRootPath = strdup(url.path)
        atexit { if let path = runRootPath { _ = try? FileManager.default.removeItem(atPath: String(cString: path)) } }
        return url
    }()

    static func tempDir() -> URL {
        let url = runRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Keys ending in `/` create empty directories.
    static func makeFiles(_ files: [String: Data], in dir: URL) {
        let fm = FileManager.default
        for (path, data) in files {
            if path.hasSuffix("/") {
                try? fm.createDirectory(at: dir.appendingPathComponent(path), withIntermediateDirectories: true)
            } else {
                let url = dir.appendingPathComponent(path)
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: data)
            }
        }
    }

    static func run(_ tool: String, _ args: [String], cwd: URL, env: [String: String] = [:]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = cwd
        if !env.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        }
        p.standardInput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ToolFailure(description: "\(tool) \(args.joined(separator: " ")) exited \(p.terminationStatus): \(String(decoding: data, as: UTF8.self))")
        }
    }

    static func bsdtar(_ args: [String], cwd: URL, env: [String: String] = [:]) throws {
        try run("/usr/bin/bsdtar", args, cwd: cwd, env: env)
    }

    static func archive(_ name: String, bsdtarArgs: [String], files: [String: Data]) throws -> URL {
        let dir = tempDir()
        makeFiles(files, in: dir)
        let top = Set(files.keys.map { $0.split(separator: "/").first.map(String.init) ?? $0 }).sorted()
        try bsdtar(["-cf", name] + bsdtarArgs + top, cwd: dir)
        return dir.appendingPathComponent(name)
    }

    static func sha256(_ url: URL) -> String {
        let data = (try? Data(contentsOf: url)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
