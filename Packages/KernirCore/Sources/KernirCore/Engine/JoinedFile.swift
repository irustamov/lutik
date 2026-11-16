import Foundation

/// Bounds-checked reads of one file, or of a multi-volume set's parts read as one file in order (a byte split
/// `x.zip.001` ... is one zip cut at arbitrary offsets, so its end records and central directory may span parts).
/// For the byte-level probes (`VolumeProbe`, `ZipEncryptionProbe`); all input is untrusted. One part's handle is
/// open at a time (a set may have hundreds of parts); a read across a boundary reads each part's share in turn.
final class JoinedFile {
    private let urls: [URL]
    /// Where each part starts in the joined bytes; `starts[urls.count]` is `size`.
    private let starts: [UInt64]
    let size: UInt64
    private var open: (index: Int, handle: FileHandle)?

    /// Opens the parts in turn for their sizes; the last one stays open (tail reads come first). No parts: `.io`.
    init(_ urls: [URL]) throws {
        guard !urls.isEmpty else { throw ArchiveError.io("Could not read the archive: no parts were given") }
        self.urls = urls
        var starts: [UInt64] = [0]
        var last: FileHandle?
        for (i, url) in urls.enumerated() {
            let handle = try Self.handle(url)
            let partSize = try Self.io(url) { try handle.seekToEnd() }
            let (end, overflow) = starts[i].addingReportingOverflow(partSize)
            guard !overflow else {
                try? handle.close()
                throw ArchiveError.io("Could not read \(url.lastPathComponent): the parts are too large")
            }
            starts.append(end)
            if i == urls.count - 1 { last = handle } else { try? handle.close() }
        }
        self.starts = starts
        self.size = starts[urls.count]
        open = last.map { (urls.count - 1, $0) }
    }

    deinit { try? open?.handle.close() }

    /// Exactly `count` bytes at `offset`, or `nil` when the range leaves the file (or a part changed size).
    func read(at offset: UInt64, count: UInt64) throws -> [UInt8]? {
        guard offset <= size, count <= size - offset else { return nil }
        if count == 0 { return [] }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(count))
        var position = offset
        let end = offset + count
        // The last part starting at or before `position`.
        var part = starts.lastIndex { $0 <= position }!
        while position < end {
            guard part < urls.count else { return nil }
            let partEnd = starts[part + 1]
            if position < partEnd {
                let wanted = min(end, partEnd) - position
                let handle = try handle(ofPart: part)
                let url = urls[part]
                let skip = position - starts[part]
                // `read(upToCount:)` hands back an autoreleased buffer; drained here, per read, or a probe that
                // walks a whole central directory in windows on one thread keeps every window resident.
                let complete = try autoreleasepool { () throws -> Bool in
                    let data = try Self.io(url) { () throws -> Data? in
                        try handle.seek(toOffset: skip)
                        return try handle.read(upToCount: Int(wanted))
                    }
                    guard let data, UInt64(data.count) == wanted else { return false }
                    bytes += data
                    return true
                }
                guard complete else { return nil }
                position += wanted
            }
            part += 1
        }
        return bytes
    }

    private func handle(ofPart index: Int) throws -> FileHandle {
        if let open, open.index == index { return open.handle }
        try? open?.handle.close()
        open = nil
        let handle = try Self.handle(urls[index])
        open = (index, handle)
        return handle
    }

    private static func handle(_ url: URL) throws -> FileHandle {
        try io(url) { try FileHandle(forReadingFrom: url) }
    }

    /// `body`, with a Foundation error turned into `.io` naming `url`.
    private static func io<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw ArchiveError.io("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
