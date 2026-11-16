import AppKit
import KernirCore
import os
import UniformTypeIdentifiers

/// A row's file promise that, once given a move token (`ArchiveActions.dragWriter`), also writes the row's
/// archive path under the private `moveType`: a drop back on the same window's table moves the item inside
/// the archive (`ArchiveTableDragAnchor.acceptMove`), and nothing outside Lutik knows the type.
final class ArchiveFilePromiseProvider: NSFilePromiseProvider {
    /// The private type of a move inside the archive: a property list `["path": <archive path>, "token":
    /// <the window's move token>]`.
    static let moveType = NSPasteboard.PasteboardType("com.kernir.app.archive-move")

    // `moveToken` and `dragOutFiles` are set once, on the main thread, by `ArchiveActions.dragWriter` before the
    // provider reaches a pasteboard, and only read afterwards: that is why AppKit's off-main reads of them
    // (`writableTypes`, `pasteboardPropertyList` when Mail or an Electron app takes the drag) are safe.

    /// The window's move token (`ArchiveActions.moveToken`); nil writes no move.
    var moveToken: String?

    /// The drag's plain files (`ArchiveDragOutFiles`), set by `ArchiveActions.dragWriter`: when its row
    /// is one of them, the provider also declares `.fileURL`, the file extracted when the drag was
    /// written, for receivers that don't take promises. Nil declares none.
    var dragOutFiles: ArchiveDragOutFiles?

    private var path: String? { (userInfo as? ArchiveFilePromiseDelegate)?.path }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if moveToken != nil { types.append(Self.moveType) }
        if let dragOutFiles, let path, !types.contains(.fileURL), dragOutFiles.offersFileURL(for: path) {
            types.append(.fileURL)
        }
        return types
    }

    /// `.fileURL` is written at once, not promised: a URL served lazily gets no sandbox extension, and the
    /// receiver reads nothing.
    override func writingOptions(forType type: NSPasteboard.PasteboardType,
                                 pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .fileURL ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL {
            // The file is ready since `writableTypes`: never waits.
            guard let dragOutFiles, let path, let url = dragOutFiles.fileURL(for: path) else { return nil }
            return (url as NSURL).pasteboardPropertyList(forType: .fileURL)
        }
        guard type == Self.moveType else { return super.pasteboardPropertyList(forType: type) }
        guard let moveToken, let path else { return nil }
        return ["path": path, "token": moveToken]
    }

    /// The archive path and token of a move this provider wrote on a pasteboard item, nil for anything else.
    static func move(on item: NSPasteboardItem) -> (path: String, token: String)? {
        guard let plist = item.propertyList(forType: moveType) as? [String: String],
              let path = plist["path"], let token = plist["token"] else { return nil }
        return (path, token)
    }
}

