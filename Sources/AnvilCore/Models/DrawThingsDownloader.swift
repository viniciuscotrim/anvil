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
    private let catalog: HuggingFaceCatalog

    public init(registry: ModelRegistry, catalog: HuggingFaceCatalog = HuggingFaceCatalog()) {
        self.registry = registry
        self.hfDownloader = HFRepoDownloader(registry: registry)
        self.catalog = catalog
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
        // A confirmed, real bug: every curated catalog entry
        // (`DrawThingsCatalog.curatedModels`) leaves both `filePaths`
        // and `filename` unset — they're multi-file mflux-format repos
        // (`text_encoder/`, `vae/`, `transformer/`, …), not the
        // single-`.ckpt`-file case those two fields exist for at all.
        // The old fallback to a literal `"model.ckpt"` was guaranteed
        // to 404 on every single one of them (confirmed directly
        // against huggingface.co). Fetching the repo's real file list
        // here — the same call `HuggingFaceCatalog.modelInfo` already
        // makes for the plain Hugging Face search tab — is what makes
        // this correct regardless of a repo's actual layout, and stays
        // correct if Draw Things' catalog adds more curated entries
        // later without anyone having to hand-maintain a file list.
        let files: [String]
        if let explicit = summary.filePaths ?? summary.filename.map({ [$0] }) {
            files = explicit
        } else {
            let info = try await catalog.modelInfo(id: summary.repoID)
            guard let resolvedFiles = info.filePaths, !resolvedFiles.isEmpty else {
                throw ModelError.downloadFailed("Could not find this repo's file list on Hugging Face.")
            }
            files = resolvedFiles
        }

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
