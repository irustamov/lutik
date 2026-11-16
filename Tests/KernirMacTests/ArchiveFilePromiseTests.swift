import AppKit
import Testing
import Foundation
import os
import UniformTypeIdentifiers
@testable import Kernir
import KernirCore

// A row dragged out of a Mac archive window is a file promise (`ArchiveFilePromiseDelegate`):
// Finder sees promised-file flavors with the item's type, not a plain public.item, and asks for
// the file only when the drop lands. Hosted (AppKit, a pasteboard): needs a hosted UI test run.

// MARK: - Helpers

private let testDeviceToken = "f11ef11ef11ef11e"

private func file(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
}

private func folder(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
}

private let entries: [ArchiveEntry] = [
    file("README.md"), folder("docs"), file("docs/report.pdf"), folder("src"), file("src/main.swift"),
    file("Makefile"),
]

/// A model whose renames are renamex_np(2) with a test device token (`.system` keeps its token in
/// the standard defaults).
@MainActor
private func makeModel(reader: (any ArchiveReading)? = nil) -> ArchiveModel {
    let model = ArchiveModel(reader: reader ?? FakeReader(entries: entries), undoManager: nil)
    model.extractionFileSystem = ExtractionFileSystem(deviceToken: testDeviceToken) { from, to, flags in
        renamex_np(from, to, flags) == 0 ? 0 : errno
    }
    return model
}

/// A fresh empty folder standing for the drop's destination; the caller removes it.
private func makeDestination() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ArchiveFilePromiseTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let promisedMetaDataType = NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")
private let promisedContentType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")

/// Every call of a promise's completion handler, with what the drop folder held then.
private final class Completions: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(any Error)?] = []
    private var listings: [[String]] = []
    let folder: URL?

    init(folder: URL? = nil) { self.folder = folder }

    func record(_ error: (any Error)?) {
        let listing = folder.map { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? ["<unreadable>"] } ?? []
        lock.withLock {
            calls.append(error)
            listings.append(listing)
        }
    }
    var all: [(any Error)?] { lock.withLock { calls } }
    /// The drop folder's names at each call.
    var seen: [[String]] { lock.withLock { listings } }

    /// Waits for the first call (at most 10 s), then 0.3 s more so a second call would show.
    func settle() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while all.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
    }
}

/// What a promise delegate answered on a background queue (`theQueueAndFileNameAnswerOffTheMainThread`).
private struct OffMainAnswers: Sendable {
    let onMainThread: Bool
    let queue: ObjectIdentifier
    let objcQueue: ObjectIdentifier?
    let name: String
    let objcName: String?
}

/// What a provider wrote, type by type (`theProviderWritesTheSameTypesOffTheMainThread`); the values are
/// property lists, read only after the writing thread is done.
private struct PropertyLists: @unchecked Sendable {
    let onMainThread: Bool
    let types: [String]
    let values: [String: Any]
}

/// `provider`'s writable types on `pasteboard` and the property list of each, asked on the calling thread.
private func propertyLists(of provider: ArchiveFilePromiseProvider, for pasteboard: NSPasteboard) -> PropertyLists {
    let types = provider.writableTypes(for: pasteboard)
    var values: [String: Any] = [:]
    for type in types { values[type.rawValue] = provider.pasteboardPropertyList(forType: type) }
    return PropertyLists(onMainThread: pthread_main_np() != 0, types: types.map(\.rawValue), values: values)
}

@Suite struct ArchiveFilePromiseTests {
    // MARK: - What the pasteboard holds

