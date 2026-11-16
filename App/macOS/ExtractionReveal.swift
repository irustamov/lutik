import AppKit

/// What shows an extraction in Finder: the two calls `ExtractionReveal` chooses between.
@MainActor
protocol FinderRevealing {
    /// A Finder window with `urls` selected.
    func select(_ urls: [URL])
    /// A Finder window showing the inside of `folder`.
    func open(_ folder: URL)
}

struct WorkspaceRevealer: FinderRevealing {
    func select(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    func open(_ folder: URL) { NSWorkspace.shared.open(folder) }
}

/// Where Finder goes after Extract…: a window inside the destination folder, with what the extraction
/// put there selected. Selecting the destination itself would open its parent (the user's home for
/// Downloads) with the destination highlighted.
enum ExtractionReveal {
    /// The items directly in `destination` that the extraction made: each placed URL, or for one
    /// deeper down (a file extracted from inside a folder) the first component under `destination`.
    /// Placed order, no repeats. Anything outside `destination` is ignored.
    static func topLevelItems(placed: [URL], in destination: URL) -> [URL] {
        let base = destination.standardizedFileURL.pathComponents
        let resolvedBase = destination.resolvingSymlinksInPath().pathComponents
        var result: [URL] = []
        var seen = Set<String>()
        for url in placed {
            let standard = url.standardizedFileURL.pathComponents
            let resolved = url.resolvingSymlinksInPath().pathComponents
            let first: String, isDirect: Bool
            if standard.count > base.count, standard.starts(with: base) {
                first = standard[base.count]
                isDirect = standard.count == base.count + 1
            } else if resolved.count > resolvedBase.count, resolved.starts(with: resolvedBase) {
                first = resolved[resolvedBase.count]
                isDirect = resolved.count == resolvedBase.count + 1
            } else {
                continue
            }
            guard seen.insert(first).inserted else { continue }
            // The placed URL itself when it is the top-level item; else the folder above a deeper one.
            result.append(isDirect ? url : destination.appendingPathComponent(first, isDirectory: true))
        }
        return result
    }

    /// Selects the extracted top-level items inside the destination; with none (everything skipped),
    /// opens the destination itself.
    @MainActor
    static func reveal(placed: [URL], in destination: URL, using revealer: FinderRevealing = WorkspaceRevealer()) {
        let items = topLevelItems(placed: placed, in: destination)
        if items.isEmpty {
            revealer.open(destination)
        } else {
            revealer.select(items)
        }
    }
}
