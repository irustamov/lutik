import Foundation
import Testing
import UIKit
import KernirCore
@testable import Kernir

/// Swiping in the preview (`PreviewQueue`): the folder's files in the listed order, each extracted
/// only when Quick Look asks for it.
@MainActor @Suite(.serialized) struct PreviewQueueTests {
    private static func file(_ path: String, size: Int64 = 1) -> ArchiveItem {
        ArchiveItem(path: path, name: (path as NSString).lastPathComponent, isDirectory: false, size: size,
                    kind: "", modificationDate: nil, isPendingAddition: false, children: nil)
    }

    private static func folder(_ path: String) -> ArchiveItem {
        ArchiveItem(path: path, name: (path as NSString).lastPathComponent, isDirectory: true, size: nil,
                    kind: "", modificationDate: nil, isPendingAddition: false, children: [])
    }

    private static let started = URL(fileURLWithPath: "/tmp/started")

    /// Extractions asked for, by path; each returns `/tmp/<path>`, or throws `failures[path]`.
    @MainActor private final class Extractor {
        private(set) var asked: [String] = []
        var failures: [String: any Error] = [:]

        var extract: @MainActor @Sendable (String) async throws -> URL {
            { [self] path in
                asked.append(path)
                if let failure = failures[path] { throw failure }
                return URL(fileURLWithPath: "/tmp/\(path)")
            }
        }
    }

    @Test func filesSkipFoldersInListedOrder() {
        let listing = [Self.folder("z"), Self.file("b.txt"), Self.folder("a"), Self.file("c.txt"), Self.file("a.txt")]
        let queue = PreviewQueue(listing: listing, previewing: "c.txt", url: Self.started, extract: Extractor().extract)

        #expect(queue.files.map(\.path) == ["b.txt", "c.txt", "a.txt"])
        #expect(queue.files.map(\.name) == ["b.txt", "c.txt", "a.txt"])
        #expect(queue.startIndex == 1)
        #expect(queue.url(at: 1) == Self.started)
    }

    /// A previewed file that isn't among the listing's files (search changed, a stray URL) previews
    /// alone, as before.
    @Test func unlistedFilePreviewsAlone() {
        let queue = PreviewQueue(listing: [Self.file("a.txt")], previewing: "docs/b.txt", url: Self.started,
                                 extract: Extractor().extract)

        #expect(queue.files.map(\.path) == ["docs/b.txt"])
        #expect(queue.files.map(\.name) == ["b.txt"])
        #expect(queue.startIndex == 0)
        #expect(queue.item(at: 0) == Self.started)
    }

    /// Nothing is extracted up front: only the files Quick Look asks for, each once.
    @Test func extractsOnDemandOnce() async {
        let listing = (0..<500).map { Self.file("f\($0).txt") }
        let extractor = Extractor()
        let queue = PreviewQueue(listing: listing, previewing: "f250.txt", url: Self.started,
                                 extract: extractor.extract, freeSpace: { .max })
        var updates: [Int] = []
        queue.onUpdate = { updates.append($0) }

        #expect(queue.item(at: 250) == Self.started)
        #expect(queue.item(at: 251) == nil, "not extracted yet")
        #expect(queue.item(at: 251) == nil, "still extracting: no second extraction")
        await queue.settle()

        #expect(extractor.asked == ["f251.txt"])
        #expect(updates == [251])
        #expect(queue.item(at: 251) == URL(fileURLWithPath: "/tmp/f251.txt"))
        #expect(queue.item(at: 249) == nil)
        #expect(queue.item(at: 500) == nil, "out of range")
        #expect(queue.item(at: -1) == nil, "out of range")
        await queue.settle()
        #expect(extractor.asked == ["f251.txt", "f249.txt"])
        #expect(queue.item(at: 251) == URL(fileURLWithPath: "/tmp/f251.txt"))
        #expect(extractor.asked.count == 2)
    }

    /// A file that can't be extracted (an encrypted RAR entry, a removed item) is tried once and
    /// says why, as a tapped row does; a cancellation says nothing.
    @Test func failedExtractionIsKeptAndExplained() async {
        // Both neighbors of the previewed file: a file two away isn't started (farFileWaitsUntilWithinOneFile).
        let listing = [Self.file("b.txt"), Self.file("a.txt"), Self.file("c.txt")]
        let extractor = Extractor()
        extractor.failures = ["b.txt": ArchiveError.unsupportedEncryption(.rar), "c.txt": CancellationError()]
        let queue = PreviewQueue(listing: listing, previewing: "a.txt", url: Self.started, extract: extractor.extract,
                                 freeSpace: { .max })
        var updates: [Int] = []
        queue.onUpdate = { updates.append($0) }

        #expect(queue.item(at: 0) == nil)
        #expect(queue.item(at: 2) == nil)
        await queue.settle()
        #expect(queue.item(at: 0) == nil)
        #expect(queue.item(at: 2) == nil)
        await queue.settle()

        #expect(extractor.asked == ["b.txt", "c.txt"], "a failed file isn't tried again")
        #expect(Set(updates) == [0, 2])
        let alert = queue.failureAlert(at: 0)
        #expect(alert?.title == "Couldn't preview “b.txt”")
        #expect(alert?.message == ArchiveError.unsupportedEncryption(.rar).localizedDescription)
        #expect(queue.failureAlert(at: 2) == nil, "cancelled: nothing to say")
        #expect(queue.failureAlert(at: 1) == nil)
    }

