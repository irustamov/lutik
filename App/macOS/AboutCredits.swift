import AppKit

/// The scrolling credits of the standard About panel: a link to the website (AppWebsite), then
/// the bundled third-party notices (BSD requires libarchive's license text to ship with the app)
/// under "Acknowledgements".
enum AboutCredits {
    /// The standard panel's options: the version and, in parentheses after it, the build number
    /// and the commit ("Version 0.1.0 (1234, 9cc7108)"), then the credits. A missing value is
    /// left to the panel's own default (the Info.plist's).
    static func panelOptions(version: AppVersion = .current) -> [NSApplication.AboutPanelOptionKey: Any] {
        // The Dock tile art (AppDelegate.installDockIcon) replaces NSApp.applicationIconImage; the
        // About panel keeps the normal bundle icon.
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: make(),
            .applicationIcon: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath),
        ]
        if let short = version.version { options[.applicationVersion] = short }
        if let detail = version.buildDetail { options[.version] = detail }
        return options
    }

    static func make() -> NSAttributedString {
        let size = NSFont.smallSystemFontSize
        let result = NSMutableAttributedString(
            string: AppWebsite.label,
            attributes: [.font: NSFont.systemFont(ofSize: size), .link: AppWebsite.url])
        result.append(NSAttributedString(
            string: "\n\n" + String(localized: "Acknowledgements") + "\n\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.labelColor]))
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return result }

        // Inline-only markdown would turn a fenced block (the license) into one code span
        // and lose its line breaks, so fenced blocks go in verbatim and only prose is parsed.
        let body = NSMutableAttributedString()
        var headings: [NSRange] = []
        for (index, segment) in text.components(separatedBy: "```\n").enumerated() {
            if index.isMultiple(of: 2) {
                appendProse(segment, to: body, headings: &headings)
            } else {
                body.append(NSAttributedString(string: segment))
            }
        }
        let all = NSRange(location: 0, length: body.length)
        body.addAttribute(.font, value: NSFont.systemFont(ofSize: size), range: all)
        body.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
        for range in headings { body.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: size), range: range) }
        result.append(body)
        return result
    }

    /// Parses inline markdown line run by line run; a heading line ("## libarchive"), which
    /// inline-only parsing would show with its marks, goes in as plain text and its range is
    /// noted so it can be set bold.
    private static func appendProse(_ text: String, to body: NSMutableAttributedString, headings: inout [NSRange]) {
        var run = ""
        func flushRun() {
            guard !run.isEmpty else { return }
            if let parsed = try? NSAttributedString(
                markdown: run, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                body.append(parsed)
            } else {
                body.append(NSAttributedString(string: run))
            }
            run = ""
        }
        let lines = text.components(separatedBy: "\n")
        for (number, line) in lines.enumerated() {
            let newline = number < lines.count - 1 ? "\n" : ""
            if let heading = heading(in: line) {
                flushRun()
                headings.append(NSRange(location: body.length, length: (heading as NSString).length))
                body.append(NSAttributedString(string: heading + newline))
            } else {
                run += line + newline
            }
        }
        flushRun()
    }

    /// The text of an ATX heading line ("# Title" through "###### Title"), or nil.
    private static func heading(in line: String) -> String? {
        let marks = line.prefix { $0 == "#" }.count
        guard (1...6).contains(marks), line.dropFirst(marks).first == " " else { return nil }
        return String(line.dropFirst(marks + 1))
    }
}
