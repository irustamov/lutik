import Foundation

/// The version line of About (the Mac About panel, iOS Acknowledgements): the marketing version,
/// the build number (the commit count, stamped by scripts/build/stamp-version.sh) and the commit,
/// read from an Info.plist dictionary. Missing, blank or unexpanded ("$(…)") values are left out.
struct AppVersion: Equatable, Sendable {
    /// The Info.plist key of the commit (project.yml: KernirGitCommit = $(KERNIR_GIT_COMMIT)).
    static let commitKey = "KernirGitCommit"

    /// CFBundleShortVersionString, e.g. "0.1.0".
    let version: String?
    /// CFBundleVersion, e.g. "1234".
    let build: String?
    /// The short commit SHA, e.g. "9cc7108" ("dev" when the build wasn't stamped).
    let commit: String?

    init(infoDictionary info: [String: Any]) {
        func value(_ key: String) -> String? {
            guard let text = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, !text.hasPrefix("$(") else { return nil }
            return text
        }
        version = value("CFBundleShortVersionString")
        build = value("CFBundleVersion")
        commit = value(Self.commitKey)
    }

    /// The running app's (the main bundle's).
    static var current: AppVersion { AppVersion(infoDictionary: Bundle.main.infoDictionary ?? [:]) }

    /// The build and the commit, "1234, 9cc7108": what the Mac About panel shows in parentheses
    /// after the version. Nil when both are missing.
    var buildDetail: String? {
        let parts = [build, commit].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "Version 0.1.0 (1234, 9cc7108)", or as much of it as is known; nil when nothing is.
    var line: String? {
        switch (version, buildDetail) {
        case let (version?, detail?):
            return String(localized: "Version \(version) (\(detail))", table: "Shared",
                   comment: "About: the app's version line. The first value is the version (e.g. “0.1.0”), the second the build number and the commit (e.g. “1234, 9cc7108”).")
        case let (version?, nil):
            return String(localized: "Version \(version)", table: "Shared",
                   comment: "About: the app's version line when the build number is unknown. The value is the version (e.g. “0.1.0”).")
        case let (nil, detail?):
            return String(localized: "Build \(detail)", table: "Shared",
                   comment: "About: the app's version line when the version is unknown. The value is the build number and the commit (e.g. “1234, 9cc7108”).")
        case (nil, nil):
            return nil
        }
    }
}

/// The product website, shown as a link in About (Mac credits, iOS Acknowledgements).
enum AppWebsite {
    static let url = URL(string: "https://lutik.io")!
    /// The link text: the domain, not translated.
    static let label = "lutik.io"
}
