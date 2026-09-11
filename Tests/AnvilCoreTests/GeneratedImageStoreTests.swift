import Foundation
import Testing
@testable import AnvilCore

@Suite("GeneratedImageStore")
struct GeneratedImageStoreTests {
    private func tempStoreFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-image-tests-\(UUID().uuidString)")
            .appendingPathComponent("registry.json")
    }

    private func makeDummyFile() -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-image-\(UUID().uuidString).png")
        FileManager.default.createFile(atPath: path.path, contents: Data([0x89, 0x50, 0x4E, 0x47]))
        return path.path
    }

    @Test
    func addThenAllRoundTrips() async throws {
        let store = GeneratedImageStore(fileURL: tempStoreFile())
        let image = GeneratedImage(
            prompt: "a red apple", modelDisplayName: "schnell",
            localPath: makeDummyFile(), width: 512, height: 512, seed: 42
        )

        let saved = try await store.add(image)
        let all = await store.all()

        #expect(all.map(\.id) == [saved.id])
        #expect(all.first?.prompt == "a red apple")
    }

    @Test
    func deleteRemovesTheEntryAndTheFile() async throws {
        let store = GeneratedImageStore(fileURL: tempStoreFile())
        let path = makeDummyFile()
        let saved = try await store.add(GeneratedImage(
            prompt: "test", modelDisplayName: "schnell", localPath: path, width: 64, height: 64, seed: 1
        ))

        try await store.delete(id: saved.id)

        #expect(await store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func allSortsNewestFirst() async throws {
        let store = GeneratedImageStore(fileURL: tempStoreFile())
        let older = try await store.add(GeneratedImage(
            prompt: "older", modelDisplayName: "schnell", localPath: makeDummyFile(),
            width: 64, height: 64, seed: 1, createdAt: Date(timeIntervalSince1970: 100)
        ))
        let newer = try await store.add(GeneratedImage(
            prompt: "newer", modelDisplayName: "schnell", localPath: makeDummyFile(),
            width: 64, height: 64, seed: 2, createdAt: Date(timeIntervalSince1970: 200)
        ))

        let all = await store.all()

        #expect(all.map(\.id) == [newer.id, older.id])
    }

    @Test
    func aFreshImageBecomesItsOwnSingletonLineage() async throws {
        let store = GeneratedImageStore(fileURL: tempStoreFile())
        let saved = try await store.add(GeneratedImage(
            prompt: "a cat", modelDisplayName: "schnell", localPath: makeDummyFile(),
            width: 512, height: 512, seed: 1
        ))

        #expect(saved.lineageID == saved.id)
        #expect(saved.versionNumber == 1)
        #expect(await store.versions(ofLineage: saved.lineageID).map(\.id) == [saved.id])
    }

    @Test
    func continuingALineageKeepsAllVersionsTogetherOldestFirst() async throws {
        let store = GeneratedImageStore(fileURL: tempStoreFile())
        let v1 = try await store.add(GeneratedImage(
            prompt: "a cat, blue fur", modelDisplayName: "schnell", localPath: makeDummyFile(),
            width: 512, height: 512, seed: 1
        ))
        let nextVersion = await store.nextVersionNumber(forLineage: v1.lineageID)
        #expect(nextVersion == 2)
        let v2 = try await store.add(GeneratedImage(
            lineageID: v1.lineageID, versionNumber: nextVersion,
            prompt: "a cat, blue fur, different model", modelDisplayName: "dev",
            localPath: makeDummyFile(), width: 512, height: 512, seed: 2
        ))

        let versions = await store.versions(ofLineage: v1.lineageID)

        #expect(versions.map(\.id) == [v1.id, v2.id])
        #expect(versions.map(\.versionNumber) == [1, 2])
    }

    @Test
    func latestPerLineageShowsOneTilePerLineageEvenWithMultipleVersions() async throws {
        let store = GeneratedImageStore(fileURL: tempStoreFile())
        let v1 = try await store.add(GeneratedImage(
            prompt: "a dog", modelDisplayName: "schnell", localPath: makeDummyFile(),
            width: 512, height: 512, seed: 1
        ))
        let v2 = try await store.add(GeneratedImage(
            lineageID: v1.lineageID, versionNumber: 2,
            prompt: "a dog, wearing a hat", modelDisplayName: "dev",
            localPath: makeDummyFile(), width: 512, height: 512, seed: 2
        ))
        _ = try await store.add(GeneratedImage(
            prompt: "a separate image", modelDisplayName: "schnell", localPath: makeDummyFile(),
            width: 512, height: 512, seed: 3
        ))

        let latest = await store.latestPerLineage()

        #expect(latest.count == 2)
        #expect(latest.contains { $0.id == v2.id })
        #expect(!latest.contains { $0.id == v1.id })
    }

    @Test
    func anImageSavedBeforeLineagesExistedDecodesAsItsOwnSingletonLineage() throws {
        let id = UUID()
        let json = """
        {
            "id": "\(id.uuidString)",
            "prompt": "an old image",
            "modelDisplayName": "schnell",
            "localPath": "/tmp/old.png",
            "width": 512,
            "height": 512,
            "seed": 7,
            "createdAt": "2026-01-01T00:00:00.000Z"
        }
        """
        let decoded = try JSONDecoder.anvil.decode(GeneratedImage.self, from: Data(json.utf8))

        #expect(decoded.lineageID == id)
        #expect(decoded.versionNumber == 1)
    }
}
