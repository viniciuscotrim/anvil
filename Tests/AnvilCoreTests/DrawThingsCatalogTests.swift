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
        #expect(curated.contains(where: { $0.baseModel == "Flux.2" }))
    }

    @Test
    func fluxSchnellHasDistinctQuantizationVariantsWithIndividualSizes() {
        let curated = DrawThingsCatalog.curatedModels
        let fluxVariants = curated.filter { $0.repoID == "mflux-community/flux-1-schnell-mflux-q4" || $0.repoID == "mflux-community/flux-1-schnell-mflux-q8" }
        #expect(!fluxVariants.isEmpty)
        
        let fourBit = curated.first { $0.repoID == "mflux-community/flux-1-schnell-mflux-q4" }
        let eightBit = curated.first { $0.repoID == "mflux-community/flux-1-schnell-mflux-q8" }
        #expect(fourBit != nil)
        #expect(eightBit != nil)
        #expect(fourBit?.sizeBytes == 6_400_000_000)
        #expect(eightBit?.sizeBytes == 12_800_000_000)
    }

    @Test
    func emptySearchReturnsCuratedModels() async throws {
        let catalog = DrawThingsCatalog()
        let results = try await catalog.search(query: "")
        #expect(!results.isEmpty)
        #expect(results.first?.repoID.contains("flux") == true)
    }

    @Test
    func drawThingsModelsAreClassifiedAsSupportedDrawThingsEngine() {
        let paths = ["model.ckpt", "model_index.json"]
        #expect(ModelCompatibility.classify(paths: paths) == .supported(.drawThings))
    }
}
