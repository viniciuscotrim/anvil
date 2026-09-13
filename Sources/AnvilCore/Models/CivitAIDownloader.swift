import Foundation

/// Downloads a CivitAI checkpoint's primary file — a plain, native
/// `URLSessionDownloadTask` via `URLDownloader` (CivitAI's
/// redirect-to-a-pre-signed-CDN-URL download needs nothing fancier than
/// a GET with the redirect followed, which `URLSession` already does by
/// default), not a Python subprocess — and registers the result the
/// same way `ModelImporter`/`ModelDownloader` do. Cooperatively
/// cancellable, and real progress throughout, matching the same
/// pause/stop/progress mechanism the Hugging Face downloader already
/// has. Cross-platform (works on iOS, unlike the macOS-only
/// Python-based `ModelDownloader`).
public struct CivitAIDownloader: Sendable {
    private let registry: ModelRegistry

    public init(registry: ModelRegistry) {
        self.registry = registry
    }

    /// Where `download(_:)` will place this model's file — exposed the
    /// same way `ModelDownloader.destinationDirectory` is, so a
    /// "Stop download" action can find and delete a partial download
    /// without duplicating this logic.
    public static func destinationDirectory(for summary: CivitAIModelSummary) -> URL {
        AppSettings.load().effectiveModelsRoot
            .appendingPathComponent("civitai--\(sanitize(summary.name))-\(summary.id)", isDirectory: true)
    }

    @discardableResult
    public func download(
        _ summary: CivitAIModelSummary,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ModelEntry {
        guard let file = summary.primaryFile else {
            throw ModelError.downloadFailed("This CivitAI model has no downloadable safetensors file.")
        }

        let destinationDir = Self.destinationDirectory(for: summary)
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let destinationFile = destinationDir.appendingPathComponent(file.filename)

        var request = URLRequest(url: file.downloadURL)
        if let token = CivitAITokenStore.load(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        #if os(iOS)
        // See `HFRepoDownloader`'s matching branch — a background
        // session keeps this transferring through a locked screen or a
        // switched-away app, moving the finished file into place
        // itself rather than handing back a temp URL to move here.
        try await BackgroundDownloadCoordinator.shared.download(request, to: destinationFile, onProgress: onProgress)
        #else
        let temporaryFileURL = try await URLDownloader.download(request, onProgress: onProgress)
        if FileManager.default.fileExists(atPath: destinationFile.path) {
            try FileManager.default.removeItem(at: destinationFile)
        }
        try FileManager.default.moveItem(at: temporaryFileURL, to: destinationFile)
        #endif

        let entry = ModelEntry(
            id: "civitai:\(summary.id)",
            displayName: summary.name,
            source: .imported(originalPath: destinationDir.standardizedFileURL.path),
            localPath: destinationDir.standardizedFileURL.path,
            sizeBytes: DirectorySize.of(destinationDir),
            kind: .image
        )
        return try await registry.upsert(entry)
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
