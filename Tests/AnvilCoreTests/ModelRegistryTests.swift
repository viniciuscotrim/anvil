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

        // `all()` always re-reads from disk (see `ModelRegistry`'s doc
        // comment — it never trusts an in-memory cache, since more than
        // one instance can point at the same file), so `addedAt` comes
        // back through the same ISO-8601-with-fractional-seconds
        // encoding used everywhere else, which is millisecond-precision
        // — coarser than an in-memory `Date`'s. Compare against an
        // equally round-tripped value rather than the original, so this
        // asserts what actually matters (a save+load round trip is
        // lossless at the precision that's ever persisted) instead of
        // failing on sub-millisecond noise that was never meaningful.
        let roundTripped = try JSONDecoder.anvil.decode(ModelEntry.self, from: JSONEncoder.anvil.encode(entry))
        #expect(all == [roundTripped])
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

    @Test
    func deduplicateByLocalPathMergesDuplicatesPreferringTheHuggingFaceSourcedOne() async throws {
        // The real reported bug: the same files ended up registered
        // twice — once under a stable Hugging Face repo id (downloaded
        // via search), once under a second, path-derived "imported:" id
        // (a later models-folder scan sweeping up the same directory).
        let registry = ModelRegistry(fileURL: tempRegistryFile())
        let downloaded = ModelEntry(
            id: "black-forest-labs/FLUX.2-klein-4b-nvfp4",
            displayName: "black-forest-labs/FLUX.2-klein-4b-nvfp4",
            source: .huggingFace(repoID: "black-forest-labs/FLUX.2-klein-4b-nvfp4", revision: "main"),
            localPath: "/tmp/flux",
            sizeBytes: 100,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let scannedDuplicate = ModelEntry(
            id: "imported:/tmp/flux",
            displayName: "flux",
            source: .imported(originalPath: "/tmp/flux"),
            localPath: "/tmp/flux",
            sizeBytes: 100,
            addedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        _ = try await registry.upsert(downloaded)
        _ = try await registry.upsert(scannedDuplicate)
        #expect(await registry.all().count == 2)

        let removedCount = try await registry.deduplicateByLocalPath()

        let all = await registry.all()
        #expect(removedCount == 1)
        #expect(all.count == 1)
        #expect(all.first?.id == "black-forest-labs/FLUX.2-klein-4b-nvfp4")
    }

    @Test
    func refreshKindsUpdatesAnEntryWhoseDetectionHasChanged() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-refresh-kind-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{}".write(to: dir.appendingPathComponent("model_index.json"), atomically: true, encoding: .utf8)

        let registry = ModelRegistry(fileURL: tempRegistryFile())
        // Registered with a stale/wrong kind, as if by an older,
        // less accurate detector.
        let entry = ModelEntry(
            id: "imported:\(dir.path)", displayName: dir.lastPathComponent,
            source: .imported(originalPath: dir.path),
            localPath: dir.path, sizeBytes: nil, kind: .text
        )
        _ = try await registry.upsert(entry)

        let changedCount = try await registry.refreshKinds()

        #expect(changedCount == 1)
        #expect(await registry.all().first?.kind == .image)
    }

    @Test
    func deduplicateByLocalPathIsANoOpWithNothingToMerge() async throws {
        let registry = ModelRegistry(fileURL: tempRegistryFile())
        let entry = ModelEntry(
            id: "org/model", displayName: "org/model",
            source: .huggingFace(repoID: "org/model", revision: "main"),
            localPath: "/tmp/a", sizeBytes: nil
        )
        _ = try await registry.upsert(entry)

        let removedCount = try await registry.deduplicateByLocalPath()

        #expect(removedCount == 0)
        #expect(await registry.all().count == 1)
    }
}
