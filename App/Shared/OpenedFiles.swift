import Foundation

/// Which archive item a tracked file stands for, so Update replaces only that item without asking,
/// never a different item that later took its path.
enum OpenedItemIdentity: Equatable, Sendable {
    /// An item of the archive as last read or saved (not removed, not replaced, nothing pending),
    /// by what the archive says of it: the same path in a different saved archive, such as one
    /// another app rewrote before a Revert, holds a different item. Two items
    /// with the same size, date and kind can't be told apart this way, nor can items the archive
    /// gives no size or date for.
    case saved(size: Int64?, modified: Date?, isDirectory: Bool)
    /// A pending addition, by the file on disk it adds (`url`): the user's own file, a file in an
    /// added folder, or a snapshot an Update put in.
    case added(URL)
}

/// The copies of archive files handed to other apps to open, each in a `Kernir-<UUID>` folder of
/// its own. The document owns them until it closes, not the model: Revert to
/// Saved and a failed reopen after a save replace the model, so the document hands this to every
/// model it makes. Only `close()`, or `discard(_:)` for a cancelled open, deletes the copies.
@MainActor
final class OpenedFiles {
    /// A copy handed to another app, or a new item another app left in its folder, with a size and
    /// modification date: as last seen when tracked, as found when `changed()` reports it.
    struct File: Sendable, Equatable {
        /// The archive path it goes back in at: the item's path when it was opened; for a new
        /// item, its name in that item's folder, until an Update puts it in under another name.
        var path: String
        /// The copy on disk, in a `Kernir-<UUID>` folder of its own, or the new item next to it.
        let url: URL
        var size: Int64?
        var modified: Date?
        /// The archive items at `path` it stands for: the item the copy was made from, as it was
        /// then, and each item an Update put in from it, so Update may replace these, and only
        /// these, without asking, also after an Update was undone. Empty for a
        /// new item, which may be named like an archive item it has nothing to do with: an export,
        /// a renamed copy.
        var itsItems: [OpenedItemIdentity] = []
    }

    /// Where the `Kernir-<UUID>` folders go. Tests pass a folder of their own.
    nonisolated let parent: URL
    /// The copies handed out, in opening order, until `close()` (or `discard(_:)` for a cancelled one).
    private(set) var files: [File] = []
    /// The `Kernir-<UUID>` folders holding `files`, until `close()` (or `discard(_:)`).
    private var directories: [URL] = []
    /// Set by `close()`: a copy still being made is then deleted, never tracked.
    private(set) var isClosed = false
    /// How many saves `rebaseItems` took in: a copy still being made during one stands for no
    /// item, since the item it was made from may since have been saved over.
    private(set) var saves = 0
    /// The model tracking these files (`adopt(by:)`), and the renames it has not saved.
    private var owner: ObjectIdentifier?
    private var unsavedRenames: [String: String] = [:]
    /// The archive path, in the archive as saved, of each file an unsaved rename moved, or that was tracked
    /// under one at its new path: where a model reading the saved archive puts it back. A file not listed
    /// is at its saved path already, such as a copy of an item that had a rename's new name all along.
    private var savedPaths: [URL: String] = [:]
    /// The archive path of each copy still being made (`copy(named:path:item:asOf:from:)`), by the URL it gets
    /// once made: a rename, or its undo or redo, meanwhile moves it as it moves `files`.
    private var making: [URL: String] = [:]
    /// The new items `markSeen` took on (Don't Update) and no Update put in since (`markUpdated`): named like
    /// an archive item they have nothing to do with, maybe, so they move only with a folder above them
    /// (`renameItems`), never through a rename of a file they share the name of.
    private(set) var keptNewItems: Set<URL> = []
    /// Makes one copy or snapshot, off the main actor. Tests swap it.
    var copyItem: @Sendable (_ source: URL, _ destination: URL) throws -> Void = {
        try FileManager.default.copyItem(at: $0, to: $1)
    }

    nonisolated init(in parent: URL = FileManager.default.temporaryDirectory) {
        self.parent = parent
    }