    /// Written to a private pasteboard, the provider puts the promise flavors there, the content type
    /// being the item's own (a folder's .folder): what Finder needs to take the drop as a promise.
    @MainActor @Test(arguments: [
        ("README.md", "net.daringfireball.markdown"),
        ("docs/report.pdf", UTType.pdf.identifier),
        ("src", UTType.folder.identifier),
        ("Makefile", UTType.data.identifier),
    ])
    func thePasteboardHoldsAFilePromise(_ path: String, _ expectedType: String) throws {
        let model = makeModel()
        let provider = ArchiveFilePromiseDelegate.provider(path: path, model: model)
        let pasteboard = NSPasteboard(name: .init("kernir-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        #expect(pasteboard.writeObjects([provider]))

        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 1)
        let types = try #require(items.first).types
        print("ArchiveFilePromiseTests \(path): pasteboard types \(types.map(\.rawValue))")
        // Required on every macOS: the item's metadata and the content type Finder reads.
        #expect(types.contains(promisedMetaDataType))
        #expect(types.contains(promisedContentType))
        // ONLY the promise before the drop: nothing else may carry a path, a URL or the
        // item's data. Allowed is the promise's own namespace, by prefix, because the set differs by
        // system: macOS 26 writes NSFilePromiseItemMetaData, promised-file-name,
        // promised-suggested-file-name, promised-file-content-type and NSFilePromiseID, and no
        // promised-file-url (older systems may). The line printed above shows what a run saw.
        let promisePrefixes = ["com.apple.pasteboard.promised-", "com.apple.NSFilePromise", "com.apple.pasteboard.NSFilePromise"]
        let strangers = types.filter { type in !promisePrefixes.contains { type.rawValue.hasPrefix($0) } }
        #expect(strangers.isEmpty, "types outside the promise: \(strangers.map(\.rawValue)); all \(types.map(\.rawValue))")
        // The ones that would hurt most, named.
        #expect(!types.contains(.fileURL))
        #expect(!types.contains(.URL))
        #expect(!types.contains(NSPasteboard.PasteboardType(expectedType)))
        #expect(!types.contains(NSPasteboard.PasteboardType(UTType.item.identifier)))
        #expect(!types.contains(NSPasteboard.PasteboardType(UTType.data.identifier)))
        #expect(provider.fileType == expectedType)
        let announced = items.first?.string(forType: promisedContentType)
        #expect(announced == expectedType)
        #expect(announced != UTType.item.identifier)
    }

    @MainActor @Test func theFileNameIsTheRowsOwnWithSlashesAsColons() {
        let model = makeModel()
        for (path, name) in [("README.md", "README.md"), ("docs/report.pdf", "report.pdf"), ("src", "src")] {
            let provider = ArchiveFilePromiseDelegate.provider(path: path, model: model)
            let delegate = provider.delegate as? ArchiveFilePromiseDelegate
            #expect(delegate != nil)
            #expect(provider.userInfo as? ArchiveFilePromiseDelegate === delegate)
            #expect(delegate?.filePromiseProvider(provider, fileNameForType: provider.fileType) == name)
        }
        #expect(ArchiveFilePromiseDelegate.fileName(for: "/") == ":")
        #expect(ArchiveFilePromiseDelegate.fileName(for: "a/b:c") == "b:c")
    }

    /// The name offered to Finder is always a valid file name, whatever the archive's entry is called
    /// (`theOfferedNameIsUsable` has the cases).
    @MainActor @Test func theOfferedNameIsAlwaysAValidFileName() {
        for path in ["..", "dir/..", ".", "", "a\0b", String(repeating: "x", count: 400) + ".txt"] {
            #expect(ArchiveDragOut.isValidFileName(ArchiveFilePromiseDelegate.fileName(for: path)), "\(path.prefix(20))")
        }
    }

    /// Every promise writes on one serial queue of its own, never the main queue.
    @MainActor @Test func promisesWriteOnOneSerialQueue() {
        let model = makeModel()
        let first = ArchiveFilePromiseDelegate.provider(path: "README.md", model: model)
        let second = ArchiveFilePromiseDelegate.provider(path: "src", model: model)
        let queue = (first.delegate as? ArchiveFilePromiseDelegate)?.operationQueue(for: first)
        #expect(queue != nil)
        #expect(queue === (second.delegate as? ArchiveFilePromiseDelegate)?.operationQueue(for: second))
        #expect(queue?.maxConcurrentOperationCount == 1)
        #expect(queue !== OperationQueue.main)
    }

    /// AppKit and FileCoordination ask for the queue and the file name off the main thread: a drop on Mail
    /// asked for the queue on com.apple.FileCoordination and trapped in the main-actor check. Asked from a
    /// background queue, directly and through the Objective-C messages AppKit sends, the answers are the
    /// main thread's.
    /// A regression in the @objc thunks traps the whole test host, not this test: a gate log that shows the
    /// host crashed (no named failure) during this suite means this regression.
    @MainActor @Test func theQueueAndFileNameAnswerOffTheMainThread() async throws {
        let model = makeModel()
        let provider = ArchiveFilePromiseDelegate.provider(path: "docs/report.pdf", model: model)
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        let mainQueue = ObjectIdentifier(delegate.operationQueue(for: provider))
        let mainName = delegate.filePromiseProvider(provider, fileNameForType: provider.fileType)
        #expect(mainName == "report.pdf")
        let fileType = provider.fileType

        nonisolated(unsafe) let unsafeProvider = provider
        let answers = await withCheckedContinuation { (continuation: CheckedContinuation<OffMainAnswers, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // As AppKit sends them: through the @objc thunks, where the main-actor check trapped.
                let object = delegate as NSObject
                let objcQueue = object.perform(NSSelectorFromString("operationQueueForFilePromiseProvider:"),
                                               with: unsafeProvider)?.takeUnretainedValue() as? OperationQueue
                let objcName = object.perform(NSSelectorFromString("filePromiseProvider:fileNameForType:"),
                                              with: unsafeProvider, with: fileType as NSString)?
                    .takeUnretainedValue() as? String
                continuation.resume(returning: OffMainAnswers(
                    onMainThread: pthread_main_np() != 0,
                    queue: ObjectIdentifier(delegate.operationQueue(for: unsafeProvider)),
                    objcQueue: objcQueue.map { ObjectIdentifier($0) },
                    name: delegate.filePromiseProvider(unsafeProvider, fileNameForType: fileType),
                    objcName: objcName))
            }
        }

        #expect(!answers.onMainThread)
        #expect(answers.queue == mainQueue)
        #expect(answers.objcQueue == mainQueue)
        #expect(answers.name == mainName)
        #expect(answers.objcName == mainName)
    }

    /// The provider's pasteboard writing (`writableTypes`, then the property list of every type) is asked for
    /// off the main thread too when another app (Mail, Electron) takes the drag: from a background queue it
    /// answers as on the main thread. With the drag's plain files (`dragOutFiles`) that includes `.fileURL`.
    @MainActor @Test(arguments: [false, true])
    func theProviderWritesTheSameTypesOffTheMainThread(withDragOutFiles: Bool) async throws {
        let reader = FakeReader(entries: entries)
        let model = makeModel(reader: reader)
        let provider = try #require(ArchiveFilePromiseDelegate.provider(path: "README.md", model: model)
            as? ArchiveFilePromiseProvider)
        provider.moveToken = "token-1"
        let folders = ArchiveDragOutFolders()
        defer { folders.removeAll() }
        if withDragOutFiles {
            let files = ArchiveDragOutFiles(reader: reader, folders: folders)
            files.add(ArchiveActions.dragOutRow(for: "README.md", in: model))
            provider.dragOutFiles = files
        }
        let pasteboard = NSPasteboard(name: .init("kernir-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let main = propertyLists(of: provider, for: pasteboard)
        // A second main-thread pass tells which values are stable, so comparable across threads.
        let mainAgain = propertyLists(of: provider, for: pasteboard)
        #expect(main.onMainThread)
        #expect(main.types.contains(ArchiveFilePromiseProvider.moveType.rawValue))
        #expect(main.types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) == withDragOutFiles)
        #expect(main.values[ArchiveFilePromiseProvider.moveType.rawValue] as? [String: String]
            == ["path": "README.md", "token": "token-1"])
        if withDragOutFiles { #expect(main.values[NSPasteboard.PasteboardType.fileURL.rawValue] != nil) }

        nonisolated(unsafe) let unsafeProvider = provider
        nonisolated(unsafe) let unsafePasteboard = pasteboard
        let answers = await withCheckedContinuation { (continuation: CheckedContinuation<PropertyLists, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: propertyLists(of: unsafeProvider, for: unsafePasteboard))
            }
        }

        #expect(!answers.onMainThread)
        #expect(answers.types == main.types)
        for type in main.types {
            let value = main.values[type]
            #expect((answers.values[type] == nil) == (value == nil), "\(type)")
            guard let value, let again = mainAgain.values[type], let offMain = answers.values[type],
                  value is Data || value is String || value is [Any] || value is [String: Any],
                  (value as AnyObject).isEqual(again) else { continue }
            #expect((offMain as AnyObject).isEqual(value), "\(type)")
        }
    }

    // MARK: - Writing the promise

    /// Called from the provider's queue as AppKit does: the item lands in the drop folder and the
    /// completion handler is called once, without an error.
    @MainActor @Test func aWrittenPromiseCompletesOnce() async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = makeModel()
        let provider = ArchiveFilePromiseDelegate.provider(path: "src", model: model)
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        let queue = delegate.operationQueue(for: provider)
        let completions = Completions(folder: destination)
        var failures = 0
        delegate.onFailure = { _ in failures += 1 }
        let url = destination.appendingPathComponent("src")

        nonisolated(unsafe) let unsafeProvider = provider
        queue.addOperation {
            delegate.filePromiseProvider(unsafeProvider, writePromiseTo: url) { completions.record($0) }
        }
        try await completions.settle()

        #expect(completions.all.count == 1)
        #expect(completions.all.first.map { $0 == nil } == true)
        // Called after every file operation: the item in place, the staging already gone.
        #expect(completions.seen == [["src"]])
        #expect(failures == 0)
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("src/main.swift").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["src"])
    }

    /// A row renamed in the window and not yet saved: its row (and so the promise) has the new name, and
    /// the file lands under that name, with the content of the item it was renamed from (the fake reader
    /// writes an entry's own path as its content), not under the old name.
    @MainActor @Test(arguments: [
        (from: "README.md", to: "Read me.md", landed: "Read me.md", content: "README.md"),
        (from: "src", to: "code", landed: "code/main.swift", content: "src/main.swift"),
    ])
    func aPendingRenameIsTheNameThatLands(from: String, to: String, landed: String, content: String) async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = makeModel()
        #expect(model.rename(from, to: to) == .success(to))
        #expect(model.item(at: from) == nil)

        let provider = ArchiveFilePromiseDelegate.provider(path: to, model: model)
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        #expect(delegate.filePromiseProvider(provider, fileNameForType: provider.fileType) == to)
        let completions = Completions(folder: destination)
        var failures = 0
        delegate.onFailure = { _ in failures += 1 }

        nonisolated(unsafe) let unsafeProvider = provider
        let url = destination.appendingPathComponent(to)
        delegate.operationQueue(for: provider).addOperation {
            delegate.filePromiseProvider(unsafeProvider, writePromiseTo: url) { completions.record($0) }
        }
        try await completions.settle()

        #expect(completions.all.count == 1)
        #expect(completions.all.first.map { $0 == nil } == true)
        #expect(failures == 0)
        #expect(completions.seen == [[to]])
        #expect(try String(contentsOf: destination.appendingPathComponent(landed), encoding: .utf8) == content)
    }

    /// A row the model doesn't have: the completion handler is called once, with the
    /// entry-not-found error, and nothing is written.
    @MainActor @Test func aFailedPromiseCompletesOnceWithTheError() async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = makeModel()
        let provider = ArchiveFilePromiseDelegate.provider(path: "gone.txt", model: model)
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        let completions = Completions(folder: destination)
        var failures: [any Error] = []
        delegate.onFailure = { failures.append($0) }

        delegate.filePromiseProvider(provider, writePromiseTo: destination.appendingPathComponent("gone.txt")) {
            completions.record($0)
        }
        try await completions.settle()

        #expect(completions.all.count == 1)
        let error = try #require(completions.all.first ?? nil)
        #expect(error as? ArchiveError == .entryNotFound("gone.txt"))
        #expect(completions.seen == [[]])
        // The window's alert hook: once, with the same error.
        #expect(failures.count == 1)
        #expect(failures.first as? ArchiveError == .entryNotFound("gone.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    /// A full disk at the final move: the error once, after the staging is gone, and one alert.
    @MainActor @Test func aFullDiskCompletesOnceAfterCleanup() async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = makeModel()
        model.extractionFileSystem = ExtractionFileSystem(deviceToken: testDeviceToken) { from, to, flags in
            if (to as NSString).deletingLastPathComponent == destination.path { return ENOSPC }
            return renamex_np(from, to, flags) == 0 ? 0 : errno
        }
        let provider = ArchiveFilePromiseDelegate.provider(path: "src", model: model)
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        let completions = Completions(folder: destination)
        var failures = 0
        delegate.onFailure = { _ in failures += 1 }

        delegate.filePromiseProvider(provider, writePromiseTo: destination.appendingPathComponent("src")) {
            completions.record($0)
        }
        try await completions.settle()

        #expect(completions.all.count == 1)
        #expect((completions.all.first ?? nil) as? POSIXError == POSIXError(.ENOSPC))
        #expect(completions.seen == [[]])
        #expect(failures == 1)
    }

    /// Queues a Cancel of its delegate the first time the failure it travels with is asked for its domain,
    /// which `ArchiveDragOut.promiseError(for:)` does (via `isCancellation`) in the write task's `catch`,
    /// the last thing the task runs: the queued Cancel lands after the task ended and before `perform`'s
    /// continuation resumes.
    private final class LateCancel: @unchecked Sendable {
        private let state = OSAllocatedUnfairLock<(delegate: ArchiveFilePromiseDelegate?, fired: Bool)>(
            initialState: (nil, false))
        func arm(_ delegate: ArchiveFilePromiseDelegate) { state.withLock { $0.delegate = delegate } }

        func fire() {
            let delegate = state.withLock { state -> ArchiveFilePromiseDelegate? in
                defer { state.fired = true }
                return state.fired ? nil : state.delegate
            }
            guard let delegate else { return }
            Task { @MainActor in delegate.cancel() }
        }
    }

    private struct FullDiskError: CustomNSError {
        static let late = LateCancel()
        static var errorDomain: String {
            late.fire()
            return NSPOSIXErrorDomain
        }
        var errorCode: Int { Int(ENOSPC) }
    }

    /// An `ArchiveReading` whose extraction fails with a real error (`FullDiskError`).
    private struct FailingReader: ArchiveReading {
        let base: FakeReader
        var url: URL { base.url }
        var format: ArchiveFormat { base.format }
        var entries: [ArchiveEntry] { base.entries }
        var isEncrypted: Bool { base.isEncrypted }

        func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
            throw FullDiskError()
        }

        func extractToTemporaryFile(_ path: String) async throws -> URL {
            try await base.extractToTemporaryFile(path)
        }
    }

    /// A real error that the write's task has already ended with, and a Cancel (or a window closing) that
    /// lands before `perform`'s continuation runs: the error stays what it was, it is not remapped to a
    /// user-cancel (the completion handler hears it, and it is alerted).
    @MainActor @Test func aRealErrorTheWriteEndedWithSurvivesALateCancel() async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = makeModel(reader: FailingReader(base: FakeReader(entries: entries)))
        let provider = ArchiveFilePromiseDelegate.provider(path: "src", model: model)
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        FullDiskError.late.arm(delegate)
        let completions = Completions(folder: destination)
        var failures = 0
        delegate.onFailure = { _ in failures += 1 }

        delegate.filePromiseProvider(provider, writePromiseTo: destination.appendingPathComponent("src")) {
            completions.record($0)
        }
        try await completions.settle()

        #expect(completions.all.count == 1)
        let error = try #require(completions.all.first ?? nil) as NSError
        #expect(error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
        #expect(failures == 1)
    }

    /// Cancelled before the write starts (the Cancel): Cocoa's user-cancelled error, once, no
    /// alert, nothing written.
    @MainActor @Test func aCancelledPromiseCompletesOnceWithUserCancelled() async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = makeModel()
        let provider = ArchiveFilePromiseDelegate.provider(path: "src", model: model)
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        let completions = Completions(folder: destination)
        var failures = 0
        delegate.onFailure = { _ in failures += 1 }

        delegate.filePromiseProvider(provider, writePromiseTo: destination.appendingPathComponent("src")) {
            completions.record($0)
        }
        delegate.cancel()
        try await completions.settle()

        #expect(completions.all.count == 1)
        let error = try #require(completions.all.first ?? nil) as NSError
        #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
        #expect(failures == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    /// The window closed before the drop landed (the model is gone): the entry-not-found error, once.
    @MainActor @Test func aPromiseWhoseModelIsGoneCompletesOnceWithTheError() async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        var model: ArchiveModel? = makeModel()
        weak let probe = model
        let provider = ArchiveFilePromiseDelegate.provider(path: "README.md", model: model!)
        model = nil
        try #require(probe == nil, "the promise must not keep the model alive")
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        let completions = Completions()

        delegate.filePromiseProvider(provider, writePromiseTo: destination.appendingPathComponent("README.md")) {
            completions.record($0)
        }
        try await completions.settle()

        #expect(completions.all.count == 1)
        let error = try #require(completions.all.first ?? nil)
        #expect(error as? ArchiveError == .entryNotFound("README.md"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    /// An `ArchiveReading` for two overlapping writes: its first extraction waits for `release`, then
    /// writes like a `FakeReader`; its second waits for its task's cancel and stops with
    /// `CancellationError`. `started` yields each call's number as it begins.
    private struct OverlapReader: ArchiveReading {
        let base: FakeReader
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let started: AsyncStream<Int>.Continuation
        let release: AsyncStream<Void>

        var url: URL { base.url }
        var format: ArchiveFormat { base.format }
        var entries: [ArchiveEntry] { base.entries }
        var isEncrypted: Bool { base.isEncrypted }

        func extract(_ paths: [String]?, to directory: URL, progress: ArchiveProgressHandler?) async throws {
            let number = calls.withLock { count -> Int in
                count += 1
                return count
            }
            started.yield(number)
            if number == 1 {
                for await _ in release { break }
                try await base.extract(paths, to: directory, progress: progress)
            } else {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                throw CancellationError()
            }
        }

        func extractToTemporaryFile(_ path: String) async throws -> URL {
            try await base.extractToTemporaryFile(path)
        }
    }

    /// A Cancel while the engine is writing, at the delegate: the completion handler hears Cocoa's
    /// user-cancelled error once, whichever way the engine stops; no alert hook; the drop
    /// folder is left empty.
    @MainActor @Test(arguments: [
        ArchiveError.cancelled as any Error & Sendable, CancellationError() as any Error & Sendable,
    ])
    func aMidWriteCancelCompletesOnceWithUserCancelled(_ engineError: any Error & Sendable) async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let (written, wrote) = AsyncStream.makeStream(of: Void.self)
        let model = makeModel(reader: MidWriteCancelReader(base: FakeReader(entries: entries), wrote: { wrote.yield() },
                                                           error: engineError))
        let provider = ArchiveFilePromiseDelegate.provider(path: "src", model: model)
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        let completions = Completions(folder: destination)
        var failures = 0
        delegate.onFailure = { _ in failures += 1 }

        delegate.filePromiseProvider(provider, writePromiseTo: destination.appendingPathComponent("src")) {
            completions.record($0)
        }
        for await _ in written { break }
        delegate.cancel()
        try await completions.settle()

        #expect(completions.all.count == 1)
        let error = try #require(completions.all.first ?? nil) as NSError
        #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
        #expect(completions.seen == [[]])
        #expect(failures == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    /// A Cancel, or a window closing, while the engine is writing, and the stop is reported as another error
    /// (`ArchiveDocument.close()` cancels the writes, then removes the temporary files under the one still
    /// running: its error is not a cancel): once cancelled, the completion handler still hears Cocoa's
    /// user-cancelled error, and no alert is asked for.
    @MainActor @Test(arguments: [
        CocoaError(.fileNoSuchFile) as any Error & Sendable, ArchiveError.entryNotFound("src") as any Error & Sendable,
    ])
    func aCancelledWriteReportsUserCancelledWhateverErrorStopsIt(_ engineError: any Error & Sendable) async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let (written, wrote) = AsyncStream.makeStream(of: Void.self)
        let model = makeModel(reader: MidWriteCancelReader(base: FakeReader(entries: entries), wrote: { wrote.yield() },
                                                           error: engineError))
        let provider = ArchiveFilePromiseDelegate.provider(path: "src", model: model)
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        let completions = Completions(folder: destination)
        var failures = 0
        delegate.onFailure = { _ in failures += 1 }

        delegate.filePromiseProvider(provider, writePromiseTo: destination.appendingPathComponent("src")) {
            completions.record($0)
        }
        for await _ in written { break }
        delegate.cancel()
        try await completions.settle()

        #expect(completions.all.count == 1)
        let error = try #require(completions.all.first ?? nil) as NSError
        #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
        #expect(failures == 0)
    }

    /// Two overlapping writes of one promise: the first one ending leaves the second one cancellable
    /// (a single task slot, cleared by the first, made `cancel` miss the second).
    @MainActor @Test func theFirstWriteEndingLeavesTheSecondCancellable() async throws {
        let first = try makeDestination(), second = try makeDestination()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let (started, didStart) = AsyncStream.makeStream(of: Int.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        let model = makeModel(reader: OverlapReader(base: FakeReader(entries: entries), started: didStart, release: released))
        let provider = ArchiveFilePromiseDelegate.provider(path: "src", model: model)
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        let firstCompletions = Completions(folder: first), secondCompletions = Completions(folder: second)
        var failures = 0
        delegate.onFailure = { _ in failures += 1 }
        var starts = started.makeAsyncIterator()

        delegate.filePromiseProvider(provider, writePromiseTo: first.appendingPathComponent("src")) {
            firstCompletions.record($0)
        }
        #expect(await starts.next() == 1)
        delegate.filePromiseProvider(provider, writePromiseTo: second.appendingPathComponent("src")) {
            secondCompletions.record($0)
        }
        #expect(await starts.next() == 2)

        release.yield()
        try await firstCompletions.settle()
        #expect(firstCompletions.all.count == 1)
        #expect(firstCompletions.all.first.map { $0 == nil } == true)
        #expect(secondCompletions.all.isEmpty)

        delegate.cancel()
        try await secondCompletions.settle()

        #expect(secondCompletions.all.count == 1)
        let error = try #require(secondCompletions.all.first ?? nil) as NSError
        #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
        #expect(failures == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: first.path) == ["src"])
    }

    /// A write waiting in the window's line (the window is busy): cancel takes it out, its completion
    /// handler hears Cocoa's user-cancelled error once, it never starts, and no alert is asked for.
    @MainActor @Test func aWriteWaitingInTheWindowsLineCancelsWithoutStarting() async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = makeModel()
        let provider = ArchiveFilePromiseDelegate.provider(path: "src", model: model)
        let delegate = try #require(provider.delegate as? ArchiveFilePromiseDelegate)
        let queue = QueuedOperations(pollInterval: .milliseconds(5)) { false }
        delegate.windowQueue = queue
        let completions = Completions(folder: destination)
        var started = 0, failures = 0
        delegate.onStart = { started += 1 }
        delegate.onFailure = { _ in failures += 1 }

        delegate.filePromiseProvider(provider, writePromiseTo: destination.appendingPathComponent("src")) {
            completions.record($0)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while queue.isIdle, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(!queue.isIdle, "the write never reached the window's line")
        #expect(queue.count == 1)
        #expect(completions.all.isEmpty)

        delegate.cancel()
        try await completions.settle()

        #expect(queue.isIdle)
        #expect(completions.all.count == 1)
        let error = try #require(completions.all.first ?? nil) as NSError
        #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
        #expect(started == 0 && failures == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    /// One drop (one drag session) of several rows: cancelling the drop stops every row of it. Rows
    /// still waiting in the window's line leave it without starting, a row whose write is asked for
    /// only after the cancel never starts either; each completion handler hears Cocoa's
    /// user-cancelled error exactly once, and no alert is asked for.
    @MainActor @Test func cancellingADropStopsEveryRowOfIt() async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = makeModel()
        let queue = QueuedOperations(pollInterval: .milliseconds(5)) { false }
        let drop = ArchiveFilePromiseDrop(id: UUID())
        let paths = ["src", "README.md", "Makefile"]
        let providers = paths.map { ArchiveFilePromiseDelegate.provider(path: $0, model: model) }
        let delegates = try providers.map { try #require($0.delegate as? ArchiveFilePromiseDelegate) }
        var started = 0, failures = 0
        for delegate in delegates {
            delegate.windowQueue = queue
            delegate.onStart = { started += 1 }
            delegate.onFailure = { _ in failures += 1 }
            drop.add(delegate)
        }
        #expect(delegates.allSatisfy { $0.drop === drop })
        let completions = paths.map { _ in Completions(folder: destination) }
        for index in 0..<2 {
            delegates[index].filePromiseProvider(providers[index],
                                                 writePromiseTo: destination.appendingPathComponent(paths[index])) {
                completions[index].record($0)
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while queue.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(queue.count == 2, "the writes never reached the window's line")

        drop.cancel()
        delegates[2].filePromiseProvider(providers[2], writePromiseTo: destination.appendingPathComponent(paths[2])) {
            completions[2].record($0)
        }
        for completion in completions { try await completion.settle() }

        #expect(queue.isIdle)
        for completion in completions {
            #expect(completion.all.count == 1)
            let error = try #require(completion.all.first ?? nil) as NSError
            #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.userCancelled.rawValue)
        }
        #expect(started == 0 && failures == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    /// Cancelling one drop leaves another drop of the same window alone: its row stays in the line
    /// and lands once the window is free.
    @MainActor @Test func cancellingADropLeavesAnotherDropAlone() async throws {
        let destination = try makeDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        let model = makeModel()
        let windowFree = OSAllocatedUnfairLock(initialState: false)
        let queue = QueuedOperations(pollInterval: .milliseconds(5)) { windowFree.withLock { $0 } }
        let first = ArchiveFilePromiseDrop(id: UUID()), second = ArchiveFilePromiseDrop(id: UUID())
        let firstProvider = ArchiveFilePromiseDelegate.provider(path: "src", model: model)
        let secondProvider = ArchiveFilePromiseDelegate.provider(path: "README.md", model: model)
        let firstDelegate = try #require(firstProvider.delegate as? ArchiveFilePromiseDelegate)
        let secondDelegate = try #require(secondProvider.delegate as? ArchiveFilePromiseDelegate)
        var failures = 0
        for (delegate, drop) in [(firstDelegate, first), (secondDelegate, second)] {
            delegate.windowQueue = queue
            delegate.onFailure = { _ in failures += 1 }
            drop.add(delegate)
        }
        let firstCompletions = Completions(folder: destination), secondCompletions = Completions(folder: destination)
        firstDelegate.filePromiseProvider(firstProvider, writePromiseTo: destination.appendingPathComponent("src")) {
            firstCompletions.record($0)
        }
        secondDelegate.filePromiseProvider(secondProvider,
                                           writePromiseTo: destination.appendingPathComponent("README.md")) {
            secondCompletions.record($0)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while queue.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(queue.count == 2, "the writes never reached the window's line")

        first.cancel()
        try await firstCompletions.settle()
        #expect(queue.count == 1)
        #expect(secondCompletions.all.isEmpty)

        windowFree.withLock { $0 = true }
        try await secondCompletions.settle()
        #expect(firstCompletions.all.count == 1)
        let error = try #require(firstCompletions.all.first ?? nil) as NSError
        #expect(error.code == CocoaError.userCancelled.rawValue)
        #expect(secondCompletions.all.count == 1)
        #expect(secondCompletions.all.first.map { $0 == nil } == true)
        #expect(failures == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["README.md"])
    }
}
