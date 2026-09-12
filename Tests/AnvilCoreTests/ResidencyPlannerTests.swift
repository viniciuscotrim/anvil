import Testing
@testable import AnvilCore

@Suite("ResidencyPlanner")
struct ResidencyPlannerTests {
    private let source = ModelSource.imported(originalPath: "/tmp/model")

    @Test
    func reservesWithinBudgetAndReleases() {
        let planner = ResidencyPlanner(physicalMemory: 10_000_000_000)
        let model = ModelEntry(
            id: "model-a",
            displayName: "Model A",
            source: source,
            localPath: "/tmp/model-a",
            sizeBytes: 1_000_000_000
        )

        #expect(planner.reserve(model))
        #expect(planner.reservedBytes == planner.estimate(for: model))
        #expect(planner.reserve(model))
        planner.release(modelID: model.id)
        #expect(planner.reservedBytes == 0)
    }

    @Test
    func rejectsAReservationThatWouldExceedTheSharedBudget() {
        let planner = ResidencyPlanner(physicalMemory: 10_000_000_000)
        let first = ModelEntry(
            id: "model-a",
            displayName: "Model A",
            source: source,
            localPath: "/tmp/model-a",
            sizeBytes: 5_000_000_000
        )
        let second = ModelEntry(
            id: "model-b",
            displayName: "Model B",
            source: source,
            localPath: "/tmp/model-b",
            sizeBytes: 1_000_000_000
        )

        #expect(planner.reserve(first))
        #expect(!planner.reserve(second))
        #expect(planner.reservation(for: second.id) == nil)
    }
}
