import AppKit
import KernirCore

/// One piece of work a Finder Service asked for. The job queue runs it with
/// `ExtractHereService` or `CompressService`.
enum ServicesJob: Equatable, Sendable {
    /// Extract Here for one archive: a plain archive, or a split set's first part.
    case extractHere(URL)
    /// Compress every item into one new archive of `format` beside them.
    case compress([URL], format: ArchiveFormat)
}

/// `NSApp.servicesProvider`: receives the Finder Services declared in Info.plist's `NSServices`
/// ("Extract Here with Lutik", "Compress with Lutik"). It reads the file URLs a Service sends,
/// sorts them (`ServicesRequest`) and hands each job to `submit`; it runs nothing itself. A Service
/// with nothing to work on sets the method's `error`, which AppKit passes back to the sender.
@MainActor
final class ServicesProvider: NSObject {
    /// The services, by their `NSMessage`. AppKit sends `<message>:userData:error:`.
    enum Service: String, CaseIterable, Sendable {
        case extractHere, compress
    }

    /// Info.plist's `NSMessage` values, one `@objc` method each.
    nonisolated static let messages = Service.allCases.map(\.rawValue)

    /// Why a Service has no job.
    enum Refusal: Error, Equatable {
        /// No file or folder came (an empty pasteboard, or web links only).
        case noFiles
        /// Extract Here got files, but none Lutik extracts.
        case noArchives

        var message: String {
            switch self {
            case .noFiles:
                String(localized: "Lutik received no files or folders.",
                       comment: "Error a Finder Service (“Extract Here with Lutik”, “Compress with Lutik”) returns when it was sent nothing it can use: no files or folders, only web links, say.")
            case .noArchives:
                String(localized: "None of the selected items is an archive Lutik can extract.",
                       comment: "Error Finder's “Extract Here with Lutik” returns when none of the selected files is an archive.")
            }
        }
    }

    private let compressFormat: @MainActor () -> ArchiveFormat
    private let submit: @MainActor (ServicesJob) -> Void

    /// `compressFormat` is read each time Compress runs (Settings > Finder by default); `submit`
    /// takes each job, in order.
    init(compressFormat: @escaping @MainActor () -> ArchiveFormat = { FinderServicesSettings().compressFormat },
         submit: @escaping @MainActor (ServicesJob) -> Void) {
        self.compressFormat = compressFormat
        self.submit = submit
    }

    /// "Extract Here with Lutik": one job per archive received; other items are left alone.
    @objc func extractHere(_ pasteboard: NSPasteboard, userData: String?,
                           error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        run(.extractHere, pasteboard: pasteboard, error: error)
    }

    /// "Compress with Lutik": every item received into one archive.
    @objc func compress(_ pasteboard: NSPasteboard, userData: String?,
                        error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        run(.compress, pasteboard: pasteboard, error: error)
    }

    private func run(_ service: Service, pasteboard: NSPasteboard,
                     error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        do throws(Refusal) {
            let jobs = try Self.jobs(for: service, urls: Self.fileURLs(on: pasteboard),
                                     compressFormat: service == .compress ? compressFormat() : .zip)
            jobs.forEach(submit)
        } catch let refusal {
            error.pointee = refusal.message as NSString
        }
    }

    /// The file URLs on `pasteboard`, in order; web links and other contents are skipped.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return objects?.compactMap { $0 as? URL } ?? []
    }

    /// The jobs `service` makes of `urls`: Extract Here one per archive (a split set once),
    /// Compress one for all items, in `compressFormat`.
    nonisolated static func jobs(for service: Service, urls: [URL],
                                 compressFormat: ArchiveFormat) throws(Refusal) -> [ServicesJob] {
        let request = ServicesRequest(urls: urls)
        guard !request.items.isEmpty else { throw .noFiles }
        switch service {
        case .extractHere:
            guard !request.archives.isEmpty else { throw .noArchives }
            return request.archives.map(ServicesJob.extractHere)
        case .compress:
            return [.compress(request.items, format: compressFormat)]
        }
    }

    /// Whether AppKit launched the app the usual way (Dock, Finder, `open`) rather than only to
    /// run a Service or open a file: `applicationDidFinishLaunching`'s
    /// `NSApplication.launchIsDefaultUserInfoKey`. Without the key, a default launch, so the quit
    /// rule never quits an app the user opened.
    static func isDefaultLaunch(_ userInfo: [AnyHashable: Any]?) -> Bool {
        (userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ?? true
    }
}
