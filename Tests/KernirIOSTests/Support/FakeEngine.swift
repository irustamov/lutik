import Foundation
import os
import KernirCore
@testable import Kernir

/// Records what `ArchiveDocument` asks of the engine and answers with a `FakeReader`.
final class FakeEngine: Sendable {
    struct OpenCall: Equatable, Sendable {
        var url: URL
        var password: String?
    }

    /// An open with the names read as `nameEncoding` asks (`DocumentEngine.openWithNameEncoding`).
    struct NameEncodingCall: Equatable, Sendable {
        var url: URL
        var password: String?
        var nameEncoding: ArchiveNameEncoding
    }

    struct WriteCall: Sendable {
        var changes: ArchiveChangeSet
        var format: ArchiveFormat
        var url: URL
        var options: ArchiveWriteOptions?
    }

    private struct State: Sendable {
        var openCalls: [OpenCall] = []
        var nameEncodingCalls: [NameEncodingCall] = []
        var writeCalls: [WriteCall] = []
        /// Thrown one per open call, before the engine succeeds.
        var openFailures: [any Error] = []
        /// When set, every open waits here after it is recorded.
        var gate: OpenGate?
    }

    /// When set, opening needs exactly this password: nil throws `.passwordRequired`
    /// (or lists an encrypted archive, see `listsWithoutPassword`), anything else `.wrongPassword`.
    private let password: String?
    /// Like an encrypted ZIP: without a password the archive still lists, marked encrypted.
    private let listsWithoutPassword: Bool
    private let makeReader: @Sendable (URL) -> FakeReader
    private let openError: ArchiveError?
    /// How many files the readers it opens are made of (a multi-volume set when more than one).
    private let volumeCount: Int
    private let writeError: ArchiveError?
    /// How long a write takes, to keep a save in flight.
    private let writeDelay: Duration
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(password: String? = nil, listsWithoutPassword: Bool = false, openError: ArchiveError? = nil,
         openFailures: [any Error] = [], volumeCount: Int = 1,
         writeError: ArchiveError? = nil, writeDelay: Duration = .zero,
         reader: @escaping @Sendable (URL) -> FakeReader = { FakeReader.sample(url: $0) }) {
        self.password = password
        self.listsWithoutPassword = listsWithoutPassword
        self.makeReader = reader
        self.openError = openError
        self.volumeCount = volumeCount
        state.withLock { $0.openFailures = openFailures }
        self.writeError = writeError
        self.writeDelay = writeDelay
    }

    /// Every open, `openWithNameEncoding`'s included.
    var openCalls: [OpenCall] { state.withLock { $0.openCalls } }
    /// The opens through `openWithNameEncoding` only, with the encoding each asked for.
    var nameEncodingCalls: [NameEncodingCall] { state.withLock { $0.nameEncodingCalls } }
    var writeCalls: [WriteCall] { state.withLock { $0.writeCalls } }

    /// Holds every open, once recorded in `openCalls`, until the test opens the gate: a test can
    /// act while an open is in flight without depending on timing.
    var gate: OpenGate? {
        get { state.withLock { $0.gate } }
        set { state.withLock { $0.gate = newValue } }
    }

    var engine: DocumentEngine {
        DocumentEngine(
            open: { url, password in try await self.open(url, password: password) },
            openWithNameEncoding: { url, password, nameEncoding in
                self.state.withLock {
                    $0.nameEncodingCalls.append(NameEncodingCall(url: url, password: password,
                                                                 nameEncoding: nameEncoding))
                }
                return try await self.open(url, password: password).reading(as: nameEncoding)
            },
            write: { _, changes, format, url, options, progress in
                try await self.write(changes, format: format, to: url, options: options, progress: progress)
            })
    }

    private func open(_ url: URL, password given: String?) async throws -> FakeReader {
        let gate = state.withLock { state in
            state.openCalls.append(OpenCall(url: url, password: given))
            return state.gate
        }
        await gate?.pass()
        if let failure = state.withLock({ $0.openFailures.isEmpty ? nil : $0.openFailures.removeFirst() }) { throw failure }
        if let openError { throw openError }
        var reader = makeReader(url)
        if volumeCount > 1 {
            reader = FakeReader(entries: reader.entries, format: reader.format, url: url,
                                legacyNameEncoding: reader.legacyNameEncoding, volumeURLs: (1...volumeCount).map { url.appendingPathExtension("\($0)") })
        }
        guard let password else { return reader }
        if let given {
            guard given == password else { throw ArchiveError.wrongPassword }
        } else if !listsWithoutPassword {
            throw ArchiveError.passwordRequired
        }
        return FakeReader(entries: reader.entries, format: reader.format, url: url, isEncrypted: true,
                          failure: reader.failure, extractDelay: reader.extractDelay,
                          legacyNameEncoding: reader.legacyNameEncoding, volumeURLs: reader.volumeURLs)
    }

    private func write(_ changes: ArchiveChangeSet, format: ArchiveFormat, to url: URL,
                       options: ArchiveWriteOptions?, progress: ArchiveProgressHandler?) async throws {
        state.withLock {
            $0.writeCalls.append(WriteCall(changes: changes, format: format, url: url, options: options))
        }
        if writeDelay > .zero { try await Task.sleep(for: writeDelay) }
        if let writeError { throw writeError }
        progress?(0.5, nil)
        try Data("fake archive".utf8).write(to: url)
        progress?(1, nil)
    }
}

/// Blocks whoever calls `pass()` until the test calls `open()`; counts the callers.
final class OpenGate: Sendable {
    private struct State {
        var isOpen = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var arrivals = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many callers reached the gate (waiting or passed).
    var arrivals: Int { state.withLock { $0.arrivals } }

    func pass() async {
        await withCheckedContinuation { continuation in
            let isOpen = state.withLock { state in
                state.arrivals += 1
                if !state.isOpen { state.waiting.append(continuation) }
                return state.isOpen
            }
            if isOpen { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}
