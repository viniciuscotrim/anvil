import Foundation

/// Whether a Hugging Face search result's own file layout looks
/// loadable by Anvil's actual image backend (`mflux`, a diffusers-style
/// pipeline loader) — computed from the repo's file list (`siblings`),
/// available straight from the search API before ever downloading
/// anything. This exists because of a real, reported case: a raw,
/// flat-single-`.safetensors`-file Flux checkpoint
/// (`black-forest-labs/FLUX.2-klein-4b-nvfp4`) downloaded and registered
/// fine, then failed to *load* with a real Python traceback — `mflux`
/// expects `transformer/`/`vae/`/`text_encoder/` component subfolders,
/// which that repo simply doesn't have. Filtering these out of search
/// results catches the problem before a multi-gigabyte download, not
/// after.
public enum ModelCompatibility: String, Sendable, Equatable {
    /// Looks like a proper diffusers-style pipeline (`model_index.json`,
    /// or `transformer/`+`vae/` component subfolders) — the shape
    /// `mflux` actually loads.
    case compatible
    /// A flat single (or few) `*.safetensors` file(s) with no pipeline
    /// directory structure and no `config.json` — the shape that threw
    /// `FileNotFoundError: No safetensors files found in .../vae` for
    /// real. Almost always a raw checkpoint meant for a different tool
    /// (ComfyUI, a CivitAI-style single-file loader, …), not something
    /// `mflux` can open as-is.
    case incompatible
    /// Neither pattern matched clearly enough to say — a plain causal
    /// LM shape (`config.json` + flat safetensors, mlx_lm's own
    /// territory), a GGUF-only repo, or something unusual. Not flagged
    /// either way rather than guessed at.
    case unknown

    /// `paths` is a repo's file list — `HFModelSummary.siblings`, or a
    /// local directory listing's relative paths.
    public static func classify(paths: [String]) -> ModelCompatibility {
        guard !paths.isEmpty else { return .unknown }
        let lowerPaths = paths.map { $0.lowercased() }

        if lowerPaths.contains("model_index.json") {
            return .compatible
        }
        let hasTransformerDir = lowerPaths.contains { $0.hasPrefix("transformer/") }
        let hasVAEDir = lowerPaths.contains { $0.hasPrefix("vae/") }
        if hasTransformerDir && hasVAEDir {
            return .compatible
        }

        let hasConfigJSON = lowerPaths.contains("config.json")
        let safetensorsCount = lowerPaths.filter { $0.hasSuffix(".safetensors") && !$0.contains("/") }.count
        // A handful of flat safetensors files with no config.json and
        // no pipeline subfolders at all — the exact shape that broke
        // for real. Any subfolder structure at all (text_encoder/,
        // tokenizer/, …) without transformer/+vae/ specifically is left
        // as `.unknown` rather than guessed at — this only flags the
        // confirmed-broken shape, not every layout it hasn't seen.
        let hasAnySubfolder = lowerPaths.contains { $0.contains("/") }
        if safetensorsCount > 0, !hasConfigJSON, !hasAnySubfolder {
            return .incompatible
        }

        return .unknown
    }
}
