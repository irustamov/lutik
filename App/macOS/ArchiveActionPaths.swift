import Foundation
import KernirCore

/// The path decisions of `ArchiveActions` that need no window: the name an alert shows for an archive path and
/// the folders above an item. No AppKit, so the tests build it without the app.
enum ArchiveActionPaths {
    // Paths split on the "/" scalar, never on Characters: a "/" followed by a combining mark or a ZWJ, or preceded
    // by a Prepend scalar, is part of one Character that is not "/" (`d/\u{301}x` is `\u{301}x` in folder `d`).

    /// The name an alert shows for the item at archive path `path`: its last component.
    static func displayName(of path: String) -> String {
        ArchiveEntry.name(of: path)
    }

    /// The paths of the folders above the item at `path`, outermost first, then `path` itself.
    static func chain(of path: String) -> [String] {
        var prefix = ""
        return ArchiveEntry.components(of: path).map { component in
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            return prefix
        }
    }

    /// The item at `path` with the folders above it, outermost first, as `model` holds them; nil only when `model`
    /// has no item at `path`. A folder `model` doesn't hold is left out rather than losing the item: Quick Look and
    /// Open (`ArchiveActions.ordered`) keep every item they're given.
    @MainActor static func items(chainOf path: String, in model: ArchiveModel) -> [ArchiveItem]? {
        guard let item = model.item(at: path) else { return nil }
        return Self.chain(of: path).dropLast().compactMap { model.item(at: $0) } + [item]
    }
}