/// A row dragged out of an archive window, as a file promise: Finder takes the drop as one (an
/// item it writes the file for) and asks for the file only when the drop lands, so starting a drag
/// costs nothing. The file work is `ArchiveDragOut.write`, into the folder Finder gives.
@MainActor
final class ArchiveFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private nonisolated static let logger = Logger(subsystem: "com.kernir.app", category: "dragOut")

    /// Every promise writes on this one serial queue, never the main one: AppKit calls
    /// `writePromiseTo` there, and that only starts the work, on the main actor, asynchronously.
    nonisolated static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.kernir.app.filePromise"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Archive path of the dragged item.
    nonisolated let path: String
    /// The model at drag time; weak, so a drag doesn't keep a closed window's archive. Gone when
    /// the drop lands: the entry-not-found error.
    private weak var model: ArchiveModel?

    private init(path: String, model: ArchiveModel) {
        self.path = path
        self.model = model
    }

    /// The promise for the row at `path` in `model`, announcing the item's type (`ArchiveDragOut
    /// .contentType`). The provider keeps its delegate alive (its `delegate` is weak) as its
    /// `userInfo`.
    static func provider(path: String, model: ArchiveModel) -> NSFilePromiseProvider {
        let isDirectory = model.item(at: path)?.isDirectory ?? false
        let type = ArchiveDragOut.contentType(name: Self.fileName(for: path), isDirectory: isDirectory)
        let delegate = ArchiveFilePromiseDelegate(path: path, model: model)
        let provider = ArchiveFilePromiseProvider(fileType: type.identifier, delegate: delegate)
        provider.userInfo = delegate
        return provider
    }

    /// The name Finder shows for the promise: the item's own, made a valid file name when the
    /// archive's isn't (`ArchiveDragOut.offeredName(forPath:)`).
    nonisolated static func fileName(for path: String) -> String {
        ArchiveDragOut.offeredName(forPath: path)
    }

    // AppKit and FileCoordination call these two off the main thread (a drop on Mail asks for the queue on
    // com.apple.FileCoordination), though the SDK marks them UI-actor: nonisolated, so the @objc thunk has no
    // main-actor check to trap on. They read only `path` (a `let`) and the static `queue` and `fileName`.

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                         fileNameForType fileType: String) -> String {
        Self.fileName(for: path)
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.queue
    }

    // The window's hooks (progress sheet, alert, line to wait in); none by default.

    /// The extraction's progress, passed to `ArchiveDragOut.write`.
    var progress: ArchiveProgressHandler?
    /// The window's line: when set, a write waits in it until the window can take an operation
    /// (no progress sheet, no other sheet), after the ones that came before. Without one it starts
    /// at once.
    var windowQueue: QueuedOperations?
    /// Called when a write starts, on the main actor: the window shows its progress sheet.
    var onStart: (@MainActor () -> Void)?
    /// Called when a write that started has ended, after the completion handler: the window clears
    /// its progress sheet.
    var onEnd: (@MainActor () -> Void)?
    /// Called once for a failure other than a cancel (`ArchiveDragOut.alertError`), after the
    /// completion handler and `onEnd`: the window shows it (the receiver may not).
    var onFailure: (@MainActor (any Error) -> Void)?

    /// One `writePromiseTo` call: from accepted to its completion handler's call.
    private final class Write {
        let id = UUID()
        let completion: PromiseCompletion
        /// The id of its place in `windowQueue`, while it has one.
        var queueID: UUID?
        /// The running file work; nil before it starts.
        var task: Task<(any Error)?, Never>?
        var isCancelled = false

        init(completion: PromiseCompletion) { self.completion = completion }
    }

    /// The drop (drag session) this promise is a row of, if any: a Cancel stops every row of it
    /// (`ArchiveFilePromiseDrop.cancel`). Held strongly; the drop holds its rows weakly.
    fileprivate(set) var drop: ArchiveFilePromiseDrop?

    /// The writes accepted and not ended, by id. A promise may be written more than once, and
    /// each ends only itself.
    private var writes: [UUID: Write] = [:]
    /// `cancel` was called: no write starts any more.
    private var isCancelled = false

    /// Stops every write of this promise: one that waits leaves the window's line, one that runs
    /// is cancelled (its staging goes first); each completion handler gets Cocoa's user-cancelled
    /// error, and none calls `onFailure`.
    func cancel() {
        isCancelled = true
        for write in Array(writes.values) {
            if let windowQueue, let queueID = write.queueID {
                windowQueue.cancel(queueID)
            } else {
                abort(write)
            }
        }
    }

    /// Called on `queue`. Hops to the main actor asynchronously (a synchronous hop could deadlock
    /// while AppKit runs the drag) and calls `completionHandler` exactly once, after every file
    /// operation is done: nil once the item is in place, else the error
    /// (`ArchiveDragOut.promiseError`).
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let completion = PromiseCompletion(completionHandler)
        Task { @MainActor in
            self.accept(url, completion: completion)
        }
    }

    private func accept(_ url: URL, completion: PromiseCompletion) {
        guard !isCancelled else {
            completion.call(CocoaError(.userCancelled))
            return
        }
        let write = Write(completion: completion)
        writes[write.id] = write
        // The closures keep the delegate alive until the write has ended: the provider may be gone.
        let run: @MainActor () async -> Void = { await self.perform(write, to: url) }
        if let windowQueue {
            write.queueID = windowQueue.add(run: run, cancel: { self.abort(write) })
        } else {
            Task { @MainActor in await run() }
        }
    }

    /// Stops `write` (the window's line, or `cancel`, calls this): a running one is cancelled; one
    /// that hasn't started never will, and its completion handler hears of it now.
    private func abort(_ write: Write) {
        write.isCancelled = true
        if let task = write.task {
            task.cancel()
        } else if writes.removeValue(forKey: write.id) != nil {
            write.completion.call(CocoaError(.userCancelled))
        }
    }

    private func perform(_ write: Write, to url: URL) async {
        guard !write.isCancelled, writes[write.id] != nil else { return }
        onStart?()
        let model = model
        let progress = progress
        let path = path
        let task = Task { @MainActor () -> (any Error)? in
            do {
                // The entry is looked up by its path now, when the file is written, not when the drag
                // started: an archive edited in between (a rename onto the dragged name)
                // writes what is at that path now, and may be a folder where the drag announced a
                // file, or the other way round. User-caused, and it stays inside the drop folder.
                guard let model else { throw ArchiveError.entryNotFound(path) }
                _ = try await ArchiveDragOut.write(path, from: model, toPromised: url, progress: progress)
                return nil
            } catch {
                // Decided here, while the failure happens: once the task is cancelled, whatever
                // stops the file work is the cancel (a closing window cancels the writes, then
                // removes the temporary files under the one still running: that error is not a
                // cancel, and no alert may follow a Cancel or a close). An error the task had
                // already ended with before the cancel arrived stays what it was, even if the
                // cancel lands before this continuation resumes. Accepted: a Cancel
                // that lands during a real error's cleanup (the staging removal is awaited before
                // the error is thrown) is reported as the cancel, with no alert; the user asked to stop.
                return Task.isCancelled ? CocoaError(.userCancelled) : ArchiveDragOut.promiseError(for: error)
            }
        }
        write.task = task
        if write.isCancelled { task.cancel() }
        let reported = await task.value
        // Only this write's own entry: another may be running by now.
        writes[write.id] = nil
        if let reported {
            let nsError = reported as NSError
            Self.logger.error("Drag out failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
        }
        write.completion.call(reported)
        onEnd?()
        if let shown = ArchiveDragOut.alertError(for: reported) { onFailure?(shown) }
    }
}

