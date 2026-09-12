import Foundation

/// Downloads official Draw Things community models and registers them
/// in `ModelRegistry` under `kind: .image` and `engineOverride: .drawThings`.
///
/// Cross-platform on purpose: the actual download is `HFRepoDownloader`
/// (plain `URLSessionDownloadTask`, no subprocess) fetching the file(s)
/// as-is — nothing here converts or touches the Python/mflux runtime,
/// so there was never a real reason for this to depend on
/// `PythonEnvironment` (macOS-only, `Process`-based; the previous
/// stored `python` property was unused dead weight that broke the iOS
/// build for no functional benefit — removed rather than gated).
public struct DrawThingsDownloader: Sendable {
    private let registry: ModelRegistry
    private let hfDownloader: HFRepoDownloader

    public init(registry: ModelRegistry) {
        self.registry = registry
        self.hfDownloader = HFRepoDownloader(registry: registry)
    }

    /// Destination folder for a Draw Things model download (separated per quantization variant).
    public static func destinationDirectory(for summary: DrawThingsModelSummary) -> URL {
        let sanitizedRepo = summary.repoID.replacingOccurrences(of: "/", with: "--")
        let variantTag: String
        if let fn = summary.filename, !fn.isEmpty {
            variantTag = "-" + (fn as NSString).deletingPathExtension
        } else if let quant = summary.quantization, !quant.isEmpty {
            variantTag = "-" + quant.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
        } else {
            variantTag = ""
        }
        return AppSettings.load().effectiveModelsRoot
            .appendingPathComponent("drawthings--\(sanitizedRepo)\(variantTag)", isDirectory: true)
    }

    @discardableResult
    public func download(
        _ summary: DrawThingsModelSummary,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ModelEntry {
        let destinationDir = Self.destinationDirectory(for: summary)
        let files = summary.filePaths ?? (summary.filename.map { [$0] } ?? ["model.ckpt"])

        let entry = try await hfDownloader.download(
            repoID: summary.repoID,
            filePaths: files,
            destinationDir: destinationDir,
            onProgress: onProgress
        )

        var updated = entry
        updated.displayName = summary.name
        updated.kind = .image
        updated.engineOverride = .drawThings
        return try await registry.upsert(updated)
    }
}
