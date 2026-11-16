import AppKit
import KernirCore
import os

/// A save with Split on writes the archive as a set of volumes into the folder the save
/// panel names (layout A), instead of NSDocument's save.
extension ArchiveDocument {
    /// Puts a split set in place; tests swap it (they never use the real Trash) and restore `.live`.
    nonisolated(unsafe) static var splitSetPlacement: SplitSetPlacement = .live

    /// What a split save must never replace: the open archive's files and every pending addition.
    func splitSaveSources(of model: ArchiveModel) -> [URL] {
        (fileURL.map { [$0] } ?? []) + (model.reader.map { [$0.url] + $0.volumeURLs } ?? [])
            + model.changes.additions.map(\.sourceURL)
    }

    /// Writes the archive split by `settings` into the folder `url` names. Save To semantics: never
    /// `super.save`, `write(to:…)` or `model.apply`, so `fileURL`, `fileType`, the change count and
    /// `model.saveOptions` stay as they were, and an untitled document stays untitled.
    ///
    /// Refuses, writing nothing, settings with a problem and a folder the panel would refuse
    /// (`SplitSetPlacement.splitDestinationError`). Otherwise the engine writes the set into a temporary
    /// folder, under the same progress sheet and Cancel as a save, with `baseName` pinned to the folder's
    /// name (so a set saved as "Photos 2" can be replaced later as "Photos 2"), and
    /// `SplitSetPlacement.place` checks the folder again and puts the set there. The archive comment is
    /// kept as `.keep`: the engine's split writer takes no other; `save(to:…)` has already
    /// refused a typed one (`ArchiveModel.splitSaveProblem`), and a removed one is what `.keep` writes. Runs as
    /// file access (`performAsynchronousFileAccess`), like NSDocument's own save.
    func saveSplit(to url: URL, settings: ArchiveSaveSettings, completionHandler: @escaping (Error?) -> Void) {
        // No model: locked, as in `write(to:…)`.
        guard let model else { return finishSave(ArchiveError.passwordRequired, completionHandler) }
        if let problem = settings.problems.first {
            return finishSave(SavePanelOptions.error(for: problem), completionHandler)
        }
        let sources = splitSaveSources(of: model)
        if let error = SplitSetPlacement.splitDestinationError(url, sources: sources) {
            return finishSave(error, completionHandler)
        }
        var changes = model.changes
        changes.comment = .keep
        // Whether the panel's Replace covers what is there: anything that turns up at a free name while
        // the set is written is refused, never trashed or replaced.
        let replacing = ArchiveSaveSettings.isNameTaken(url)
        let job = SplitSaveJob(source: model.reader, changes: changes, format: settings.format,
                               options: settings.options, destination: url, sources: sources,
                               replacing: replacing, engine: Self.engine, placement: Self.splitSetPlacement,
                               quarantine: QuarantinePropagation.Mark(of: model.quarantineSources))
        let cancellation = TaskCancellation()
        let operation = OperationProgress(title: String(localized: "Saving “\(url.lastPathComponent)”…"),
                                          fraction: nil, cancel: { cancellation.cancel() })
        let progress = state.progressHandler(for: operation.id)
        state.progress = operation
        performAsynchronousFileAccess { fileAccessDone in
            let task = Task { @MainActor in
                let error = await job.run(progress: progress)
                fileAccessDone()
                if error == nil { self.savedSplitSet = true }
                self.finishSave(error, completionHandler)
            }
            cancellation.register(task)
        }
    }
}

/// One split save, captured on the main actor and run off it.
private struct SplitSaveJob: Sendable {
    let source: (any ArchiveReading)?
    let changes: ArchiveChangeSet
    let format: ArchiveFormat
    let options: ArchiveWriteOptions
    let destination: URL
    let sources: [URL]
    /// Something was at `destination` when the save started.
    let replacing: Bool
    let engine: ArchiveEngine
    let placement: SplitSetPlacement
    /// The open archive's quarantine, set on the volumes once in place, as `save(to:…)` does for an archive.
    let quarantine: QuarantinePropagation.Mark?

    /// Writes the set and puts it in place; the error to report, nil when it is there. On a failure or
    /// Cancel before the move the temporary folder goes (the engine has deleted its volumes) and the
    /// destination is untouched. A folder made in place (`SplitSetPlacement.Folder.inPlace`) goes only
    /// when nothing but what the save wrote is in it, and the folder above it never.
    func run(progress: ArchiveProgressHandler?) async -> (any Error)? {
        do {
            let folder = try placement.makeFolder(for: destination, replacing: replacing)
            // What the engine wrote, once it is done: on its own error or Cancel it removes them itself.
            var volumes: [URL] = []
            do {
                volumes = try await engine.writeVolumes(source, changes, format, folder.url,
                                                        destination.lastPathComponent, options, progress)
                try Task.checkCancellation()
            } catch {
                placement.discard(folder, volumes: volumes)
                throw error
            }
            try placement.place(folder, at: destination, sources: sources, replacing: replacing, volumes: volumes)
            quarantine?.apply(to: volumes.map { destination.appendingPathComponent($0.lastPathComponent) }, recursive: false)
            return nil
        } catch ArchiveError.cancelled, is CancellationError {
            // The one error NSDocument never presents.
            return CocoaError(.userCancelled)
        } catch is ArchiveVolumeLimitError {
            // Not an `ArchiveError`: its own text, the one the panel shows for an estimate over the limit.
            return SavePanelOptions.error(for: .tooManyVolumes)
        } catch {
            Self.logger.error("The split save failed (\(SplitSetPlacement.codes(of: error), privacy: .public))")
            return error
        }
    }

    private static let logger = Logger(subsystem: "com.kernir.app", category: "document")
}
