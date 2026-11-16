import Testing
import Foundation
@testable import Kernir

// MARK: - Launch arguments

@Test func noLaunchArgumentsChangeNothing() {
    #expect(ExtractHereLaunchArguments(domain: [:]) == ExtractHereLaunchArguments())
    #expect(ExtractHereLaunchArguments(domain: ["KernirSuppressReveal": "NO"]).suppressesReveal == false)
}

@Test func launchArgumentsAreRead() {
    let arguments = ExtractHereLaunchArguments(domain: [
        "KernirSuppressReveal": "YES",
        "KernirTrashDirectory": "/private/tmp/work/trash",
        "KernirFolderAccessGrantsKey": "KernirUITestFolderAccessGrants",
        "KernirFolderAccessGrantsReset": "run-1",
    ])
    #expect(arguments.suppressesReveal)
    #expect(arguments.trashDirectory == URL(fileURLWithPath: "/private/tmp/work/trash", isDirectory: true))
    #expect(arguments.folderAccessGrantsKey == "KernirUITestFolderAccessGrants")
    #expect(arguments.folderAccessGrantsReset == "run-1")
}

@Test(arguments: ["", "trash", "~/trash", "./trash"])
func aTrashDirectoryMustBeAnAbsolutePath(_ path: String) {
    #expect(ExtractHereLaunchArguments(domain: ["KernirTrashDirectory": path]).trashDirectory == nil)
}

/// `-KernirDisableOwnContainerSkip YES` is read in Debug builds only; a Release build ignores it.
@Test func theOwnContainerSkipArgumentIsReadInDebugOnly() {
    let arguments = ExtractHereLaunchArguments(domain: ["KernirDisableOwnContainerSkip": "YES"])
    #if DEBUG
    #expect(arguments.disablesOwnContainerSkip)
    #else
    #expect(!arguments.disablesOwnContainerSkip)
    #endif
    #expect(!ExtractHereLaunchArguments(domain: ["KernirDisableOwnContainerSkip": "NO"]).disablesOwnContainerSkip)
}

@Test func anEmptyGrantsKeyIsIgnored() {
    #expect(ExtractHereLaunchArguments(domain: ["KernirFolderAccessGrantsKey": ""]).folderAccessGrantsKey == nil)
}

// MARK: - Reveal

#if os(macOS)
@MainActor @Test func revealShowsTheItemsUnlessSuppressed() {
    let item = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
    var shown: [[URL]] = []

    #expect(ExtractHereEffects.reveal([item], arguments: ExtractHereLaunchArguments()) { shown.append($0) })
    #expect(shown == [[item]])

    var suppressed = ExtractHereLaunchArguments()
    suppressed.suppressesReveal = true
    #expect(!ExtractHereEffects.reveal([item], arguments: suppressed) { shown.append($0) })
    #expect(shown == [[item]])
}
#endif

// MARK: - Trash

@Test func aTestTrashDirectoryTakesTheArchiveInsteadOfTheTrash() throws {
    let work = FileManager.default.temporaryDirectory
        .appendingPathComponent("ExtractHereEffectsTests-\(UUID().uuidString)", isDirectory: true)
    let trash = work.appendingPathComponent("trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let archive = work.appendingPathComponent("project.zip")
    try Data("archive".utf8).write(to: archive)
    try Data("earlier".utf8).write(to: trash.appendingPathComponent("project.zip"))
    var arguments = ExtractHereLaunchArguments()
    arguments.trashDirectory = trash

    let trashed = try ExtractHereEffects.moveToTrash(archive, arguments: arguments)

    // Never replaces what is there, as the Trash renames a duplicate.
    #expect(trashed == trash.appendingPathComponent("project 2.zip"))
    #expect(!FileManager.default.fileExists(atPath: archive.path))
    #expect(String(decoding: try Data(contentsOf: trash.appendingPathComponent("project.zip")), as: UTF8.self)
            == "earlier")
    #expect(String(decoding: try Data(contentsOf: try #require(trashed)), as: UTF8.self) == "archive")
}

// MARK: - Folder access grants

