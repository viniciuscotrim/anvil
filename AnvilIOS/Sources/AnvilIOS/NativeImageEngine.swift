import Foundation
import MLX
import SwiftUI

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

    nonisolated let configuration = StableDiffusionConfiguration.presetSDXLTurbo
    private var container: ModelContainer<TextToImageGenerator>?

    var isLoaded: Bool { container != nil }

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
        errorMessage = nil
        isGenerating = true
        generationProgress = 0
        defer { isGenerating = false; generationProgress = nil }

        let totalSteps = configuration.defaultParameters().steps

        do {
            try await container.performTwoStage { generator -> (ImageDecoder, DenoiseIterator) in
                var parameters = self.configuration.defaultParameters()
                parameters.prompt = prompt
                let latents = generator.generateLatents(parameters: parameters)
                return (generator.detachedDecoder(), latents)
            } second: { [weak self] (decoder: ImageDecoder, latents: DenoiseIterator) in
                var lastXt: MLXArray?
                for (index, xt) in latents.enumerated() {
                    eval(xt)
                    lastXt = xt
                    self?.updateGenerationProgress(Double(index + 1) / Double(max(totalSteps, 1)))
                }
                if let lastXt {
                    let decoded = decoder(lastXt)
                    let raster = (decoded * 255).asType(.uint8).squeezed()
                    eval(raster)
                    let cgImage = MLXRasterImage(raster).asCGImage()
                    self?.updateImage(cgImage)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Cross-actor updates (StableDiffusion's own generation
    // closures don't run on the main actor — mirrors the official
    // StableDiffusionExample app's own `updateProgress`/`updateImage`
    // pattern rather than improvising a different one).

    nonisolated private func updateLoadProgress(_ value: Double) {
        Task { @MainActor in self.loadProgress = value }
    }

    nonisolated private func updateGenerationProgress(_ value: Double) {
        Task { @MainActor in self.generationProgress = value }
    }

    nonisolated private func updateImage(_ image: CGImage?) {
        Task { @MainActor in self.lastImage = image }
    }
}
