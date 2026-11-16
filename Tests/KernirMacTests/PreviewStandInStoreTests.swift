import Foundation
import Testing
@testable import Kernir

/// Where the preview's stand-ins live and when they go: a
/// folder per stand-in, old renders pruned, everything removed when the preview closes, and no
/// late render writing anything afterwards. Share's copies stay until the window closes.
struct PreviewStandInStoreTests {
    /// A store under a fresh parent folder of the test's own; `body` gets both.
    private func withStore(_ body: (PreviewStandInStore, URL) async throws -> Void) async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernirTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try await body(PreviewStandInStore(parent: parent), parent)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("The root is a Kernir-Preview-<UUID> folder, made only with the first stand-in")
    func root() async throws {
        try await withStore { store, parent in
            #expect(store.root.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL)
            let name = store.root.lastPathComponent
            #expect(name.hasPrefix(PreviewStandInStore.prefix))
            #expect(UUID(uuidString: String(name.dropFirst(PreviewStandInStore.prefix.count))) != nil)
            #expect(name.hasPrefix("Kernir-"), "isOwnTemporaryFile must know it")

            let batch = store.beginBatch()
            #expect(!exists(store.root))
            _ = try store.newFile(named: "a.txt", in: batch)
            #expect(exists(store.root))
        }
    }

    @Test("Each stand-in gets a UUID folder of its own in its batch's folder")
    func folderPerStandIn() async throws {
        try await withStore { store, _ in
            let batch = store.beginBatch()
            let first = try store.newFile(named: "Budget.csv.txt", in: batch)
            let second = try store.newFile(named: "Budget.csv.txt", in: batch)
            #expect(first != second)
            for file in [first, second] {
                #expect(file.lastPathComponent == "Budget.csv.txt")
                let folder = file.deletingLastPathComponent()
                #expect(UUID(uuidString: folder.lastPathComponent) != nil)
                #expect(exists(folder))
                #expect(folder.deletingLastPathComponent().standardizedFileURL == store.folder(of: batch).standardizedFileURL)
            }
            #expect(store.folder(of: batch).deletingLastPathComponent().standardizedFileURL == store.root.standardizedFileURL)
        }
    }

    @Test("A text copy and a written image are real files with the stand-in's name")
    func textCopyAndWrite() async throws {
        try await withStore { store, parent in
            let source = parent.appendingPathComponent("Budget.csv")
            try Data("a,b\n1,2\n".utf8).write(to: source)
            let batch = store.beginBatch()
            let copy = try store.textCopy(of: source, in: batch)
            #expect(copy.lastPathComponent == "Budget.csv.txt")
            #expect(try Data(contentsOf: copy) == Data("a,b\n1,2\n".utf8))
            let image = try store.write(Data([1, 2, 3]), named: "Report.docx.png", in: batch)
            #expect(try Data(contentsOf: image) == Data([1, 2, 3]))
        }
    }

    @Test("Installing a batch deletes the batches before it, which get no more files")
    func installPrunes() async throws {
        try await withStore { store, _ in
            let old = store.beginBatch()
            let oldFile = try store.write(Data([1]), named: "old.png", in: old)
            #expect(store.install(old))
            let new = store.beginBatch()
            let newFile = try store.write(Data([2]), named: "new.png", in: new)
            // The panel still shows `old` until `new` is installed.
            #expect(exists(oldFile))

            #expect(store.install(new))
            #expect(!exists(oldFile))
            #expect(!exists(store.folder(of: old)))
            #expect(exists(newFile))
            #expect(throws: CancellationError.self) { try store.newFile(named: "late.png", in: old) }
            #expect(!exists(store.folder(of: old)))
        }
    }

    @Test("A discarded render is deleted; the installed batch never is")
    func discard() async throws {
        try await withStore { store, _ in
            let shown = store.beginBatch()
            let shownFile = try store.write(Data([1]), named: "shown.png", in: shown)
            store.install(shown)
            let superseded = store.beginBatch()
            _ = try store.write(Data([2]), named: "superseded.png", in: superseded)

            store.discard(superseded)
            #expect(!exists(store.folder(of: superseded)))
            #expect(throws: CancellationError.self) { try store.newFile(named: "late.png", in: superseded) }
            #expect(!store.install(superseded))

            store.discard(shown)
            #expect(exists(shownFile))
        }
    }

    @Test("Closing the preview removes every stand-in and the root")
    func removeAll() async throws {
        try await withStore { store, _ in
            let shown = store.beginBatch()
            _ = try store.write(Data([1]), named: "shown.png", in: shown)
            store.install(shown)
            let pending = store.beginBatch()
            _ = try store.write(Data([2]), named: "pending.png", in: pending)

            store.removeAll()
            #expect(!exists(store.root))
            #expect(!store.install(pending))
        }
    }

