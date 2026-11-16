import SwiftUI
import UIKit

/// The bundled third-party notices (BSD requires libarchive's and zstd's license texts to ship
/// with the app), shown from the launch browser's info button. The Mac shows the same file in
/// About > Acknowledgements (AboutCredits).
enum Acknowledgements {
    static var url: URL? { Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") }

    static func load() -> AttributedString {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return AttributedString() }
        return render(text)
    }

    /// Inline-only markdown would turn a fenced block (a license) into one code span and lose its
    /// line breaks, so fenced blocks go in verbatim and only prose is parsed.
    static func render(_ markdown: String) -> AttributedString {
        var result = AttributedString()
        for (index, segment) in markdown.components(separatedBy: "```\n").enumerated() {
            if index.isMultiple(of: 2) {
                result += prose(segment)
            } else {
                var block = AttributedString(segment)
                block.font = .footnote
                result += block
            }
        }
        return result
    }

    /// Parses inline markdown run by run; a heading line ("## libarchive"), which inline-only
    /// parsing would show with its marks, goes in as headline text. Relative links (to files in
    /// the repository) lead nowhere in the app, so only web links stay.
    private static func prose(_ text: String) -> AttributedString {
        var result = AttributedString()
        var run = ""
        func flushRun() {
            guard !run.isEmpty else { return }
            var parsed = (try? AttributedString(
                markdown: run, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(run)
            let deadLinks = parsed.runs[\.link].compactMap { link, range -> Range<AttributedString.Index>? in
                guard let link, !["http", "https"].contains(link.scheme ?? "") else { return nil }
                return range
            }
            for range in deadLinks { parsed[range].link = nil }
            result += parsed
            run = ""
        }
        let lines = text.components(separatedBy: "\n")
        for (number, line) in lines.enumerated() {
            let newline = number < lines.count - 1 ? "\n" : ""
            if let heading = heading(in: line) {
                flushRun()
                var title = AttributedString(heading + newline)
                title.font = .headline
                result += title
            } else {
                run += line + newline
            }
        }
        flushRun()
        return result
    }

    /// The text of an ATX heading line ("# Title" through "###### Title"), or nil.
    private static func heading(in line: String) -> String? {
        let marks = line.prefix { $0 == "#" }.count
        guard (1...6).contains(marks), line.dropFirst(marks).first == " " else { return nil }
        return String(line.dropFirst(marks + 1))
    }

    /// The launch browser's info button; it presents the notices over `presenter`, the browser
    /// whose bar holds it.
    @MainActor static func barButtonItem(presentingFrom presenter: UIViewController) -> UIBarButtonItem {
        let action = UIAction { [weak presenter] _ in
            presenter?.present(UIHostingController(rootView: AcknowledgementsView()), animated: true)
        }
        return UIBarButtonItem(title: String(localized: "Acknowledgements"),
                               image: UIImage(systemName: "info.circle"), primaryAction: action, menu: nil)
    }
}

/// The notices under the app's version line (AppVersion: "Version 0.1.0 (1234, 9cc7108)") and a
/// link to the website, as the Mac's About panel shows them.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    private let text = Acknowledgements.load()
    private let version = AppVersion.current.line

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let version {
                        Text(version)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Link(AppWebsite.label, destination: AppWebsite.url)
                    Text(text)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Acknowledgements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if #available(iOS 26.0, *) {
                        Button(role: .close) { dismiss() }
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
}
