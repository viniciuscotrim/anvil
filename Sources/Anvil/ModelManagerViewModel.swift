import Foundation
import AnvilCore

/// Plain `ObservableObject` (not `@Observable`) so it can be held with
/// `@StateObject` — see the toolchain note in README about `@State`.
@MainActor
final class ModelManagerViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var searchResults: [HFModelSummary] = []
    @Published var registeredModels: [ModelEntry] = []
    @Published var statusMessage: String = ""
    @Published var isBusy: Bool = false
    @Published var errorMessage: String?
    @Published var isImportPanelPresented: Bool = false
    /// Where downloads land and "scan for existing models" looks — nil
    /// shows as "Default" in the UI (Anvil's own Application Support
    /// folder). Loaded from `AppSettings` at init.
    @Published var modelsRootPath: String?
    @Published var isChoosingModelsFolder: Bool = false

    /// nil = no size filter. Small/Medium/Large are relative to this
    /// Mac's own RAM (see `ModelSizeClass`), not an absolute cutoff.
    @Published var sizeFilter: ModelSizeClass?
    /// When on, typing (3+ characters) searches automatically after a
    /// short pause instead of waiting for Search/Return.
    @Published var isLiveSearchEnabled: Bool = false
    private var liveSearchTask: Task<Void, Never>?

    private let ramBytes = ProcessInfo.processInfo.physicalMemory

    /// What the list actually shows — `searchResults` narrowed by
    /// `sizeFilter`. A result with no size estimate at all (no
    /// safetensors metadata, e.g. a GGUF-only repo) is kept when no
    /// filter is active but excluded by any specific filter, since
    /// there's nothing to classify it by.
    var filteredSearchResults: [HFModelSummary] {
        guard let sizeFilter else { return searchResults }
        return searchResults.filter { summary in
            guard let bytes = summary.sizeBytes else { return false }
            return ModelSizeClass.classify(sizeBytes: bytes, ramBytes: ramBytes) == sizeFilter
        }
    }

    /// Which model's server-settings popover is open, if any — one at
    /// a time is plenty.
    @Published var openServerSettingsFor: String?
    /// Draft port/access per model, edited in the popover before being
    /// applied — separate from `ModelSessionManager.Session` so editing
    /// doesn't affect anything until the user confirms.
    @Published private var serverDrafts: [String: ServerDraft] = [:]

    struct ServerDraft: Equatable {
        var portText: String
        var access: ServerAccess
    }

    private let requirements: RequirementsManager
    private let catalog = HuggingFaceCatalog()
    private let registry: ModelRegistry
    private let downloader: ModelDownloader
    private let importer: ModelImporter

    init(requirements: RequirementsManager) {
        self.requirements = requirements
        let registry = ModelRegistry()
        self.registry = registry
        self.downloader = ModelDownloader(registry: registry)
        self.importer = ModelImporter(registry: registry)
        self.modelsRootPath = AppSettings.load().modelsRootPath
    }

    func loadRegistry() async {
        registeredModels = await registry.all()
    }

    // MARK: - Models folder

    /// The user picked a new folder for models: it becomes both the
    /// destination for future downloads and gets scanned right away for
    /// anything already inside it, so pointing Anvil at an existing
    /// models folder (an old oMLX directory, say) immediately populates
    /// "Registered models" instead of requiring a separate action.
    func changeModelsRoot(to url: URL) async {
        errorMessage = nil
        var settings = AppSettings.load()
        settings.modelsRootPath = url.path
        do {
            try settings.save()
        } catch {
            errorMessage = "Could not save the models folder setting: \(error.localizedDescription)"
            return
        }
        modelsRootPath = url.path
        await rescanModelsRoot()
    }

    /// Resets to Anvil's own default folder under Application Support —
    /// does not move or delete anything already downloaded elsewhere.
    func resetModelsRootToDefault() {
        var settings = AppSettings.load()
        settings.modelsRootPath = nil
        try? settings.save()
        modelsRootPath = nil
    }

    /// Re-scans the current models folder for anything not yet
    /// registered — for when the user adds model folders manually
    /// (Finder, another app's download) without changing the folder
    /// itself.
    func rescanModelsRoot() async {
        isBusy = true
        statusMessage = "Scanning for models…"
        defer { isBusy = false; statusMessage = "" }

        let root = AppSettings.load().effectiveModelsRoot
        do {
            _ = try await importer.importFolder(at: root)
            await loadRegistry()
        } catch {
            errorMessage = "Could not scan \(root.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Call whenever `query` changes. Only does anything when live
    /// search is on and there are at least 3 characters — debounced so
    /// it doesn't fire a request per keystroke.
    func queryDidChange() {
        liveSearchTask?.cancel()
        guard isLiveSearchEnabled,
              query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else {
            return
        }
        liveSearchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        do {
            searchResults = try await catalog.search(query: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(_ summary: HFModelSummary) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false; statusMessage = "" }

        let ready = await requirements.ensure(HuggingFaceClientDependency())
        guard ready else {
            errorMessage = requirements.lastError ?? "Could not set up the model browser"
            return
        }

        do {
            _ = try await downloader.download(repoID: summary.modelID) { [weak self] line in
                Task { @MainActor in self?.statusMessage = line }
            }
            await loadRegistry()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Image model defaults (keep-loaded toggle, resolution)

    /// Persists this image model's chat-unload preference and default
    /// resolution straight to the registry — read by `ChatViewModel`
    /// whenever it loads/generates through this model.
    func updateImageDefaults(
        for modelID: String,
        keepLoadedInChat: Bool,
        width: Int?,
        height: Int?
    ) async {
        guard var entry = registeredModels.first(where: { $0.id == modelID }) else { return }
        entry.keepImageModelLoadedInChat = keepLoadedInChat
        entry.defaultImageWidth = width
        entry.defaultImageHeight = height
        guard let updated = try? await registry.upsert(entry) else { return }
        if let index = registeredModels.firstIndex(where: { $0.id == modelID }) {
            registeredModels[index] = updated
        }
    }

    func importModel(at url: URL) async {
        errorMessage = nil
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await importer.importModel(at: url)
            await loadRegistry()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Server settings draft (port + local/network access)
    //
    // Takes primitives (current port/access) rather than a session
    // manager directly, so the same draft logic serves both
    // `ModelSessionManager` (text) and `ImageSessionManager` (image)
    // without coupling to either concrete type — the caller already
    // knows which manager applies to a given model's `kind`.

    func portText(for modelID: String, currentPort: Int) -> String {
        serverDrafts[modelID]?.portText ?? String(currentPort)
    }

    func access(for modelID: String, currentAccess: ServerAccess) -> ServerAccess {
        serverDrafts[modelID]?.access ?? currentAccess
    }

    func setPortText(_ text: String, for modelID: String, currentPort: Int, currentAccess: ServerAccess) {
        var draft = draft(for: modelID, currentPort: currentPort, currentAccess: currentAccess)
        draft.portText = text
        serverDrafts[modelID] = draft
    }

    func setAccess(_ access: ServerAccess, for modelID: String, currentPort: Int, currentAccess: ServerAccess) {
        var draft = draft(for: modelID, currentPort: currentPort, currentAccess: currentAccess)
        draft.access = access
        serverDrafts[modelID] = draft
    }

    /// Validates the current draft and hands the resolved (access, port)
    /// to `apply` — the caller loads or restarts whichever session
    /// manager actually applies to this model.
    func applyServerSettings(
        for modelID: String,
        currentPort: Int,
        currentAccess: ServerAccess,
        apply: (ServerAccess, Int) async -> Void
    ) async {
        let text = portText(for: modelID, currentPort: currentPort)
        guard let port = Int(text), (1...65535).contains(port) else {
            errorMessage = "Enter a valid port number (1–65535)."
            return
        }
        errorMessage = nil
        openServerSettingsFor = nil
        let access = access(for: modelID, currentAccess: currentAccess)
        await apply(access, port)
    }

    private func draft(for modelID: String, currentPort: Int, currentAccess: ServerAccess) -> ServerDraft {
        serverDrafts[modelID] ?? ServerDraft(
            portText: portText(for: modelID, currentPort: currentPort),
            access: access(for: modelID, currentAccess: currentAccess)
        )
    }
}