    @Test("A render that ends after the preview closed doesn't re-create the root")
    func lateWriteAfterClose() async throws {
        try await withStore { store, parent in
            let source = parent.appendingPathComponent("Page.html")
            try Data("<p>hi</p>".utf8).write(to: source)
            let batch = store.beginBatch()
            // A path handed out just before the panel closed…
            let path = try store.newFile(named: "Page.html.txt", in: batch)
            store.removeAll()
            // …can't be written any more, and nothing comes back.
            #expect(throws: (any Error).self) { try Data([1]).write(to: path, options: .withoutOverwriting) }
            #expect(throws: (any Error).self) { try FileManager.default.copyItem(at: source, to: path) }
            #expect(throws: CancellationError.self) { try store.newFile(named: "late.txt", in: batch) }
            #expect(throws: CancellationError.self) { try store.textCopy(of: source, in: batch) }
            #expect(throws: CancellationError.self) { try store.write(Data([1]), named: "late.png", in: batch) }
            #expect(!exists(store.root))

            // A new render after that starts afresh.
            let next = store.beginBatch()
            _ = try store.textCopy(of: source, in: next)
            #expect(exists(store.root))
            #expect(!exists(store.folder(of: batch)))
        }
    }

    #if DEBUG
    /// The store a test's `afterWrite` hook ends batches in, set once the store exists.
    private final class StoreBox: @unchecked Sendable {
        var store: PreviewStandInStore?
    }

    @Test("The preview closing while a stand-in is written leaves nothing behind")
    func closeDuringWrite() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernirTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let source = parent.appendingPathComponent("Page.html")
        try Data("<p>hi</p>".utf8).write(to: source)
        let box = StoreBox()
        // The panel closes while the stand-in is written: `removeAll()`'s sweep runs, and the
        // file lands after it (on disk the sweep then fails with "directory not empty").
        let store = PreviewStandInStore(parent: parent) { target in
            box.store?.removeAll()
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? Data([1]).write(to: target)
        }
        box.store = store

