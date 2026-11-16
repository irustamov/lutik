import AppKit
import Observation
import UniformTypeIdentifiers

/// "Make <app> the default app for archives" as the Welcome window and Settings > General show it:
/// one row per format group (`DefaultArchiveApp.groups`), whether the app opens them, and the
/// outcome of the last change. `refresh()` re-reads the system's handlers (the windows call it
/// when they become key: the user may have changed a default in Finder meanwhile). The Welcome
/// window and Settings share one (`shared`), so `isWorking` keeps the two from running at once.
@MainActor
@Observable
final class DefaultAppModel {
    /// The running app's, for the Welcome window and Settings.
    static let shared = DefaultAppModel(defaultApp: .forRunningApp())

    struct Row: Identifiable, Equatable {
        let id: String
        /// Format names, e.g. "ZIP" or "TAR, TAR.GZ, TAR.BZ2, TAR.XZ" (not translated).
        let title: String
        let isDefault: Bool
        /// Part of "for all" (`DefaultArchiveApp.FormatGroup.isInAll`).
        var isInAll = true
    }

    /// What the last change did, for the line under the button.
    enum Outcome: Equatable {
        /// Every type asked for now opens in the app.
        case madeDefault
        /// Some or all types failed; the line comes from `problemMessage(pointsToSettings:)`.
        case problem(DefaultAppChange)
    }

    @ObservationIgnored let defaultApp: DefaultArchiveApp
    @ObservationIgnored let appName: String
    @ObservationIgnored private let groups: [DefaultArchiveApp.FormatGroup]

    private(set) var rows: [Row] = []
    /// A change is running (the system may be asking the user to confirm).
    private(set) var isWorking = false
    /// nil before any change, and after the user turned the system's confirmation down.
    private(set) var outcome: Outcome?
    /// Types the system took but a fresh process didn't see (`DefaultAppChange.Outcome.notApplied`):
    /// not the default, whatever this process reads, until a later check sees them.
    @ObservationIgnored private var unconfirmed: Set<String> = []
    @ObservationIgnored private var recheck: Task<Void, Never>?

    init(defaultApp: DefaultArchiveApp, appName: String = AppDisplayName.current,
         groups: [DefaultArchiveApp.FormatGroup] = DefaultArchiveApp.groups) {
        self.defaultApp = defaultApp
        self.appName = appName
        self.groups = groups.filter { !$0.types.isEmpty }
        refresh()
    }

    /// "Make … the Default App" only records the change (`DryRunDefaultAppWorkspace`, Debug):
    /// the Welcome window shows `DefaultAppDryRunMarker`, and the UI tests click only when they find it.
    var isDryRun: Bool {
        #if DEBUG
        defaultApp.workspace is DryRunDefaultAppWorkspace
        #else
        false
        #endif
    }

    /// The line for a failed change; the Welcome window points to Settings, Settings doesn't.
    func problemMessage(pointsToSettings: Bool) -> String? {
        guard case .problem(let change) = outcome else { return nil }
        return change.message(appName: appName, pointsToSettings: pointsToSettings)
    }

    /// The app opens the types of every group in "for all" (ISO's needn't be).
    var isDefaultForAll: Bool {
        let all = rows.filter(\.isInAll)
        return !all.isEmpty && all.allSatisfy(\.isDefault)
    }

    /// Re-reads which groups the app is the default for. Unconfirmed types count as not the
    /// default; with `recheck`, a fresh-process check of them runs in the background.
    func refresh(recheck: Bool = true) {
        let fresh = groups.map { group in
            Row(id: group.id, title: group.title,
                isDefault: defaultApp.isDefault(for: group.types) && !group.types.contains { unconfirmed.contains($0.identifier) },
                isInAll: group.isInAll)
        }
        if fresh != rows { rows = fresh }
        if recheck, !unconfirmed.isEmpty, self.recheck == nil {
            self.recheck = Task { [weak self] in
                await self?.recheckUnconfirmed()
                self?.recheck = nil
            }
        }
    }

    /// Asks a fresh process about the unconfirmed types; the ones it sees as the app's are confirmed.
    func recheckUnconfirmed() async {
        let identifiers = unconfirmed.sorted()
        guard !identifiers.isEmpty, let seen = await defaultApp.handlersSeenByFinder(identifiers) else { return }
        let confirmed = identifiers.filter { seen[$0] == true }
        guard !confirmed.isEmpty else { return }
        unconfirmed.subtract(confirmed)
        refresh(recheck: false)
    }

    /// Makes the app the default for every group in "for all" (not ISO).
    func makeDefaultForAll() async {
        await change(groups.filter(\.isInAll).flatMap(\.types))
    }

    /// Makes the app the default for one group's types.
    func makeDefault(groupID: String) async {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        await change(group.types)
    }

    private func change(_ types: [UTType]) async {
        guard !isWorking else { return }
        isWorking = true
        outcome = nil
        let result = await defaultApp.setDefault(for: types, unconfirmed: unconfirmed)
        for entry in result.entries {
            switch entry.outcome {
            case .notApplied: unconfirmed.insert(entry.type.identifier)
            case .changed, .alreadyDefault: unconfirmed.remove(entry.type.identifier)
            case .declined, .skipped, .failed: break
            }
        }
        isWorking = false
        refresh(recheck: false)
        switch result.summary {
        case .allSet: outcome = .madeDefault
        case .declined: outcome = nil
        case .partial, .failed, .notApplied: outcome = .problem(result)
        }
    }
}

extension DefaultArchiveApp {
    /// The running app's: the system's handlers, or with `-KernirDefaultAppDryRun YES` (Debug, UI
    /// tests) a stand-in that records the changes and never touches Launch Services.
    static func forRunningApp() -> DefaultArchiveApp {
        #if DEBUG
        if LaunchOverrides.defaultAppDryRun {
            return DefaultArchiveApp(workspace: DryRunDefaultAppWorkspace.shared)
        }
        #endif
        return DefaultArchiveApp()
    }
}

#if DEBUG
/// `-KernirDefaultAppDryRun YES`: no type has a default app until the app "sets" itself, which
/// only records the type. Nothing reaches Launch Services.
@MainActor
final class DryRunDefaultAppWorkspace: DefaultAppWorkspace {
    static let shared = DryRunDefaultAppWorkspace()

    private var handlers: [String: URL] = [:]
    /// The type identifiers the app asked to open, in order.
    private(set) var requests: [String] = []

    func urlForApplication(toOpen contentType: UTType) -> URL? { handlers[contentType.identifier] }

    func setDefaultApplication(at applicationURL: URL, toOpen contentType: UTType) async throws {
        requests.append(contentType.identifier)
        handlers[contentType.identifier] = applicationURL
    }
}
#endif
