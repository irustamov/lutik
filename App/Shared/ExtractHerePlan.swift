import Foundation
import KernirCore

/// Where Extract Here puts the requested items, next to the archive. One item (after dropping
/// items inside another requested folder) is placed as it is, a folder or a file; more than one go
/// in a new folder named after the archive. Hidden Finder metadata never counts: `ArchiveModel`
/// doesn't show it, so it is never an item here. Pure: the names it picks are made unique only
/// when the result moves into place (`ExtractHereService`).
enum ExtractHerePlan: Equatable, Sendable {
    /// One item, placed next to the archive as `name` (its own name; a nested item comes out on
    /// its own, without the folders above it).
    case single(path: String, name: String, isDirectory: Bool)
    /// Several items, extracted with their archive paths into a folder named `folderName`.
    case wrapped(folderName: String, paths: [String])

    /// A requested item as the user sees it.
    struct Item: Equatable, Sendable {
        let path: String
        let isDirectory: Bool
    }

    /// The plan for `items`, in their order; an item inside another requested folder is covered by
    /// it and dropped, as is a repeat. nil when nothing is left. `isVolumeSet` names the folder
    /// after the set, not the part (`ExtractHereNaming.folderName`).
    static func make(_ items: [Item], archiveURL: URL, isVolumeSet: Bool) -> ExtractHerePlan? {
        let requested = Set(items.map(\.path))
        var seen = Set<String>()
        let topmost = items.filter {
            !ArchiveModel.isCovered(ArchiveModel.parentPath(of: $0.path), by: requested) && seen.insert($0.path).inserted
        }
        guard let first = topmost.first else { return nil }
        if topmost.count == 1 {
            let name = ArchiveEntry.name(of: first.path)
            return .single(path: first.path, name: name, isDirectory: first.isDirectory)
        }
        return .wrapped(folderName: ExtractHereNaming.folderName(for: archiveURL, isVolumeSet: isVolumeSet),
                        paths: topmost.map(\.path))
    }

    /// The plan for `paths` in `model` (nil: every top-level item, in the model's order) as the
    /// user sees them, pending additions included. Paths the model doesn't show (hidden metadata,
    /// an item gone meanwhile) are left out.
    @MainActor
    static func make(_ paths: [String]?, in model: ArchiveModel, archiveURL: URL) -> ExtractHerePlan? {
        let items = paths.map { $0.compactMap(model.item(at:)) } ?? model.items
        let isVolumeSet = (model.reader?.volumeURLs.count ?? 0) > 1
        return make(items.map { Item(path: $0.path, isDirectory: $0.isDirectory) },
                    archiveURL: archiveURL, isVolumeSet: isVolumeSet)
    }
}
