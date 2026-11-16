import Foundation
import KernirCore

/// The files a Quick Look preview swipes through, as in Files: the folder level's files in the order
/// its list shows them, folders left out. The listing is taken when the preview comes up and kept while
/// it is up (the list can't change under the full-screen preview; a save sends it away).
///
/// Nothing is extracted up front: the previewed file comes extracted (`ScreenState.preview`), and every
/// other one only when Quick Look asks for it (`item(at:)`). Its copy is the one a tapped row's
/// preview gets (`ArchiveModel.localFileURL(for:)`): the reader's cache or the model's temporary
/// folders, reused there and deleted with the reader or the document's close, so the queue deletes
/// nothing itself.
///
/// In a solid or streamed archive each extraction reads from the start, so few run at once
/// (`maxRunning`), the file on screen first, and swiping on (`show`) cancels the ones it left behind;
/// those are asked for again if the user comes back. A neighbor Quick Look asks for ahead of time
/// waits until it is on screen when it is big (`prefetchLimit`) or the disk is nearly full.
@MainActor final class PreviewQueue {
    struct File: Equatable {
        let path: String
        let name: String
        /// Uncompressed, when the archive says.
        var size: Int64? = nil
    }

    typealias Extract = @MainActor @Sendable (String) async throws -> URL

    /// Extractions at once, cancelled ones still stopping included.
    static let maxRunning = 2
    /// A neighbor bigger than this (uncompressed) isn't extracted before it is on screen.
    static let prefetchLimit: Int64 = 100 * 1024 * 1024
    /// What a neighbor's extraction leaves free on the disk at least; else it waits to be on screen.
    static let prefetchReserve: Int64 = 1024 * 1024 * 1024

    let files: [File]
    /// The previewed file's index in `files`.
    let startIndex: Int
    /// The file on screen, as last told by `show`.
    private(set) var currentIndex: Int
    /// An extraction has ended, with its file or a failure: Quick Look shows the item at that index again.
    var onUpdate: ((Int) -> Void)?

    private let extract: Extract
    /// Free bytes on the temporary folder's volume, nil when unknown.
    private let freeSpace: @MainActor () -> Int64?
    private var urls: [Int: URL]
    private var failures: [Int: any Error] = [:]
    /// Asked for and not started yet.
    private var pending: Set<Int> = []
    /// Running, by index; `id` tells a cancelled run's late end from a new one's.
    private var running: [Int: (id: Int, task: Task<Void, Never>)] = [:]
    /// Cancelled and not ended yet: they still count against `maxRunning`.
    private var stopping: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    /// Indexes Quick Look got nil for, still showing that blank page (`takeRefresh`).
    private var placeholders: Set<Int> = []
    private var isCancelled = false

    /// `listing`: the level's rows as shown. A previewed file that isn't one of its files (the search
    /// changed meanwhile) previews alone, as before swiping.
    init(listing: [ArchiveItem], previewing path: String, url: URL, extract: @escaping Extract,
         freeSpace: @escaping @MainActor () -> Int64? = PreviewQueue.temporaryVolumeFreeSpace) {
        let listed = listing.filter { !$0.isDirectory }.map { File(path: $0.path, name: $0.name, size: $0.size) }
        if let index = listed.firstIndex(where: { $0.path == path }) {
            files = listed
            startIndex = index
        } else {
            files = [File(path: path, name: (path as NSString).lastPathComponent)]
            startIndex = 0
        }
        currentIndex = startIndex
        urls = [startIndex: url]
        self.extract = extract
        self.freeSpace = freeSpace
    }

    /// The file at `index`, if extracted.
    func url(at index: Int) -> URL? { urls[index] }

    /// The file at `index` for Quick Look: nil until it is extracted, which is asked for now if it
    /// hasn't been (and hasn't failed); `onUpdate` tells when it ends.
    func item(at index: Int) -> URL? {
        guard files.indices.contains(index) else { return nil }
        if let url = urls[index] { return url }
        placeholders.insert(index)
        request(index)
        return nil
    }

