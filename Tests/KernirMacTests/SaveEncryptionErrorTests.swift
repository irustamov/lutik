import Testing
import Foundation
@testable import Kernir
import KernirCore

/// A save whose format can't carry the archive's encryption (⌘S on an encrypted
/// zip whose file is named .tar) says so in save words. The open-side text of
/// `ArchiveError.unsupportedEncryption` ("Encrypted TAR archives aren't supported yet. Decrypt it
/// with another app first, …") stays for opening and reading (`archiveErrorsHaveUserFacingText`).
struct SaveEncryptionErrorTests {
    @Test func theRefusalSaysWhatTheSaveCantDo() throws {
        let reported = SaveEncryptionError.reporting(ArchiveError.unsupportedEncryption(.tar),
                                                     encryption: .zipCrypto, format: .tar)
        let error = try #require(reported as? SaveEncryptionError)
        #expect(error == SaveEncryptionError(format: .tar))
        #expect(error.errorDescription == "TAR archives can't be saved with this encryption.")
        #expect(error.failureReason == error.errorDescription)
        #expect(error.recoverySuggestion == "Use Save As to save it as ZIP or 7z, or without a password.")
    }

    /// NSDocument's save alert reads the failure reason and the recovery suggestion, as the open
    /// alert does: both are the save's.
    @Test func theSaveAlertGetsTheSaveText() {
        let error = SaveEncryptionError.reporting(ArchiveError.unsupportedEncryption(.tarGzip),
                                                  encryption: .aes256, format: .tarGzip) as NSError
        #expect(error.localizedFailureReason == "TAR.GZ archives can't be saved with this encryption.")
        #expect(error.localizedRecoverySuggestion == "Use Save As to save it as ZIP or 7z, or without a password.")
    }

    /// A scheme 7z has no writer for is the save's refusal too.
    @Test(arguments: [ArchiveEncryption.zipCrypto, .aes128])
    func aSchemeTheFormatLacksIsTheSavesRefusal(_ encryption: ArchiveEncryption) {
        let reported = SaveEncryptionError.reporting(ArchiveError.unsupportedEncryption(.sevenZip),
                                                     encryption: encryption, format: .sevenZip)
        #expect(reported as? SaveEncryptionError == SaveEncryptionError(format: .sevenZip))
    }

    /// Not the save's refusal, so the open-side text stays: the archive's own data can't be decrypted
    /// while it is repacked (a zip with strong encryption, which zip's AES-256 doesn't explain), an
    /// error about another format than the one written, or a save that writes no encryption.
    @Test func otherEncryptionErrorsStayAsTheyAre() {
        let cases: [(ArchiveError, ArchiveEncryption, ArchiveFormat)] = [
            (.unsupportedEncryption(.zip), .aes256, .zip),
            (.unsupportedEncryption(.zip), .zipCrypto, .tar),
            (.unsupportedEncryption(.rar), .none, .zip),
            (.unsupportedEncryption(.tar), .none, .tar),
        ]
        for (error, encryption, format) in cases {
            let reported = SaveEncryptionError.reporting(error, encryption: encryption, format: format)
            #expect(reported as? ArchiveError == error)
        }
    }

    @Test func otherErrorsStayAsTheyAre() {
        let io = SaveEncryptionError.reporting(ArchiveError.io("disk full"), encryption: .zipCrypto, format: .tar)
        #expect(io as? ArchiveError == .io("disk full"))
        let cocoa = SaveEncryptionError.reporting(CocoaError(.fileWriteOutOfSpace), encryption: .aes256, format: .tar)
        #expect((cocoa as? CocoaError)?.code == .fileWriteOutOfSpace)
    }

    /// The live engine's refusal of an encrypted TAR is the one mapped, and it writes nothing.
    @Test func theLiveEnginesRefusalIsMapped() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveEncryptionErrorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved.tar")
        let options = ArchiveWriteOptions(encryption: .zipCrypto, password: "secret")

        var thrown: (any Error)?
        do {
            try await ArchiveEngine.live.write(nil, ArchiveChangeSet(), .tar, url, options, nil)
        } catch {
            thrown = error
        }
        let error = try #require(thrown)
        #expect(SaveEncryptionError.reporting(error, encryption: options.encryption, format: .tar)
                    as? SaveEncryptionError == SaveEncryptionError(format: .tar))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
