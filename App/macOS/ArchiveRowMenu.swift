import AppKit
import KernirCore
import UniformTypeIdentifiers

/// The row menu's Open With and Share: which rows each takes, whether it can run, and Open
/// With's apps. Made each time the menu opens, from the clicked or selected rows, in no order: Select All on a
/// large archive must not sort them for a menu (`ArchiveActions.ordered` runs only when Share or Open With is
/// chosen). `ArchiveActions.rowMenu(for:)` asks the system for the apps (by each file's type, from its name:
/// nothing is extracted to build the menu), and `ArchiveTableView` only shows it. Read-only archives get both:
/// neither changes the archive.
struct ArchiveRowMenu: Equatable {
    /// One clicked or selected row.
    struct Row: Equatable {
        let path: String
        let isDirectory: Bool
    }

    /// Share's items: every row, folders too, except one inside a folder also shared.
    let sharePaths: Set<String>
    /// Open With's files: folders are skipped (they open in place).
    let openWithPaths: Set<String>
    /// Open With's apps, as Finder lists them: the default first, then the rest by name, each once
    /// (`PreviewNavigation.openWithApps`). With several files, only the apps that open every one of them,
    /// and a default only when it is every file's default.
    let apps: [URL]
    /// The app that leads `apps`, if any.
    let defaultApp: URL?
    /// Open With (its apps and Other…) can run now: there are files, and no operation runs.
    let canOpen: Bool
    /// Share… can run now: there are rows, no operation runs, and no other Share is being prepared.
    let canShare: Bool

    /// Open With shows for a row menu with at least one file; disabled when it can't run.
    var showsOpenWith: Bool { !openWithPaths.isEmpty }
    /// The apps after the default (all of them when none leads).
    var otherApps: [URL] { defaultApp == nil ? apps : Array(apps.dropFirst()) }
    /// A separator between the default app and the others, as in Finder.
    var showsSeparatorAfterDefault: Bool { defaultApp != nil && apps.count > 1 }

    /// `rows` in any order; `canRun` is false while an operation runs (`ArchiveActions.canOpen`), `isSharing`
    /// while a Share is being prepared (`ArchiveActions.isSharing`). `type` is asked once per distinct
    /// lowercased extension, `appsToOpen` and `defaultApp` at most once per distinct type, and no more once no
    /// app and no default is common to the types so far; `name` orders the apps.
    init(rows: [Row], canRun: Bool, isSharing: Bool = false,
         type typeOf: (_ pathExtension: String) -> UTType = ArchiveRowMenu.type,
         appsToOpen: (UTType) -> [URL], defaultApp: (UTType) -> URL?, name: (URL) -> String) {
        let all = Set(rows.map(\.path))
        sharePaths = all.filter { !ArchiveModel.isCovered(ArchiveModel.parentPath(of: $0), by: all) }
        canShare = canRun && !isSharing && !sharePaths.isEmpty
        let files = rows.filter { !$0.isDirectory }.map(\.path)
        openWithPaths = Set(files)
        canOpen = canRun && !files.isEmpty

        // Each extension once, then each type once (two extensions can name one type): a type lookup per
        // extension, not per file. Sorted, so the lookups don't follow the rows' (unordered) order.
        let extensions = Set(files.map { (ArchiveEntry.name(of: $0) as NSString).pathExtension.lowercased() })
        var types: [UTType] = []
        for pathExtension in extensions.sorted() {
            let found = typeOf(pathExtension)
            if !types.contains(found) { types.append(found) }
        }
        guard let first = types.first else {
            apps = []
            self.defaultApp = nil
            return
        }
        // The apps of the first type that every other type has too; the default when all types share it. A
        // type's default is asked only while one is still shared, and no type is asked once neither is left.
        var common = appsToOpen(first)
        var sharedDefault = defaultApp(first)
        for type in types.dropFirst() {
            if common.isEmpty, sharedDefault == nil { break }
            let keys = Set(appsToOpen(type).map(Self.key))
            common = common.filter { keys.contains(Self.key($0)) }
            if let current = sharedDefault, defaultApp(type).map(Self.key) != Self.key(current) {
                sharedDefault = nil
            }
        }
        apps = PreviewNavigation.openWithApps(common, defaultApp: sharedDefault, name: name)
        self.defaultApp = sharedDefault
    }

    /// A file's type by its lowercased extension ("" for none), as `PreviewNavigation.iconType` gives it.
    static func type(_ pathExtension: String) -> UTType {
        pathExtension.isEmpty ? .data : UTType(filenameExtension: pathExtension) ?? .data
    }

    /// One app under any spelling of its path.
    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// An app's icon at menu size, as Finder shows it.
    @MainActor
    static func icon(for app: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}