    /// Quick Look shows `index` now: extractions more than one file away stop (and are asked for
    /// again when the user comes back), and the file and its neighbors that Quick Look holds blank
    /// pages for are asked for again if they were stopped.
    func show(_ index: Int) {
        guard files.indices.contains(index), !isCancelled else { return }
        currentIndex = index
        for (far, run) in running where abs(far - index) > 1 {
            run.task.cancel()
            running[far] = nil
            stopping[run.id] = run.task
        }
        pending = pending.filter { abs($0 - index) <= 1 }
        for near in index - 1...index + 1 where placeholders.contains(near) { request(near) }
        pump()
    }

    /// Whether Quick Look's page for `index` is a blank one whose file is ready now: true once, the
    /// caller then shows it again.
    func takeRefresh(at index: Int) -> Bool {
        guard placeholders.contains(index), urls[index] != nil else { return false }
        placeholders.remove(index)
        return true
    }

    /// Why the file at `index` couldn't be extracted, worded as a tapped row's alert; nil when it
    /// didn't fail or was cancelled (the user, a save or Text Encoding asked for that).
    func failureAlert(at index: Int) -> AlertContent? {
        guard let error = failures[index], !(error is CancellationError),
              error as? ArchiveError != .cancelled else { return nil }
        return AlertContent(title: String(localized: "Couldn't preview “\(files[index].name)”"),
                            message: error.localizedDescription)
    }

    /// The preview has gone: running extractions are cancelled and their results dropped, and none
    /// starts again.
    func cancel() {
        isCancelled = true
        onUpdate = nil
        for run in running.values { run.task.cancel() }
        running = [:]
        pending = []
    }

    /// The indexes extracting now, cancelled ones left out. Tests.
    var runningIndexes: Set<Int> { Set(running.keys) }

    /// The extraction running for `index`, cancelled ones left out. Tests await it.
    func runningTask(at index: Int) -> Task<Void, Never>? { running[index]?.task }

    /// The extractions running now, cancelled ones still stopping included. Tests await them.
    var runningTasks: [Task<Void, Never>] { running.values.map(\.task) + stopping.values }

    /// Waits until no extraction runs, including the ones that start meanwhile. Tests.
    func settle() async {
        while let task = runningTasks.first { await task.value }
    }

    /// The free space of the volume holding the temporary folder, as the system counts it for
    /// files the user asked for.
    static func temporaryVolumeFreeSpace() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func request(_ index: Int) {
        guard !isCancelled, urls[index] == nil, failures[index] == nil, running[index] == nil else { return }
        pending.insert(index)
        pump()
    }

    /// Starts what is asked for, the file on screen first, then the nearest, while fewer than
    /// `maxRunning` run. One more than a file away stays pending: `show` would stop it at once.
    private func pump() {
        let order = pending.sorted { (abs($0 - currentIndex), $0) < (abs($1 - currentIndex), $1) }
        for index in order where running.count + stopping.count < Self.maxRunning {
            guard abs(index - currentIndex) <= 1 else { continue }
            guard index == currentIndex || mayPrefetch(files[index]) else { continue }
            pending.remove(index)
            start(index)
        }
    }

    /// A neighbor is extracted ahead of time unless it is big or would leave the disk nearly full.
    private func mayPrefetch(_ file: File) -> Bool {
        let size = file.size ?? 0
        guard size <= Self.prefetchLimit else { return false }
        guard let free = freeSpace() else { return true }
        return free - size >= Self.prefetchReserve
    }

    private func start(_ index: Int) {
        let path = files[index].path
        let id = nextID
        nextID += 1
        let task = Task { [weak self, extract] in
            let result: Result<URL, any Error>
            do {
                result = .success(try await extract(path))
            } catch {
                result = .failure(error)
            }
            self?.finish(index, id: id, result)
        }
        running[index] = (id, task)
    }

    private func finish(_ index: Int, id: Int, _ result: Result<URL, any Error>) {
        if stopping.removeValue(forKey: id) != nil {
            // Cancelled by a swipe away: it can be asked for again.
            pump()
            return
        }
        guard !isCancelled, running[index]?.id == id else { return }
        running[index] = nil
        switch result {
        case .success(let url): urls[index] = url
        case .failure(let error): failures[index] = error
        }
        pump()
        onUpdate?(index)
    }
}
