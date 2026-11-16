import Foundation

/// The app's user-visible name, for copy that names the app ("Welcome to …", "Make … the default
/// app for archives"). Read from Info.plist so the product rename (Kernir is the code name) needs no
/// code change: CFBundleDisplayName, then CFBundleName.
enum AppDisplayName {
    /// The name in `info`; blank, non-string and unexpanded ("$(…)") values count as missing, and
    /// with neither key usable it is `fallback`.
    static func resolve(infoDictionary info: [String: Any], fallback: String) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let text = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty, !text.hasPrefix("$(") {
                return text
            }
        }
        return fallback
    }

    /// The running app's (the main bundle's, localized Info.plist values first).
    static var current: String {
        let info = (Bundle.main.infoDictionary ?? [:])
            .merging(Bundle.main.localizedInfoDictionary ?? [:]) { _, localized in localized }
        return resolve(infoDictionary: info, fallback: ProcessInfo.processInfo.processName)
    }
}
