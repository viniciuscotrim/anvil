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

    func portText(for modelID: String, sessions: ModelSessionManager) -> String {
        serverDrafts[modelID]?.portText ?? String(sessions.session(for: modelID)?.port ?? sessions.suggestedPort())
    }

    func access(for modelID: String, sessions: ModelSessionManager) -> ServerAccess {
        serverDrafts[modelID]?.access ?? sessions.session(for: modelID)?.access ?? .localOnly
    }

    func setPortText(_ text: String, for modelID: String, sessions: ModelSessionManager) {
        var draft = draft(for: modelID, sessions: sessions)
        draft.portText = text
        serverDrafts[modelID] = draft
    }

    func setAccess(_ access: ServerAccess, for modelID: String, sessions: ModelSessionManager) {
        var draft = draft(for: modelID, sessions: sessions)
        draft.access = access
        serverDrafts[modelID] = draft
    }

    /// Applies the current draft — loads the model if it isn't running
    /// yet, or restarts it under the new settings if it already is.
    func applyServerSettings(for model: ModelEntry, sessions: ModelSessionManager, requirements: RequirementsManager) async {
        let text = portText(for: model.id, sessions: sessions)
        guard let port = Int(text), (1...65535).contains(port) else {
            errorMessage = "Enter a valid port number (1–65535)."
            return
        }
        errorMessage = nil
        openServerSettingsFor = nil
        let access = access(for: model.id, sessions: sessions)

        if sessions.isLoaded(modelID: model.id) {
            await sessions.updateServerSettings(modelID: model.id, requirements: requirements, access: access, port: port)
        } else {
            await sessions.load(model, requirements: requirements, access: access, port: port)
        }
    }

    private func draft(for modelID: String, sessions: ModelSessionManager) -> ServerDraft {
        serverDrafts[modelID] ?? ServerDraft(
            portText: portText(for: modelID, sessions: sessions),
            access: access(for: modelID, sessions: sessions)
        )
    }
}
