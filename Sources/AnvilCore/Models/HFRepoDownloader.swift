import Foundation

/// Downloads a Hugging Face repo's files one at a time via
/// `URLDownloader` (plain `URLSessionDownloadTask` against
/// `huggingface.co/<repo>/resolve/<revision>/<path>`) — no
/// `huggingface_hub`, no Python, no subprocess. This exists specifically
/// because the macOS `ModelDownloader` is `Process`-based and therefore
/// unavailable on iOS; this is the iOS-compatible way to get the same
/// files. Callers must already have the repo's file list (a search
/// result's own `filePaths`/`siblings` — the same data
/// `ModelCompatibility` already reads, no extra API call needed).
///
/// Not byte-range-resumable the way `snapshot_download` is, but file-
/// level resumable: a file only ever lands at its destination path
/// after finishing (see the loop below), so a cancelled download never
/// leaves a partial file sitting there to be mistaken for a complete
/// one — `download` skips any file already present at its destination,
/// meaning pausing and resuming a multi-file download only re-fetches
/// whichever file was actually in flight when it was cancelled, not
/// the whole repo from scratch.
public struct HFRepoDownloader: Sendable {
    private let registry: ModelRegistry

    public init(registry: ModelRegistry) {
        self.registry = registry
    }

    public static func destinationDirectory(forRepoID repoID: String) -> URL {
        AppSettings.load().effectiveModelsRoot.appendingPathComponent(sanitize(repoID), isDirectory: true)
    }

    /// `filePaths` is the repo's own file list — skips the same
    /// redundant root-level weight-file duplicate the macOS downloader
    /// does (see `ModelCompatibility.redundantRootLevelWeightFiles`).
    /// Progress is file-count-weighted (`(filesDone + currentFileFraction)
    /// / totalFiles`), not byte-weighted — this downloader doesn't know
    /// every file's size upfront the way `ModelDownloader`'s tqdm-parsed
    /// progress does, so a handful of huge files and many small ones
    /// won't report perfectly smoothly, but it's honest progress, not a
    /// guess.
    @discardableResult
    public func download(
        repoID: String,
        revision: String = "main",
        filePaths: [String],
        destinationDir: URL? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ModelEntry {
        let ignored = Set(ModelCompatibility.redundantRootLevelWeightFiles(in: filePaths))
        let filesToDownload = filePaths.filter { !ignored.contains($0) && !$0.isEmpty && !$0.hasSuffix("/") }
        guard !filesToDownload.isEmpty else {
            throw ModelError.downloadFailed("This repo has no downloadable files.")
        }

        let destination = destinationDir ?? Self.destinationDirectory(forRepoID: repoID)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let token = HFTokenStore.load()
        let total = filesToDownload.count

        for (index, filePath) in filesToDownload.enumerated() {
            let destinationFile = destination.appendingPathComponent(filePath)
            let completedFiles = Double(index)

            // Already fully fetched by an earlier, since-cancelled call
            // to this same method (see the type's own doc comment) —
            // resuming just skips straight past it instead of
            // re-downloading a file that's already there.
            if FileManager.default.fileExists(atPath: destinationFile.path) {
                onProgress?((completedFiles + 1) / Double(total))
                continue
            }

            guard let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let fileURL = URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(encodedPath)") else {
                throw ModelError.downloadFailed("Could not build a download URL for \(filePath)")
            }
            var request = URLRequest(url: fileURL)
            if let token, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            try FileManager.default.createDirectory(
                at: destinationFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let temporaryFileURL = try await URLDownloader.download(request) { fileFraction in
                onProgress?((completedFiles + fileFraction) / Double(total))
            }
            // Cancellation lands here too (as a thrown CancellationError
            // from the continuation `URLDownloader.download` awaits on)
            // — checked explicitly rather than relying on `moveItem`
            // alone throwing, so a cancellation racing right after the
            // download itself finishes still doesn't silently keep going
            // into the next file.
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destinationFile.path) {
                try FileManager.default.removeItem(at: destinationFile)
            }
            try FileManager.default.moveItem(at: temporaryFileURL, to: destinationFile)
        }

        let entry = ModelEntry(
            id: repoID,
            displayName: repoID,
            source: .huggingFace(repoID: repoID, revision: revision),
            localPath: destination.standardizedFileURL.path,
            sizeBytes: DirectorySize.of(destination),
            kind: ModelKindDetector.detect(at: destination)
        )
        return try await registry.upsert(entry)
    }

    private static func sanitize(_ repoID: String) -> String {
        repoID.replacingOccurrences(of: "/", with: "--")
    }
}
