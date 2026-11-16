import SwiftUI

/// A long-running operation in a sheet over the archive window: title, progress, Cancel.
struct ProgressSheet: View {
    let progress: OperationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.title)
                .font(.headline)
            // VoiceOver reads the bar with the operation's title, then its percentage.
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .accessibilityLabel(progress.title)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(progress.title)
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel",
                    comment: "Cancel button of the password sheet, the progress sheet (stops the operation), the read-only volume alert, and the alert after a Finder service (“Extract Here with Lutik”, “Compress with Lutik”) couldn't write in its folder.")) {
                    progress.cancel?()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(progress.cancel == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .interactiveDismissDisabled()
    }
}
