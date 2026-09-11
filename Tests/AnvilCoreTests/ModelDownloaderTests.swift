import Foundation
import Testing
@testable import AnvilCore

@Suite("ModelDownloader")
struct ModelDownloaderTests {
    @Test
    func skipsARootLevelWeightFileWhenARealPipelineIsConfirmed() {
        // The exact real repo this was found on:
        // black-forest-labs/FLUX.2-klein-4B ships flux-2-klein-4b.safetensors
        // at the root — a 7.8GB byte-for-byte duplicate of
        // transformer/diffusion_pytorch_model.safetensors — on top of
        // the ~16GB the pipeline actually needs.
        let paths = [
            ".gitattributes", "LICENSE.md", "README.md",
            "flux-2-klein-4b.safetensors",
            "model_index.json",
            "transformer/config.json", "transformer/diffusion_pytorch_model.safetensors",
            "vae/config.json", "vae/diffusion_pytorch_model.safetensors",
            "text_encoder/config.json", "text_encoder/model-00001-of-00002.safetensors"
        ]
        let ignored = ModelDownloader.redundantRootLevelWeightFiles(in: paths)
        #expect(ignored == ["flux-2-klein-4b.safetensors"])
    }

    @Test
    func neverSkipsAnythingWithoutModelIndexJSON() {
        // The exact real repo this must never touch — the flat, truly
        // single-file, no-pipeline-at-all case (a different, genuinely
        // incompatible shape — ModelCompatibility already flags this
        // one, not this mechanism).
        let paths = [
            ".gitattributes", "LICENSE.md", "flux-2-klein-4b-nvfp4.safetensors"
        ]
        #expect(ModelDownloader.redundantRootLevelWeightFiles(in: paths).isEmpty)
    }

    @Test
    func neverSkipsAFileInsideAComponentSubfolder() {
        let paths = ["model_index.json", "transformer/diffusion_pytorch_model.safetensors"]
        #expect(ModelDownloader.redundantRootLevelWeightFiles(in: paths).isEmpty)
    }

    @Test
    func skipsMultipleRootLevelWeightFilesIfPresent() {
        let paths = ["model_index.json", "model.safetensors", "model.ckpt", "transformer/x.safetensors"]
        let ignored = Set(ModelDownloader.redundantRootLevelWeightFiles(in: paths))
        #expect(ignored == ["model.safetensors", "model.ckpt"])
    }

    @Test
    func emptyFilePathsSkipsNothing() {
        #expect(ModelDownloader.redundantRootLevelWeightFiles(in: []).isEmpty)
    }
}
