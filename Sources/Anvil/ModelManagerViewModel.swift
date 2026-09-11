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
}
