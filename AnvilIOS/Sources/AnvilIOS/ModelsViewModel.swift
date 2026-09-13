import Foundation
import AnvilCore
import Observation

/// Whether iOS's own on-device engines (`NativeChatEngine` — MLX-format
/// *and*, as of the GGUF backend in `GGUFChatBackend.swift`, llama.cpp
/// via `LLM.swift`; `NativeImageEngine`/`StableDiffusionModelLoader` —
/// diffusers-pipeline `mflux`-shaped only) can actually load a result
/// at all, as opposed to `ModelCompatibility`'s own broader "does this
/// look like a pipeline some engine could run" read — `drawThings` is
/// a real, useful engine the *Mac* app has, but iOS has no runtime for
/// it, so a result needing it is downloadable-but-inert here today,
/// worth flagging before the download, not after. iOS-only extension —
/// doesn't change `ModelCompatibility`'s own cross-platform meaning.
extension HFModelSummary {
    var isLoadableOnIOS: Bool {
        switch compatibility {
        case .supported(.drawThings): return false
        default: return true
        }
    }
}

/// One thing that can be downloaded — a Hugging Face repo or a CivitAI
/// checkpoint — unified so a single queue/progress/pause-stop mechanism
/// covers both sources: never simultaneous, whichever source it's from.
/// Mirrors the Mac app's own `DownloadJob`.
enum DownloadJob: Identifiable, Equatable {
    case huggingFace(HFModelSummary)
    case civitai(CivitAIModelSummary)
    case drawThings(DrawThingsModelSummary)

    var id: String {
        switch self {
        case .huggingFace(let summary): return "hf:\(summary.modelID)"
        case .civitai(let summary): return "civitai:\(summary.id)"
        case .drawThings(let summary): return "drawthings:\(summary.id)"
        }
    }

