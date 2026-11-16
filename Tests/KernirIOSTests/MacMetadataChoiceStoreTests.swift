import Foundation
import os
import Testing
@testable import Kernir

/// `MacMetadataChoiceStore`: the per-file Mac metadata answer on iOS (true is Remove). Each test has
/// defaults of its own (`makeTestDefaults`: the plist stays in the temporary folder) and a folder of its
/// own, so the tests run in parallel. Foundation only: the same file runs in a macOS SwiftPM
/// mirror.
struct MacMetadataChoiceStoreTests {
    /// A store in defaults of its own; `cleanUp()` removes them and the files.
    private struct TestStore {
        let suiteName: String
        let defaults: UserDefaults
        let store: MacMetadataChoiceStore
        let directory: URL

        init(capacity: Int = MacMetadataChoiceStore.defaultCapacity,
             identityOfFile: (@Sendable (String) -> MacMetadataChoiceStore.FileIdentity?)? = nil) throws {
            let made = makeTestDefaults("MacMetadataChoiceStoreTests")
            defaults = made.0
            suiteName = made.1
            if let identityOfFile {
                store = MacMetadataChoiceStore(defaults: defaults, capacity: capacity, identityOfFile: identityOfFile)
            } else {
                store = MacMetadataChoiceStore(defaults: defaults, capacity: capacity)
            }
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacMetadataChoiceStoreTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        /// Another store on the same defaults, as after relaunching the app.
        func reloaded() -> MacMetadataChoiceStore {
            MacMetadataChoiceStore(defaults: UserDefaults(suiteName: suiteName)!, capacity: store.capacity)
        }

        var isEmpty: Bool { defaults.object(forKey: MacMetadataChoiceStore.defaultsKey) == nil }

        func makeFile(_ name: String, contents: String = "zip") throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }

        /// A safe save, as UIDocument does: a new file swapped in (new file ID, same creation date).
        func safeSave(_ url: URL) throws {
            let written = try makeFile("written-\(UUID().uuidString).zip", contents: "saved")
            _ = try FileManager.default.replaceItemAt(url, withItemAt: written)
        }

        /// Another archive later saved under the same name: new file ID, new creation date.
        func replaceWithAnotherFile(_ url: URL) throws {
            try FileManager.default.removeItem(at: url)
            Thread.sleep(forTimeInterval: 0.01)
            try Data("another archive".utf8).write(to: url)
        }

        func cleanUp() {
            removeTestDefaults(defaults, suite: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fileID(_ url: URL) throws -> UInt64? {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileIdentifierKey]).fileIdentifier
    }

    @Test(arguments: [false, true])
    func remembersTheAnswerAcrossStoreInstances(_ strips: Bool) throws {
        let test = try TestStore()
        defer { test.cleanUp() }
        let archive = try test.makeFile("a.zip")
        let other = try test.makeFile("b.zip")

        #expect(test.store.choice(for: archive) == nil)
        test.store.remember(strips, for: archive)

        #expect(test.store.choice(for: archive) == strips)
        #expect(test.reloaded().choice(for: archive) == strips)
        #expect(test.store.choice(for: other) == nil)
        // The same file however its path is spelled: dotted, through a linked folder, or with or without
        // /private (/var and /tmp are links).
        #expect(test.store.choice(for: test.directory.appendingPathComponent("sub/../a.zip")) == strips)
        let linked = test.directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: test.directory)
        #expect(test.store.choice(for: linked.appendingPathComponent("a.zip")) == strips)
        let path = archive.path
        let otherSpelling = path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path
        if FileManager.default.fileExists(atPath: otherSpelling) {  // not on the simulator's paths
            #expect(test.store.choice(for: URL(fileURLWithPath: otherSpelling)) == strips)
        }
    }

    /// A safe save keeps the creation date and changes the file ID: Keep still applies.
    @Test func keepMatchesByCreationDateAfterSafeSave() throws {
        let test = try TestStore()
        defer { test.cleanUp() }
        let archive = try test.makeFile("a.zip")
        test.store.remember(false, for: archive)
        let before = try fileID(archive)

        try test.safeSave(archive)

        #expect(try fileID(archive) != before)
        #expect(test.store.choice(for: archive) == false)
    }