    /// Copies `source` as `name` into a fresh `Kernir-<UUID>` folder and tracks it as the copy of
    /// the archive item `item` at archive path `path`, or of no item when a save came after `saves`
    /// (the count when `item` was taken). The copy runs off the main actor: `source` can be the
    /// user's own big file on a slow volume. Throws `CancellationError`, leaving nothing behind,
    /// when the task is cancelled or `close()` comes first, before or during the copy.
    func copy(_ source: URL, named name: String, path: String, item: OpenedItemIdentity,
              asOf saves: Int) async throws -> URL {
        try await copy(named: name, path: path, item: item, asOf: saves) { source }
    }

    /// `copy(_:named:path:item:asOf:)` of the file `source` returns, such as the item extracted. From the
    /// call on, the copy goes where renames take `path`: a rename, or its undo or redo, while `source` runs or
    /// the copy is made moves it as it moves a tracked copy (`renameItems`), so it is tracked at its item's
    /// path then, and Revert finds it at the saved one.
    func copy(named name: String, path: String, item: OpenedItemIdentity, asOf saves: Int,
              from source: @MainActor () async throws -> URL) async throws -> URL {
        try checkOpen()
        let url = cloneURL(named: name)
        making[url] = path
        noteSavedPath(of: url, at: path)
        defer { making[url] = nil }
        do {
            let clone = try await clone(try await source(), to: url)
            files.append(File(path: making[url] ?? path, url: clone.url, size: clone.copy?.size,
                              modified: clone.copy?.modified, itsItems: saves == self.saves ? [item] : []))
            return clone.url
        } catch {
            savedPaths[url] = nil
            throw error
        }
    }

    /// A clone of `file` as it is now, named `name` (by default its own name) in a fresh
    /// `Kernir-<UUID>` folder, for Update to put in the archive: the other app can go on writing
    /// the copy itself while the archive is saved. `seen` is `file` with the size
    /// and modification date it had before the clone, the bytes the clone holds. Only `close()`
    /// deletes the snapshot, and `changed()` never looks in its folder. Throws as `copy` does, and
    /// `fileReadUnknown` when the file changed during the clone twice running.
    func snapshot(of file: File, named name: String? = nil) async throws -> (url: URL, seen: File) {
        let clone = try await clone(file.url, to: cloneURL(named: name ?? file.url.lastPathComponent))
        var seen = file
        seen.size = clone.source.size
        seen.modified = clone.source.modified
        return (clone.url, seen)
    }

    /// Deletes a snapshot (`snapshot(of:named:)`) Update made but won't put in, with its `Kernir-<UUID>`
    /// folder, rather than keep a full copy of a maybe big file until `close()`. A copy's
    /// folder, or one these files never made, is left.
    func discardSnapshot(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        guard let index = directories.firstIndex(where: { $0.path == directory.path }),
              !files.contains(where: { $0.url.deletingLastPathComponent().path == directory.path }) else { return }
        try? FileManager.default.removeItem(at: directory)
        directories.remove(at: index)
    }

    /// What to ask about, in two parts. First the tracked copies that still exist and whose size
    /// or modification date differs from when they were last seen, in opening order. Then, folder
    /// by folder in opening order and by name within each, the items another app left in a copy's
    /// folder: an export, a Save As, a renamed copy. Each goes in beside the copy's
    /// item, at that item's archive folder. A missing copy isn't reported: renamed, it shows up as
    /// a new item; deleted, there's nothing to keep. Hidden items (.DS_Store, lock and swap files)
    /// aren't reported. Each comes with the size and modification date found now, so `markSeen`
    /// takes as seen only what the user was shown.
    func changed() -> [File] {
        let changed = files.compactMap { file -> File? in
            guard let stamp = Self.stamp(of: file.url), stamp != Stamp(size: file.size, modified: file.modified)
            else { return nil }
            var found = file
            found.size = stamp.size
            found.modified = stamp.modified
            return found
        }
        return changed + folders().flatMap(newItems(in:))
    }

