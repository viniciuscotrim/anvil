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
}
