import Testing
@testable import Kernir

/// On iOS too, "Exclude Mac metadata" starts on.
/// Its own file, with the flip, so the flip can be dropped alone.
@Suite struct MetadataDefaultTests {
    @Test func iOSExcludesMacMetadataByDefault() {
        #expect(ArchiveSaveSettings.excludesMacMetadataByDefault)
    }
}