    /// True for a copy handed out or an item taken on by `markSeen`; false for a new item
    /// `changed()` found next to one.
    func isTracked(_ file: File) -> Bool {
        files.contains { $0.url == file.url }
    }

    /// Takes the size and modification date `file` carries as seen, without looking at the disk
    /// again, so a change made since it was reported is reported again. A tracked file keeps its
    /// `path` and `itsItems` as they are now, and a new item in a copy's folder is tracked from then
    /// on, like a copy, at its path there now (`path(of:)`): a rename since `changed()` reported it
    /// may have moved either.
    func markSeen(_ file: File) {
        if let index = files.firstIndex(where: { $0.url == file.url }) {
            files[index].size = file.size
            files[index].modified = file.modified
        } else {
            var file = file
            file.path = path(of: file)
            if track(file) { keptNewItems.insert(file.url) }
        }
    }

    /// Takes `file` as an Update put it in: its size and modification date as seen, its `path` and
    /// `itsItems` as they are now, so set with no suspension since `path(of:)` was read. A new item
    /// is tracked from then on.
    func markUpdated(_ file: File) {
        keptNewItems.remove(file.url)
        if let index = files.firstIndex(where: { $0.url == file.url }) {
            files[index] = file
        } else {
            track(file)
        }
    }

    /// The archive path `file` goes back in at now: a tracked file's own, a new item's in its copy's
    /// folder's archive folder. A rename since `changed()` reported it may have moved either.
    func path(of file: File) -> String {
        if let tracked = files.first(where: { $0.url == file.url }) { return tracked.path }
        let folder = file.url.deletingLastPathComponent().path
        guard let archiveFolder = folders().first(where: { $0.folder.path == folder })?.archiveFolder
        else { return file.path }
        return Self.path(of: file.url.lastPathComponent, in: archiveFolder)
    }

    /// `file` as it goes back in now: at `path(of:)`, with a tracked file's `itsItems` as they are now (a save
    /// since `changed()` reported it may have rebased them), and its size and modification date as reported.
    func current(_ file: File) -> File {
        var current = file
        current.path = path(of: file)
        if let tracked = files.first(where: { $0.url == file.url }) { current.itsItems = tracked.itsItems }
        return current
    }

    /// Tracks `new`, an item another app left in a copy's folder, from then on, like a copy. False when
    /// `new` isn't in a copy's folder, and isn't tracked.
    @discardableResult
    private func track(_ new: File) -> Bool {
        guard folders().contains(where: { $0.folder.path == new.url.deletingLastPathComponent().path })
        else { return false }
        files.append(new)
        noteSavedPath(of: new.url, at: new.path, isNewItem: true)
        return true
    }

    /// Sets the `itsItems` of every tracked file that has some to what `transform` returns for it:
    /// a save makes the items it saved `.saved`, and the rest no item's. Counts the save.
    func rebaseItems(_ transform: (File) -> [OpenedItemIdentity]) {
        saves += 1
        for index in files.indices where !files[index].itsItems.isEmpty {
            files[index].itsItems = transform(files[index])
        }
    }

    /// Sets the `path` of every tracked file to what `transform` returns for it: View > Text Encoding
    /// listed the archive's names anew, and each file goes back in at its item's new name.
    func renamePaths(_ transform: (String) -> String) {
        for index in files.indices {
            files[index].path = transform(files[index].path)
        }
        for (url, path) in making { making[url] = transform(path) }
    }

