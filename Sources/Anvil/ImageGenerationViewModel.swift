import Foundation
import AnvilCore

/// Standalone image generation — its own tab, its own gallery. Plain
/// `ObservableObject` (not `@Observable`) so it can be held with
/// `@StateObject` — see the `@State` toolchain note in README.
@MainActor
final class ImageGenerationViewModel: ObservableObject {
    @Published var selectedModelID: String?
    @Published var prompt: String = ""
    @Published var settings = ImageGenerationSettings.default
    @Published var isGenerating: Bool = false
    @Published var isSettingsOpen: Bool = false
    @Published var errorMessage: String?
    @Published private(set) var gallery: [GeneratedImage] = []

    private let imageSessions: ImageSessionManager
    private let store: GeneratedImageStore
    private let client = ImageClient()

    init(imageSessions: ImageSessionManager, store: GeneratedImageStore) {
        self.imageSessions = imageSessions
        self.store = store
    }

    func loadGallery() async {
        gallery = await store.all()
    }

    func syncSelectedModel() {
        if let id = selectedModelID, imageSessions.isLoaded(modelID: id) { return }
        selectedModelID = imageSessions.readySessions.first?.id
    }

    @discardableResult
    func generate() async -> GeneratedImage? {
        guard let id = selectedModelID, let endpoint = imageSessions.imageEndpoint(for: id) else {
            errorMessage = "Pick a loaded image model first"
            return nil
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return nil }
        errorMessage = nil
        isGenerating = true
        defer { isGenerating = false }

        let modelDisplayName = imageSessions.session(for: id)?.model.displayName ?? id

        do {
            let result = try await client.generate(prompt: text, baseURL: endpoint, settings: settings)
            let image = GeneratedImage(
                prompt: text,
                modelDisplayName: modelDisplayName,
                localPath: result.localPath,
                width: result.width,
                height: result.height,
                seed: result.seed
            )
            let saved = try await store.add(image)
            gallery.insert(saved, at: 0)
            return saved
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func delete(_ image: GeneratedImage) async {
        try? await store.delete(id: image.id)
        gallery.removeAll { $0.id == image.id }
    }
}
