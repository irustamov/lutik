import Testing
import Foundation
@testable import Kernir

/// Uses its own service name so the app's real saved passwords are never touched.
@Test func keychainRoundTrip() {
    let service = "com.kernir.app.tests.archive-password"
    let url = URL(fileURLWithPath: "/tmp/KeychainPasswordStoreTests-\(UUID().uuidString).zip")
    defer { KeychainPasswordStore.remove(for: url, service: service) }

    #expect(KeychainPasswordStore.password(for: url, service: service) == nil)

    KeychainPasswordStore.save("secret", for: url, service: service)
    #expect(KeychainPasswordStore.password(for: url, service: service) == "secret")

    // Saving again replaces the password.
    KeychainPasswordStore.save("better secret", for: url, service: service)
    #expect(KeychainPasswordStore.password(for: url, service: service) == "better secret")

    // The account is the standardized path, so another spelling of the same file finds it.
    let sameFile = URL(fileURLWithPath: "/tmp/./" + url.lastPathComponent)
    #expect(KeychainPasswordStore.password(for: sameFile, service: service) == "better secret")

    // Other services are separate.
    #expect(KeychainPasswordStore.password(for: url, service: service + ".other") == nil)

    KeychainPasswordStore.remove(for: url, service: service)
    #expect(KeychainPasswordStore.password(for: url, service: service) == nil)
}

/// The label is only built, never written: no Keychain access.
@Test func keychainLabel() {
    #expect(KeychainPasswordStore.label(for: URL(fileURLWithPath: "/tmp/Photos 2026.zip")) == "Lutik: Photos 2026.zip")
}