@Test func theAppsStoreUsesTheRealKeyWithoutArguments() throws {
    let (defaults, suite) = makeTestDefaults("ExtractHereEffectsTests")
    defer { removeTestDefaults(defaults, suite: suite) }
    let folder = FileManager.default.temporaryDirectory
    try FolderAccessStore(defaults: defaults).grant(folder)
    let kept = try #require(defaults.data(forKey: FolderAccessStore.defaultKey))

    var arguments = ExtractHereLaunchArguments()
    // A reset without an alternate key never touches the real grants.
    arguments.folderAccessGrantsReset = "run-1"
    let store = ExtractHereEffects.folderAccessStore(defaults: defaults, arguments: arguments)

    // It reads the grants under the real key.
    #expect(store.grants == [folder.standardizedFileURL])
    #expect(defaults.data(forKey: FolderAccessStore.defaultKey) == kept)
}

@Test func uiTestGrantsLiveUnderTheirOwnKeyAndResetOncePerToken() throws {
    let (defaults, suite) = makeTestDefaults("ExtractHereEffectsTests")
    defer { removeTestDefaults(defaults, suite: suite) }
    let real = Data("real grants".utf8)
    defaults.set(real, forKey: FolderAccessStore.defaultKey)
    var arguments = ExtractHereLaunchArguments()
    arguments.folderAccessGrantsKey = "KernirUITestFolderAccessGrants"
    arguments.folderAccessGrantsReset = "test-1"
    let folder = FileManager.default.temporaryDirectory

    // First launch of a test: starts empty, grants go under the test key.
    let first = ExtractHereEffects.folderAccessStore(defaults: defaults, arguments: arguments)
    #expect(first.grants.isEmpty)
    try first.grant(folder)
    #expect(defaults.data(forKey: "KernirUITestFolderAccessGrants") != nil)

    // A relaunch in the same test (same token) keeps them.
    #expect(ExtractHereEffects.folderAccessStore(defaults: defaults, arguments: arguments).grants.count == 1)

    // The next test (new token) starts empty again.
    arguments.folderAccessGrantsReset = "test-2"
    #expect(ExtractHereEffects.folderAccessStore(defaults: defaults, arguments: arguments).grants.isEmpty)
    #expect(defaults.data(forKey: FolderAccessStore.defaultKey) == real)
}

// MARK: - Own container

private let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

/// iOS skips the app's own container (On My iPhone > Kernir is its Documents); macOS doesn't, as
/// its sandbox container links out (Data/Downloads -> ~/Downloads). With either key.
@Test func theAppsStoreSkipsTheOwnContainerOnIOSOnly() throws {
    let (defaults, suite) = makeTestDefaults("ExtractHereEffectsTests")
    defer { removeTestDefaults(defaults, suite: suite) }
    var uiTest = ExtractHereLaunchArguments()
    uiTest.folderAccessGrantsKey = "KernirUITestFolderAccessGrants"
    let documents = home.appendingPathComponent("Documents", isDirectory: true)

    for arguments in [ExtractHereLaunchArguments(), uiTest] {
        let iOS = ExtractHereEffects.folderAccessStore(defaults: defaults, arguments: arguments, onIOS: true)
        #expect(iOS.ownContainer == home)
        #expect(try #require(iOS.access(for: documents)).url == home)

        let macOS = ExtractHereEffects.folderAccessStore(defaults: defaults, arguments: arguments, onIOS: false)
        #expect(macOS.ownContainer == nil)
        #expect(macOS.access(for: documents) == nil)
    }
    #if os(macOS)
    #expect(ExtractHereEffects.folderAccessStore(defaults: defaults, arguments: ExtractHereLaunchArguments())
        .ownContainer == nil)
    #else
    #expect(ExtractHereEffects.folderAccessStore(defaults: defaults, arguments: ExtractHereLaunchArguments())
        .ownContainer == home)
    #endif
}

/// The picker UI tests' fixtures land in the app's Documents: the argument turns the skip off.
@Test func theDisableOwnContainerSkipArgumentTurnsItOff() {
    let (defaults, suite) = makeTestDefaults("ExtractHereEffectsTests")
    defer { removeTestDefaults(defaults, suite: suite) }
    var arguments = ExtractHereLaunchArguments()
    arguments.disablesOwnContainerSkip = true

    let store = ExtractHereEffects.folderAccessStore(defaults: defaults, arguments: arguments, onIOS: true)
    #expect(store.ownContainer == nil)
    #expect(store.access(for: home.appendingPathComponent("Documents", isDirectory: true)) == nil)
    arguments.folderAccessGrantsKey = "KernirUITestFolderAccessGrants"
    #expect(ExtractHereEffects.folderAccessStore(defaults: defaults, arguments: arguments, onIOS: true)
        .ownContainer == nil)
}

