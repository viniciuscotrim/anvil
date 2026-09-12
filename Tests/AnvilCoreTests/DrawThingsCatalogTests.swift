import Foundation
import Testing
@testable import AnvilCore

@Suite("DrawThingsCatalog")
struct DrawThingsCatalogTests {
    @Test
    func curatedModelsContainOfficialDrawThingsModels() {
        let curated = DrawThingsCatalog.curatedModels
        #expect(!curated.isEmpty)
        #expect(curated.contains(where: { $0.baseModel == "Flux.1" }))
        #expect(curated.contains(where: { $0.baseModel == "SDXL" }))
    }

    @Test
    func fluxSchnellHasDistinctQuantizationVariantsWithIndividualSizes() {
        let curated = DrawThingsCatalog.curatedModels
        let fluxVariants = curated.filter { $0.repoID == "drawthingsai/FLUX.1-schnell" }
        #expect(fluxVariants.count >= 4)
        
        let fourBit = fluxVariants.first { $0.quantization == "4-bit" }
        let eightBit = fluxVariants.first { $0.quantization == "8-bit" }
        #expect(fourBit != nil)
        #expect(eightBit != nil)
        #expect(fourBit?.sizeBytes == 6_400_000_000)
        #expect(eightBit?.sizeBytes == 12_800_000_000)
        #expect(fourBit?.filename == "flux_1_schnell_4bit.ckpt")
        #expect(eightBit?.filename == "flux_1_schnell_8bit.ckpt")
    }

    @Test
    func emptySearchReturnsCuratedModels() async throws {
        let catalog = DrawThingsCatalog()
        let results = try await catalog.search(query: "")
        #expect(!results.isEmpty)
        #expect(results.first?.repoID.contains("drawthings") == true)
    }

    @Test
    func drawThingsModelsAreClassifiedAsSupportedDrawThingsEngine() {
        let paths = ["model.ckpt", "model_index.json"]
        #expect(ModelCompatibility.classify(paths: paths) == .supported(.drawThings))
    }
}