    /// The preview gone, extractions still running are cancelled and their results dropped; nothing
    /// new starts.
    @Test func cancelDropsRunningExtractions() async {
        let listing = [Self.file("a.txt"), Self.file("b.txt"), Self.file("c.txt")]
        let gate = Gate()
        let queue = PreviewQueue(listing: listing, previewing: "a.txt", url: Self.started, extract: { path in
            await gate.wait()
            try Task.checkCancellation()
            return URL(fileURLWithPath: "/tmp/\(path)")
        }, freeSpace: { .max })
        var updates: [Int] = []
        queue.onUpdate = { updates.append($0) }

        #expect(queue.item(at: 1) == nil)
        await Task.yield()
        let running = queue.runningTasks
        queue.cancel()
        gate.open()
        for task in running { await task.value }

        #expect(queue.url(at: 1) == nil)
        #expect(updates.isEmpty)
        #expect(queue.item(at: 2) == nil)
        #expect(queue.runningTasks.isEmpty, "nothing starts after cancel")
    }

    /// At most two extractions run at once, the file on screen first; swiping on stops the ones more
    /// than one file away (counted until they have stopped), and they are asked for again on the way back.
    @Test func runsTwoAtOnceAndStopsWhatTheSwipeLeft() async {
        let listing = (0..<10).map { Self.file("f\($0)") }
        let gates = PathGates()
        let queue = PreviewQueue(listing: listing, previewing: "f3", url: Self.started, extract: gates.extract,
                                 freeSpace: { .max })
        var updates: [Int] = []
        queue.onUpdate = { updates.append($0) }

        #expect(queue.item(at: 2) == nil)
        #expect(queue.item(at: 4) == nil)
        await gates.untilWaiting(["f2", "f4"])
        #expect(queue.runningIndexes == [2, 4])

        queue.show(4)
        #expect(queue.runningIndexes == [4], "f2 is two away: stopped")
        #expect(queue.item(at: 5) == nil)
        #expect(gates.asked == ["f2", "f4"], "nothing new while f2 is still stopping")
        gates.open("f2")
        await gates.untilWaiting(["f4", "f5"])
        #expect(queue.runningIndexes == [4, 5])
        // f5 is already held: wait for f4's run itself to end, not for the gates.
        let f4 = queue.runningTask(at: 4)
        #expect(f4 != nil)
        gates.open("f4")
        if let f4 { await f4.value }
        #expect(updates == [4])
        await gates.untilWaiting(["f5"])
        gates.open("f5")
        await queue.settle()

        #expect(gates.maxInFlight == 2)
        #expect(gates.asked == ["f2", "f4", "f5"])
        #expect(Set(updates) == [4, 5], "a stopped extraction tells nothing")
        #expect(queue.url(at: 2) == nil)
        #expect(queue.failureAlert(at: 2) == nil, "stopped, not failed")
        #expect(queue.takeRefresh(at: 4))
        #expect(!queue.takeRefresh(at: 4), "once")

        // Back at f3: f2's blank page is asked for again.
        queue.show(3)
        #expect(queue.runningIndexes == [2])
        gates.open("f2")
        await queue.settle()
        #expect(gates.asked == ["f2", "f4", "f5", "f2"])
        #expect(queue.url(at: 2) == URL(fileURLWithPath: "/tmp/f2"))
    }

    /// A file two or more away that is asked for isn't started (the next swipe would stop it at once,
    /// wasting a preview slot); it starts when it comes within one file.
    @Test func farFileWaitsUntilWithinOneFile() async {
        let listing = (0..<5).map { Self.file("f\($0)") }
        let extractor = Extractor()
        let queue = PreviewQueue(listing: listing, previewing: "f0", url: Self.started, extract: extractor.extract,
                                 freeSpace: { .max })

        #expect(queue.item(at: 2) == nil)
        await queue.settle()
        #expect(queue.runningIndexes.isEmpty)
        #expect(extractor.asked.isEmpty, "two away: kept pending")
        queue.show(1)
        await queue.settle()
        #expect(extractor.asked == ["f2"])
        #expect(queue.url(at: 2) == URL(fileURLWithPath: "/tmp/f2"))
    }

