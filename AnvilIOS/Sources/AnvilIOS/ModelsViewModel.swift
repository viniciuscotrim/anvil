import Foundation
import AnvilCore
import Observation

/// Search, download, and manage registered models on iOS — the same
/// `AnvilCore` types the Mac app's Model Manager uses
/// (`HuggingFaceCatalog`, `ModelCompatibility`, `ModelRegistry`), with
/// `HFRepoDownloader` (native `URLSessionDownloadTask`, no Python) in
/// place of the Mac's Process-based `ModelDownloader`.
///
/// `@Observable`, not the `@StateObject`+`ObservableObject` combination
/// the macOS app's view models use — that workaround exists there only
/// because that target builds outside Xcode.app, which doesn't compile
/// the `@State`/`@Observable` macros; this target is a real Xcode
/// project, so the modern, simpler API applies.
@Observable
@MainActor
final class ModelsViewModel {
    var query = ""
    var searchResults: [HFModelSummary] = []
    var registeredModels: [ModelEntry] = []
    var isSearching = false
    var errorMessage: String?

    var activeDownloadRepoID: String?
    var downloadProgress: Double?
    var isDownloading: Bool { activeDownloadRepoID != nil }

    private let catalog = HuggingFaceCatalog()
    private let registry = ModelRegistry()
    private let downloader: HFRepoDownloader

    init() {
        downloader = HFRepoDownloader(registry: registry)
    }

    func loadRegistry() async {
        // Same self-healing the Mac app's Models tab does on load — see
        // ModelRegistry.deduplicateByLocalPath/refreshKinds' own doc
        // comments for the real bugs each one fixes.
        _ = try? await registry.deduplicateByLocalPath()
        _ = try? await registry.refreshKinds()
        registeredModels = await registry.all()
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await catalog.search(query: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(_ summary: HFModelSummary) async {
        guard !isDownloading else { return }
        guard let filePaths = summary.filePaths, !filePaths.isEmpty else {
            errorMessage = "No file list available for \(summary.modelID)."
            return
        }
        errorMessage = nil
        activeDownloadRepoID = summary.modelID
        downloadProgress = 0
        defer { activeDownloadRepoID = nil; downloadProgress = nil }

        do {
            _ = try await downloader.download(repoID: summary.modelID, filePaths: filePaths) { [weak self] progress in
                Task { @MainActor in self?.downloadProgress = progress }
            }
            await loadRegistry()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Moves the model's files to the Trash (not a permanent delete —
    /// same reasoning as the Mac app's own delete button) and removes
    /// it from the registry.
    func delete(_ entry: ModelEntry) async {
        let url = URL(fileURLWithPath: entry.localPath)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                errorMessage = "Could not delete \(entry.displayName): \(error.localizedDescription)"
                return
            }
        }
        try? await registry.remove(id: entry.id)
        registeredModels.removeAll { $0.id == entry.id }
    }
}
