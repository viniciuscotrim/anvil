import AnvilCore
import Foundation
import MLX
import SwiftUI
import UIKit

/// Native, in-process image generation for iOS — the real replacement
/// for what `ImageServer` does on macOS (spawn the `mflux`-wrapping
/// Python script as a subprocess, talk to it over HTTP), which can't
/// exist on iOS at all (no `Process`). Runs Stable Diffusion directly
/// in this process via `mlx-swift-examples`'s own `StableDiffusion`
/// library — a different model family from the Mac app's `mflux`
/// (Flux-only): this one supports `sdxl-turbo` and
/// `stable-diffusion-2-1`, matching this pattern closely from the
/// library's own real, working `StableDiffusionExample` app rather
/// than guessing at its API shape.
@MainActor
final class NativeImageEngine: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadProgress: Double?
    @Published private(set) var isGenerating = false
    @Published private(set) var generationProgress: Double?
    @Published var errorMessage: String?
    @Published private(set) var lastImage: CGImage?
    /// One tile per lineage (its latest version) — the same gallery
    /// grid `ImageGenerationViewModel` gives the Mac app's Images tab,
    /// backed by the same cross-platform `GeneratedImageStore`.
    @Published private(set) var gallery: [GeneratedImage] = []
    /// The lineage `generate(prompt:)` continues as a new version
    /// instead of starting fresh — set by `selectImage`, cleared by
    /// `deselectImage` or `unload`.
    @Published private(set) var selectedImage: GeneratedImage?
    @Published private(set) var selectedLineageVersions: [GeneratedImage] = []

    nonisolated let configuration = StableDiffusionConfiguration.presetSDXLTurbo
    private var container: ModelContainer<TextToImageGenerator>?
    private let store = GeneratedImageStore()

    var isLoaded: Bool { container != nil }

    func loadGallery() async {
        gallery = await store.latestPerLineage()
    }

    /// Shows this image large, loads its prompt back into the caller's
    /// input field, and loads its whole lineage's version history —
    /// mirrors `ImageGenerationViewModel.selectImage` on the Mac app.
    func selectImage(_ image: GeneratedImage) async {
        selectedImage = image
        selectedLineageVersions = await store.versions(ofLineage: image.lineageID)
        if let cgImage = Self.loadCGImage(atPath: image.localPath) {
            lastImage = cgImage
        }
    }

    /// Back to the gallery grid — also what makes the next `generate`
    /// start a brand-new lineage instead of continuing one.
    func deselectImage() {
        selectedImage = nil
        selectedLineageVersions = []
    }

    func delete(_ image: GeneratedImage) async {
        try? await store.delete(id: image.id)
        gallery = await store.latestPerLineage()
        if selectedImage?.id == image.id {
            deselectImage()
        }
    }

    func load() async {
        guard !isLoading, container == nil else { return }
        errorMessage = nil
        isLoading = true
        loadProgress = 0
        defer { isLoading = false }

        do {
            do {
                try await configuration.download { [weak self] progress in
                    self?.updateLoadProgress(progress.fractionCompleted)
                }
            } catch {
                let nsError = error as NSError
                // Already-cached weights load fine even without a
                // network connection — only re-throw a real failure.
                if nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorNotConnectedToInternet {
                    throw error
                }
            }

            let loadConfiguration = LoadConfiguration(float16: true, quantize: false)
            let newContainer = try ModelContainer<TextToImageGenerator>.createTextToImageGenerator(
                configuration: configuration, loadConfiguration: loadConfiguration)
            try await newContainer.perform { model in model.ensureLoaded() }
            container = newContainer
        } catch {
            errorMessage = error.localizedDescription
        }
        loadProgress = nil
    }

    func unload() {
        container = nil
    }

    func generate(prompt: String) async {
        guard let container else {
            errorMessage = "Load the model first."
            return
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        errorMessage = nil
        isGenerating = true
        generationProgress = 0
        defer { isGenerating = false; generationProgress = nil }

        // Built as a `let` (not mutated again after this) so the
        // concurrently-executing `first` closure below captures an
        // immutable value — a mutable `var` capture there is a
        // Swift 6 concurrency error, not just this mode's warning.
        let parameters: EvaluateParameters = {
            var parameters = configuration.defaultParameters()
            parameters.prompt = text
            return parameters
        }()
        let totalSteps = parameters.steps
        let seed = parameters.seed

        // Generating again while something's selected continues that
        // lineage as a new version instead of starting a fresh one —
        // same "change the prompt/model, don't overwrite" mechanism
        // `ImageGenerationViewModel.generate()` gives the Mac app.
        let continuingLineageID = selectedImage?.lineageID
        let versionNumber: Int
        if let continuingLineageID {
            versionNumber = await store.nextVersionNumber(forLineage: continuingLineageID)
        } else {
            versionNumber = 1
        }

        do {
            // `second` returns the decoded frame directly rather than
            // only reporting it through the fire-and-forget `self?.
            // updateImage` callback below — that callback hops to the
            // main actor via its own unstructured `Task`, which isn't
            // guaranteed to have landed by the time `performTwoStage`
            // returns here, so persisting straight off `lastImage`
            // would race the very save it's supposed to trigger.
            let cgImage = try await container.performTwoStage { generator -> (ImageDecoder, DenoiseIterator) in
                let latents = generator.generateLatents(parameters: parameters)
                return (generator.detachedDecoder(), latents)
            } second: { [weak self] (decoder: ImageDecoder, latents: DenoiseIterator) -> CGImage? in
                var lastXt: MLXArray?
                for (index, xt) in latents.enumerated() {
                    eval(xt)
                    lastXt = xt
                    self?.updateGenerationProgress(Double(index + 1) / Double(max(totalSteps, 1)))
                }
                guard let lastXt else { return nil }
                let decoded = decoder(lastXt)
                let raster = (decoded * 255).asType(.uint8).squeezed()
                eval(raster)
                return MLXRasterImage(raster).asCGImage()
            }
            if let cgImage {
                // Already on the main actor here (unlike the progress
                // callback above) — assign directly instead of going
                // through `updateImage`'s extra actor-hop.
                lastImage = cgImage
                try await persist(
                    cgImage, prompt: text, seed: seed,
                    lineageID: continuingLineageID, versionNumber: versionNumber)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes the generated frame to a real PNG file under this app's
    /// `images/` directory and records it in `GeneratedImageStore` —
    /// the same "a real file on disk, not just a database blob" pattern
    /// `GeneratedImage` documents, just produced in-process here instead
    /// of by a Python server writing the file itself.
    private func persist(
        _ cgImage: CGImage, prompt: String, seed: UInt64,
        lineageID: UUID?, versionNumber: Int
    ) async throws {
        let directory = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("images", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).png")
        guard let pngData = UIImage(cgImage: cgImage).pngData() else {
            throw NativeImageEngineError.encodingFailed
        }
        try pngData.write(to: fileURL, options: .atomic)

        let image = GeneratedImage(
            lineageID: lineageID,
            versionNumber: versionNumber,
            prompt: prompt,
            modelDisplayName: configuration.id,
            localPath: fileURL.path,
            width: cgImage.width,
            height: cgImage.height,
            seed: Int(truncatingIfNeeded: seed)
        )
        let saved = try await store.add(image)
        gallery = await store.latestPerLineage()
        selectedImage = saved
        selectedLineageVersions = await store.versions(ofLineage: saved.lineageID)
    }

    nonisolated private static func loadCGImage(atPath path: String) -> CGImage? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return UIImage(data: data)?.cgImage
    }

    // MARK: - Cross-actor updates (StableDiffusion's own generation
    // closures don't run on the main actor — mirrors the official
    // StableDiffusionExample app's own `updateProgress` pattern rather
    // than improvising a different one; the final image itself is
    // returned as `performTwoStage`'s result instead, so its assignment
    // doesn't race a fire-and-forget `Task` the way progress can afford
    // to).

    nonisolated private func updateLoadProgress(_ value: Double) {
        Task { @MainActor in self.loadProgress = value }
    }

    nonisolated private func updateGenerationProgress(_ value: Double) {
        Task { @MainActor in self.generationProgress = value }
    }
}

enum NativeImageEngineError: LocalizedError {
    case encodingFailed
    var errorDescription: String? { "Couldn't encode the generated image." }
}