    /// A neighbor over the size limit, or one that would leave the disk nearly full, waits until it
    /// is on screen; the file on screen is extracted whatever its size.
    @Test func bigNeighborWaitsUntilShown() async {
        let big = PreviewQueue.prefetchLimit + 1
        let listing = [Self.file("a"), Self.file("big", size: big), Self.file("c"), Self.file("d", size: 1)]
        let extractor = Extractor()
        let disk = Disk()
        let queue = PreviewQueue(listing: listing, previewing: "a", url: Self.started, extract: extractor.extract,
                                 freeSpace: { disk.free })

        #expect(queue.item(at: 1) == nil)
        await queue.settle()
        #expect(extractor.asked.isEmpty, "too big to extract ahead of time")
        queue.show(1)
        await queue.settle()
        #expect(extractor.asked == ["big"])
        #expect(queue.takeRefresh(at: 1))

        disk.free = PreviewQueue.prefetchReserve
        #expect(queue.item(at: 2) == nil)
        await queue.settle()
        #expect(extractor.asked == ["big"], "the disk would be nearly full")
        queue.show(2)
        await queue.settle()
        #expect(extractor.asked == ["big", "c"])
        disk.free = PreviewQueue.prefetchReserve + 1
        #expect(queue.item(at: 3) == nil)
        await queue.settle()
        #expect(extractor.asked == ["big", "c", "d"])
    }

    /// The swipe goes through the level's files in the order the list shows them (More > Sort By).
    @Test func swipeOrderIsTheSortedListsOrder() {
        func entry(_ path: String, size: Int64? = nil) -> ArchiveEntry {
            ArchiveEntry(path: path, isDirectory: size == nil, size: size, compressedSize: size, modificationDate: nil)
        }
        let entries = [entry("docs"), entry("a.txt", size: 30), entry("b.txt", size: 10), entry("c.txt", size: 20),
                       entry("docs/d.txt", size: 5)]
        let model = ArchiveModel(reader: FakeReader(entries: entries), undoManager: nil)
        let bySize = FolderSortOrder(key: .size, ascending: true)
        let rows = SortedLevelCache().rows(of: model, path: "", searchText: "", order: bySize)
        let queue = PreviewQueue(listing: rows, previewing: "c.txt", url: Self.started, extract: Extractor().extract)

        #expect(queue.files.map(\.path) == rows.filter { !$0.isDirectory }.map(\.path))
        #expect(queue.files.map(\.path) == ["b.txt", "c.txt", "a.txt"])
        #expect(queue.startIndex == 1)
        #expect(queue.files.map(\.size) == [10, 20, 30])
    }

    /// The free space the queue is told.
    @MainActor private final class Disk {
        var free: Int64 = .max
    }

    /// Extractions held per path until opened; each returns `/tmp/<path>`, or throws once cancelled.
    @MainActor private final class PathGates {
        private(set) var asked: [String] = []
        private(set) var maxInFlight = 0
        private var inFlight = 0
        private var opened: Set<String> = []
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]

        var extract: @MainActor @Sendable (String) async throws -> URL {
            { [self] path in
                asked.append(path)
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
                defer { inFlight -= 1 }
                if !opened.contains(path) {
                    await withCheckedContinuation { waiters[path] = $0 }
                }
                opened.remove(path)
                try Task.checkCancellation()
                return URL(fileURLWithPath: "/tmp/\(path)")
            }
        }

        func open(_ path: String) {
            if let waiter = waiters.removeValue(forKey: path) {
                waiter.resume()
            } else {
                opened.insert(path)
            }
        }

        /// Returns once exactly `paths` are held, with a bounded number of yields.
        func untilWaiting(_ paths: Set<String>, sourceLocation: SourceLocation = #_sourceLocation) async {
            var yields = 0
            while Set(waiters.keys) != paths, yields < 10_000 {
                yields += 1
                await Task.yield()
            }
            #expect(Set(waiters.keys) == paths, sourceLocation: sourceLocation)
        }
    }

    /// Holds extractions until opened.
    @MainActor private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }
}

/// Where the preview is presented from (`FilePreview.presenter(over:)`): over whatever is presented
/// over the level (the search field's controller), and not while something is moving.
@MainActor struct FilePreviewPresenterTests {
    private final class Fake: UIViewController {
        var fakePresented: UIViewController?
        var fakeBeingPresented = false
        var fakeBeingDismissed = false
        override var presentedViewController: UIViewController? { fakePresented }
        override var isBeingPresented: Bool { fakeBeingPresented }
        override var isBeingDismissed: Bool { fakeBeingDismissed }
    }

    @Test func presentsFromTheTopmostSettledController() {
        let host = Fake()
        #expect(FilePreview.presenter(over: host) === host, "nothing over the level")

        let search = Fake()
        host.fakePresented = search
        #expect(FilePreview.presenter(over: host) === search, "the search field's controller is up")
        let alert = Fake()
        search.fakePresented = alert
        #expect(FilePreview.presenter(over: host) === alert)

        alert.fakeBeingDismissed = true
        #expect(FilePreview.presenter(over: host) == nil, "going away: try again")
        alert.fakeBeingDismissed = false
        alert.fakeBeingPresented = true
        #expect(FilePreview.presenter(over: host) == nil, "coming up: try again")
    }
}
