import AppKit
import Testing
@testable import Kernir
import KernirCore

// The context menu's Move To… and its folder sheet. `MoveToFolders` is the sheet's tree (the archive's
// folders under a row named after the archive) and which rows the items can move into; `ArchiveActions` builds it
// with `canMove` and moves through `move(_:into:)` once the sheet is gone. A recording mover stands for the model's
// move (`ArchiveActions.Mover`), as in `ArchiveTableMoveTests`. Hosted (AppKit) run only.

/// Records what the actions asked the model's move; each moved root lands in the folder under its own name.
@MainActor
private final class MoveRecorder {
    var calls: [(paths: [String], folder: String)] = []

    func install(on actions: ArchiveActions) {
        actions.mover = ArchiveActions.Mover(
            conflicts: { _, _, _ in [] },
            move: { [unowned self] _, paths, folder in
                calls.append((paths, folder))
                guard case .success(let roots) = MovePlanning.roots(paths, into: folder) else { return .failure(.intoItself) }
                var moves: [String: String] = [:]
                for root in roots {
                    let name = String(root.split(separator: "/").last ?? Substring(root))
                    moves[root] = folder.isEmpty ? name : folder + "/" + name
                }
                return .success(moves)
            })
    }
}

private func file(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: false, size: 1, compressedSize: 1, modificationDate: nil)
}

private func folder(_ path: String) -> ArchiveEntry {
    ArchiveEntry(path: path, isDirectory: true, size: nil, compressedSize: nil, modificationDate: nil)
}

/// A window held offscreen and ordered front, so a sheet attaches to it.
@MainActor
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    static func make() -> OffscreenWindow {
        let window = OffscreenWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }
}

@Suite(.serialized) @MainActor
struct MoveToSheetTests {
    private static let entries = [
        folder("docs"), file("docs/a.txt"), folder("docs/sub"), file("docs/sub/d.txt"),
        folder("Other"), folder("other2"), folder("other2/deep"), folder("other2/deep/deeper"),
        file("README"), file("notes"),
    ]

    private func makeActions(format: ArchiveFormat = .zip, entries: [ArchiveEntry] = MoveToSheetTests.entries)
        throws -> (ArchiveDocument, ArchiveActions, MoveRecorder) {
        let document = try ArchiveDocument(type: "public.zip-archive")
        // Doesn't group by event: nothing here may register undo outside a group (the recorder registers none, and
        // the actions' remap registers only into an open group).
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        document.state.model = ArchiveModel(reader: FakeReader(entries: entries, format: format),
                                            undoManager: undoManager)
        let actions = ArchiveActions(document: document)
        document.actions = actions
        let recorder = MoveRecorder()
        recorder.install(on: actions)
        return (document, actions, recorder)
    }

    /// Every row as "path:enabled", depth first, the root as "".
    private func rows(_ folder: MoveToFolders.Folder) -> [String] {
        ["\(folder.id):\(folder.isEnabled)"] + (folder.children ?? []).flatMap(rows)
    }

    // MARK: - The tree

