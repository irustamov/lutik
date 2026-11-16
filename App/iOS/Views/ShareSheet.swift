import SwiftUI
import UIKit

/// The system share sheet for files. `FolderScreen` presents it in a popover, which on iPad
/// points at the row or toolbar button it came from and on iPhone becomes a sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [URL]
    /// Called once the user has shared or closed the sheet.
    var completion: @MainActor @Sendable () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { [completion] _, _, _, _ in
            Task { @MainActor in completion() }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
