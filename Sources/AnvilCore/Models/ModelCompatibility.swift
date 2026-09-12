import Foundation

/// Whether a Hugging Face or catalog model's file layout looks
/// loadable by Anvil's backend engines — and which engine it maps to.
public enum ModelCompatibility: Sendable, Equatable {
    /// Compatible with a specific inference engine.
    case supported(InferenceEngine)
    /// Incompatible layout (e.g. raw flat safetensors without pipeline config).
    case incompatible(reason: String)
    /// Structure not recognized or cannot be determined.
    case unknown

    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    public var engine: InferenceEngine? {
        if case .supported(let engine) = self { return engine }
        return nil
    }

    /// `paths` is a repo's file list — `HFModelSummary.siblings`, or a
    /// local directory listing's relative paths.
    public static func classify(paths: [String]) -> ModelCompatibility {
        guard !paths.isEmpty else { return .unknown }
        let lowerPaths = paths.map { $0.lowercased() }

        // 1. Check for Diffusers / mflux image pipelines
        if lowerPaths.contains("model_index.json") {
            return .supported(.mflux)
        }
        let hasTransformerDir = lowerPaths.contains { $0.hasPrefix("transformer/") }
        let hasVAEDir = lowerPaths.contains { $0.hasPrefix("vae/") }
        if hasTransformerDir && hasVAEDir {
            return .supported(.mflux)
        }

        // 2. Check for GGUF files (supported via llama.cpp)
        let hasGGUF = lowerPaths.contains { $0.hasSuffix(".gguf") }
        let hasConfigJSON = lowerPaths.contains("config.json")
        let hasSafetensors = lowerPaths.contains { $0.hasSuffix(".safetensors") }

        if hasGGUF {
            return .supported(.llamaCpp)
        }

        // 3. Check for MLX / Safetensors Causal LM
        if hasConfigJSON && hasSafetensors {
            return .supported(.mlx)
        }

        let safetensorsCount = lowerPaths.filter { $0.hasSuffix(".safetensors") && !$0.contains("/") }.count
        let hasAnySubfolder = lowerPaths.contains { $0.contains("/") }
        if safetensorsCount > 0 && !hasConfigJSON && !hasAnySubfolder {
            return .incompatible(reason: "Single-file safetensors checkpoint requires pipeline files")
        }

        return .unknown
    }

    /// Root-level (no `/` in the path) weight files to skip when
    /// downloading — only when `model_index.json` is present,
    /// confirming a real diffusers pipeline exists in this repo's
    /// component subfolders, so a same-shaped file sitting loose at the
    /// top level is a redundant duplicate for a different tool, not
    /// something this pipeline itself needs. Real, reported case:
    /// `black-forest-labs/FLUX.2-klein-4B` ships a 7.8GB root-level
    /// `flux-2-klein-4b.safetensors` byte-for-byte the same size as
    /// `transformer/diffusion_pytorch_model.safetensors` — downloading
    /// it turned a real ~16GB need into ~24GB for nothing. Cross-platform
    /// (both the macOS Python-based `ModelDownloader` and any native
    /// per-file downloader use this same check) since it's pure path
    /// logic, no platform-specific download mechanism involved.
    public static func redundantRootLevelWeightFiles(in filePaths: [String]) -> [String] {
        guard filePaths.contains(where: { $0.caseInsensitiveCompare("model_index.json") == .orderedSame }) else {
            return []
        }
        let weightExtensions: Set<String> = ["safetensors", "bin", "ckpt", "pt", "gguf"]
        return filePaths.filter { path in
            !path.contains("/") && weightExtensions.contains((path as NSString).pathExtension.lowercased())
        }
    }
}
