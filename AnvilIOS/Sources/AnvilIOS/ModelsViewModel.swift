import Foundation
import AnvilCore
import Observation

/// Search, download, and manage registered models on iOS — the same
/// `AnvilCore` types the Mac app's Model Manager uses
/// (`HuggingFaceCatalog`, `ModelCompatibility`, `ModelRegistry`), with
/// `HFRepoDownloader` (native `URLSessionDownloadTask`, no Python) in
/// place of the Mac's Process-based `ModelDownloader`.
///
/// Backs two separate screens — `ModelSearchView` (search/filter/
/// download) and `ModelLibraryView` (registered models, grouped by
/// family, Load/Unload/Delete) — where the Mac's single Model Manager
/// window fits both in one scrollable pane (real desktop vertical
/// space). On a phone, search results, an active download's progress,
/// and the registered list all fighting for the same few hundred
/// points of height read as broken, not just cramped — hence two tabs
/// here instead of one.
///
/// `@Observable`, not the `@StateObject`+`ObservableObject` combination
/// the macOS app's view models use — that workaround exists there only
/// because that target builds outside Xcode.app, which doesn't compile
/// the `@State`/`@Observable` macros; this target is a real Xcode
/// project, so the modern, simpler API applies.
@Observable
@MainActor
final class ModelsViewModel {
    enum Source: String, CaseIterable, Identifiable {
        case huggingFace = "Hugging Face"
        case civitai = "CivitAI"
        var id: String { rawValue }
    }

    /// A single search field shared by both sources — switching sources
    /// clears it along with whatever results were showing, rather than
    /// leaving a CivitAI query sitting behind an HF-labeled field or
    /// vice versa.
    var source: Source = .huggingFace {
        didSet {
            guard source != oldValue else { return }
            query = ""
            searchResults = []
            civitaiResults = []
            errorMessage = nil
        }
    }
    var query = ""
    var searchResults: [HFModelSummary] = []
    var civitaiResults: [CivitAIModelSummary] = []
    var registeredModels: [ModelEntry] = []
    var isSearching = false
    var errorMessage: String?

    /// Hides HF results `ModelCompatibility` flags as a raw, unpipelined
    /// checkpoint — see that type's own doc comment for the real broken
    /// download this catches before it happens, not after.
    var compatibleOnlyHF = false
    /// `nil` = no size limit. Applies to both sources — the main ask on
    /// a phone: filter out anything that won't comfortably fit before
    /// even trying it, using the same RAM-relative classification the
    /// Mac's Model Manager and the registered-models list already show.
    var maxSizeClass: ModelSizeClass?

    var activeDownloadID: String?
    var downloadProgress: Double?
    var isDownloading: Bool { activeDownloadID != nil }

    private let catalog = HuggingFaceCatalog()
    private let civitaiCatalog = CivitAICatalog()
    private let registry = ModelRegistry()
    private let downloader: HFRepoDownloader
    private let civitaiDownloader: CivitAIDownloader

    init() {
        downloader = HFRepoDownloader(registry: registry)
        civitaiDownloader = CivitAIDownloader(registry: registry)
    }

    /// What the HF results section actually shows once
    /// `compatibleOnlyHF`/`maxSizeClass` are applied.
    var filteredSearchResults: [HFModelSummary] {
        searchResults.filter { summary in
            if compatibleOnlyHF, summary.compatibility == .incompatible { return false }
            return Self.fitsSizeFilter(summary.sizeBytes, maxSizeClass)
        }
    }

    /// What the CivitAI results section shows once `maxSizeClass` is
    /// applied. No compatibility toggle here — unlike the Mac app's
    /// `mflux` (Flux-only, so CivitAI's `baseModel` is a meaningful
    /// compatibility signal there), `NativeImageEngine` doesn't load
    /// arbitrary downloaded checkpoints at all yet (see its own header
    /// comment), so no CivitAI result is more "compatible" than another
    /// on iOS today regardless of base model.
    var filteredCivitAIResults: [CivitAIModelSummary] {
        civitaiResults.filter { Self.fitsSizeFilter($0.primaryFile?.sizeBytes, maxSizeClass) }
    }

    private static func fitsSizeFilter(_ sizeBytes: Int64?, _ maxSizeClass: ModelSizeClass?) -> Bool {
        guard let maxSizeClass else { return true }
        // A result with no known size can't be judged against the
        // filter — kept rather than hidden, so an unfiltered field
        // never silently disappears just because HF/CivitAI didn't
        // report a size for it.
        guard let sizeBytes else { return true }
        switch (ModelSizeClass.classify(sizeBytes: sizeBytes), maxSizeClass) {
        case (.small, _): return true
        case (.medium, .small): return false
        case (.medium, _): return true
        case (.large, .large): return true
        case (.large, _): return false
        }
    }

    /// Registered models grouped by family (every "Qwen3.5" size/quant
    /// variant together, "FLUX.2-klein" its own, …) for the Library
    /// screen — same `ModelFamilyGrouping` the Mac app's Model Manager
    /// uses, so a long flat list of near-identical entries doesn't read
    /// worse here than it does there.
    var registeredModelFamilies: [ModelFamilyGrouping.Family] {
        ModelFamilyGrouping.group(registeredModels)
    }

    func loadRegistry() async {
        // Same self-healing the Mac app's Models tab does on load — see
        // ModelRegistry.deduplicateByLocalPath/refreshKinds' own doc
        // comments for the real bugs each one fixes.
        _ = try? await registry.deduplicateByLocalPath()
        _ = try? await registry.refreshKinds()
        registeredModels = await registry.all()
    }

    /// Routes to whichever source is active — the single search field
    /// (and its submit action) doesn't need to know which catalog is
    /// behind it.
    func performSearch() async {
        switch source {
        case .huggingFace: await search()
        case .civitai: await searchCivitAI()
        }
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

    func searchCivitAI() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isSearching = true
        defer { isSearching = false }
        do {
            civitaiResults = try await civitaiCatalog.search(query: trimmed)
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
        activeDownloadID = "hf:\(summary.modelID)"
        downloadProgress = 0
        defer { activeDownloadID = nil; downloadProgress = nil }

        do {
            _ = try await downloader.download(repoID: summary.modelID, filePaths: filePaths) { [weak self] progress in
                Task { @MainActor in self?.downloadProgress = progress }
            }
            await loadRegistry()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(_ summary: CivitAIModelSummary) async {
        guard !isDownloading else { return }
        errorMessage = nil
        activeDownloadID = "civitai:\(summary.id)"
        downloadProgress = 0
        defer { activeDownloadID = nil; downloadProgress = nil }

        do {
            _ = try await civitaiDownloader.download(summary) { [weak self] progress in
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
