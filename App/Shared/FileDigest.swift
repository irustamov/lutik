import CryptoKit
import Foundation

/// The SHA-256 of a file, for the archive file's checksum (Test archive). Streams the file through
/// a `FileHandle` in 1 MiB chunks, so memory stays flat for any size, and hashes on a background
/// task, never on the main actor.
enum FileDigest {
    /// Why a file could not be checksummed (besides I/O errors and cancellation).
    enum Error: Swift.Error, Sendable, Equatable, LocalizedError {
        /// The path is not a regular file (a FIFO, device or directory); it is never opened for reading.
        case notRegularFile
        /// The file's size or modification time changed while it was being hashed, so the digest is
        /// not trustworthy. The UI says: "The archive changed while its checksum was calculated".
        case fileChanged

        var errorDescription: String? {
            switch self {
            case .notRegularFile: "The item is not a regular file."
            case .fileChanged: "The archive changed while its checksum was calculated."
            }
        }
    }

    /// Bytes read per step; also the unit of cancellation and progress checks.
    static let chunkSize = 1 << 20

    /// The lowercase hex SHA-256 of the regular file at `url`.
    ///
    /// The caller must hold security-scoped access to `url` for the whole call (until it returns or
    /// throws). Cancelling the calling task stops the read at the next chunk and throws
    /// `CancellationError`. `progress` gets the fraction of the file's size read so far (0 to 1),
    /// strictly increasing, about once per percent, and ends with exactly one 1.0; it is called on the
    /// hashing task's thread, never on the main actor. Throws `Error.notRegularFile` for anything but a
    /// regular file and `Error.fileChanged` if the file's size or modification time changed meanwhile.
    static func sha256(of url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let task = Task.detached(priority: .userInitiated) {
            try hash(url, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Opens `url` read-only without blocking (a FIFO would otherwise wait for a writer) and checks
    /// on the open descriptor that it is a regular file.
    private static func openRegularFile(_ url: URL) throws -> (handle: FileHandle, info: stat) {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(descriptor)
            throw POSIXError(code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw Error.notRegularFile
        }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: false), info)
    }

    private static func hash(_ url: URL, progress: (@Sendable (Double) -> Void)?) throws -> String {
        try Task.checkCancellation()
        let (handle, before) = try openRegularFile(url)
        defer { try? handle.close() }
        let size = Double(before.st_size)
        var hasher = SHA256()
        var done = 0.0
        var reportedPercent = -1
        while true {
            try Task.checkCancellation()
            let finished = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return true }
                hasher.update(data: chunk)
                done += Double(chunk.count)
                return false
            }
            if finished { break }
            if let progress, size > 0 {
                let percent = Int(min(done / size, 1) * 100)
                if percent > reportedPercent {
                    reportedPercent = percent
                    progress(Double(percent) / 100)
                }
            }
        }
        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw Error.fileChanged
        }
        if reportedPercent < 100 { progress?(1) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
