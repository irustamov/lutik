import CryptoKit
import Foundation
import Testing
@testable import Kernir

/// FileDigest: the streaming SHA-256 of the archive file.
struct FileDigestTests {
    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let file: String
            let fileSha256: String
        }
        let fixtures: [Entry]
    }

    /// Collects progress values from the hashing task's thread.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func add(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
        var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// Lets the progress callback cancel the task that was started after the callback was made.
    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<String, any Error>?
        private var requested = false
        func set(_ task: Task<String, any Error>) {
            lock.lock(); self.task = task; let cancelNow = requested; lock.unlock()
            if cancelNow { task.cancel() }
        }
        func cancel() {
            lock.lock(); requested = true; let task = task; lock.unlock()
            task?.cancel()
        }
    }

    @discardableResult
    private func withTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileDigest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    /// A file of `mebibytes` MiB of a repeating, non-constant pattern.
    private func makeFile(in directory: URL, mebibytes: Int) throws -> URL {
        let url = directory.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let block = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
        for _ in 0..<mebibytes { try handle.write(contentsOf: block) }
        return url
    }

    @Test(.enabled(if: Fixture.isReadable))
    func everyFixtureMatchesItsManifestDigest() async throws {
        let data = try Data(contentsOf: Fixture.root.appendingPathComponent("manifest.json"))
        let entries = try JSONDecoder().decode(Manifest.self, from: data).fixtures
        #expect(!entries.isEmpty)
        for entry in entries {
            let url = Fixture.root.appendingPathComponent(entry.file)
            let digest = try await FileDigest.sha256(of: url)
            #expect(digest == entry.fileSha256, "\(entry.file)")
        }
    }

    @Test func emptyFile() async throws {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("empty")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            let digest = try await FileDigest.sha256(of: url)
            #expect(digest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        }
    }

    @Test func multiChunkFileMatchesCryptoKit() async throws {
        try await withTempDirectory { directory in
            let url = try makeFile(in: directory, mebibytes: 3)
            let expected = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            #expect(try await FileDigest.sha256(of: url) == expected)
        }
    }

    @Test func missingFileThrows() async throws {
        try await withTempDirectory { directory in
            await #expect(throws: (any Error).self) {
                _ = try await FileDigest.sha256(of: directory.appendingPathComponent("nope"))
            }
        }
    }

    @Test func cancelledBeforeStartingThrowsCancellationError() async throws {
        try await withTempDirectory { directory in
            let url = try makeFile(in: directory, mebibytes: 1)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await FileDigest.sha256(of: url)
            }
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
    }

    @Test func cancelledWhileHashingThrowsCancellationError() async throws {
        try await withTempDirectory { directory in
            let url = try makeFile(in: directory, mebibytes: 64)
            let box = CancelBox()
            let task = Task { try await FileDigest.sha256(of: url, progress: { _ in box.cancel() }) }
            box.set(task)
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
    }

    @Test func progressIncreasesAndEndsAtOne() async throws {
        try await withTempDirectory { directory in
            let url = try makeFile(in: directory, mebibytes: 5)
            let recorder = Recorder()
            _ = try await FileDigest.sha256(of: url, progress: { recorder.add($0) })
            let values = recorder.all
            #expect(values.last == 1.0)
            #expect(values.filter { $0 == 1.0 }.count == 1)
            #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
            #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
        }
    }

    @Test func emptyFileReportsOne() async throws {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("empty")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            let recorder = Recorder()
            _ = try await FileDigest.sha256(of: url, progress: { recorder.add($0) })
            #expect(recorder.all == [1.0])
        }
    }

    @Test func fileChangingWhileHashingThrowsFileChanged() async throws {
        try await withTempDirectory { directory in
            let url = try makeFile(in: directory, mebibytes: 4)
            await #expect(throws: FileDigest.Error.fileChanged) {
                _ = try await FileDigest.sha256(of: url, progress: { _ in
                    if let handle = try? FileHandle(forWritingTo: url) {
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: Data([0x42]))
                        try? handle.close()
                    }
                })
            }
        }
    }

    @Test func fifoThrowsNotRegularFileInsteadOfBlocking() async throws {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("pipe")
            #expect(mkfifo(url.path, 0o600) == 0)
            await #expect(throws: FileDigest.Error.notRegularFile) {
                _ = try await FileDigest.sha256(of: url)
            }
        }
    }

    @Test func directoryThrowsNotRegularFile() async throws {
        try await withTempDirectory { directory in
            await #expect(throws: FileDigest.Error.notRegularFile) {
                _ = try await FileDigest.sha256(of: directory)
            }
        }
    }
}