    /// Remove needs the same file ID: after a safe save nobody remembered it for, it no longer applies,
    /// and the stale record goes.
    @Test func removeNeedsTheSameFileID() throws {
        let test = try TestStore()
        defer { test.cleanUp() }
        let archive = try test.makeFile("a.zip")
        test.store.remember(true, for: archive)

        try test.safeSave(archive)

        #expect(test.store.choice(for: archive) == nil)
        #expect(test.isEmpty)
    }

    /// The document remembers its answer again after each of its own saves: the record gets the new file ID.
    @Test func rememberAfterSaveRefreshesTheFileID() throws {
        let test = try TestStore()
        defer { test.cleanUp() }
        let archive = try test.makeFile("a.zip")
        test.store.remember(true, for: archive)

        try test.safeSave(archive)
        test.store.remember(true, for: archive)

        #expect(test.store.choice(for: archive) == true)
        #expect(test.reloaded().choice(for: archive) == true)
    }

    /// Another archive later saved under the same name (new file ID, new creation date) gets no answer.
    @Test(arguments: [false, true])
    func anotherFileAtThePathDoesNotInherit(_ strips: Bool) throws {
        let test = try TestStore()
        defer { test.cleanUp() }
        let archive = try test.makeFile("a.zip")
        test.store.remember(strips, for: archive)

        try test.replaceWithAnotherFile(archive)

        #expect(test.store.choice(for: archive) == nil)
        #expect(test.isEmpty)
    }

    /// A Remove for a file without a file ID is the session's only. It is not stored, so a later
    /// file at the same path (with the same creation date, even) never gets it, and it replaces an earlier
    /// stored Keep rather than leaving it behind.
    @Test func removeWithoutFileIDIsNotStored() throws {
        let identity = MacMetadataChoiceStore.FileIdentity(fileID: nil, created: 1000)
        let test = try TestStore(identityOfFile: { _ in identity })
        defer { test.cleanUp() }
        let archive = test.directory.appendingPathComponent("a.zip")
        test.store.remember(false, for: archive)
        #expect(test.store.choice(for: archive) == false)

        test.store.remember(true, for: archive)

        #expect(test.isEmpty)
        #expect(test.store.choice(for: archive) == nil)
    }

    /// A Remove record without a file ID (written by an older build, say) never matches a file
    /// without one: nil is not a file ID. The stale record goes.
    @Test func storedRemoveWithoutFileIDNeverMatches() throws {
        let test = try TestStore(identityOfFile: { _ in .init(fileID: nil, created: 1000) })
        defer { test.cleanUp() }
        let archive = test.directory.appendingPathComponent("a.zip")
        let record: [String: Any] = ["path": archive.path, "strips": true, "created": 1000.0]
        test.defaults.set(try JSONSerialization.data(withJSONObject: [record]),
                          forKey: MacMetadataChoiceStore.defaultsKey)

        #expect(test.store.choice(for: archive) == nil)
        #expect(test.isEmpty)
    }

    /// After a save on a file system without file IDs (none written, none at the path), nil matches nil: the
    /// Remove is allowed, so the session keeps it, but it is not stored, so it is the session's only.
    @Test func removeAfterSaveWithoutFileIDsIsTheSessionsOnly() throws {
        let identity = MacMetadataChoiceStore.FileIdentity(fileID: nil, created: 1000)
        let test = try TestStore(identityOfFile: { _ in identity })
        defer { test.cleanUp() }
        let archive = test.directory.appendingPathComponent("a.zip")
        #expect(MacMetadataChoiceStore.mayRememberAfterSave(true, savedFileID: nil, current: identity))

        #expect(test.store.remember(true, for: archive, savedFileID: nil))

        #expect(test.isEmpty)
        #expect(test.store.choice(for: archive) == nil)
    }

