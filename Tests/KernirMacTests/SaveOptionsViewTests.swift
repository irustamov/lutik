import Testing
import AppKit
import SwiftUI
@testable import Kernir
import KernirCore

@MainActor
struct SaveOptionsViewTests {
    /// The save panel sizes its accessory from the view's fitting size; a grouped Form scrolls and
    /// can collapse to nothing, so check it reports its content and grows with the password fields.
    @Test func accessoryFitsItsContent() {
        let options = SavePanelOptions(settings: ArchiveSaveSettings(
            format: .zip, options: ArchiveWriteOptions(method: .deflate, compressionLevel: 6)))
        let view = NSHostingView(rootView: SaveOptionsView(options: options))
        let plain = view.fittingSize
        options.settings.options.encryption = .aes256
        view.layoutSubtreeIfNeeded()
        let encrypting = view.fittingSize
        #expect(plain.width == 420)
        #expect(plain.height > 100)
        #expect(encrypting.height > plain.height)
    }

    /// The panel's accessory follows its content (seen in a UI run): set once at its fitting size, it kept that height,
    /// so a split ZIP's two notes were cut off at the bottom and the Format row slid under the panel's header.
    @Test func thePanelsAccessoryGrowsWithTheSplitNotes() throws {
        let options = SavePanelOptions(settings: ArchiveSaveSettings(
            format: .zip, options: ArchiveWriteOptions(method: .deflate, compressionLevel: 6)), comment: "Hi")
        let panel = NSSavePanel()
        options.attach(to: panel, fileName: "a.zip")
        let accessory = try #require(panel.accessoryView)
        // The frame is the fitting size rounded up per side: a fractional size (363.5) the panel rounds would
        // set off another fit on every layout.
        let fitted = { NSSize(width: accessory.fittingSize.width.rounded(.up),
                              height: accessory.fittingSize.height.rounded(.up)) }
        let plain = accessory.frame.size
        #expect(plain == fitted())

        options.split = .preset(.mb25)
        #expect(options.droppedCommentNote != nil)
        // The panel never shows here: lay the view out as its window would, then a turn of the main run loop
        // for the frame to follow.
        accessory.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let split = accessory.frame.size
        #expect(split.height > plain.height)
        #expect(split == fitted())

        // Back to one file: the frame shrinks to fit again (a few points off its first size, measured out of
        // the panel's window).
        options.split = .none
        accessory.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        #expect(accessory.frame.height < split.height)
        #expect(accessory.frame.size == fitted())
    }

    @Test func choosingAFormatFitsTheOptions() {
        let options = SavePanelOptions(settings: ArchiveSaveSettings(
            format: .zip, options: ArchiveWriteOptions(method: .deflate, encryption: .aes256, password: "pw"),
            verifyPassword: "pw"))
        options.format = .tarGzip

        var expected = ArchiveSaveSettings(
            format: .tarGzip, options: ArchiveWriteOptions(method: .deflate, encryption: .aes256, password: "pw"),
            verifyPassword: "pw")
        expected.formatDidChange()
        #expect(options.settings == expected)
    }

    // MARK: - Exclude Mac metadata

    private func fittingSize(@ViewBuilder _ content: () -> some View) -> NSSize {
        let view = NSHostingView(rootView: Form { content() }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(minWidth: 420, idealWidth: 420)
            .fixedSize(horizontal: false, vertical: true))
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
    }

