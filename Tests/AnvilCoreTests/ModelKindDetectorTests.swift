import Foundation
import Testing
@testable import AnvilCore

@Suite("ModelKindDetector")
struct ModelKindDetectorTests {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-kind-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a minimal, real safetensors file — an 8-byte
    /// little-endian header-length prefix, then that many bytes of the
    /// JSON header itself (the only part `ModelKindDetector` ever
    /// reads), then a little real tensor-data padding so a header
    /// length larger than the actual file wouldn't accidentally read
    /// past the end.
    private func writeSafetensorsFile(at url: URL, tensorNames: [String]) throws {
        var header: [String: Any] = [:]
        for name in tensorNames {
            header[name] = ["dtype": "F16", "shape": [1], "data_offsets": [0, 2]]
        }
        let headerData = try JSONSerialization.data(withJSONObject: header)
        var lengthBytes = withUnsafeBytes(of: UInt64(headerData.count).littleEndian) { Data($0) }
        lengthBytes.append(headerData)
        lengthBytes.append(Data(repeating: 0, count: 16))
        try lengthBytes.write(to: url)
    }

    // MARK: - Existing structural checks still work

    @Test
    func detectsModelIndexJSONAsImage() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{}".write(to: dir.appendingPathComponent("model_index.json"), atomically: true, encoding: .utf8)

        #expect(ModelKindDetector.detect(at: dir) == .image)
    }

    @Test
    func plainConfigJSONIsText() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{}".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        #expect(ModelKindDetector.detect(at: dir) == .text)
    }

    // MARK: - The real reported case: a flat single-safetensors-file repo

    @Test
    func detectsAFlatFluxCheckpointByNameEvenWithNoConfigJSON() throws {
        // The real reported bug: black-forest-labs/FLUX.2-klein-4b-nvfp4
        // ships as one flat *.safetensors file with no config.json and
        // no diffusers-pipeline directory structure — the old
        // structural-only check always fell through to .text for it.
        let dir = try makeTempDirectory()
            .appendingPathComponent("black-forest-labs--FLUX.2-klein-4b-nvfp4", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSafetensorsFile(at: dir.appendingPathComponent("weights.safetensors"), tensorNames: ["model.layers.0.self_attn.q_proj.weight"])

        #expect(ModelKindDetector.detect(at: dir) == .image)
    }

    @Test
    func detectsADiffusionCheckpointByTensorNamesWhenTheFolderNameGivesNoHint() throws {
        // The folder name alone doesn't say "diffusion" here — only the
        // safetensors header's own tensor names do.
        let dir = try makeTempDirectory()
            .appendingPathComponent("some-community-conversion-4bit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSafetensorsFile(
            at: dir.appendingPathComponent("weights.safetensors"),
            tensorNames: ["double_blocks.0.img_attn.qkv.weight", "vae.decoder.conv_in.weight"]
        )

        #expect(ModelKindDetector.detect(at: dir) == .image)
    }

    @Test
    func aFlatSafetensorsCausalLMStaysText() throws {
        let dir = try makeTempDirectory()
            .appendingPathComponent("some-llm-4bit", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSafetensorsFile(
            at: dir.appendingPathComponent("weights.safetensors"),
            tensorNames: ["model.layers.0.self_attn.q_proj.weight", "model.embed_tokens.weight", "lm_head.weight"]
        )

        #expect(ModelKindDetector.detect(at: dir) == .text)
    }

    @Test
    func nameKeywordMatchingIsCaseInsensitive() {
        #expect(ModelKindDetector.nameLooksLikeDiffusionFamily("FLUX.2-klein-4b-nvfp4"))
        #expect(ModelKindDetector.nameLooksLikeDiffusionFamily("stable-diffusion-xl-base-1.0"))
        #expect(!ModelKindDetector.nameLooksLikeDiffusionFamily("Qwen3.5-9B-MLX-8bit"))
    }
}
