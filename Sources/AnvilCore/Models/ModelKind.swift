import Foundation

/// What a registered model is for — decides which serving mechanism
/// (`LLMServer`/`mlx_lm` vs `ImageServer`/`mflux`) loading it uses.
public enum ModelKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
}

/// Guesses a model's kind from its files. Diffusion pipelines usually
/// lay weights out very differently from a plain causal LM (separate
/// `transformer/`/`vae/` component directories, often a second text
/// encoder for Flux's dual T5+CLIP setup) — but a real, reported case
/// broke that assumption: `black-forest-labs/FLUX.2-klein-4b-nvfp4`
/// ships as one flat `*.safetensors` file with no pipeline directory
/// structure at all and no `config.json` either, so the original
/// structural-only check always fell through to `.text` for it —
/// wrongly, since it's very much an image model, just packaged as a
/// single raw checkpoint. Two more signals now catch that case: the
/// repo/folder name itself against known diffusion-family keywords,
/// and, failing that, peeking at a flat safetensors file's own JSON
/// header (present at the very start of the file — no need to read any
/// tensor data) for architecture-specific tensor-name patterns.
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
        // A diffusion pipeline (Flux and friends): weights live inside
        // component subdirectories rather than flat at the top level.
        if names.contains("transformer") && names.contains("vae") {
            return .image
        }
        if nameLooksLikeDiffusionFamily(path.lastPathComponent) {
            return .image
        }
        let safetensorsFiles = contents.filter { $0.pathExtension.lowercased() == "safetensors" }
        if let firstSafetensors = safetensorsFiles.first, looksLikeDiffusionCheckpoint(firstSafetensors) {
            return .image
        }
        return .text
    }

    /// Well-known diffusion/image-model family names that show up in a
    /// repo's own folder name — cheap, reliable for anything using a
    /// recognizable name (which is most community conversions), and
    /// tried before the more expensive header-parsing fallback below.
    private static let diffusionFamilyKeywords = [
        "flux", "stable-diffusion", "stablediffusion", "sdxl", "sd3",
        "kolors", "pixart", "hunyuandit", "auraflow", "kandinsky",
        "playground-v2", "wuerstchen", "cogview"
    ]

    static func nameLooksLikeDiffusionFamily(_ name: String) -> Bool {
        let lower = name.lowercased()
        return diffusionFamilyKeywords.contains { lower.contains($0) }
    }

    /// Reads just a safetensors file's JSON header (an 8-byte
    /// little-endian length prefix, then that many bytes of JSON
    /// describing every tensor's name/dtype/shape — never the tensor
    /// data itself, so this stays fast even for a multi-gigabyte
    /// checkpoint) and looks for tensor-name fragments specific to
    /// diffusion architectures (FLUX-style `img_in`/`txt_in`/
    /// `time_text_embed`/`double_blocks`/`single_blocks`, or a
    /// `vae.`/`text_encoder.` prefix) that a causal LM's own tensor
    /// names (`model.layers.`, `lm_head`, `embed_tokens`) never have.
    static func looksLikeDiffusionCheckpoint(_ fileURL: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? handle.close() }
        guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8 else { return false }
        let headerLength = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        // Sanity cap — a real safetensors header is at most a few MB
        // even for a model with thousands of tensors; anything wildly
        // larger means this isn't a safetensors file we understand.
        guard headerLength > 0, headerLength < 50_000_000 else { return false }
        guard let headerData = try? handle.read(upToCount: Int(headerLength)),
              let json = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
            return false
        }

        let diffusionMarkers = [
            "img_in", "txt_in", "time_text_embed", "double_blocks", "single_blocks",
            "vae.", "text_encoder.", "to_q.", "to_k.", "to_v.", "add_q_proj"
        ]
        for key in json.keys {
            let lowerKey = key.lowercased()
            if diffusionMarkers.contains(where: { lowerKey.contains($0) }) {
                return true
            }
        }
        return false
    }
}