// MARK: - iOS UI test hooks

/// `-KernirExtractHereGrant <path>` (Debug builds) names the folder the first `.grant` picker of a
/// launch stands for (`ExtractHereTestHooks.takeGrant`): an absolute path as given, a relative one
/// in the app's home (the UI tests can't name the app's Documents), nested ones too. An empty or
/// absent one is none.
/// Mutants: reading it in a Release build; a relative path taken from the working directory or
/// cut to its first component; an absolute path put under the home.
@Test func theExtractHereGrantArgumentNamesAFolderInDebugOnly() {
    let appHome = URL(fileURLWithPath: "/private/tmp/kernir-app-home", isDirectory: true)
    let absolute = ExtractHereLaunchArguments(domain: ["KernirExtractHereGrant": "/private/tmp/picked"], home: appHome)
    let relative = ExtractHereLaunchArguments(domain: ["KernirExtractHereGrant": "Documents"], home: appHome)
    let nested = ExtractHereLaunchArguments(domain: ["KernirExtractHereGrant": "Documents/Sub"], home: appHome)
    #if DEBUG
    #expect(absolute.extractHereGrant == URL(fileURLWithPath: "/private/tmp/picked", isDirectory: true))
    #expect(relative.extractHereGrant == appHome.appendingPathComponent("Documents", isDirectory: true))
    #expect(nested.extractHereGrant?.path == appHome.path + "/Documents/Sub")
    #expect(nested.extractHereGrant?.hasDirectoryPath == true)
    #else
    #expect(absolute.extractHereGrant == nil)
    #expect(relative.extractHereGrant == nil)
    #expect(nested.extractHereGrant == nil)
    #endif
    #expect(ExtractHereLaunchArguments(domain: ["KernirExtractHereGrant": ""], home: appHome).extractHereGrant == nil)
    #expect(ExtractHereLaunchArguments(domain: [:], home: appHome).extractHereGrant == nil)
    // The other hooks' arguments don't stand in for it.
    #expect(ExtractHereLaunchArguments(domain: ["KernirTrashDirectory": "/private/tmp/picked"], home: appHome)
        .extractHereGrant == nil)
}

/// `-KernirExtractHereReadOnly YES` (Debug builds): the first Extract Here into the archive's
/// folder fails as on a read-only volume, for the `.readOnly` alert (`ExtractHereTestHooks.takeReadOnly`).
/// YES, true and 1 in any case turn it on, like the other switches.
/// Mutants: reading it in a Release build; only "YES" read; a case-sensitive compare.
@Test(arguments: ["YES", "yes", "true", "TRUE", "1"])
func theExtractHereReadOnlyArgumentIsReadInDebugOnly(_ value: String) {
    #if DEBUG
    #expect(ExtractHereLaunchArguments(domain: ["KernirExtractHereReadOnly": value]).failsExtractHereAsReadOnly)
    #else
    #expect(!ExtractHereLaunchArguments(domain: ["KernirExtractHereReadOnly": value]).failsExtractHereAsReadOnly)
    #endif
}

/// Any other value of `-KernirExtractHereReadOnly`, or none, leaves Extract Here as it is.
/// Mutants: any value turning it on; its presence alone turning it on.
@Test(arguments: ["NO", "no", "false", "0", "", "2"])
func aNegativeExtractHereReadOnlyArgumentIsOff(_ value: String) {
    #expect(!ExtractHereLaunchArguments(domain: ["KernirExtractHereReadOnly": value]).failsExtractHereAsReadOnly)
}

@Test func noExtractHereReadOnlyArgumentIsOff() {
    #expect(!ExtractHereLaunchArguments(domain: [:]).failsExtractHereAsReadOnly)
    #expect(!ExtractHereLaunchArguments(domain: ["KernirSuppressReveal": "YES"]).failsExtractHereAsReadOnly)
}

