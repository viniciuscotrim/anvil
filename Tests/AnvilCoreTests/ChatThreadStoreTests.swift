import Foundation
import Testing
@testable import AnvilCore

@Suite("ChatThread")
struct ChatThreadTests {
    @Test
    func previewShowsTheFirstUserMessage() {
        let thread = ChatThread(messages: [
            ChatMessage(role: .assistant, content: "Hi, how can I help?"),
            ChatMessage(role: .user, content: "What's the capital of France?")
        ])

        #expect(thread.preview == "What's the capital of France?")
    }

    @Test
    func previewReportsEmptyForAThreadWithNoMessages() {
        #expect(ChatThread(messages: []).preview == "Empty conversation")
    }
}

@Suite("ChatThreadStore")
struct ChatThreadStoreTests {
    private func tempStoreFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-thread-tests-\(UUID().uuidString)")
            .appendingPathComponent("threads.json")
    }

    @Test
    func upsertThenAllRoundTrips() async throws {
        let store = ChatThreadStore(fileURL: tempStoreFile())
        let thread = ChatThread(title: "Test", messages: [ChatMessage(role: .user, content: "hi")])

        let saved = try await store.upsert(thread)
        let all = await store.all()

        #expect(all.map(\.id) == [saved.id])
        #expect(all.first?.title == "Test")
    }

    @Test
    func deleteRemovesTheThread() async throws {
        let store = ChatThreadStore(fileURL: tempStoreFile())
        let thread = try await store.upsert(ChatThread(title: "Test"))

        try await store.delete(id: thread.id)

        #expect(await store.all().isEmpty)
        #expect(await store.get(id: thread.id) == nil)
    }

    @Test
    func allSortsByMostRecentlyUpdatedFirst() async throws {
        // upsert stamps `updatedAt` with the current time on every save
        // (so editing a thread always bumps it to the top), so ordering
        // here comes from call order, not a value passed in.
        let store = ChatThreadStore(fileURL: tempStoreFile())
        _ = try await store.upsert(ChatThread(title: "Older"))
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try await store.upsert(ChatThread(title: "Newer"))

        let all = await store.all()

        #expect(all.map(\.title) == ["Newer", "Older"])
    }

    @Test
    func persistsAcrossSeparateStoreInstances() async throws {
        let fileURL = tempStoreFile()
        let thread = ChatThread(
            title: "Persisted",
            messages: [ChatMessage(role: .user, content: "hi", createdAt: Date(timeIntervalSince1970: 1_700_000_000))]
        )

        let saved = try await ChatThreadStore(fileURL: fileURL).upsert(thread)
        let reopened = await ChatThreadStore(fileURL: fileURL).get(id: saved.id)

        #expect(reopened?.title == "Persisted")
        #expect(reopened?.messages == saved.messages)
    }
}
