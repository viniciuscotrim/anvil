import Foundation
import Testing
@testable import AnvilCore

@Suite("ModelRegistry")
struct ModelRegistryTests {
    private func tempRegistryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-tests-\(UUID().uuidString)")
            .appendingPathComponent("registry.json")
    }

    @Test
    func upsertThenAllRoundTrips() async throws {
        let registry = ModelRegistry(fileURL: tempRegistryFile())
        let entry = ModelEntry(
            id: "org/model",
            displayName: "org/model",
            source: .huggingFace(repoID: "org/model", revision: "main"),
            localPath: "/tmp/org--model",
            sizeBytes: 1024
        )

        _ = try await registry.upsert(entry)
        let all = await registry.all()

        #expect(all == [entry])
    }

    @Test
    func upsertWithSameIDReplacesRatherThanDuplicates() async throws {
        let registry = ModelRegistry(fileURL: tempRegistryFile())
        let original = ModelEntry(
            id: "org/model", displayName: "org/model",
            source: .huggingFace(repoID: "org/model", revision: "main"),
            localPath: "/tmp/a", sizeBytes: 100
        )
        let updated = ModelEntry(
            id: "org/model", displayName: "org/model (renamed)",
            source: .huggingFace(repoID: "org/model", revision: "main"),
            localPath: "/tmp/a", sizeBytes: 200
        )

        _ = try await registry.upsert(original)
        _ = try await registry.upsert(updated)
        let all = await registry.all()

        #expect(all.count == 1)
        #expect(all.first?.sizeBytes == 200)
    }

    @Test
    func persistsAcrossSeparateRegistryInstances() async throws {
        let fileURL = tempRegistryFile()
        let entry = ModelEntry(
            id: "imported:/tmp/local-model",
            displayName: "local-model",
            source: .imported(originalPath: "/tmp/local-model"),
            localPath: "/tmp/local-model",
            sizeBytes: nil,
            // Fixed instant: this test decodes from disk into a fresh
            // instance, and Date's sub-millisecond precision doesn't
            // round-trip through JSON — pin it so the comparison below
            // isn't flaky regardless of formatter precision.
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        _ = try await ModelRegistry(fileURL: fileURL).upsert(entry)
        let reopened = await ModelRegistry(fileURL: fileURL).all()

        #expect(reopened == [entry])
    }

    @Test
    func removeDeletesTheEntry() async throws {
        let registry = ModelRegistry(fileURL: tempRegistryFile())
        let entry = ModelEntry(
            id: "org/model", displayName: "org/model",
            source: .huggingFace(repoID: "org/model", revision: "main"),
            localPath: "/tmp/a", sizeBytes: nil
        )
        _ = try await registry.upsert(entry)

        try await registry.remove(id: "org/model")

        #expect(await registry.all().isEmpty)
        #expect(await registry.contains(id: "org/model") == false)
    }
}
