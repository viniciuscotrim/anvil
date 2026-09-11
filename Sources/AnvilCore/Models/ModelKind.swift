import Foundation

/// What a registered model is for — decides which serving mechanism
/// (`LLMServer`/`mlx_lm` vs `ImageServer`/`mflux`) loading it uses.
public enum ModelKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
}

/// Guesses a model's kind from its files — diffusion pipelines (Flux
/// and friends) lay out weights very differently from a plain causal
/// LM: separate `transformer/`/`vae/` component directories (often
/// alongside a second text encoder, `text_encoder_2/`, for Flux's dual
/// T5+CLIP setup) rather than one flat set of `*.safetensors` next to a
/// single `tokenizer.json`. Not every diffusers-style repo ships
/// `model_index.json`, so the directory shape is the more reliable
/// signal across the community conversions this app actually meets.
public enum ModelKindDetector {
    public static func detect(at path: URL) -> ModelKind {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) else {
            return .text
        }
        let names = Set(contents.map(\.lastPathComponent))

        if names.contains("model_index.json") {
            return .image
        }
        if names.contains("transformer") && names.contains("vae") {
            return .image
        }
        return .text
    }
}