    /// A save that wrote no file ID never backs a Remove for a file that has one: refused, nothing stored.
    /// A Keep is remembered either way.
    @Test func removeAfterSaveWithoutSavedFileIDIsRefused() throws {
        let identity = MacMetadataChoiceStore.FileIdentity(fileID: 7, created: 1000)
        let test = try TestStore(identityOfFile: { _ in identity })
        defer { test.cleanUp() }
        let archive = test.directory.appendingPathComponent("a.zip")
        #expect(!MacMetadataChoiceStore.mayRememberAfterSave(true, savedFileID: nil, current: identity))
        #expect(MacMetadataChoiceStore.mayRememberAfterSave(false, savedFileID: nil, current: identity))

        #expect(!test.store.remember(true, for: archive, savedFileID: nil))

        #expect(test.isEmpty)
        #expect(test.store.choice(for: archive) == nil)
        #expect(test.store.remember(false, for: archive, savedFileID: nil))
        #expect(test.store.choice(for: archive) == false)
    }

    /// Keep without a file ID is stored and matches by the creation date alone.
    @Test func keepWithoutFileIDMatchesByCreationDate() throws {
        let test = try TestStore(identityOfFile: { _ in .init(fileID: nil, created: 1000) })
        defer { test.cleanUp() }
        let archive = test.directory.appendingPathComponent("a.zip")

        test.store.remember(false, for: archive)

        #expect(!test.isEmpty)
        #expect(test.store.choice(for: archive) == false)
    }

    /// Keep without a creation date matches by the file ID only: a missing date is not a match.
    @Test func keepWithoutCreationDateNeedsTheFileID() throws {
        let current = OSAllocatedUnfairLock(initialState: MacMetadataChoiceStore.FileIdentity(fileID: 1, created: nil))
        let test = try TestStore(identityOfFile: { _ in current.withLock { $0 } })
        defer { test.cleanUp() }
        let archive = test.directory.appendingPathComponent("a.zip")
        test.store.remember(false, for: archive)
        #expect(test.store.choice(for: archive) == false)

        current.withLock { $0 = .init(fileID: 2, created: nil) }

        #expect(test.store.choice(for: archive) == nil)
        #expect(test.isEmpty)
    }

    @Test func evictsLeastRecentlyUsedBeyondCapacity() throws {
        let test = try TestStore(capacity: 2)
        defer { test.cleanUp() }
        let a = try test.makeFile("a.zip")
        let b = try test.makeFile("b.zip")
        let c = try test.makeFile("c.zip")
        test.store.remember(true, for: a)
        test.store.remember(false, for: b)
        // Reading a makes b the least recently used.
        #expect(test.store.choice(for: a) == true)

        test.store.remember(false, for: c)

        #expect(test.store.choice(for: a) == true)
        #expect(test.store.choice(for: b) == nil)
        #expect(test.store.choice(for: c) == false)
    }

    @Test func forgetRemovesTheRecord() throws {
        let test = try TestStore()
        defer { test.cleanUp() }
        let archive = try test.makeFile("a.zip")
        let other = try test.makeFile("b.zip")
        test.store.remember(true, for: archive)
        test.store.remember(false, for: other)

        test.store.forget(archive)

        #expect(test.store.choice(for: archive) == nil)
        #expect(test.reloaded().choice(for: archive) == nil)
        #expect(test.store.choice(for: other) == false)
        test.store.forget(other)
        #expect(test.isEmpty)
    }

    /// Nothing at the path (or no identity at all): nothing is stored, and the answer is the session's only.
    @Test(arguments: [false, true])
    func fileWithoutIdentityIsNotStored(_ strips: Bool) throws {
        let test = try TestStore()
        defer { test.cleanUp() }
        let missing = test.directory.appendingPathComponent("missing.zip")
        test.store.remember(strips, for: missing)
        #expect(test.isEmpty)

        let noIdentity = try TestStore(identityOfFile: { _ in nil })
        defer { noIdentity.cleanUp() }
        let archive = try noIdentity.makeFile("a.zip")
        noIdentity.store.remember(strips, for: archive)
        #expect(noIdentity.isEmpty)
        #expect(noIdentity.store.choice(for: archive) == nil)
    }

    /// Lookups alone never write: only an answer does.
    @Test func neverWritesWithoutAnAnswer() throws {
        let test = try TestStore()
        defer { test.cleanUp() }
        let archive = try test.makeFile("a.zip")

        #expect(test.store.choice(for: archive) == nil)
        #expect(test.store.choice(for: test.directory.appendingPathComponent("missing.zip")) == nil)
        test.store.forget(archive)

        #expect(test.isEmpty)
    }
}
