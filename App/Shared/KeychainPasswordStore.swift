import Foundation
import Security
import os

/// Archive passwords the user chose to remember (opt-in, off by default).
/// A generic password per archive: the account is the file's standardized path.
enum KeychainPasswordStore {
    static let service = "com.kernir.app.archive-password"

    private static let logger = Logger(subsystem: "com.kernir.app", category: "keychain")

    static func password(for url: URL, service: String = service) -> String? {
        var query = baseQuery(for: url, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound { log("read", status) }
            return nil
        }
        return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    static func save(_ password: String, for url: URL, service: String = service) {
        let query = baseQuery(for: url, service: service)
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label(for: url)
            let added = SecItemAdd(item as CFDictionary, nil)
            if added != errSecSuccess { log("add", added) }
        } else if status != errSecSuccess {
            log("update", status)
        }
    }

    /// The item's name in Keychain Access. Only shown: lookups, updates and deletes match the
    /// service and account (`baseQuery`), never the label, and an update leaves a saved item's
    /// label as it was written.
    static func label(for url: URL) -> String {
        String(localized: "Lutik: \(url.lastPathComponent)", table: "Shared",
               comment: "The name of an archive's saved password, shown in Keychain Access. %@ = the archive's file name (e.g. “Photos.zip”); Lutik is the app name and is not translated.")
    }

    static func remove(for url: URL, service: String = service) {
        let status = SecItemDelete(baseQuery(for: url, service: service) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound { log("delete", status) }
    }

    private static func baseQuery(for url: URL, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: url.standardizedFileURL.path,
        ]
    }

    private static func log(_ operation: String, _ status: OSStatus) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? ""
        logger.error("Keychain \(operation, privacy: .public) failed: \(status) \(message, privacy: .public)")
    }
}
