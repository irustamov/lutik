import Testing
import Foundation
@testable import Kernir
import KernirCore

struct FinderServicesSettingsTests {
    /// Defaults of their own (`makeTestDefaults`), removed when `body` ends.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let (defaults, suite) = makeTestDefaults("FinderServicesSettingsTests")
        defer { removeTestDefaults(defaults, suite: suite) }
        try body(defaults)
    }

    @Test func defaultsAreZipWithoutMacMetadata() throws {
        try withDefaults { defaults in
            let settings = FinderServicesSettings(defaults: defaults)
            #expect(settings.compressFormat == .zip)
            #expect(settings.excludesMacMetadata)
        }
    }

    @Test func savedSettingsComeBack() throws {
        try withDefaults { defaults in
            var settings = FinderServicesSettings(defaults: defaults)
            settings.compressFormat = .sevenZip
            settings.excludesMacMetadata = false
            settings.save(to: defaults)
            #expect(FinderServicesSettings(defaults: defaults) == settings)
        }
    }

    /// A read-only format can't be written; an unknown one may come from a later version.
    @Test(arguments: [ArchiveFormat.rar.rawValue, "lz4", ""])
    func aFormatThatCannotBeWrittenFallsBackToZip(stored: String) throws {
        try withDefaults { defaults in
            defaults.set(stored, forKey: FinderServicesSettings.compressFormatKey)
            #expect(FinderServicesSettings(defaults: defaults).compressFormat == .zip)
        }
    }

    @Test func choosingAFormatThatCannotBeWrittenSavesZip() throws {
        try withDefaults { defaults in
            var settings = FinderServicesSettings(defaults: defaults)
            settings.compressFormat = .rar
            settings.save(to: defaults)
            #expect(FinderServicesSettings(defaults: defaults).compressFormat == .zip)
        }
    }
}