/// The rows of one drop (one drag session out of the table): a Cancel on any row's sheet stops them
/// all. Rows still waiting in the window's line leave it without a sheet, a row asked for
/// after the cancel never starts, and a row mid-write is cancelled; each completion handler hears
/// Cocoa's user-cancelled error once, and none gets an alert. Other drops go on.
@MainActor
final class ArchiveFilePromiseDrop {
    private struct Row { weak var delegate: ArchiveFilePromiseDelegate? }

    /// The drag session's id, given by the table's hook.
    let id: UUID
    private var rows: [Row] = []

    init(id: UUID) { self.id = id }

    /// Makes `delegate` a row of this drop.
    func add(_ delegate: ArchiveFilePromiseDelegate) {
        rows.removeAll { $0.delegate == nil }
        rows.append(Row(delegate: delegate))
        delegate.drop = self
    }

    /// Cancels every row of this drop, in the order they were added.
    func cancel() {
        for row in rows { row.delegate?.cancel() }
    }
}

/// A promise's completion handler, called at most once whatever calls it.
private final class PromiseCompletion: Sendable {
    private let handler: OSAllocatedUnfairLock<(@Sendable ((any Error)?) -> Void)?>

    init(_ handler: @escaping @Sendable ((any Error)?) -> Void) {
        self.handler = OSAllocatedUnfairLock(initialState: handler)
    }

    func call(_ error: (any Error)?) {
        let handler = self.handler.withLock { handler in
            defer { handler = nil }
            return handler
        }
        handler?(error)
    }
}
