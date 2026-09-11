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
    }

    func loadRegistry() async {
        registeredModels = await registry.all()
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
