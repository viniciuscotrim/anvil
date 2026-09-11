import Foundation
import AnvilCore

/// Standalone image generation — its own tab, Draw-Things-style: a
/// gallery of lineages (one tile per generated image family, its
/// latest version), and a detail canvas with a vertical version-history
/// carousel once one's selected. Plain `ObservableObject` (not
/// `@Observable`) so it can be held with `@StateObject` — see the
/// `@State` toolchain note in README.
@MainActor
final class ImageGenerationViewModel: ObservableObject {
    @Published var selectedModelID: String?
    @Published var prompt: String = ""
    @Published var settings = ImageGenerationSettings.default
    @Published var isGenerating: Bool = false
    @Published var isSettingsOpen: Bool = false
    @Published var errorMessage: String?
    /// nil until the first progress reading arrives (or if the server
    /// never reports a total, e.g. mid-startup) — CircularProgressView
    /// falls back to a plain spinner for that gap.
    @Published private(set) var generationProgress: Double?
    /// One tile per lineage (its latest version) — the main gallery.
    @Published private(set) var gallery: [GeneratedImage] = []
    /// The image showing large in the detail canvas, if any — nil
    /// means "show the gallery grid instead". Selecting one loads its
    /// prompt into the input field and its full version history into
    /// `selectedLineageVersions`.
    @Published private(set) var selectedImage: GeneratedImage?
    /// Every version of `selectedImage`'s lineage, oldest first — the
    /// vertical history carousel. Generating again while something's
    /// selected adds to this lineage instead of starting a new one,
    /// whether only the prompt changed or a different model was picked.
    @Published private(set) var selectedLineageVersions: [GeneratedImage] = []

    private let imageSessions: ImageSessionManager
    private let store: GeneratedImageStore
    private let client = ImageClient()

    init(imageSessions: ImageSessionManager, store: GeneratedImageStore) {
        self.imageSessions = imageSessions
        self.store = store
    }

    func loadGallery() async {
        gallery = await store.latestPerLineage()
    }

    func syncSelectedModel() {
        if let id = selectedModelID, imageSessions.isLoaded(modelID: id) { return }
        selectedModelID = imageSessions.readySessions.first?.id
    }

    // MARK: - Selection / version history

    /// Shows this image large in the detail canvas, loads its prompt
    /// back into the input field (so it's visible, and editable before
    /// generating a new version — matches how the model picker already
    /// works: shown, changeable, applied on the next Generate), and
    /// loads its whole lineage's version history into the carousel.
    func selectImage(_ image: GeneratedImage) async {
        selectedImage = image
        prompt = image.prompt
        selectedLineageVersions = await store.versions(ofLineage: image.lineageID)
    }

    /// Back to the gallery grid — also what makes the next Generate
    /// start a brand-new lineage instead of continuing one.
    func deselectImage() {
        selectedImage = nil
        selectedLineageVersions = []
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
        generationProgress = nil
        defer { isGenerating = false; generationProgress = nil }

        let modelDisplayName = imageSessions.session(for: id)?.model.displayName ?? id
        // A version continuing whatever's currently selected, or a
        // fresh lineage of its own if nothing is (see `selectImage`/
        // `deselectImage`) — this is the whole "change the model,
        // don't overwrite, add a version" mechanism.
        let continuingLineageID = selectedImage?.lineageID
        let versionNumber: Int
        if let continuingLineageID {
            versionNumber = await store.nextVersionNumber(forLineage: continuingLineageID)
        } else {
            versionNumber = 1
        }

        do {
            let result = try await client.generate(prompt: text, baseURL: endpoint, settings: settings) { [weak self] progress in
                Task { @MainActor in self?.generationProgress = progress.fraction }
            }
            let image = GeneratedImage(
                lineageID: continuingLineageID,
                versionNumber: versionNumber,
                prompt: text,
                modelDisplayName: modelDisplayName,
                localPath: result.localPath,
                width: result.width,
                height: result.height,
                seed: result.seed
            )
            let saved = try await store.add(image)
            gallery = await store.latestPerLineage()
            selectedImage = saved
            selectedLineageVersions = await store.versions(ofLineage: saved.lineageID)
            return saved
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func delete(_ image: GeneratedImage) async {
        try? await store.delete(id: image.id)
        gallery = await store.latestPerLineage()

        guard selectedImage?.lineageID == image.lineageID else { return }
        let remaining = await store.versions(ofLineage: image.lineageID)
        selectedLineageVersions = remaining
        if selectedImage?.id == image.id {
            // Fall back to the latest surviving version of this
            // lineage, or back to the gallery if none are left.
            if let fallback = remaining.last {
                selectedImage = fallback
                prompt = fallback.prompt
            } else {
                deselectImage()
            }
        }
    }
}