    private func formatPicker() -> some View {
        Picker("Format", selection: .constant(ArchiveFormat.tar)) {
            ForEach(ArchiveFormat.writable, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
        }
    }

    /// TAR has no compression, encryption or advanced options, so its accessory is the format
    /// picker plus the "Exclude Mac metadata" row and nothing else. The English label is two
    /// lines at 420 pt (a one-word label would be one); the Mac UI run checks it by eye.
    @Test func theMetadataToggleIsARowForAFormatWithNoOtherOptions() {
        let options = SavePanelOptions(settings: ArchiveSaveSettings(format: .tar, options: ArchiveWriteOptions()))
        let accessory = NSHostingView(rootView: SaveOptionsView(options: options)).fittingSize
        let pickerOnly = fittingSize { formatPicker() }
        let pickerAndToggle = fittingSize {
            formatPicker()
            Toggle(isOn: .constant(false)) {
                Text(verbatim: "Exclude Mac metadata (.DS_Store, __MACOSX, ._ files)")
            }
        }
        #expect(accessory.height > pickerOnly.height)
        #expect(accessory.height == pickerAndToggle.height)
    }

    /// The toggle is on the accessory for every writable format, and turning it on or off adds
    /// or removes nothing.
    @Test(arguments: ArchiveFormat.writable)
    func theAccessoryFitsWithTheToggleOnOrOff(_ format: ArchiveFormat) {
        var settings = ArchiveSaveSettings(format: format, options: ArchiveWriteOptions())
        settings.formatDidChange()
        let options = SavePanelOptions(settings: settings)
        let view = NSHostingView(rootView: SaveOptionsView(options: options))
        let off = view.fittingSize
        options.settings.options.excludesMacMetadata = true
        view.layoutSubtreeIfNeeded()
        let on = view.fittingSize
        #expect(off.width == 420)
        #expect(on == off)
    }

    /// What the toggle edits is the settings the save uses, and choosing another format keeps it.
    @Test func theToggleRoundTripsThroughTheSettings() {
        let options = SavePanelOptions(settings: ArchiveSaveSettings(format: .zip, options: ArchiveWriteOptions()))
        options.settings.options.excludesMacMetadata = true
        options.format = .tarGzip
        #expect(options.settings.options.excludesMacMetadata)
        options.format = .sevenZip
        #expect(options.settings.options.excludesMacMetadata)
        options.settings.options.excludesMacMetadata = false
        options.format = .zip
        #expect(!options.settings.options.excludesMacMetadata)
    }

    // MARK: - Split into volumes

    private func accessory(_ format: ArchiveFormat) -> (SavePanelOptions, NSHostingView<SaveOptionsView>) {
        var settings = ArchiveSaveSettings(format: format, options: ArchiveWriteOptions())
        settings.formatDidChange()
        let options = SavePanelOptions(settings: settings)
        return (options, NSHostingView(rootView: SaveOptionsView(options: options)))
    }

    /// The split row is there for 7z and ZIP only: Custom's size field grows the accessory
    /// for those, and changes nothing for a format that can't split.
    @Test(arguments: ArchiveFormat.writable)
    func theSplitRowShowsOnlyForFormatsThatCanSplit(_ format: ArchiveFormat) {
        let (options, view) = accessory(format)
        let plain = view.fittingSize
        options.split = .custom(amount: "2", unit: .mb)
        view.layoutSubtreeIfNeeded()
        let custom = view.fittingSize
        #expect(custom.width == 420)
        if format.supportsVolumes {
            #expect(custom.height > plain.height)
        } else {
            #expect(custom.height == plain.height)
        }
    }

    /// The ZIP note shows under the picker for ZIP only, and only while splitting.
    @Test func theZipNoteShowsForZipOnly() {
        let (zip, zipView) = accessory(.zip)
        let zipPlain = zipView.fittingSize
        zip.split = .preset(.mb100)
        zipView.layoutSubtreeIfNeeded()
        #expect(zipView.fittingSize.height > zipPlain.height)

        let (sevenZip, sevenZipView) = accessory(.sevenZip)
        let sevenZipPlain = sevenZipView.fittingSize
        sevenZip.split = .preset(.mb100)
        sevenZipView.layoutSubtreeIfNeeded()
        #expect(sevenZipView.fittingSize.height == sevenZipPlain.height)
    }

    /// Choosing TAR while splitting drops the split, and the row with it.
    @Test func choosingAFormatThatCannotSplitRemovesTheRow() {
        let (options, view) = accessory(.tar)
        let tar = view.fittingSize
        options.format = .zip
        options.split = .custom(amount: "2", unit: .mb)
        options.format = .tar
        view.layoutSubtreeIfNeeded()
        #expect(options.split == .none)
        #expect(view.fittingSize == tar)
    }
}
