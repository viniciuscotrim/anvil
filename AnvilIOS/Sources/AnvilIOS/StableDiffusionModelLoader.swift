import AnvilCore
import Foundation
import MLX
import MLXNN

/// Builds a real, loadable `StableDiffusionConfiguration` for an
/// arbitrary, already-registered diffusers-format checkpoint — not just
/// the two hardcoded presets the vendored library ships
/// (`presetSDXLTurbo`/`presetStableDiffusion21Base`, each pinned to one
/// exact Hugging Face repo).
///
/// `StableDiffusionXL`/`StableDiffusionBase` themselves are already
/// fully generic — their `init` just reads whatever `config.json`/
/// weights the configuration's `files` dict points to; nothing in them
/// is turbo- or Stability-AI-specific. A "preset" is only a convenience
/// wrapper picking one `id`+`files`+`factory` combination. This builds
/// that same wrapper for any registered model instead, choosing the
/// SDXL (dual text encoder) vs single-text-encoder shape from what's
/// actually in the model's own folder — real, on-device architecture
/// detection, the same kind of thing Draw Things and other serious
/// on-device diffusion apps do. iOS never stopped this; only the
/// vendored library's own two-preset convenience layer did.
enum StableDiffusionModelLoader {
    enum Architecture {
        case sdxl
        case base
    }

    /// A second text encoder folder (`text_encoder_2/`) is the one
    /// structural feature every proper SDXL-family diffusers repo has
    /// and no SD1.x/2.x repo does — the same kind of structural signal
    /// `ModelCompatibility` already uses (`transformer/`+`vae/`) for
    /// Flux on the Mac side. `nil` when the folder doesn't look like a
    /// diffusers pipeline this loader can drive at all (missing unet/
    /// vae/text_encoder entirely — a raw checkpoint, wrong shape, etc.).
    static func architecture(at directory: URL) -> Architecture? {
        let fm = FileManager.default
        guard isDirectory(fm, directory.appendingPathComponent("unet")),
            isDirectory(fm, directory.appendingPathComponent("vae")),
            isDirectory(fm, directory.appendingPathComponent("text_encoder"))
        else { return nil }
        return isDirectory(fm, directory.appendingPathComponent("text_encoder_2")) ? .sdxl : .base
    }

    private static func isDirectory(_ fm: FileManager, _ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Picks whichever weight filename actually exists on disk for a
    /// component — the `.fp16.safetensors` variant when present (half
    /// the size, the same fix already applied to `presetSDXLTurbo`
    /// itself), the plain `.safetensors` name otherwise. Whatever the
    /// user's own search-and-download actually fetched, not a guess.
    private static func weightFilename(in directory: URL, component: String, base: String) -> String {
        let fp16Path = "\(component)/\(base).fp16.safetensors"
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(fp16Path).path) {
            return fp16Path
        }
        return "\(component)/\(base).safetensors"
    }

    static func configuration(for entry: ModelEntry) -> StableDiffusionConfiguration? {
        let directory = URL(fileURLWithPath: entry.localPath)
        guard let architecture = architecture(at: directory) else { return nil }

        let unetWeights = weightFilename(in: directory, component: "unet", base: "diffusion_pytorch_model")
        let textEncoderWeights = weightFilename(in: directory, component: "text_encoder", base: "model")
        let vaeWeights = weightFilename(in: directory, component: "vae", base: "diffusion_pytorch_model")

        switch architecture {
        case .sdxl:
            return StableDiffusionConfiguration(
                id: entry.id,
                files: [
                    .unetConfig: "unet/config.json",
                    .unetWeights: unetWeights,
                    .textEncoderConfig: "text_encoder/config.json",
                    .textEncoderWeights: textEncoderWeights,
                    .textEncoderConfig2: "text_encoder_2/config.json",
                    .textEncoderWeights2: weightFilename(in: directory, component: "text_encoder_2", base: "model"),
                    .vaeConfig: "vae/config.json",
                    .vaeWeights: vaeWeights,
                    .diffusionConfig: "scheduler/scheduler_config.json",
                    .tokenizerVocabulary: "tokenizer/vocab.json",
                    .tokenizerMerges: "tokenizer/merges.txt",
                    .tokenizerVocabulary2: "tokenizer_2/vocab.json",
                    .tokenizerMerges2: "tokenizer_2/merges.txt",
                ],
                // A standard (non-"turbo") SDXL checkpoint's own usual
                // guidance/step count, but at 768² rather than SDXL's
                // native 1024² — a real, confirmed crash: generating at
                // 1024² OOM-killed this process on a phone (same
                // JetsamEvent "per-process-limit" reason the load-time
                // crash gave, this time during the UNet/VAE forward pass
                // itself, not just holding the weights resident). 768² is
                // roughly half the pixel count of 1024², which is
                // roughly half the activation/decode memory at generation
                // time. `sdxl-turbo` itself is still reached through the
                // built-in preset, which keeps its own tuned (0 cfg, 2
                // step, 512²) defaults untouched.
                defaultParameters: { EvaluateParameters(cfgWeight: 6.0, steps: 25, latentSize: [96, 96]) },
                factory: { hub, sdConfiguration, loadConfiguration in
                    let sd = try StableDiffusionXL(
                        hub: hub, configuration: sdConfiguration, dType: loadConfiguration.dType)
                    if loadConfiguration.quantize {
                        quantize(model: sd.textEncoder, filter: { _, m in m is Linear })
                        quantize(model: sd.textEncoder2, filter: { _, m in m is Linear })
                        quantize(model: sd.unet, groupSize: 32, bits: 8)
                    }
                    return sd
                }
            )
        case .base:
            return StableDiffusionConfiguration(
                id: entry.id,
                files: [
                    .unetConfig: "unet/config.json",
                    .unetWeights: unetWeights,
                    .textEncoderConfig: "text_encoder/config.json",
                    .textEncoderWeights: textEncoderWeights,
                    .vaeConfig: "vae/config.json",
                    .vaeWeights: vaeWeights,
                    .diffusionConfig: "scheduler/scheduler_config.json",
                    .tokenizerVocabulary: "tokenizer/vocab.json",
                    .tokenizerMerges: "tokenizer/merges.txt",
                ],
                defaultParameters: { EvaluateParameters(cfgWeight: 7.5, steps: 30, latentSize: [64, 64]) },
                factory: { hub, sdConfiguration, loadConfiguration in
                    let sd = try StableDiffusionBase(
                        hub: hub, configuration: sdConfiguration, dType: loadConfiguration.dType)
                    if loadConfiguration.quantize {
                        quantize(model: sd.textEncoder, filter: { _, m in m is Linear })
                        quantize(model: sd.unet, groupSize: 32, bits: 8)
                    }
                    return sd
                }
            )
        }
    }
}
