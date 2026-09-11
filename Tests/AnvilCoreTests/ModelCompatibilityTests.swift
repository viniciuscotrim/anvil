import Foundation
import Testing
@testable import AnvilCore

@Suite("ModelCompatibility")
struct ModelCompatibilityTests {
    @Test
    func flagsARealFlatSingleFileCheckpointAsIncompatible() {
        // The exact real repo that broke: black-forest-labs/FLUX.2-klein-4b-nvfp4
        let paths = [
            ".gitattributes", "LICENSE.md", "README.md", "editing.jpg",
            "flux-2-klein-4b-nvfp4.safetensors", "others.jpg", "realism.jpg"
        ]
        #expect(ModelCompatibility.classify(paths: paths) == .incompatible)
    }

    @Test
    func recognizesARealMfluxCommunityPipelineAsCompatible() {
        // The exact real repo confirmed working: mflux-community/flux-1-schnell-mflux-q3
        let paths = [
            ".gitattributes",
            "text_encoder/0.safetensors", "text_encoder/model.safetensors.index.json",
            "text_encoder_2/0.safetensors", "text_encoder_2/model.safetensors.index.json",
            "tokenizer/tokenizer.json", "tokenizer_2/tokenizer.json",
            "transformer/0.safetensors", "transformer/1.safetensors", "transformer/model.safetensors.index.json",
            "vae/0.safetensors", "vae/model.safetensors.index.json"
        ]
        #expect(ModelCompatibility.classify(paths: paths) == .compatible)
    }

    @Test
    func recognizesModelIndexJSONAsCompatible() {
        #expect(ModelCompatibility.classify(paths: ["model_index.json", "unet/model.safetensors"]) == .compatible)
    }

    @Test
    func aPlainTextModelShapeIsUnknownNotIncompatible() {
        // config.json + flat safetensors — mlx_lm's own territory, not
        // what this classifier is judging; must never be flagged
        // incompatible just because it isn't a diffusion pipeline.
        let paths = ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]
        #expect(ModelCompatibility.classify(paths: paths) == .unknown)
    }

    @Test
    func anUnusualStructureIsUnknownRatherThanGuessed() {
        let paths = ["text_encoder/model.safetensors", "README.md"]
        #expect(ModelCompatibility.classify(paths: paths) == .unknown)
    }

    @Test
    func emptyPathsAreUnknown() {
        #expect(ModelCompatibility.classify(paths: []) == .unknown)
    }
}
