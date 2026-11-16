import Foundation

/// Carries a downloaded archive's quarantine over to what Lutik makes from it, as Archive Utility does.
///
/// The Mac app has `com.apple.security.files.user-selected.executable`, so the sandbox no longer
/// quarantines the files it writes in folders the user chose: without that entitlement every archive
/// it creates and every item it extracts got `com.apple.quarantine` (0082, agent Lutik), and
/// Gatekeeper refused to open them ("Apple could not verify … is free of malware"). With it, an item
/// extracted from a quarantined download would lose its quarantine (a Gatekeeper bypass); this puts it
/// back. A sandboxed app can't remove a quarantine, and raw setxattr of one is refused, but setting
/// `quarantineProperties` works (checked in a sandbox on macOS 26: the agent becomes Lutik, the
/// event identifier is kept).
///
/// With the entitlement the sandbox also drops the quarantine of an item the app renames into a
/// user-selected folder (not of what is inside a renamed folder): mark items once they are in place,
/// after the last move (measured on macOS 26, 2026-11-16).
enum QuarantinePropagation {
    /// Gives every item in `items` (and, when `recursive`, everything inside a folder among them) the
    /// quarantine of the first quarantined archive in `sources`. Does nothing when none is quarantined.
    /// Best effort: an item that can't be marked is skipped. Returns how many items were marked.
    @discardableResult
    static func propagate(from sources: [URL], to items: [URL], recursive: Bool = true) -> Int {
        #if os(macOS)
        guard let properties = properties(of: sources) else { return 0 }
        return apply(properties, to: items, recursive: recursive)
        #else
        return 0
        #endif
    }

    #if os(macOS)
    /// The quarantine properties of the first URL in `sources` quarantined by someone else than the sandbox
    /// for Lutik itself (`isOwnSandboxMark`), nil when none is.
    static func properties(of sources: [URL]) -> [String: Any]? {
        sources.lazy.compactMap(quarantineProperties(of:)).first { !isOwnSandboxMark($0) }
    }

    /// Whether `properties` are the quarantine the sandbox gives every file Lutik writes in its own container
    /// (0086, agent Lutik, no download event, no origin): never carried over, or an archive Lutik made itself,
    /// such as an inner archive of a clean one, would make what comes out of it look downloaded (Gatekeeper
    /// refuses it). A downloaded archive's mark has an event or an origin, also once Lutik carried it over.
    static func isOwnSandboxMark(_ properties: [String: Any], agents: Set<String> = ownAgentNames) -> Bool {
        let provenance = ["LSQuarantineEventIdentifier", "LSQuarantineOriginURL", "LSQuarantineDataURL"]
        guard provenance.allSatisfy({ properties[$0] == nil }) else { return false }
        let agent = ["LSQuarantineAgentBundleIdentifier", "LSQuarantineAgentName"]
            .compactMap { properties[$0] as? String }
        return !agent.isEmpty && agent.allSatisfy(agents.contains)
    }

    /// The names the sandbox records as this app's agent: its bundle identifier, names and process name.
    static let ownAgentNames: Set<String> = {
        let info = Bundle.main.infoDictionary ?? [:]
        let names = [Bundle.main.bundleIdentifier, info["CFBundleName"] as? String,
                     info["CFBundleDisplayName"] as? String, info["CFBundleExecutable"] as? String,
                     ProcessInfo.processInfo.processName]
        return Set(names.compactMap { $0 })
    }()

    /// Sets `properties` as the quarantine of `items` and, when `recursive`, of everything inside a folder
    /// among them. Never through a symlink: its target may be outside what was written. Best effort.
    /// `stopsWhenCancelled`: stops early once the task is cancelled (asked every `cancellationStride` items),
    /// only for what a cancel then removes (an extraction's staging); what is already in place is always
    /// marked whole, or a cancel would leave it unquarantined.
    @discardableResult
    static func apply(_ properties: [String: Any], to items: [URL], recursive: Bool = true,
                      stopsWhenCancelled: Bool = false) -> Int {
        var marked = 0, visited = 0
        func stops() -> Bool {
            defer { visited += 1 }
            return stopsWhenCancelled && visited % cancellationStride == 0 && Task.isCancelled
        }
        func mark(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return }
            var url = url
            var values = URLResourceValues()
            values.quarantineProperties = properties
            if (try? url.setResourceValues(values)) != nil { marked += 1 }
        }
        for item in items {
            if stops() { return marked }
            mark(item)
            var info = stat()
            guard recursive, lstat(item.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  let enumerator = FileManager.default.enumerator(at: item, includingPropertiesForKeys: nil)
            else { continue }
            // The enumerator lists symlinks without following them; `mark` skips them.
            for case let url as URL in enumerator {
                if stops() { return marked }
                mark(url)
            }
        }
        return marked
    }

    /// How many items `apply` marks between two looks at the task's cancellation.
    static let cancellationStride = 256

    /// `url`'s quarantine properties, nil when it isn't quarantined.
    static func quarantineProperties(of url: URL) -> [String: Any]? {
        var url = url
        url.removeAllCachedResourceValues()
        guard let properties = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties,
              !properties.isEmpty else { return nil }
        return properties
    }
    #endif

    /// A source's quarantine, captured before a save replaces it (or an extraction moves what it wrote)
    /// and set on the result afterwards (`apply(_:to:recursive:stopsWhenCancelled:)`). Never one on iOS.
    /// Unchecked: the property-list values are never mutated.
    struct Mark: @unchecked Sendable {
        let properties: [String: Any]
        init?(of sources: [URL]) {
            #if os(macOS)
            guard let properties = QuarantinePropagation.properties(of: sources) else { return nil }
            self.properties = properties
            #else
            return nil
            #endif
        }
        /// Tests: a mark of `properties` as they are.
        init(properties: [String: Any]) {
            self.properties = properties
        }
        @discardableResult
        func apply(to items: [URL], recursive: Bool = true, stopsWhenCancelled: Bool = false) -> Int {
            #if os(macOS)
            QuarantinePropagation.apply(properties, to: items, recursive: recursive,
                                        stopsWhenCancelled: stopsWhenCancelled)
            #else
            0
            #endif
        }
    }
}
