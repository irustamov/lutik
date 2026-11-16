import SwiftUI
import UIKit

/// Hosts the root folder inside the document view controller. The document view controller
/// returns this controller's `navigationItem` as its own, so SwiftUI's subtitle, search and bar
/// items, UIDocumentViewController's title menu and rename, and TrailingEditItems' pinned Undo,
/// Redo and Save share one item.
/// Bottom-bar items SwiftUI sets here are forwarded, because the navigation controller shows
/// the toolbar of the document view controller, not of its child.
final class ChromeHostingController<Content: View>: UIHostingController<Content> {
    var onToolbarItemsChange: (@MainActor ([UIBarButtonItem]?, Bool) -> Void)?

    override func setToolbarItems(_ toolbarItems: [UIBarButtonItem]?, animated: Bool) {
        super.setToolbarItems(toolbarItems, animated: animated)
        onToolbarItemsChange?(toolbarItems, animated)
    }
}
