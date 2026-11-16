import Foundation

extension ArchiveEntry {
    /// The folder that holds the item at `path`: everything before its last "/" scalar, "" for a top-level item.
    ///
    /// Splits on the "/" unicode scalar, never on Characters: a "/" followed by a combining mark or a ZWJ, or
    /// preceded by a Prepend scalar, is part of one Character that is not "/", so `lastIndex(of: "/")` on the
    /// String hides it (`d/\u{301}x` would have no parent). Use this, not a Character split, wherever an app
    /// places, groups or covers items by path, so it agrees with the core.
    ///
    /// Precondition: `path` is normalized as the core produces entry paths ("/"-separated, no leading or trailing
    /// "/", no empty components). Nothing is normalized here: `"a/"` gives `"a"`, `"a//b"` gives `"a/"`.
    public static func parentPath(of path: String) -> String {
        EntryPath.parent(of: path) ?? ""
    }

    /// The last component of `path` (after its last "/" scalar); `path` itself when it has no component.
    /// Scalar split, same precondition as `parentPath(of:)`.
    public static func name(of path: String) -> String {
        EntryPath.split(path).last ?? path
    }

    /// `path` split on the "/" scalar, empty components omitted as `String.split` omits them; nothing else is
    /// changed (no normalization). Scalar split, same precondition as `parentPath(of:)`.
    public static func components(of path: String) -> [String] {
        EntryPath.split(path)
    }
}
