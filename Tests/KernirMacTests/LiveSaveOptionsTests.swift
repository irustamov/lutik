import Testing
import Foundation
@testable import Kernir
import KernirCore

/// Save options through the real engine (`ArchiveEngine.live`), without any UI.
struct LiveSaveOptionsTests {
    /// With `KERNIR_KEEP_LIVE_ZIP=1` (from xcodebuild: `TEST_RUNNER_KERNIR_KEEP_LIVE_ZIP=1`),
    /// `aes256ZipOpensWithItsPassword` keeps its ZIP here and prints the path, so `unzip -P pw -t`
    /// can check it from a shell. Overwritten on every such run; otherwise the ZIP is deleted.
    static let keptAES256ZipURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("KernirLiveSaveOptions-aes256.zip")
    private static let keepsAES256Zip = ProcessInfo.processInfo.environment["KERNIR_KEEP_LIVE_ZIP"] == "1"

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveSaveOptionsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("Kernir save options \(name)\n".utf8).write(to: url)
        return url
    }

    @Test func aes256ZipOpensWithItsPassword() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let added = try makeFile("hello.txt", in: directory)
        let engine = ArchiveEngine.live
        let url = Self.keepsAES256Zip ? Self.keptAES256ZipURL : directory.appendingPathComponent("aes256.zip")
        try? FileManager.default.removeItem(at: url)

        let options = ArchiveWriteOptions(encryption: .aes256, password: "pw")
        try await engine.write(nil, ArchiveChangeSet(additions: [.init(sourceURL: added, destinationDirectory: "")]),
                               .zip, url, options, nil)
        if Self.keepsAES256Zip { print("LiveSaveOptionsTests: AES-256 ZIP kept at \(url.path)") }

        let reader = try await engine.open(url, "pw")
        #expect(reader.entries.map(\.path) == ["hello.txt"])
        #expect(reader.isEncrypted)
        #expect(reader.encryption == .aes256)
    }

    /// A plain save (nil options) of a ZipCrypto ZIP stays ZipCrypto.
    @Test func plainRepackKeepsZipCrypto() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeFile("first.txt", in: directory)
        let second = try makeFile("second.txt", in: directory)
        let engine = ArchiveEngine.live
        let source = directory.appendingPathComponent("source.zip")
        let repacked = directory.appendingPathComponent("repacked.zip")

        try await engine.write(nil, ArchiveChangeSet(additions: [.init(sourceURL: first, destinationDirectory: "")]),
                               .zip, source, ArchiveWriteOptions(encryption: .zipCrypto, password: "pw"), nil)
        let reader = try await engine.open(source, "pw")
        #expect(reader.encryption == .zipCrypto)

        try await engine.write(reader, ArchiveChangeSet(additions: [.init(sourceURL: second, destinationDirectory: "")]),
                               .zip, repacked, nil, nil)

        let reopened = try await engine.open(repacked, "pw")
        #expect(Set(reopened.entries.map(\.path)) == ["first.txt", "second.txt"])
        #expect(reopened.encryption == .zipCrypto)
        // `encryption` is the strongest scheme across entries, so check each file: the added one too.
        let everyFileEncrypted = reopened.entries.filter { !$0.isDirectory }.allSatisfy { $0.isEncrypted }
        #expect(everyFileEncrypted)
        let withoutPassword = try await engine.open(repacked, nil)
        await #expect(throws: ArchiveError.passwordRequired) {
            _ = try await withoutPassword.extractToTemporaryFile("second.txt")
        }
    }
}
