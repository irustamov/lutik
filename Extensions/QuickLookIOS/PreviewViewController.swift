import UIKit
import QuickLook
import SwiftUI

/// Files-app Quick Look preview for archives: lists the archive as an outline.
final class PreviewViewController: UIViewController, QLPreviewingController {
    func preparePreviewOfFile(at url: URL) async throws {
        let content = try await PreviewLoader.load(url)
        let host = UIHostingController(rootView: ArchivePreviewView(content: content))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}