    var displayName: String {
        switch self {
        case .huggingFace(let summary): return summary.modelID
        case .civitai(let summary): return summary.name
        case .drawThings(let summary): return summary.name
        }
    }
}

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
        case drawThings = "Draw Things"
        var id: String { rawValue }
    }

    /// A single search field shared by all sources — switching sources
    /// clears it along with whatever results were showing, rather than
    /// leaving a previous source's query sitting behind a differently-
    /// labeled field.
    var source: Source = .huggingFace {
        didSet {
            guard source != oldValue else { return }
            query = ""
            searchResults = []
            civitaiResults = []
            drawThingsResults = []
            errorMessage = nil
        }
    }
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            queryDidChange()
        }
    }
    /// Off by default (matches the Mac app's own default) — searches
    /// automatically, debounced, once 3+ characters are typed.
    var isLiveSearchEnabled = false
    private var liveSearchTask: Task<Void, Never>?
    var searchResults: [HFModelSummary] = []
    var civitaiResults: [CivitAIModelSummary] = []
    var drawThingsResults: [DrawThingsModelSummary] = []
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

    /// The job actively downloading, if any — drives
    /// `ModelDownloadsSection`'s Pause/Stop and blocks starting a second
    /// download at the same time (a third pick just enqueues instead).
    private(set) var activeJob: DownloadJob?
    var activeDownloadID: String? { activeJob?.id }
    /// Jobs waiting their turn — one shared queue for both sources, so
    /// an HF download and a CivitAI download never run at the same time
    /// either; drains one at a time as each finishes.
    private(set) var downloadQueue: [DownloadJob] = []
    var downloadProgress: Double?
    var isDownloading: Bool { activeJob != nil }

    /// Drives the "pick a quantization" sheet — set by `beginDownload`
    /// when a GGUF repo has more than one `.gguf` file (see its own
    /// doc comment for the real bug this exists to prevent), `nil`
    /// otherwise. `files` starts empty while `fileTree` is still
    /// in flight.
    struct GGUFFilePicker: Identifiable {
        let summary: HFModelSummary
        var files: [HFRepoFile] = []
        var isLoading = true
        var errorMessage: String?
        var id: String { summary.modelID }
    }
    var ggufFilePicker: GGUFFilePicker?

    private let catalog = HuggingFaceCatalog()
    private let civitaiCatalog = CivitAICatalog()
    private let drawThingsCatalog = DrawThingsCatalog()
    private let registry = ModelRegistry()
    private let downloader: HFRepoDownloader
    private let civitaiDownloader: CivitAIDownloader
    private let drawThingsDownloader: DrawThingsDownloader
    /// Fire-and-forget by design (`download` isn't `async`) so the
    /// caller — a button — doesn't hold the download's `Task` itself;
    /// `pauseDownload()`/`stopDownload()` cancel the one stored here.
    private var downloadTask: Task<Void, Never>?
    private var deletePartialOnCancel = false

    init() {
        downloader = HFRepoDownloader(registry: registry)
        civitaiDownloader = CivitAIDownloader(registry: registry)
        drawThingsDownloader = DrawThingsDownloader(registry: registry)
    }

    /// What the HF results section actually shows once
    /// `compatibleOnlyHF`/`maxSizeClass` are applied, then reordered so
    /// results that actually fit this iPhone's RAM come first — a real,
    /// reported problem was a 30GB result sitting near the top next to
    /// models that will actually load, especially noticeable on a phone
    /// with far less RAM than a Mac.
    var filteredSearchResults: [HFModelSummary] {
        let filtered = searchResults.filter { summary in
            if compatibleOnlyHF, !summary.isLoadableOnIOS { return false }
            return Self.fitsSizeFilter(summary.sizeBytes, maxSizeClass)
        }
        return ModelSizeClass.sortedByRunnability(filtered) { $0.sizeBytes }
    }

    /// What the CivitAI results section shows once `maxSizeClass` is
    /// applied, reordered the same way. No compatibility toggle here —
    /// unlike the Mac app's `mflux` (Flux-only, so CivitAI's `baseModel`
    /// is a meaningful compatibility signal there), `NativeImageEngine`
    /// doesn't load arbitrary downloaded checkpoints at all yet (see its
    /// own header comment), so no CivitAI result is more "compatible"
    /// than another on iOS today regardless of base model.
    var filteredCivitAIResults: [CivitAIModelSummary] {
        let filtered = civitaiResults.filter { Self.fitsSizeFilter($0.primaryFile?.sizeBytes, maxSizeClass) }
        return ModelSizeClass.sortedByRunnability(filtered) { $0.primaryFile?.sizeBytes }
    }

    /// What the Draw Things results section shows, reordered the same
    /// way. No compatibility toggle here either — `NativeImageEngine`
    /// only loads diffusers-pipeline (`mflux`-shaped) folders, never
    /// Draw Things' own `libnnc` checkpoint format, so nothing in this
    /// source is more "compatible" than another on iOS today (same
    /// "downloads and registers, can't load yet" honesty the Mac's own
    /// Draw Things source note gives, just true here for a different
    /// reason — no runtime for that format at all, not a missing
    /// single-file loading path).
    var filteredDrawThingsResults: [DrawThingsModelSummary] {
        let filtered = drawThingsResults.filter { Self.fitsSizeFilter($0.sizeBytes, maxSizeClass) }
        return ModelSizeClass.sortedByRunnability(filtered) { $0.sizeBytes }
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
        case .drawThings: await searchDrawThings()
        }
    }

    /// Debounced live search — a no-op unless `isLiveSearchEnabled` is
    /// on and there's enough typed to bother searching for, same
    /// threshold and delay as the Mac app's own opt-in toggle.
    private func queryDidChange() {
        liveSearchTask?.cancel()
        guard isLiveSearchEnabled,
            query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
        else { return }
        liveSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.performSearch()
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

    func searchDrawThings() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isSearching = true
        defer { isSearching = false }
        do {
            drawThingsResults = try await drawThingsCatalog.search(query: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Not `async` — never simultaneous, from either source; a second
    /// pick while one is already running enqueues instead of starting
    /// it, and the queue drains one at a time as each download finishes
    /// (however it finishes: completed, paused, or stopped).
    func download(_ summary: HFModelSummary) {
        enqueueOrStart(.huggingFace(summary))
    }

    /// A search result row's actual "Download" action — routes through
    /// here instead of calling `download(_:)` directly so a GGUF repo
    /// shipping several quantizations (a real, common, and previously
    /// unhandled shape: one repo, ten-plus multi-gigabyte `.gguf`
    /// files, e.g. IQ2 through Q8_0) doesn't silently queue *every one
    /// of them* — `HFRepoDownloader.download` has no concept of "just
    /// this one file", it downloads whatever `filePaths` it's given in
    /// full. Reported live: an expected single ~8GB file turned into an
    /// attempt to pull the whole repo (100GB+ across every quant) at
    /// once. A repo with zero or one `.gguf` file is unaffected — there
    /// is nothing to choose between, so it downloads immediately like
    /// any other result.
    func beginDownload(_ summary: HFModelSummary) {
        let ggufPaths = (summary.filePaths ?? []).filter { $0.lowercased().hasSuffix(".gguf") }
        guard ggufPaths.count > 1 else {
            download(summary)
            return
        }
        ggufFilePicker = GGUFFilePicker(summary: summary)
        Task { [weak self] in
            guard let self else { return }
            do {
                let allFiles = try await self.catalog.fileTree(repoID: summary.modelID)
                let sizesByPath = Dictionary(uniqueKeysWithValues: allFiles.map { ($0.path, $0.sizeBytes) })
                self.ggufFilePicker?.files = ggufPaths.map { path in
                    HFRepoFile(path: path, sizeBytes: sizesByPath[path] ?? nil)
                }
            } catch {
                self.ggufFilePicker?.errorMessage = error.localizedDescription
            }
            self.ggufFilePicker?.isLoading = false
        }
    }

    /// Starts the download for exactly the one file the user picked
    /// from `ggufFilePicker` — everything else about `summary` (repo
    /// id, its place in the download queue, how it registers once
    /// finished) stays the same; only `filePaths` narrows to a single
    /// entry, since a GGUF file is self-contained and needs no sibling
    /// files (`config.json`, other quantizations, `README.md`, …) the
    /// way an MLX/diffusers pipeline directory does.
    func downloadSelectedGGUFFile(_ file: HFRepoFile) {
        guard let summary = ggufFilePicker?.summary else { return }
        ggufFilePicker = nil
        let narrowed = HFModelSummary(
            modelID: summary.modelID,
            downloads: summary.downloads,
            likes: summary.likes,
            tags: summary.tags,
            sizeBytes: file.sizeBytes ?? summary.sizeBytes,
            filePaths: [file.path]
        )
        download(narrowed)
    }

    func cancelGGUFFilePicker() {
        ggufFilePicker = nil
    }

    func download(_ summary: CivitAIModelSummary) {
        enqueueOrStart(.civitai(summary))
    }

    func download(_ summary: DrawThingsModelSummary) {
        enqueueOrStart(.drawThings(summary))
    }

    private func enqueueOrStart(_ job: DownloadJob) {
        guard downloadTask == nil else {
            guard job.id != activeJob?.id, !downloadQueue.contains(where: { $0.id == job.id }) else { return }
            downloadQueue.append(job)
            return
        }
        startDownload(job)
    }

    /// Removes a not-yet-started download from the queue — no effect on
    /// the one currently in progress; use `pauseDownload()`/
    /// `stopDownload()` for that.
    func removeFromQueue(_ job: DownloadJob) {
        downloadQueue.removeAll { $0.id == job.id }
    }

    private func startDownload(_ job: DownloadJob) {
        errorMessage = nil
        activeJob = job
        downloadProgress = 0
        deletePartialOnCancel = false

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch job {
                case .huggingFace(let summary):
                    guard let filePaths = summary.filePaths, !filePaths.isEmpty else {
                        throw ModelError.downloadFailed("No file list available for \(summary.modelID).")
                    }
                    _ = try await self.downloader.download(repoID: summary.modelID, filePaths: filePaths) { progress in
                        Task { @MainActor in self.downloadProgress = progress }
                    }
                case .civitai(let summary):
                    _ = try await self.civitaiDownloader.download(summary) { progress in
                        Task { @MainActor in self.downloadProgress = progress }
                    }
                case .drawThings(let summary):
                    _ = try await self.drawThingsDownloader.download(summary) { progress in
                        Task { @MainActor in self.downloadProgress = progress }
                    }
                }
                await self.loadRegistry()
            } catch is CancellationError {
                if self.deletePartialOnCancel {
                    switch job {
                    case .huggingFace(let summary):
                        try? FileManager.default.removeItem(at: HFRepoDownloader.destinationDirectory(forRepoID: summary.modelID))
                    case .civitai(let summary):
                        try? FileManager.default.removeItem(at: CivitAIDownloader.destinationDirectory(for: summary))
                    case .drawThings(let summary):
                        try? FileManager.default.removeItem(at: DrawThingsDownloader.destinationDirectory(for: summary))
                    }
                }
                // Paused (not deleted): nothing else to do — the partial
                // directory stays; HFRepoDownloader itself skips any
                // file already fully fetched on the next attempt (see
                // its own doc comment), so resuming only re-fetches
                // whichever file was actually in flight.
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.finishDownload()
        }
    }

    /// Cancels the in-flight download but keeps whatever's already been
    /// fetched.
    func pauseDownload() {
        deletePartialOnCancel = false
        downloadTask?.cancel()
    }

    /// Cancels the in-flight download and deletes whatever was
    /// partially fetched.
    func stopDownload() {
        deletePartialOnCancel = true
        downloadTask?.cancel()
    }

    private func finishDownload() {
        downloadProgress = nil
        downloadTask = nil
        activeJob = nil
        if !downloadQueue.isEmpty {
            startDownload(downloadQueue.removeFirst())
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
