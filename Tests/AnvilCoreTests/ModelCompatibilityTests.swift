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
        if case .incompatible = ModelCompatibility.classify(paths: paths) {
            #expect(Bool(true))
        } else {
            Issue.record("Expected incompatible for flat safetensors without config")
        }
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
        #expect(ModelCompatibility.classify(paths: paths) == .supported(.mflux))
    }

    @Test
    func recognizesModelIndexJSONAsCompatible() {
        #expect(ModelCompatibility.classify(paths: ["model_index.json", "unet/model.safetensors"]) == .supported(.mflux))
    }

    @Test
    func recognizesGGUFFilesAsSupportedLlamaCpp() {
        let paths = ["Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf", "README.md"]
        #expect(ModelCompatibility.classify(paths: paths) == .supported(.llamaCpp))
    }

    @Test
    func recognizesCausalLMSafetensorsAsSupportedMLX() {
        let paths = ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]
        #expect(ModelCompatibility.classify(paths: paths) == .supported(.mlx))
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
