import Foundation
import Testing
@testable import AnvilCore

@Suite("CivitAIModelSummary")
struct CivitAIModelSummaryTests {
    /// This shape is what civitai.com/api/v1/models actually returns
    /// (confirmed via a live request before writing this) — trimmed to
    /// the fields this type reads.
    @Test
    func decodesARealCheckpointShape() throws {
        let json = #"""
        {
            "id": 212251,
            "name": "Clean and Crisp SDXL and Flux",
            "type": "Checkpoint",
            "nsfw": false,
            "stats": {"downloadCount": 883},
            "creator": {"username": "cainezen"},
            "modelVersions": [
                {
                    "id": 1258719,
                    "baseModel": "Flux.1 D",
                    "files": [
                        {
                            "name": "cleanAndCrispSDXLAnd_fluxV1010steps.safetensors",
                            "sizeKB": 6536616.18,
                            "type": "Model",
                            "primary": true,
                            "downloadUrl": "https://civitai.com/api/download/models/1258719",
                            "metadata": {"format": "SafeTensor"}
                        }
                    ]
                }
            ]
        }
        """#
        let summary = try JSONDecoder().decode(CivitAIModelSummary.self, from: Data(json.utf8))

        #expect(summary.id == 212251)
        #expect(summary.name == "Clean and Crisp SDXL and Flux")
        #expect(summary.baseModel == "Flux.1 D")
        #expect(summary.downloadCount == 883)
        #expect(summary.creatorUsername == "cainezen")
        #expect(summary.isFluxFamily)
        let file = try #require(summary.primaryFile)
        #expect(file.filename == "cleanAndCrispSDXLAnd_fluxV1010steps.safetensors")
        #expect(file.downloadURL.absoluteString == "https://civitai.com/api/download/models/1258719")
        #expect(file.sizeBytes == Int64(6536616.18 * 1024))
    }

    @Test
    func sdxlBaseModelIsNotFluxFamily() throws {
        let json = #"""
        {"id": 1, "name": "Some SDXL model", "type": "Checkpoint", "modelVersions": [{"baseModel": "SDXL 1.0", "files": []}]}
        """#
        let summary = try JSONDecoder().decode(CivitAIModelSummary.self, from: Data(json.utf8))
        #expect(!summary.isFluxFamily)
        #expect(summary.primaryFile == nil)
    }

    @Test
    func missingModelVersionsDecodesWithNilPrimaryFile() throws {
        let json = #"{"id": 1, "name": "Empty model", "type": "Checkpoint"}"#
        let summary = try JSONDecoder().decode(CivitAIModelSummary.self, from: Data(json.utf8))
        #expect(summary.primaryFile == nil)
        #expect(summary.baseModel == nil)
        #expect(!summary.nsfw)
    }

    @Test
    func picksThePrimaryFlaggedFileOverOthers() throws {
        let json = #"""
        {
            "id": 1, "name": "Multi-file model", "type": "Checkpoint",
            "modelVersions": [{
                "baseModel": "SD 1.5",
                "files": [
                    {"name": "pruned.safetensors", "sizeKB": 100, "primary": false, "downloadUrl": "https://x/1", "metadata": {"format": "SafeTensor"}},
                    {"name": "full.safetensors", "sizeKB": 200, "primary": true, "downloadUrl": "https://x/2", "metadata": {"format": "SafeTensor"}}
                ]
            }]
        }
        """#
        let summary = try JSONDecoder().decode(CivitAIModelSummary.self, from: Data(json.utf8))
        #expect(summary.primaryFile?.filename == "full.safetensors")
    }
}