/// The hook's folder is a plain path, not a security-scoped pick, so on a device the system won't
/// start access to it: with the hook (iOS, Debug), access to that folder or one inside it counts
/// as started; any other URL gets the system's answer, so a real grant whose scope won't start is
/// passed over as in production. Only accesses the system started are stopped through it, once per
/// start. Without the hook, or on macOS, the scope is the system's. (A Mac process outside the
/// sandbox starts any URL, so the systems here are fakes.)
/// Mutants: the system's answer kept for the hook's folder (Extract Here then says "couldn't be
/// opened"); every grant lenient; stopping an access the system refused; a stop forwarded twice
/// for one start; the lenient scope without the hook or on macOS.
@Test func theGrantHookCountsOnlyItsOwnFolderAsStarted() {
    let grant = URL(fileURLWithPath: "/private/tmp/kernir-no-such-folder-\(UUID().uuidString)", isDirectory: true)
    let inside = grant.appendingPathComponent("Sub", isDirectory: true)
    let outside = URL(fileURLWithPath: "/private/tmp/kernir-elsewhere-\(UUID().uuidString)", isDirectory: true)
    let started = URL(fileURLWithPath: "/private/tmp/kernir-scoped-\(UUID().uuidString)", isDirectory: true)
    let system = FakeSystemScope(starts: [started])
    var hooked = ExtractHereLaunchArguments()
    hooked.extractHereGrant = grant
    let lenient = ExtractHereEffects.scope(for: hooked, onIOS: true, system: system.scope)

    #if DEBUG
    #expect(lenient.start(grant))
    #expect(lenient.start(inside))
    #expect(!lenient.start(outside))
    lenient.stop(grant)
    lenient.stop(inside)
    lenient.stop(outside)
    #expect(system.stopped.isEmpty)

    #expect(lenient.start(started))
    #expect(lenient.start(started))
    lenient.stop(started)
    lenient.stop(started)
    lenient.stop(started)
    #expect(system.stopped == [started, started])

    #expect(!ExtractHereEffects.scope(for: ExtractHereLaunchArguments(), onIOS: true, system: system.scope).start(grant))
    #expect(!ExtractHereEffects.scope(for: hooked, onIOS: false, system: system.scope).start(grant))
    let onMac = ExtractHereEffects.scope(for: hooked, onIOS: false, system: system.scope)
    onMac.stop(grant)
    #expect(system.stopped == [started, started, grant])
    #else
    // A Release build has no lenient path: the hook's folder gets the system's answer, a refusal.
    #expect(!lenient.start(grant))
    #expect(!lenient.start(inside))
    #expect(lenient.start(started))
    lenient.stop(started)
    lenient.stop(grant)
    #expect(system.stopped == [started, grant])
    #endif
}

/// The factory's store, built with the hook's arguments, opens a granted folder from a folder
/// inside it: a real bookmark and the system's scope end to end. This does not prove the hook's
/// scope is the one wired in: `folderAccessStore` has no seam for the system scope, and a Mac
/// process outside the sandbox starts a temp URL itself, so a store without the hook's scope passes
/// too. That wiring is covered where the scope is built (`theGrantHookCountsOnlyItsOwnFolderAsStarted`)
/// and by the iOS UI tests, on a device whose system refuses the hook's plain path.
@Test func theAppStoreBuiltWithTheGrantHookOpensAGrantedFolder() throws {
    let (defaults, suite) = makeTestDefaults("ExtractHereEffectsTests")
    defer { removeTestDefaults(defaults, suite: suite) }
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("kernir-s8-\(UUID().uuidString)", isDirectory: true)
    let sub = folder.appendingPathComponent("sub", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var hooked = ExtractHereLaunchArguments()
    hooked.extractHereGrant = folder
    hooked.folderAccessGrantsKey = "KernirUITestFolderAccessGrants"
    hooked.disablesOwnContainerSkip = true
    #if DEBUG
    let store = ExtractHereEffects.folderAccessStore(defaults: defaults, arguments: hooked, onIOS: true)
    try store.grant(folder)
    let access = try #require(store.access(for: sub))
    #expect(access.url.standardizedFileURL.resolvingSymlinksInPath() == folder.standardizedFileURL.resolvingSymlinksInPath())
    access.stop()
    #else
    // A Release build ignores the hook's folder: with a system that refuses it, there is no access.
    let refusing = FakeSystemScope(starts: [])
    #expect(!ExtractHereEffects.scope(for: hooked, onIOS: true, system: refusing.scope).start(folder))
    #endif
}

/// A system scope that starts only `starts`, and records what it was asked to stop.
private final class FakeSystemScope: @unchecked Sendable {
    private let lock = NSLock()
    private let starts: Set<URL>
    private var stops: [URL] = []

    init(starts: Set<URL>) { self.starts = starts }

    var stopped: [URL] { lock.withLock { stops } }

    var scope: SecurityScope {
        SecurityScope(start: { [self] in starts.contains($0) },
                      stop: { [self] url in lock.withLock { stops.append(url) } })
    }
}
