import Foundation
import MachO
import os

/// Deletes the Quick Look stand-in roots (`Kernir-Preview-<UUID>`, see `PreviewStandInStore`) that
/// an earlier run left behind by crashing or being killed before its windows closed.
///
/// Only Lutik's own roots go: direct children of `parent` named exactly `Kernir-Preview-` plus an
/// uppercase UUID (as `UUID().uuidString` writes it), that are real directories (never a symlink
/// or a file, checked with lstat) owned by this user, that this process doesn't use (`isLive`) and
/// that no other running instance holds (`PreviewRootLock`). Everything else in `parent` is left
/// alone, `Kernir/` and `Kernir-<UUID>` folders above all: those hold extracted files and opened
/// copies that may carry the user's edits.
///
/// The app runs it once, synchronously, in `applicationWillFinishLaunching` (`runAtLaunch()`),
/// before any document opens. `parent` has no default, so nothing reaches the real temporary
/// folder by accident; tests pass a folder of their own.
struct PreviewLeftoverSweeper {
    /// The start of every root's name; `PreviewStandInStore.prefix` must match it.
    static let prefix = "Kernir-Preview-"

    private static let logger = Logger(subsystem: "com.kernir.app", category: "previewSweep")

    /// The folder whose direct children are swept.
    let parent: URL
    let fileManager: FileManager
    /// True for a root this process still uses: it stays.
    let isLive: (URL) -> Bool

    init(parent: URL, fileManager: FileManager = .default, isLive: @escaping (URL) -> Bool = { _ in false }) {
        self.parent = parent
        self.fileManager = fileManager
        self.isLive = isLive
    }

    /// Whether `name` is exactly `Kernir-Preview-` plus a UUID in its canonical (uppercase) form.
    static func isRootName(_ name: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        return UUID(uuidString: suffix)?.uuidString == suffix
    }

    /// Deletes every leftover root and returns the ones it deleted. Never throws: what can't be
    /// read or deleted is logged and skipped.
    @discardableResult
    func sweep() -> [URL] {
        guard !Self.refuses(parent: parent) else {
            Self.logger.error("Preview sweep refused: the real temporary folder while tests run")
            return []
        }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: parent.path)
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                Self.logger.error("Preview sweep can't list its folder: \(error.localizedDescription, privacy: .public)")
            }
            return []
        }
        var removed: [URL] = []
        for name in names.sorted() where Self.isRootName(name) {
            let root = parent.appendingPathComponent(name, isDirectory: true)
            guard !isLive(root) else { continue }
            if remove(root) { removed.append(root) }
        }
        if !removed.isEmpty {
            Self.logger.info("Preview sweep removed \(removed.count, privacy: .public) leftover folder(s)")
        }
        return removed
    }

    /// Deletes `root` if it is a real directory of this user's that no other instance holds.
    private func remove(_ root: URL) -> Bool {
        var info = stat()
        guard lstat(root.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid() else { return false }
        // Held while deleting, so the folder can't be swapped for a symlink or claimed meanwhile.
        guard let lock = PreviewRootLock(sweeping: root, expecting: info) else { return false }
        defer { lock.unlock() }
        do {
            try fileManager.removeItem(at: root)
            return true
        } catch {
            Self.logger.error("Preview sweep can't remove \(root.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Launch

    /// The launch sweep of the app's own temporary folder (the sandbox container's tmp). Skipped
    /// when the app hosts unit tests, so a test run never touches the real folder.
    @discardableResult
    static func runAtLaunch() -> [URL] {
        guard !isHostedByTests else { return [] }
        return PreviewLeftoverSweeper(parent: FileManager.default.temporaryDirectory).sweep()
    }

    /// True while XCTest or Swift Testing runs in this process (the app as a test host, or a
    /// test runner).
    static var isHostedByTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
        if keys.contains(where: { environment[$0] != nil }) { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        if Bundle.allBundles.contains(where: { $0.bundleURL.pathExtension == "xctest" }) { return true }
        // Swift Testing under `swift test` loads no XCTest class or bundle: look for its library.
        let markers = ["/XCTest.framework/", "/Testing.framework/", "/libXCTestBundleInject.dylib", "/libTesting.dylib"]
        return (0..<_dyld_image_count()).contains { index in
            guard let name = _dyld_get_image_name(index).map(String.init(cString:)) else { return false }
            return markers.contains { name.contains($0) }
        }
    }

    /// True for the real temporary folder while tests run: a sweep there is refused.
    static func refuses(parent: URL) -> Bool {
        guard isHostedByTests else { return false }
        func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        return canonical(parent) == canonical(FileManager.default.temporaryDirectory)
    }
}

/// An advisory lock (flock(2)) on a `Kernir-Preview-<UUID>` root folder itself, so no lock file
/// is needed. A `PreviewStandInStore` that holds one for its root keeps the launch sweep of a
/// second instance (`open -n`) away from it; the sweeper takes it before deleting. The lock goes
/// with the object (or `unlock()`), and with the process if it dies.
final class PreviewRootLock: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    /// Locks the existing directory `root` for this process. Nil if it isn't a real directory
    /// (a symlink isn't followed) or another holder has it.
    convenience init?(holding root: URL) {
        self.init(root, expecting: nil)
    }

    /// The sweeper's lock: also nil unless `root` is still the directory `expected` describes.
    convenience init?(sweeping root: URL, expecting expected: stat) {
        self.init(root, expecting: expected)
    }

    private init?(_ root: URL, expecting expected: stat?) {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              expected.map({ $0.st_dev == info.st_dev && $0.st_ino == info.st_ino }) ?? true,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
    }

    /// Whether the lock is still held and on the directory at `root` now (not one deleted since,
    /// with another made in its place). A symlink at `root` isn't followed.
    func isHolding(_ root: URL) -> Bool {
        lock.withLock {
            guard descriptor >= 0 else { return false }
            var held = stat()
            var current = stat()
            return fstat(descriptor, &held) == 0 && lstat(root.path, &current) == 0
                && held.st_dev == current.st_dev && held.st_ino == current.st_ino
        }
    }

    /// Releases the lock; later calls do nothing.
    func unlock() {
        lock.withLock {
            guard descriptor >= 0 else { return }
            close(descriptor)  // Closing the only descriptor releases the flock.
            descriptor = -1
        }
    }

    deinit { unlock() }
}
