import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Kernir

/// The Welcome screen's feature rows and header art layout.
struct WelcomeContentTests {
    @Test func macRows() {
        let rows = WelcomeFeature.mac
        #expect(rows.map { $0.id } == [.quickLook, .openAndExtract, .edit, .formats])
        #expect(Set(rows.map { $0.id }).count == rows.count)
        for row in rows {
            #expect(!row.title.isEmpty && !row.detail.isEmpty && !row.systemImage.isEmpty)
        }
    }

    @Test func iOSRows() {
        let rows = WelcomeFeature.iOS
        #expect(rows.map { $0.id } == [.browseAndExtract, .edit, .formats])
    }

    @Test func titleUsesTheAppName() {
        #expect(WelcomeFeature.welcomeTitle(appName: "Lutik") == "Welcome to Lutik")
    }

    /// The formats row names only formats the app opens.
    @Test func formatsRowMatchesTheDocumentTypes() {
        let row = WelcomeFeature.mac.first { $0.id == .formats }!
        for name in ["ZIP", "7z", "RAR", "TAR", "ISO"] { #expect(row.detail.contains(name)) }
        #expect(WelcomeFeature.listedFormats.allSatisfy { format in
            KernirDocumentTypes.readable.map { $0.identifier }.contains(KernirDocumentTypes.utType(for: format).identifier)
        })
        let edit = WelcomeFeature.mac.first { $0.id == .edit }!
        #expect(WelcomeFeature.editableFormats.allSatisfy { $0.isWritable })
        for format in WelcomeFeature.editableFormats { #expect(edit.detail.contains(format.displayName)) }
    }

    /// Titles are in title case and descriptions in sentence case, with the serial comma. The
    /// lists use a fixed U.S. English list format, whatever the machine's region (en_GB drops
    /// the serial comma); the copy itself is English only.
    @Test func englishCopy() {
        let english = Locale(identifier: "en_US")
        let mac = Dictionary(uniqueKeysWithValues: WelcomeFeature.mac(locale: english).map { ($0.id, $0) })
        #expect(mac[.quickLook]?.title == "Preview in Finder")
        #expect(mac[.quickLook]?.detail == "Select an archive in Finder and press the Space bar to see what’s inside.")
        #expect(mac[.openAndExtract]?.title == "Open and Extract")
        #expect(mac[.edit]?.title == "Edit Archives")
        #expect(mac[.edit]?.detail == "Add, rename, move, and delete files in ZIP, 7z, and TAR archives without unpacking them.")
        #expect(mac[.formats]?.title == "Common Formats")
        #expect(mac[.formats]?.detail == "Opens ZIP, 7z, RAR, TAR, GZ, XZ, ISO, and more.")
        let ios = WelcomeFeature.iOS(locale: english).first { $0.id == .browseAndExtract }
        #expect(ios?.title == "Browse and Extract")
        #expect(ios?.detail == "Look inside an archive and save just the files you need.")
    }

    /// The art always fills the width at its own aspect (1600 x 686): no fill beside it (iOS's Welcome
    /// sheet; the Mac window shows the hero instead). At 640 pt wide that is a ~274 pt header.
    @Test func headerFillsTheWidth() {
        let mac = WelcomeHeaderArt.layout(width: 640, maxHeight: nil)
        #expect(abs(mac.height - 640 * 686 / 1600) < 0.001)
        #expect(mac.imageRect == CGRect(x: 0, y: 0, width: 640, height: mac.height))
        // A cap above the natural height changes nothing.
        let phone = WelcomeHeaderArt.layout(width: 390, maxHeight: 190)
        #expect(abs(phone.height - 390 * 686 / 1600) < 0.001)
        #expect(phone.imageRect == CGRect(x: 0, y: 0, width: 390, height: phone.height))
        #expect(WelcomeHeaderArt.layout(width: 0, maxHeight: nil).height == 0)
    }

    /// Under a lower cap the art stays full width (aspect-fill) and loses only flat band rows,
    /// shared between the top and bottom bands in proportion.
    @Test func headerCropsOnlyTheFlatBands() {
        let width: CGFloat = 844, natural = width * 686 / 1600
        let header = WelcomeHeaderArt.layout(width: width, maxHeight: 300)
        #expect(abs(header.height - 300) < 0.001)
        #expect(header.imageRect.minX == 0 && header.imageRect.width == width)
        #expect(abs(header.imageRect.height - natural) < 0.001)
        let cropTop = -header.imageRect.minY, cropBottom = header.imageRect.maxY - header.height
        #expect(cropTop > 0 && cropBottom > 0)
        #expect(abs(cropTop + cropBottom - (natural - 300)) < 0.001)
        #expect(cropTop <= natural * WelcomeHeaderArt.flatTop + 0.001)
        #expect(cropBottom <= natural * WelcomeHeaderArt.flatBottom + 0.001)
        #expect(abs(cropTop / cropBottom - WelcomeHeaderArt.flatTop / WelcomeHeaderArt.flatBottom) < 0.001)
    }

    /// A cap below the art's content height is not met: the header keeps the content whole.
    @Test func headerNeverCropsTheContent() {
        let width: CGFloat = 844, natural = width * 686 / 1600
        let header = WelcomeHeaderArt.layout(width: width, maxHeight: 100)
        let content = natural * (1 - WelcomeHeaderArt.flatTop - WelcomeHeaderArt.flatBottom)
        #expect(abs(header.height - content) < 0.001)
        #expect(abs(-header.imageRect.minY - natural * WelcomeHeaderArt.flatTop) < 0.001)
        #expect(abs(header.imageRect.maxY - header.height - natural * WelcomeHeaderArt.flatBottom) < 0.001)
    }
}