    @Test func theTreeHasTheFoldersOnlyInFinderOrderUnderTheArchiveRow() throws {
        let (document, _, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let items = try #require(document.state.model?.items)
        let folders = MoveToFolders(paths: ["README"], items: items, archiveName: "Photos.zip", canMove: { _, _ in true })

        #expect(folders.root.id == "")
        #expect(folders.root.name == "Photos.zip")
        #expect(folders.root.children?.map(\.id) == ["docs", "Other", "other2"])
        let docs = try #require(folders.root.children?.first)
        #expect(docs.name == "docs")
        #expect(docs.children?.map(\.id) == ["docs/sub"])
        // A folder with no subfolders has no disclosure triangle; files never show.
        #expect(docs.children?.first?.children == nil)
        #expect(folders.root.children?.last?.children?.first?.children?.map(\.id) == ["other2/deep/deeper"])
    }

    @Test func rowsAreEnabledWhereCanMoveSaysSo() throws {
        let (document, _, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let items = try #require(document.state.model?.items)
        var asked: [String] = []
        let folders = MoveToFolders(paths: ["README"], items: items, archiveName: "a.zip", canMove: { paths, folder in
            #expect(paths == ["README"])
            asked.append(folder)
            return folder.hasPrefix("other2")
        })
        #expect(Set(asked) == ["", "docs", "docs/sub", "Other", "other2", "other2/deep", "other2/deep/deeper"])
        #expect(!folders.isEnabled(""))
        #expect(!folders.isEnabled("docs/sub"))
        #expect(folders.isEnabled("other2/deep"))
        #expect(!folders.isEnabled("README"))
        #expect(!folders.isEnabled("gone"))
        #expect(folders.hasTarget)
        #expect(!MoveToFolders(paths: ["README"], items: items, archiveName: "a.zip", canMove: { _, _ in false }).hasTarget)
    }

    /// A disabled row says why (its VoiceOver hint): the items are all in it already, or it is a moved folder or
    /// beneath one. Enabled rows, and rows `canMove` refuses for some other reason, give none.
    @Test func disabledRowsSayWhy() throws {
        let (document, _, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let items = try #require(document.state.model?.items)
        let sibling = MoveToFolders(paths: ["docs/sub", "docs/a.txt"], items: items, archiveName: "a.zip",
                                    canMove: { _, folder in folder != "Other" && folder != "docs" })
        #expect(sibling.disabledReason("docs") == .alreadyThere)
        #expect(sibling.disabledReason("docs/sub") == .intoItself)
        #expect(sibling.disabledReason("") == nil)
        #expect(sibling.disabledReason("Other") == nil)
        #expect(sibling.disabledReason("gone") == nil)

        let top = MoveToFolders(paths: ["other2"], items: items, archiveName: "a.zip",
                                canMove: { _, folder in !folder.isEmpty })
        #expect(top.disabledReason("") == .alreadyThere)
        #expect(top.disabledReason("other2") == .intoItself)
        #expect(top.disabledReason("other2/deep/deeper") == .intoItself)
        #expect(top.disabledReason("docs") == nil)
    }

    @Test func theSheetOpensOnTheFoldersAboveTheMovedItems() throws {
        let (document, _, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let items = try #require(document.state.model?.items)
        func expanded(_ paths: [String]) -> Set<String> {
            MoveToFolders(paths: paths, items: items, archiveName: "a.zip", canMove: { _, _ in true }).initiallyExpanded
        }
        #expect(expanded(["README"]) == [""])
        #expect(expanded(["other2/deep/deeper", "docs/a.txt"]) == ["", "other2", "other2/deep", "docs"])
        // A folder moves with what is in it: only the folders above the folder open.
        #expect(expanded(["docs", "docs/sub/d.txt"]) == [""])
        #expect(expanded(["docs/sub/d.txt", "docs/a.txt"]) == ["", "docs", "docs/sub"])
    }

    /// The sheet scrolls to the folder the first moved item is in now, the deepest open row above it.
    @Test func theSheetScrollsToTheFirstMovedItemsFolder() throws {
        let (document, _, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let items = try #require(document.state.model?.items)
        func target(_ paths: [String]) -> String? {
            MoveToFolders(paths: paths, items: items, archiveName: "a.zip", canMove: { _, _ in true })
                .initialScrollTarget
        }
        #expect(target(["README"]) == "")
        #expect(target(["other2/deep/deeper", "docs/a.txt"]) == "other2/deep")
        #expect(target(["docs/sub/d.txt", "docs/a.txt"]) == "docs/sub")
        // A folder moves with what is in it: its own folder, not the one inside it.
        #expect(target(["docs", "docs/sub/d.txt"]) == "")
        #expect(target([]) == nil)
    }

    @Test func itemsInsideAMovedFolderDoNotCount() throws {
        let (document, _, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let items = try #require(document.state.model?.items)
        func folders(_ paths: [String]) -> MoveToFolders {
            MoveToFolders(paths: paths, items: items, archiveName: "a.zip", canMove: { _, _ in true })
        }
        let docs = folders(["docs", "docs/a.txt", "docs/sub/d.txt"])
        #expect(docs.paths == ["docs", "docs/a.txt", "docs/sub/d.txt"])
        #expect(docs.movedItems == ["docs"])
        #expect(docs.movedCount == 1)
        #expect(docs.singleMovedName == "docs")
        #expect(folders(["other2/deep"]).singleMovedName == "deep")
        let two = folders(["README", "notes"])
        #expect(two.movedCount == 2)
        #expect(two.singleMovedName == nil)
    }

    /// `Targets.takes` is `MovePlanning.roots` succeeding with something to move, NFC spellings included.
    @Test func targetsAnswerAsMovePlanningDoes() {
        let nfd = "Cafe\u{301}"
        let nfc = "Caf\u{E9}"
        let moves: [[String]] = [
            ["README"], ["docs/a.txt"], ["docs", "docs/a.txt"], ["other2/deep", "README"], ["\(nfd)/x", "\(nfd)/y"],
            ["\(nfd)"], ["a/\(nfc)/b", "a/c"], [],
        ]
        let folders = ["", "docs", "docs/sub", "other2", "other2/deep", "other2/deep/deeper", nfc, nfd, "\(nfc)/z",
                       "a", "a/\(nfd)", "a/\(nfd)/b", "a/c"]
        for paths in moves {
            let targets = MoveToFolders.Targets(paths: paths)
            for folder in folders {
                let expected = if case .success(let roots) = MovePlanning.roots(paths, into: folder) {
                    !roots.isEmpty
                } else {
                    false
                }
                #expect(targets.takes(folder) == expected, "\(paths) into \(folder)")
            }
        }
    }

    // MARK: - A big archive

    /// One top folder holding 50 folders of 10 folders of 3 files each: 551 folders, 1,500 files.
    private static let bigEntries: [ArchiveEntry] = {
        var entries = [folder("top")]
        for i in 0..<50 {
            entries.append(folder("top/d\(i)"))
            for j in 0..<10 {
                entries.append(folder("top/d\(i)/e\(j)"))
                for k in 0..<3 { entries.append(file("top/d\(i)/e\(j)/f\(k).txt")) }
            }
        }
        return entries
    }()

    /// The sheet's rows the slow way: `canMove` for every folder.
    private func slowRows(_ actions: ArchiveActions, _ paths: [String], _ items: [ArchiveItem]) -> [String] {
        func walk(_ items: [ArchiveItem]) -> [String] {
            items.filter(\.isDirectory)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .flatMap { ["\($0.path):\(actions.canMove(paths, into: $0.path))"] + walk($0.children ?? []) }
        }
        return [":\(actions.canMove(paths, into: ""))"] + walk(items)
    }

    /// ⌘A on the expanded tree: every item moves, so no folder takes them. The menu answers at once, and the
    /// moved items' folders are disabled without asking `canMove`.
    @Test(.timeLimit(.minutes(1))) func selectingAllOfABigArchiveAnswersAtOnce() throws {
        let (document, actions, _) = try makeActions(entries: Self.bigEntries)
        defer { withExtendedLifetime(document) {} }
        let items = try #require(document.state.model?.items)
        let all = Set(Self.bigEntries.map(\.path))

        var answer = true
        let elapsed = ContinuousClock().measure { answer = actions.canMoveTo(all) }
        #expect(!answer)
        // Well under that in practice; 2 s leaves room for a debug build on a loaded machine.
        #expect(elapsed < .seconds(2), "canMoveTo took \(elapsed)")
        #expect(actions.moveToFolders(for: all) == nil)
        let paths = all.sorted()
        for folder in ["", "top", "top/d0", "top/d49/e9"] {
            #expect(!actions.canMove(paths, into: folder))
        }

        var asked: [String] = []
        let folders = MoveToFolders(paths: paths, items: items, archiveName: "a.zip") { paths, folder in
            asked.append(folder)
            return actions.canMove(paths, into: folder)
        }
        #expect(asked == [""])
        #expect(rows(folders.root).count == 552)
        #expect(!folders.hasTarget)
        #expect(folders.movedItems == ["top"])
    }

    @Test(.timeLimit(.minutes(1))) func everyFileOfABigArchiveCanMoveIntoAnyFolder() throws {
        let (document, actions, _) = try makeActions(entries: Self.bigEntries)
        defer { withExtendedLifetime(document) {} }
        let files = Set(Self.bigEntries.filter { !$0.isDirectory }.map(\.path))

        var answer = false
        let elapsed = ContinuousClock().measure { answer = actions.canMoveTo(files) }
        #expect(answer)
        var built: MoveToFolders?
        let buildTime = ContinuousClock().measure { built = actions.moveToFolders(for: files) }
        // Well under that in practice; 2 s leaves room for a debug build on a loaded machine.
        #expect(elapsed + buildTime < .seconds(2), "canMoveTo \(elapsed), moveToFolders \(buildTime)")
        let folders = try #require(built)
        let shown = rows(folders.root)
        #expect(shown.count == 552)
        #expect(shown.allSatisfy { $0.hasSuffix(":true") })
        #expect(folders.movedCount == 1_500)
    }

    /// Files from one folder, a folder with something inside it selected too, and a file in another: the one pass
    /// disables the same rows as `canMove` asked of every folder.
    @Test(.timeLimit(.minutes(1))) func aBigArchiveDisablesTheRowsCanMoveRefuses() throws {
        let (document, actions, _) = try makeActions(entries: Self.bigEntries)
        defer { withExtendedLifetime(document) {} }
        let items = try #require(document.state.model?.items)
        let selections: [Set<String>] = [
            ["top/d3/e1/f0.txt", "top/d3/e1/f1.txt", "top/d3/e1/f2.txt"],
            ["top/d7", "top/d7/e2", "top/d7/e2/f1.txt", "top/d9/e0/f0.txt"],
            ["top/d1", "top/d2"],
            ["top/d4/e4"],
        ]
        for paths in selections {
            let folders = try #require(actions.moveToFolders(for: paths), "\(paths)")
            #expect(rows(folders.root) == slowRows(actions, paths.sorted(), items), "\(paths)")
            #expect(actions.canMoveTo(paths))
        }
    }

    // MARK: - Which rows the actions disable

    @Test func theItemsOwnFolderIsDisabled() throws {
        let (document, actions, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let folders = try #require(actions.moveToFolders(for: ["docs/a.txt"]))
        #expect(rows(folders.root) == [
            ":true", "docs:false", "docs/sub:true", "Other:true", "other2:true", "other2/deep:true",
            "other2/deep/deeper:true",
        ])
    }

    @Test func aMovedFolderAndEverythingInItAreDisabled() throws {
        let (document, actions, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let folders = try #require(actions.moveToFolders(for: ["other2"]))
        // The top level is where it already is.
        #expect(rows(folders.root) == [
            ":false", "docs:true", "docs/sub:true", "Other:true", "other2:false", "other2/deep:false",
            "other2/deep/deeper:false",
        ])
    }

    @Test func itemsFromTwoFoldersCanMoveIntoEitherButNotBeneathOne() throws {
        let (document, actions, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let folders = try #require(actions.moveToFolders(for: ["README", "docs/sub"]))
        #expect(folders.paths == ["README", "docs/sub"])
        #expect(rows(folders.root) == [
            ":true", "docs:true", "docs/sub:false", "Other:true", "other2:true", "other2/deep:true",
            "other2/deep/deeper:true",
        ])
    }

    @Test func theArchiveRowIsNamedAfterTheDocument() throws {
        let (document, actions, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let folders = try #require(actions.moveToFolders(for: ["README"]))
        #expect(folders.root.name == document.displayName)
    }

    @Test func notOfferedWhereNothingCanMove() throws {
        let (rarDocument, rar, _) = try makeActions(format: .rar)
        defer { withExtendedLifetime(rarDocument) {} }
        #expect(rar.moveToFolders(for: ["README"]) == nil)
        #expect(!rar.canMoveTo(["README"]))

        let (document, actions, _) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        #expect(!actions.canMoveTo([]))
        #expect(!actions.canMoveTo(["gone"]))
        document.state.progress = OperationProgress(title: "Saving", fraction: nil, cancel: nil)
        #expect(!actions.canMoveTo(["README"]))
        document.state.progress = nil
        #expect(actions.canMoveTo(["README"]))
        actions.beginRename("notes")
        #expect(!actions.canMoveTo(["README"]))
        actions.beginMoveTo(["README"])
        #expect(document.state.moveTo == nil)
    }

    // MARK: - Move and Cancel

    @Test func moveClosesTheSheetThenMovesIntoTheChosenFolder() throws {
        let (document, actions, recorder) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        document.state.selection = ["README"]
        actions.beginMoveTo(["README"])
        #expect(document.state.moveTo?.paths == ["README"])

        actions.chooseMoveTo("docs/sub")
        #expect(document.state.moveTo == nil)
        // Not before the sheet is gone: the replace alert must be able to attach.
        #expect(recorder.calls.isEmpty)
        actions.moveToSheetDidEnd()
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.paths == ["README"] && recorder.calls.first?.folder == "docs/sub")
        #expect(document.state.selection == ["docs/sub/README"])
        // Once only.
        actions.moveToSheetDidEnd()
        #expect(recorder.calls.count == 1)
    }

    @Test func theArchiveRowMovesToTheTopLevel() throws {
        let (document, actions, recorder) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        actions.beginMoveTo(["docs/a.txt"])
        actions.chooseMoveTo("")
        actions.moveToSheetDidEnd()
        #expect(recorder.calls.first?.paths == ["docs/a.txt"] && recorder.calls.first?.folder == "")
    }

    @Test func aDisabledRowMovesNothingAndKeepsTheSheet() throws {
        let (document, actions, recorder) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        actions.beginMoveTo(["docs/a.txt"])
        actions.chooseMoveTo("docs")
        actions.chooseMoveTo("gone")
        #expect(document.state.moveTo != nil)
        actions.moveToSheetDidEnd()
        #expect(recorder.calls.isEmpty)
    }

    @Test func cancelMovesNothing() throws {
        let (document, actions, recorder) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        actions.beginMoveTo(["README"])
        actions.cancelMoveTo()
        #expect(document.state.moveTo == nil)
        actions.moveToSheetDidEnd()
        #expect(recorder.calls.isEmpty)
    }

    /// SwiftUI can call the sheet's `onDismiss` while AppKit still has it attached, when `canMove` refuses: the
    /// move waits for the sheet to end.
    @Test func theMoveWaitsForTheSheetToEnd() async throws {
        let (document, actions, recorder) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let window = OffscreenWindow.make()
        defer { window.orderOut(nil) }
        actions.window = window
        actions.beginMoveTo(["README"])
        actions.chooseMoveTo("Other")

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet, completionHandler: nil)
        #expect(window.attachedSheet != nil)
        actions.moveToSheetDidEnd()
        #expect(recorder.calls.isEmpty)

        window.endSheet(sheet)
        // `whenNoSheetAttached` checks every 20 ms; give it up to 2 s.
        let deadline = ContinuousClock.now + .seconds(2)
        while recorder.calls.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.paths == ["README"] && recorder.calls.first?.folder == "Other")
    }

    /// The wait gives up with the sheet still attached: the chosen move can't run, and it beeps rather than go
    /// silently. The swapped-in wait runs the move when the test says, so no 2 s timeout runs here.
    @Test func aMoveThatCantRunAfterTheWaitBeeps() throws {
        let (document, actions, recorder) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let window = OffscreenWindow.make()
        defer { window.orderOut(nil) }
        actions.window = window
        let late = LateMoves()
        late.install(on: actions)

        actions.beginMoveTo(["README"])
        actions.chooseMoveTo("Other")
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet, completionHandler: nil)
        defer { if window.attachedSheet != nil { window.endSheet(sheet) } }
        actions.moveToSheetDidEnd()
        #expect(late.waiting.count == 1)
        #expect(late.beeps == 0)

        // The wait gave up: the sheet is still there.
        late.runNext()
        #expect(recorder.calls.isEmpty)
        #expect(late.beeps == 1)

        // One that can run moves, with no beep (a window without a sheet: AppKit may still be ending this one).
        let clear = OffscreenWindow.make()
        defer { clear.orderOut(nil) }
        actions.window = clear
        document.state.selection = ["README"]
        actions.beginMoveTo(["README"])
        actions.chooseMoveTo("Other")
        actions.moveToSheetDidEnd()
        late.runNext()
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.paths == ["README"] && recorder.calls.first?.folder == "Other")
        #expect(document.state.selection == ["Other/README"])
        #expect(late.beeps == 1)
    }

    /// No window: no sheet to wait for, so the chosen move runs at once; one that can't run then beeps as the
    /// windowed late move does, rather than go silently.
    @Test func aWindowlessMoveThatCantRunBeeps() throws {
        let (document, actions, recorder) = try makeActions()
        defer { withExtendedLifetime(document) {} }
        let late = LateMoves()
        late.install(on: actions)

        actions.beginMoveTo(["README"])
        actions.chooseMoveTo("Other")
        // The archive changed meanwhile: a name field now shows, and `canMove` refuses.
        document.state.renamingPath = "notes"
        actions.moveToSheetDidEnd()
        #expect(late.waiting.isEmpty)
        #expect(recorder.calls.isEmpty)
        #expect(late.beeps == 1)

        document.state.renamingPath = nil
        actions.beginMoveTo(["README"])
        actions.chooseMoveTo("Other")
        actions.moveToSheetDidEnd()
        #expect(late.waiting.isEmpty)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.paths == ["README"] && recorder.calls.first?.folder == "Other")
        #expect(late.beeps == 1)
    }
}

/// Holds the Move To moves waiting for the sheet to go (`ArchiveActions.whenNoSheetAttached`) and counts the beeps.
@MainActor
private final class LateMoves {
    var waiting: [@MainActor () -> Void] = []
    var beeps = 0

    func install(on actions: ArchiveActions) {
        actions.whenNoSheetAttached = { [unowned self] _, body in self.waiting.append(body) }
        actions.beep = { [unowned self] in self.beeps += 1 }
    }

    /// Runs the oldest waiting move, as the wait does when the sheet goes or it gives up.
    func runNext() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst()()
    }
}
