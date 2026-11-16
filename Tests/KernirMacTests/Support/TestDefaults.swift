import Foundation

/// A defaults suite of a test's own, named by an absolute path in the temporary folder, so its
/// plist lives there and not in Library/Preferences. A named suite can't be cleaned up there:
/// cfprefsd writes an empty plist for it seconds after `removePersistentDomain`, whatever the
/// test deletes meanwhile, and runs piled up thousands. Remove it with `removeTestDefaults`.
func makeTestDefaults(_ prefix: String) -> (UserDefaults, String) {
    let suite = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)").path
    return (UserDefaults(suiteName: suite)!, suite)
}

/// Removes a suite made by `makeTestDefaults`: its domain and its plist.
func removeTestDefaults(_ defaults: UserDefaults, suite: String) {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(atPath: suite + ".plist")
}
