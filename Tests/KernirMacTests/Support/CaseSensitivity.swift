import Foundation

/// The volume holding `url` says it folds case (an APFS or HFS+ default). A missing answer counts as
/// case-sensitive, so a test that requires a case-insensitive volume skips rather than fails.
func isCaseInsensitive(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == false
}