    /// Moves the `path` of every tracked file at or beneath the archive path `oldPath` to `newPath`
    /// (`ArchiveModel.remap`): a rename, or its undo or redo, took the item or a folder above it there,
    /// and each file goes back in at its item's new path. Files in `kept` stay: the undo or redo of a
    /// rename passes the files that stayed when the rename (or its undo) was applied, so it moves back
    /// only those that moved then, and those tracked since (made or kept under the name it undoes),
    /// never a copy of another item that had `oldPath` all along. A kept new item (`markSeen`)
    /// moves only when `oldPath` is a folder above it, never when it is its own path: a file rename, or its
    /// undo, would take it onto another item. Returns the files that stay now, for the step
    /// after.
    @discardableResult
    func renameItems(from oldPath: String, to newPath: String, keeping kept: Set<URL> = []) -> Set<URL> {
        var stayed = Set<URL>()
        func move(_ url: URL, from path: String) -> String {
            let moved = kept.contains(url) || (keptNewItems.contains(url) && path == oldPath) ? path
                : ArchiveModel.remap([path], from: oldPath, to: newPath).first ?? path
            if moved.unicodeScalars.elementsEqual(path.unicodeScalars) {
                stayed.insert(url)
                return path
            }
            if savedPaths[url] == nil, !unsavedRenames.isEmpty { savedPaths[url] = path }
            return moved
        }
        for index in files.indices {
            files[index].path = move(files[index].url, from: files[index].path)
        }
        // A copy still being made moves as it would once tracked.
        for (url, path) in making { making[url] = move(url, from: path) }
        return stayed
    }

    /// Tells these files the renames `owner`, the model tracking them, has not saved
    /// (`ArchiveChangeSet.renamedPaths`). Ignored from a model already replaced.
    func noteUnsavedRenames(_ renames: [String: String], by owner: ObjectIdentifier) {
        guard owner == self.owner else { return }
        unsavedRenames = renames
    }

    /// `owner` wrote its edits, or adopted a new listing: every file's path is where the archive now
    /// has its item, so `adopt(by:)` leaves them all. Ignored from a model already replaced.
    func noteArchiveSaved(by owner: ObjectIdentifier) {
        guard owner == self.owner else { return }
        unsavedRenames = [:]
        savedPaths = [:]
    }

    /// A new model (`owner`) tracks these files, read from the archive as saved: Revert to Saved, or a
    /// reread after a reopen failed. Each file an unsaved rename of the previous model moved, or that was
    /// tracked under one, goes back to the path the saved archive has its item at; the
    /// rest stay, a copy of an item that had a rename's new name all along included.
    func adopt(by owner: ObjectIdentifier) {
        self.owner = owner
        unsavedRenames = [:]
        let saved = savedPaths
        savedPaths = [:]
        guard !saved.isEmpty else { return }
        for index in files.indices {
            if let path = saved[files[index].url] { files[index].path = path }
        }
        for (url, path) in making { making[url] = saved[url] ?? path }
    }

    /// Keeps where the file at `url`, tracked now (or being copied) at `path`, is in the archive as saved,
    /// for `adopt(by:)`: a copy of an item at the path an unsaved rename gave the item
    /// (`RenameMap.sourcePath(ofFinal:)`); a new item, `isNewItem`, only where a rename of a folder above
    /// it took it, never through a rename of a file it happens to share the new name of, such as an export
    /// "b.txt" after a.txt → b.txt.
    private func noteSavedPath(of url: URL, at path: String, isNewItem: Bool = false) {
        guard !unsavedRenames.isEmpty else { return }
        let renames = RenameMap(unsavedRenames)
        let saved: String
        if isNewItem {
            let folder = ArchiveModel.parentPath(of: path)
            guard !folder.isEmpty else { return }
            let name = String(String.UnicodeScalarView(path.unicodeScalars.dropFirst(folder.unicodeScalars.count + 1)))
            saved = Self.path(of: name, in: renames.sourcePath(ofFinal: folder))
        } else {
            saved = renames.sourcePath(ofFinal: path)
        }
        if !saved.unicodeScalars.elementsEqual(path.unicodeScalars) { savedPaths[url] = saved }
    }

