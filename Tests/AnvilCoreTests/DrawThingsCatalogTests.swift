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
