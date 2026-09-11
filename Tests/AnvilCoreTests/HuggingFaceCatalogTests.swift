import Foundation
import Testing
@testable import AnvilCore

@Suite("HFModelSummary")
struct HFModelSummaryTests {
    /// This exact shape is what huggingface.co/api/models actually
    /// returns with expand=safetensors (confirmed via a live request
    /// against Qwen/Qwen3.5-4B before writing this).
    @Test
    func decodesSizeFromSafetensorsParameterCounts() throws {
        let json = #"""
        {
            "id": "Qwen/Qwen3.5-4B",
            "likes": 911,
            "downloads": 7196884,
            "safetensors": {"parameters": {"BF16": 4659861248, "F32": 3840}, "total": 4659865088},
            "tags": ["transformers", "safetensors"]
        }
        """#
        let summary = try JSONDecoder().decode(HFModelSummary.self, from: Data(json.utf8))

        #expect(summary.modelID == "Qwen/Qwen3.5-4B")
        #expect(summary.downloads == 7196884)
        // BF16 (2 bytes) * 4659861248 + F32 (4 bytes) * 3840
        let expectedBytes: Int64 = 4_659_861_248 * 2 + 3840 * 4
        let actualBytes = try #require(summary.sizeBytes)
        #expect(actualBytes == expectedBytes)
    }

    @Test
    func sizeIsNilWithNoSafetensorsMetadata() throws {
        let json = #"{"id": "unsloth/SmolLM2-135M-Instruct-GGUF", "downloads": 93460}"#
        let summary = try JSONDecoder().decode(HFModelSummary.self, from: Data(json.utf8))

        #expect(summary.sizeBytes == nil)
    }
}

@Suite("ModelSizeClass")
struct ModelSizeClassTests {
    private let ram: UInt64 = 24 * 1_000_000_000 // 24GB, matching the M4 Pro in the brief

    @Test
    func classifiesAtTheQuarterAndHalfBoundaries() {
        #expect(ModelSizeClass.classify(sizeBytes: Int64(ram) / 4, ramBytes: ram) == .small)
        #expect(ModelSizeClass.classify(sizeBytes: Int64(ram) / 4 + 1, ramBytes: ram) == .medium)
        #expect(ModelSizeClass.classify(sizeBytes: Int64(ram) / 2, ramBytes: ram) == .medium)
        #expect(ModelSizeClass.classify(sizeBytes: Int64(ram) / 2 + 1, ramBytes: ram) == .large)
    }
}
