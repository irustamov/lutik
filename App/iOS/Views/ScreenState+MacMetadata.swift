import Foundation

/// Save's Mac metadata question (`MacMetadataSaveQuestion`) on this document.
extension ScreenState: MacMetadataSaveQuestion {
    func setMacMetadataChoice(_ strips: Bool) {
        document.setMacMetadataChoice(strips)
    }

    func commitSave() async -> Bool {
        await document.commitSave()
    }
}
