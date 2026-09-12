import Foundation

/// Downloads official Draw Things community models and registers them
/// in `ModelRegistry` under `kind: .image` and `engineOverride: .drawThings`.
public struct DrawThingsDownloader: Sendable {
    private let registry: ModelRegistry
    private let python: PythonEnvironment
    private let hfDownloader: HFRepoDownloader

    public init(registry: ModelRegistry, python: PythonEnvironment = PythonEnvironment()) {
        self.registry = registry
        self.python = python
        self.hfDownloader = HFRepoDownloader(registry: registry)
    }

    /// Destination folder for a Draw Things model download.
    public static func destinationDirectory(for summary: DrawThingsModelSummary) -> URL {
        AppSettings.load().effectiveModelsRoot
            .appendingPathComponent("drawthings--\(summary.repoID.replacingOccurrences(of: "/", with: "--"))", isDirectory: true)
    }

    @discardableResult
    public func download(
        _ summary: DrawThingsModelSummary,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ModelEntry {
        let files = summary.filePaths ?? ["model.ckpt", "model_index.json"]
        let entry = try await hfDownloader.download(
            repoID: summary.repoID,
            filePaths: files,
            onProgress: onProgress
        )

        var updated = entry
        updated.displayName = summary.name
        updated.kind = .image
        updated.engineOverride = .drawThings
        return try await registry.upsert(updated)
    }
}
