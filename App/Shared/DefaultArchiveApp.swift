#if os(macOS)
import AppKit
import KernirCore
import os
import UniformTypeIdentifiers

/// The part of NSWorkspace that reads and sets the default app for a content type; a seam for tests.
@MainActor
protocol DefaultAppWorkspace: AnyObject {
    func urlForApplication(toOpen contentType: UTType) -> URL?
    func setDefaultApplication(at applicationURL: URL, toOpen contentType: UTType) async throws
    /// Whether a fresh process (as Finder does) sees the app with `bundleIdentifier` as the
    /// default for each of `types` (identifiers): this process's own reading may be stale. A type
    /// missing from the map, or nil for all, means it can't tell.
    func handlersSeenByFinder(bundleIdentifier: String, types: [String]) async -> [String: Bool]?
}

extension DefaultAppWorkspace {
    /// Can't tell (the dry run).
    func handlersSeenByFinder(bundleIdentifier: String, types: [String]) async -> [String: Bool]? { nil }
}

/// NSWorkspace.shared (macOS 12+ API).
@MainActor
final class SystemDefaultAppWorkspace: DefaultAppWorkspace {
    func urlForApplication(toOpen contentType: UTType) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: contentType)
    }

    /// The SDK's async form: Swift makes its completion handler itself, not main-actor isolated, so
    /// Launch Services calling back off the main thread is fine (the completion-handler form
    /// isn't imported into Swift).
    func setDefaultApplication(at applicationURL: URL, toOpen contentType: UTType) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpen: contentType)
    }

    /// Asks a new `osascript` process (`finderCheckScript`): on macOS 26.2 an app without an
    /// entitlement for it gets success from `setDefaultApplication` and reads itself as the
    /// default in its own process, while Launch Services refused and Finder keeps the old app.
    /// nil when the process fails, prints nothing usable or takes over 10 s.
    func handlersSeenByFinder(bundleIdentifier: String, types: [String]) async -> [String: Bool]? {
        guard !types.isEmpty else { return [:] }
        let arguments = ["-l", "JavaScript", "-e", Self.finderCheckScript, bundleIdentifier] + types
        guard let output = await Self.output(of: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: arguments,
                                             timeout: 10) else {
            Self.logger.error("Default app check: osascript failed or timed out; the change is taken as made")
            return nil
        }
        guard let seen = Self.parseHandlers(output, types: types) else {
            Self.logger.error("Default app check: osascript answered nothing usable; the change is taken as made")
            return nil
        }
        return seen
    }

    nonisolated private static let logger = Logger(subsystem: "com.kernir.app", category: "default-app")

    /// JXA. Arguments: the bundle id, then type identifiers. One line per type:
    /// `type<TAB>1|0<TAB>handler path` (1: the handler is a copy of the app), `type<TAB>?` for a
    /// type this process doesn't know.
    nonisolated static let finderCheckScript = #"""
        ObjC.import("AppKit");
        function run(argv) {
            var ws = $.NSWorkspace.sharedWorkspace;
            var mine = ws.URLsForApplicationsWithBundleIdentifier(argv[0]).js.map(function (u) { return ObjC.unwrap(u.URLByStandardizingPath.path); });
            var UTType = $.NSClassFromString("UTType");
            return argv.slice(1).map(function (id) {
                var type = UTType.typeWithIdentifier(id);
                if (type.isNil()) { return id + "\t?"; }
                var url = ws.URLForApplicationToOpenContentType(type);
                if (url.isNil()) { return id + "\t0\t"; }
                var path = ObjC.unwrap(url.URLByStandardizingPath.path);
                var bundle = $.NSBundle.bundleWithURL(url);
                var theirs = bundle.isNil() ? "" : ObjC.unwrap(bundle.bundleIdentifier);
                return id + "\t" + (theirs === argv[0] || mine.indexOf(path) >= 0 ? "1" : "0") + "\t" + path;
            }).join("\n");
        }
        """#

    /// `finderCheckScript`'s output as a map of `types`; lines for other types, `?` and anything
    /// else are skipped. nil when no line names one of `types` (an error message, say).
    nonisolated static func parseHandlers(_ output: String, types: [String]) -> [String: Bool]? {
        let wanted = Set(types)
        var seen: [String: Bool] = [:]
        var answered = false
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, wanted.contains(String(fields[0])) else { continue }
            answered = true
            switch fields[1] {
            case "1": seen[String(fields[0])] = true
            case "0": seen[String(fields[0])] = false
            default: continue
            }
        }
        return answered ? seen : nil
    }

    /// A process's standard output when it exits with 0 within `timeout` seconds; else nil
    /// (terminated, then killed 2 s later if still there).
    nonisolated private static func output(of executable: URL, arguments: [String], timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runToEnd(executable, arguments: arguments, timeout: timeout))
            }
        }
    }

    nonisolated private static func runToEnd(_ executable: URL, arguments: [String], timeout: TimeInterval) -> String? {
        final class Child: @unchecked Sendable {
            let process = Process()
        }
        let child = Child()
        let process = child.process
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem {
            guard child.process.isRunning else { return }
            child.process.terminate()
            let pid = child.process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        exited.wait()
        deadline.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// "Make <app> the default app for archives" (Mac Welcome window) and its per-format form
/// (Settings > General). The claimed types are the app's archive document types
/// (KernirDocumentTypes) minus the split-archive part (the app's own type, Alternate rank) and the
/// zip-based developer packages (jar, apk…: Alternate rank, their own tools stay the default).
/// "For all" (the Welcome button, Settings' Make Default for All) leaves out ISO
/// (`FormatGroup.isInAll`): a double-clicked disk image keeps mounting with DiskImageMounter; only
/// its own Settings row claims it.
@MainActor
struct DefaultArchiveApp {
    /// One user-visible row of Settings: a format, or a few related ones, and their types.
    struct FormatGroup: Identifiable, Sendable {
        let id: String
        /// Format names, e.g. "TAR, TAR.GZ, TAR.BZ2, TAR.XZ" (not translated).
        let title: String
        let types: [UTType]
        /// Part of "for all" (`typesForAll`); ISO isn't.
        var isInAll = true
    }

    let appURL: URL
    /// The app's, for the fresh-process check; nil skips the check.
    let bundleIdentifier: String?
    let workspace: DefaultAppWorkspace

    init(appURL: URL = Bundle.main.bundleURL, bundleIdentifier: String? = nil, workspace: DefaultAppWorkspace? = nil) {
        self.appURL = appURL
        self.bundleIdentifier = bundleIdentifier ?? Bundle(url: appURL)?.bundleIdentifier
        self.workspace = workspace ?? SystemDefaultAppWorkspace()
    }

    /// Identifiers in `identifiers` that name an archive the app should claim, in order, once each:
    /// not a catch-all or folder type, the app's own drag type, the split part or a developer package.
    nonisolated static func claimableIdentifiers(from identifiers: [String]) -> [String] {
        let excluded: Set<String> = Set(KernirDocumentTypes.packageTypes.map(\.identifier)).union([
            KernirDocumentTypes.volumeSetIdentifier, "com.kernir.app.archive-items",
            UTType.item.identifier, UTType.content.identifier, UTType.data.identifier,
        ])
        var seen = Set<String>()
        return identifiers.filter { identifier in
            guard !excluded.contains(identifier), seen.insert(identifier).inserted else { return false }
            if let type = UTType(identifier), type.conforms(to: .directory) || type.conforms(to: .package) { return false }
            return true
        }
    }

    /// Every type to claim.
    nonisolated static var types: [UTType] {
        claimableIdentifiers(from: KernirDocumentTypes.identifiers).map { UTType($0) ?? UTType(importedAs: $0) }
    }

    /// The types "for all" claims: every group's but ISO's.
    nonisolated static var typesForAll: [UTType] {
        groups.filter(\.isInAll).flatMap(\.types)
    }

    /// The claimed types, grouped for Settings > General. Every claimed type is in exactly one group.
    nonisolated static var groups: [FormatGroup] {
        func group(_ id: String, _ formats: [ArchiveFormat], extra: [String] = [], isInAll: Bool = true) -> FormatGroup {
            var identifiers = formats.map { KernirDocumentTypes.utType(for: $0).identifier }
            identifiers += extra
            let claimed = claimableIdentifiers(from: identifiers)
            return FormatGroup(id: id, title: formats.map(\.displayName).joined(separator: ", "),
                               types: claimed.map { UTType($0) ?? UTType(importedAs: $0) }, isInAll: isInAll)
        }
        return [
            group("zip", [.zip]),
            group("7z", [.sevenZip]),
            group("rar", [.rar]),
            // GNU tar has a type of its own but no format: a tar.
            group("tar", [.tar, .tarGzip, .tarBzip2, .tarXz], extra: ["org.gnu.gnu-tar-archive"]),
            // tar.zst and zst share one type.
            group("compressed", [.gzip, .bzip2, .xz, .zstd]),
            // Not in "for all": Finder mounts disk images with DiskImageMounter.
            group("iso", [.iso], isInAll: false),
            group("other", [.cpio, .xar, .cab, .lha]),
        ]
    }

    /// The app is the default for `type`. Another copy of the app (same bundle id) counts.
    func isDefault(for type: UTType) -> Bool {
        guard let handler = workspace.urlForApplication(toOpen: type) else { return false }
        if Self.samePath(handler, appURL) { return true }
        guard let mine = Bundle(url: appURL)?.bundleIdentifier,
              let theirs = Bundle(url: handler)?.bundleIdentifier else { return false }
        return mine == theirs
    }

    /// The app is the default for every one of `types` (false for none).
    func isDefault(for types: [UTType]) -> Bool {
        !types.isEmpty && types.allSatisfy { isDefault(for: $0) }
    }

    /// Whether a fresh process sees the app as the default for each of `identifiers`
    /// (`DefaultAppWorkspace.handlersSeenByFinder`); nil when it can't tell.
    func handlersSeenByFinder(_ identifiers: [String]) async -> [String: Bool]? {
        guard let bundleIdentifier, !identifiers.isEmpty else { return nil }
        return await workspace.handlersSeenByFinder(bundleIdentifier: bundleIdentifier, types: identifiers)
    }

    /// Makes the app the default for each of `types`, one at a time (the system may ask the user
    /// to confirm each). Types it already opens aren't asked again, but `unconfirmed` ones (a
    /// fresh process didn't see the last change) are. When the user turns one down, the rest
    /// aren't asked. A change a fresh process doesn't see is `.notApplied`. Never throws: each
    /// type's outcome is in the result.
    func setDefault(for types: [UTType], unconfirmed: Set<String> = []) async -> DefaultAppChange {
        var entries: [DefaultAppChange.Entry] = []
        var declined = false
        for type in types {
            if declined {
                entries.append(.init(type: type, outcome: .skipped))
            } else if !unconfirmed.contains(type.identifier) && isDefault(for: type) {
                entries.append(.init(type: type, outcome: .alreadyDefault))
            } else {
                do {
                    try await workspace.setDefaultApplication(at: appURL, toOpen: type)
                    entries.append(.init(type: type, outcome: .changed))
                } catch where Self.isUserCancellation(error) {
                    declined = true
                    entries.append(.init(type: type, outcome: .declined))
                } catch {
                    entries.append(.init(type: type, outcome: .failed(error.localizedDescription)))
                }
            }
        }
        let changed = entries.filter { $0.outcome == .changed }.map(\.type.identifier)
        if !changed.isEmpty, let seen = await handlersSeenByFinder(changed) {
            entries = entries.map { entry in
                entry.outcome == .changed && seen[entry.type.identifier] == false
                    ? .init(type: entry.type, outcome: .notApplied) : entry
            }
        }
        return DefaultAppChange(entries: entries)
    }

    /// The user turned down the system's confirmation: Cocoa's user-cancelled, or userCanceledErr
    /// (-128) as an OSStatus or a Launch Services error, also as an underlying error.
    ///
    /// Assumption, unverified: which error macOS returns when the user declines its "Use <app>
    /// for …?" confirmation isn't documented, and checking it would change a real handler
    /// (an owner check by hand). These are the known cancel codes; a decline is never told as a
    /// failure when the error is one of them. Any other error shows the "couldn't" line.
    nonisolated static func isUserCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        let cancelDomains: Set<String> = [NSOSStatusErrorDomain, "com.apple.LaunchServices"]
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError { return true }
        if cancelDomains.contains(error.domain) && error.code == -128 { return true }
        var underlying: [Error] = []
        if let one = error.userInfo[NSUnderlyingErrorKey] as? Error { underlying.append(one) }
        if let many = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] { underlying += many }
        return underlying.contains { isUserCancellation($0) }
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        func path(_ url: URL) -> String {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        return path(a) == path(b)
    }
}

/// What `DefaultArchiveApp.setDefault(for:)` did, type by type, and one line for the UI.
struct DefaultAppChange: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case changed, alreadyDefault
        /// The system reported success, but a fresh process (Finder) still sees another app.
        case notApplied
        /// The user turned down the system's confirmation.
        case declined
        /// Not asked, after a decline.
        case skipped
        /// The system refused; the error's description.
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    struct Entry: Equatable, Sendable {
        let type: UTType
        let outcome: Outcome
    }

    enum Summary: Equatable, Sendable {
        /// Every type now opens in the app (also for no types).
        case allSet
        /// The user said no: show nothing, re-read the state.
        case declined
        /// Some types failed, some are set.
        case partial(failed: Int, total: Int)
        /// None could be set.
        case failed
        /// The system took the change but Finder doesn't see it (`Outcome.notApplied`), for some types; the
        /// system may have refused others (`failedTypes`), which the message tells as well.
        case notApplied
    }

    let entries: [Entry]

    var failedTypes: [UTType] { entries.filter(\.outcome.isFailure).map(\.type) }

    /// The types the system took but a fresh process doesn't see.
    var notAppliedTypes: [UTType] { entries.filter { $0.outcome == .notApplied }.map(\.type) }

    var summary: Summary {
        if entries.contains(where: { $0.outcome == .declined }) { return .declined }
        if !notAppliedTypes.isEmpty { return .notApplied }
        let failed = failedTypes.count
        if failed == 0 { return .allSet }
        return failed == entries.count ? .failed : .partial(failed: failed, total: entries.count)
    }

    /// The alert line for the UI; nil when there's nothing to tell (all set, or the user said no).
    /// `pointsToSettings` adds where to look or retry (the Welcome window); Settings itself leaves it out.
    func message(appName: String, pointsToSettings: Bool = true) -> String? {
        switch summary {
        case .allSet, .declined:
            return nil
        case .notApplied where !failedTypes.isEmpty:
            return String(localized: "macOS didn’t make \(appName) the default app for archives, and refused some archive types outright. In Finder, select an archive of each type, choose File > Get Info, pick \(appName) under “Open with”, then click Change All.", table: "Shared",
                          comment: "Mac Welcome window and Settings: macOS reported success making the app the default for some archive types, but Finder still opens them with another app, and refused other types with an error. Both %@ = the app’s name. File > Get Info, “Open with” and Change All are Finder’s menu item, section and button; keep them as macOS names them.")
        case .notApplied:
            return String(localized: "macOS didn’t make \(appName) the default app for archives. In Finder, select an archive, choose File > Get Info, pick \(appName) under “Open with”, then click Change All.", table: "Shared",
                          comment: "Mac Welcome window and Settings: macOS reported success making the app the default for archives, but Finder still opens them with another app. Both %@ = the app’s name. File > Get Info, “Open with” and Change All are Finder’s menu item, section and button; keep them as macOS names them.")
        case .partial:
            return pointsToSettings
                ? String(localized: "\(appName) is now the default app for some archive types. Settings shows which ones.", table: "Shared",
                         comment: "Mac Welcome window: making the app the default for archives worked for some types and failed for others. %@ = the app’s name. Settings is the app’s Settings window.")
                : String(localized: "\(appName) is now the default app for some archive types.", table: "Shared",
                         comment: "Mac Settings: making the app the default for archives worked for some types and failed for others. %@ = the app’s name.")
        case .failed:
            return pointsToSettings
                ? String(localized: "\(appName) couldn’t be made the default app for archives. Try again in Settings.", table: "Shared",
                         comment: "Mac Welcome window: making the app the default for archives failed. %@ = the app’s name. Settings is the app’s Settings window.")
                : String(localized: "\(appName) couldn’t be made the default app for archives.", table: "Shared",
                         comment: "Mac Settings: making the app the default for archives failed. %@ = the app’s name.")
        }
    }
}
#endif
