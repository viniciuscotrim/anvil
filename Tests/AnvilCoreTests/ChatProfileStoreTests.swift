import Foundation
import Testing
@testable import AnvilCore

@Suite("ChatProfileStore")
struct ChatProfileStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-profile-tests-\(UUID().uuidString)")
            .appendingPathComponent("profiles.json")
    }

    @Test
    func upsertThenAllRoundTrips() async throws {
        let store = ChatProfileStore(fileURL: tempFile())
        let profile = ChatProfile(name: "Sofia", prompt: "You are Sofia, warm and concise.")

        _ = try await store.upsert(profile)
        let all = await store.all()

        #expect(all.map(\.id) == [profile.id])
        #expect(all.first?.name == "Sofia")
    }

    @Test
    func atMostOneProfileHoldsAGivenModelDefault() async throws {
        let store = ChatProfileStore(fileURL: tempFile())
        let first = ChatProfile(name: "First", prompt: "a", defaultForModelID: "model-x")
        _ = try await store.upsert(first)

        let second = ChatProfile(name: "Second", prompt: "b", defaultForModelID: "model-x")
        _ = try await store.upsert(second)

        let all = await store.all()
        let firstReloaded = all.first { $0.id == first.id }
        let secondReloaded = all.first { $0.id == second.id }

        // Claiming the model for `second` releases it from `first` —
        // never two profiles claiming the same model at once.
        #expect(firstReloaded?.defaultForModelID == nil)
        #expect(secondReloaded?.defaultForModelID == "model-x")
        #expect(await store.defaultProfile(forModelID: "model-x")?.id == second.id)
    }

    @Test
    func deleteRemovesTheProfile() async throws {
        let store = ChatProfileStore(fileURL: tempFile())
        let profile = ChatProfile(name: "Temp", prompt: "x")
        _ = try await store.upsert(profile)

        try await store.delete(id: profile.id)

        let all = await store.all()
        #expect(all.isEmpty)
    }

    @Test
    func independentInstancesPointingAtTheSameFileSeeEachOthersWrites() async throws {
        // A real regression this guards: `ModelRegistry` used to cache
        // its contents in memory forever after first load, so a second
        // instance pointed at the same file never saw writes made
        // through the first — `ChatProfileStore` follows the same
        // always-re-read pattern for the same reason (`ChatViewModel`
        // and the Profiles screen each hold their own instance).
        let url = tempFile()
        let writer = ChatProfileStore(fileURL: url)
        let reader = ChatProfileStore(fileURL: url)

        _ = try await writer.upsert(ChatProfile(name: "Written elsewhere", prompt: "p"))

        let seenByReader = await reader.all()
        #expect(seenByReader.count == 1)
        #expect(seenByReader.first?.name == "Written elsewhere")
    }
}
