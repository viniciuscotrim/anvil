import Foundation
import Testing
@testable import AnvilCore

@Suite("ModelFamilyGrouping")
struct ModelFamilyGroupingTests {
    private func entry(_ displayName: String, kind: ModelKind = .text) -> ModelEntry {
        ModelEntry(
            id: "imported:/tmp/\(displayName)",
            displayName: displayName,
            source: .imported(originalPath: "/tmp/\(displayName)"),
            localPath: "/tmp/\(displayName)",
            sizeBytes: nil,
            kind: kind
        )
    }

    @Test
    func groupsSizeAndQuantVariantsOfTheSameFamilyTogether() {
        let entries = [
            entry("Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-MLX-bf16"),
            entry("Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-MLX-mxfp8"),
            entry("Qwen3.5-4B-MLX-4bit")
        ]

        let families = ModelFamilyGrouping.group(entries)

        #expect(families.count == 1)
        #expect(families.first?.name == "Qwen3.5")
        #expect(families.first?.models.count == 3)
    }

    @Test
    func keepsDifferentFamiliesSeparate() {
        let entries = [
            entry("Qwen3.5-4B-MLX-4bit"),
            entry("Qwen3-4B-4bit"),
            entry("FLUX.2-klein-4b-nvfp4", kind: .image)
        ]

        let families = ModelFamilyGrouping.group(entries)

        #expect(Set(families.map(\.name)) == ["Qwen3.5", "Qwen3", "FLUX.2-klein"])
    }

    @Test
    func fallsBackToTheWholeNameWhenNoVariantTokenIsFound() {
        #expect(ModelFamilyGrouping.familyName(for: "some-unusual-name") == "some-unusual-name")
    }
}