    /// The archive path of `name` in the archive folder `folder` ("" at the top).
    private static func path(of name: String, in folder: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// Deletes the copy at `url` that `copy` made, with its `Kernir-<UUID>` folder, and forgets it:
    /// an open cancelled after the copy, before any app got it. Pass only urls `copy(_:named:path:item:asOf:)`
    /// returned: the folder of any other url is deleted when this tracks it, and a url in no tracked
    /// folder is left alone.
    func discard(_ url: URL) {
        let folder = url.deletingLastPathComponent().path
        guard let index = directories.firstIndex(where: { $0.path == folder }) else { return }
        try? FileManager.default.removeItem(at: directories.remove(at: index))
        for file in files where file.url.deletingLastPathComponent().path == folder { savedPaths[file.url] = nil }
        files.removeAll { $0.url.deletingLastPathComponent().path == folder }
        keptNewItems = keptNewItems.filter { $0.deletingLastPathComponent().path != folder }
    }

    /// Deletes every copy's folder and forgets them; a copy still being made is deleted once it's
    /// done. Call when the document closes.
    func close() {
        isClosed = true
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        files = []
        savedPaths = [:]
        making = [:]
        keptNewItems = []
    }

    /// The copies' folders, each once, in opening order, with the archive folder their items go in.
    private func folders() -> [(folder: URL, archiveFolder: String)] {
        var folders: [(folder: URL, archiveFolder: String)] = []
        for file in files {
            let folder = file.url.deletingLastPathComponent()
            if !folders.contains(where: { $0.folder.path == folder.path }) {
                folders.append((folder, ArchiveModel.parentPath(of: file.path)))
            }
        }
        return folders
    }

    /// The items in `folder` that aren't tracked and aren't hidden, by name, as new files of the
    /// archive folder `archiveFolder`, seen as they are now.
    private func newItems(in folder: (folder: URL, archiveFolder: String)) -> [File] {
        let tracked = files.filter { $0.url.deletingLastPathComponent().path == folder.folder.path }
            .map(\.url.lastPathComponent)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.folder.path)) ?? []
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name in
            guard !name.hasPrefix("."), !tracked.contains(name) else { return nil }
            let url = folder.folder.appendingPathComponent(name)
            guard (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden != true,
                  let stamp = Self.stamp(of: url) else { return nil }
            return File(path: Self.path(of: name, in: folder.archiveFolder), url: url, size: stamp.size,
                        modified: stamp.modified)
        }
    }

    /// Where a clone named `name` goes: in a fresh `Kernir-<UUID>` folder, not made yet.
    private func cloneURL(named name: String) -> URL {
        parent.appendingPathComponent("Kernir-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    /// Clones `source` to `url` (`cloneURL(named:)`) off the main actor, and keeps its fresh
    /// `Kernir-<UUID>` folder for `close()` to delete. `source` is stamped before and after the clone; if it
    /// changed meanwhile, the clone may hold a mix of two saves, so it's made once more, and a
    /// second change throws `fileReadUnknown` rather than keep bytes nobody saved. Returns the
    /// source's stamp from before the clone it kept, and the clone's own. Throws
    /// `CancellationError`, leaving nothing behind, when the task is cancelled or `close()` comes
    /// first, before or during the clone.
    private func clone(_ source: URL, to url: URL) async throws
        -> (url: URL, source: Stamp, copy: Stamp?) {
        try checkOpen()
        let directory = url.deletingLastPathComponent()
        let copyItem = copyItem
        let cloned = await Task.detached(priority: Task.currentPriority) {
            Result {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for attempt in 1...2 {
                    let before = Self.stamp(of: source)
                    try copyItem(source, url)
                    if let before, before == Self.stamp(of: source) {
                        return (url, before, Self.stamp(of: url))
                    }
                    if attempt == 1 { try FileManager.default.removeItem(at: url) }
                }
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: source.path])
            }
        }.value
        do {
            // A clone made for a closed document or a cancelled task would never be deleted.
            try checkOpen()
            let clone = try cloned.get()
            directories.append(directory)
            return clone
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func checkOpen() throws {
        if isClosed || Task.isCancelled { throw CancellationError() }
    }

    /// A file's size and modification date, as `File` keeps them.
    private struct Stamp: Sendable, Equatable {
        var size: Int64?
        var modified: Date?
    }

    /// Size and modification date read from disk now (no cached resource values); nil if it's gone.
    private nonisolated static func stamp(of url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Stamp(size: (attributes[.size] as? NSNumber)?.int64Value,
                     modified: attributes[.modificationDate] as? Date)
    }
}