        let batch = store.beginBatch()
        #expect(throws: CancellationError.self) { try store.write(Data([1]), named: "Report.docx.png", in: batch) }
        #expect(!exists(store.root))
        #expect(throws: CancellationError.self) { try store.textCopy(of: source, in: store.beginBatch()) }
        #expect(!exists(store.root))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).filter {
            $0.hasPrefix(PreviewStandInStore.prefix)
        }.isEmpty)
    }

    @Test("A render superseded while its stand-in is written leaves nothing in its folder")
    func supersededDuringWrite() async throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernirTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let box = StoreBox()
        // A newer render is installed while this one's stand-in is written; its file lands after
        // `install` deleted the old batch's folder.
        let store = PreviewStandInStore(parent: parent) { target in
            guard let store = box.store, target.lastPathComponent == "old.png" else { return }
            let newer = store.beginBatch()
            _ = try? store.write(Data([2]), named: "new.png", in: newer)
            store.install(newer)
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? Data([1]).write(to: target)
        }
        box.store = store

        let old = store.beginBatch()
        #expect(throws: CancellationError.self) { try store.write(Data([1]), named: "old.png", in: old) }
        #expect(!exists(store.folder(of: old)))
        // The installed render keeps its stand-in.
        let batches = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        #expect(batches.count == 1)
    }
    #endif

    // MARK: - Share

    @Test("A Share copy is the real file, under its real name, in share/<UUID>/")
    func shareCopy() async throws {
        try await withStore { store, parent in
            let source = parent.appendingPathComponent("extracted.csv")
            try Data("a,b\n1,2\n".utf8).write(to: source)
            let copy = try store.shareCopy(of: source, named: "Budget.csv")
            #expect(copy.lastPathComponent == "Budget.csv")
            #expect(try Data(contentsOf: copy) == Data("a,b\n1,2\n".utf8))
            let folder = copy.deletingLastPathComponent()
            #expect(UUID(uuidString: folder.lastPathComponent) != nil)
            #expect(folder.deletingLastPathComponent().standardizedFileURL
                    == store.root.appendingPathComponent(PreviewStandInStore.shareFolderName).standardizedFileURL)
            // A copy per click: two shares of the same name never collide.
            let again = try store.shareCopy(of: source, named: "Budget.csv")
            #expect(again != copy)
            #expect(exists(copy) && exists(again))
            // Writing to the copy never touches the source.
            try Data("changed".utf8).write(to: copy)
            #expect(try Data(contentsOf: source) == Data("a,b\n1,2\n".utf8))
        }
    }

    @Test("A folder entry is shared as a copy of the whole folder")
    func shareFolder() async throws {
        try await withStore { store, parent in
            let source = parent.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: source.appendingPathComponent("main.swift"))
            let copy = try store.shareCopy(of: source, named: "src")
            #expect(try Data(contentsOf: copy.appendingPathComponent("main.swift")) == Data("x".utf8))
        }
    }

    @Test("Share copies outlive the preview and go with the window (close)")
    func shareCopiesLifetime() async throws {
        try await withStore { store, parent in
            let source = parent.appendingPathComponent("Report.docx")
            try Data([7]).write(to: source)
            let batch = store.beginBatch()
            let standIn = try store.write(Data([1]), named: "Report.docx.png", in: batch)
            store.install(batch)
            let copy = try store.shareCopy(of: source, named: "Report.docx")

            store.removeAll()
            #expect(!exists(standIn))
            #expect(!exists(store.folder(of: batch)))
            #expect(exists(copy), "AirDrop may still be reading it")

            store.close()
            #expect(!exists(store.root))
            #expect(throws: CancellationError.self) { try store.shareCopy(of: source, named: "Report.docx") }
            #expect(throws: CancellationError.self) { try store.newFile(named: "late.png", in: store.beginBatch()) }
            #expect(!exists(store.root))
        }
    }

    @Test("Closing the preview with only Share copies left keeps the root; without any, it goes")
    func removeAllKeepsOnlyShare() async throws {
        try await withStore { store, parent in
            let source = parent.appendingPathComponent("a.txt")
            try Data([1]).write(to: source)
            _ = try store.shareCopy(of: source, named: "a.txt")
            store.removeAll()
            let left = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
            #expect(left == [PreviewStandInStore.shareFolderName])
        }
    }

    @Test("A failed Share copy leaves nothing")
    func shareCopyFailure() async throws {
        try await withStore { store, parent in
            let missing = parent.appendingPathComponent("gone.txt")
            #expect(throws: (any Error).self) { try store.shareCopy(of: missing, named: "gone.txt") }
            let share = store.root.appendingPathComponent(PreviewStandInStore.shareFolderName)
            let left = try FileManager.default.contentsOfDirectory(atPath: share.path)
            #expect(left.isEmpty)
        }
    }

    @Test("A Share copy's name is one path component, never . or ..")
    func shareName() {
        #expect(PreviewStandInStore.shareName("Budget.csv", fallback: "x") == "Budget.csv")
        #expect(PreviewStandInStore.shareName("", fallback: "Budget.csv") == "Budget.csv")
        #expect(PreviewStandInStore.shareName(".", fallback: "Budget.csv") == "Budget.csv")
        #expect(PreviewStandInStore.shareName("..", fallback: "Budget.csv") == "Budget.csv")
        #expect(PreviewStandInStore.shareName("a/b", fallback: "Budget.csv") == "Budget.csv")
        #expect(PreviewStandInStore.shareName("..", fallback: "..") == "Shared Item")
        #expect(PreviewStandInStore.shareName("...", fallback: "x") == "...")
    }

    @Test("A cancelled render gets no file")
    func cancelledTask() async throws {
        try await withStore { store, _ in
            let batch = store.beginBatch()
            let task = Task.detached { () -> Bool in
                while !Task.isCancelled { await Task.yield() }
                return (try? store.newFile(named: "late.png", in: batch)) != nil
            }
            task.cancel()
            #expect(await task.value == false)
            #expect(!exists(store.root))
        }
    }

    // MARK: - Root lock (the launch sweep of another instance)

    /// A sweep of `parent` as a second Kernir's launch would run it: nothing counts as live in it.
    private func sweep(_ parent: URL) -> [URL] {
        PreviewLeftoverSweeper(parent: parent).sweep()
    }

    @Test("While the root exists the store holds its lock: a sweep of the same folder leaves it")
    func lockKeepsTheSweepAway() async throws {
        try await withStore { store, parent in
            #expect(!store.holdsRootLock, "no root yet, no lock")
            let batch = store.beginBatch()
            let file = try store.write(Data([1]), named: "shown.png", in: batch)
            store.install(batch)
            #expect(store.holdsRootLock)
            #expect(PreviewRootLock(holding: store.root) == nil, "another holder can't take it")
            let stale = parent.appendingPathComponent(PreviewStandInStore.prefix + UUID().uuidString)
            try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)

            #expect(sweep(parent).map(\.lastPathComponent) == [stale.lastPathComponent])
            #expect(exists(file))
            #expect(!exists(stale))
        }
    }

    @Test("removeAll() deleting the root drops the lock; the next stand-in makes and locks it again")
    func lockFollowsTheRoot() async throws {
        try await withStore { store, parent in
            _ = try store.write(Data([1]), named: "a.png", in: store.beginBatch())
            #expect(store.holdsRootLock)
            store.removeAll()
            #expect(!exists(store.root))
            #expect(!store.holdsRootLock)

            let batch = store.beginBatch()
            let file = try store.write(Data([2]), named: "b.png", in: batch)
            #expect(store.holdsRootLock)
            #expect(sweep(parent).isEmpty)
            #expect(exists(file))
        }
    }

    @Test("Share copies keep the root, and its lock, after removeAll(); close() drops both")
    func lockWithShareCopies() async throws {
        try await withStore { store, parent in
            let source = parent.appendingPathComponent("Budget.csv")
            try Data([7]).write(to: source)
            let copy = try store.shareCopy(of: source, named: "Budget.csv")
            #expect(store.holdsRootLock, "a Share copy alone makes and locks the root")
            store.removeAll()
            #expect(exists(copy))
            #expect(store.holdsRootLock)
            #expect(sweep(parent).isEmpty)
            #expect(exists(copy), "AirDrop may still be reading it")

            store.close()
            #expect(!exists(store.root))
            #expect(!store.holdsRootLock)
            // Nothing holds the old root's name any more: a folder made there now is a leftover.
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: false)
            #expect(sweep(parent).map(\.lastPathComponent) == [store.root.lastPathComponent])
        }
    }

    @Test("A root deleted behind the store's back is locked afresh when it is made again")
    func lockOnARemadeRoot() async throws {
        try await withStore { store, parent in
            _ = try store.write(Data([1]), named: "a.png", in: store.beginBatch())
            try FileManager.default.removeItem(at: store.root)
            #expect(!store.holdsRootLock, "the lock is on a folder that's gone")
            _ = try store.write(Data([2]), named: "b.png", in: store.beginBatch())
            #expect(store.holdsRootLock)
            #expect(sweep(parent).isEmpty)
            #expect(exists(store.root))
        }
    }

    #if DEBUG
    /// What a test's `beforeRootLock` hook did: how often it ran, and a lock it took on the root.
    private final class RootHook: @unchecked Sendable {
        var calls = 0
        /// While true, the hook holds the lock on the root as it is now.
        var blocks = true
        var lock: PreviewRootLock?
    }

    /// A fresh parent folder of the test's own, removed afterwards.
    private func withParent(_ body: (URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernirTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(parent)
    }

    @Test("A root swept between being made and locked is made again and locked")
    func rootSweptBeforeItIsLocked() throws {
        try withParent { parent in
            let hook = RootHook()
            // Another instance's launch sweep takes the new, still empty root once.
            let store = PreviewStandInStore(parent: parent, beforeRootLock: { root in
                hook.calls += 1
                if hook.calls == 1 { try? FileManager.default.removeItem(at: root) }
            })
            let file = try store.write(Data([1]), named: "a.png", in: store.beginBatch())
            #expect(hook.calls == 2)
            #expect(store.holdsRootLock)
            #expect(sweep(parent).isEmpty)
            #expect(exists(file))
        }
    }

    @Test("A root that can't be locked gets no stand-in and no Share copy, and goes")
    func rootThatCantBeLocked() throws {
        try withParent { parent in
            let source = parent.appendingPathComponent("Budget.csv")
            try Data([7]).write(to: source)
            let hook = RootHook()
            // Someone else holds the root's lock, every time the store tries.
            let store = PreviewStandInStore(parent: parent, beforeRootLock: { root in
                hook.calls += 1
                guard hook.blocks, hook.lock?.isHolding(root) != true else { return }
                hook.lock?.unlock()
                hook.lock = PreviewRootLock(holding: root)
            })
            #expect(throws: CocoaError.self) { try store.write(Data([1]), named: "a.png", in: store.beginBatch()) }
            #expect(hook.calls == 3)
            #expect(!store.holdsRootLock)
            #expect(!exists(store.root), "the empty root it made goes")
            #expect(throws: CocoaError.self) { try store.shareCopy(of: source, named: "Budget.csv") }
            #expect(hook.calls == 6)
            #expect(!exists(store.root))

            // Once the other holder lets go, the next stand-in makes and locks the root.
            hook.blocks = false
            hook.lock?.unlock()
            let file = try store.write(Data([2]), named: "b.png", in: store.beginBatch())
            #expect(store.holdsRootLock)
            #expect(exists(file))
        }
    }

    @Test("close() racing a Share copy leaves no folder behind, not even the root")
    func closeDuringShareCopy() throws {
        try withParent { parent in
            let source = parent.appendingPathComponent("Budget.csv")
            try Data([7]).write(to: source)
            let box = StoreBox()
            // The archive window closes while the copy is written: `close()` deletes the root, and
            // the copy lands after that (on disk the delete then fails with "directory not empty").
            let store = PreviewStandInStore(parent: parent) { target in
                box.store?.close()
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? Data([7]).write(to: target)
            }
            box.store = store
            #expect(throws: CancellationError.self) { try store.shareCopy(of: source, named: "Budget.csv") }
            #expect(!exists(store.root))
            #expect(!store.holdsRootLock)
            #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path) == ["Budget.csv"])
        }
    }
    #endif
}
