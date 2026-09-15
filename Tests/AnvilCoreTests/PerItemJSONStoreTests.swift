import Foundation
import Testing
@testable import AnvilCore

/// `ChatMemoryStore`/`ChatMemorySuggestionStore` had no dedicated
/// persistence tests before this file — `ChatMemoryTests.swift` only
/// covers the `ChatMemory` struct's own encoding, never the store that
/// saves it. Added alongside the move to `PerItemJSONStore` (one file
/// per item instead of one big array) specifically to pin down the
/// migration from the old format, since that's the one part of this
/// change with real user data on the line.
@Suite("ChatMemoryStore")
struct ChatMemoryStoreTests {
    private func tempStoreFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-memory-tests-\(UUID().uuidString)")
            .appendingPathComponent("memories.json")
    }

    @Test
    func upsertThenAllRoundTrips() async throws {
        let store = ChatMemoryStore(fileURL: tempStoreFile())
        let memory = ChatMemory(content: "Prefers concise answers")

        let saved = try await store.upsert(memory)
        let all = await store.all()

        #expect(all.map(\.id) == [saved.id])
        #expect(all.first?.content == "Prefers concise answers")
    }

    @Test
    func deleteRemovesTheMemoryAndRecordsATombstone() async throws {
        let store = ChatMemoryStore(fileURL: tempStoreFile())
        let memory = try await store.upsert(ChatMemory(content: "Temporary"))

        try await store.delete(id: memory.id)

        #expect(await store.all().isEmpty)
        #expect(await store.deletionTimestamps()[memory.id] != nil)
    }

    @Test
    func aWriteThroughOneInstanceIsVisibleToAnotherAlreadyLoadedInstance() async throws {
        let fileURL = tempStoreFile()
        let writer = ChatMemoryStore(fileURL: fileURL)
        let reader = ChatMemoryStore(fileURL: fileURL)
        _ = await writer.all()
        _ = await reader.all()

        let saved = try await writer.upsert(ChatMemory(content: "From writer"))

        #expect(await reader.all().map(\.id) == [saved.id])
    }

    /// Same migration guarantee as `ChatThreadStoreTests
    /// .migratesFromTheOldSingleFileFormatWithoutLosingAnything` — a
    /// pre-existing `memories.json` written in the old all-in-one-array
    /// shape (simulating an install from before this change) must still
    /// read back completely through the new per-file store.
    @Test
    func migratesFromTheOldSingleFileFormatWithoutLosingAnything() async throws {
        let fileURL = tempStoreFile()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let legacyMemories = [
            ChatMemory(content: "First memory"),
            ChatMemory(content: "Second memory")
        ]
        try JSONEncoder.anvil.encode(legacyMemories).write(to: fileURL)

        let store = ChatMemoryStore(fileURL: fileURL)
        let all = await store.all()

        #expect(Set(all.map(\.content)) == Set(["First memory", "Second memory"]))
        #expect(FileManager.default.fileExists(
            atPath: fileURL.deletingLastPathComponent().appendingPathComponent("memories.json.pre-migration").path
        ))
    }
}

@Suite("ChatMemorySuggestionStore")
struct ChatMemorySuggestionStoreTests {
    private func tempStoreFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-suggestion-tests-\(UUID().uuidString)")
            .appendingPathComponent("memory_suggestions.json")
    }

    @Test
    func upsertThenAllRoundTrips() async throws {
        let store = ChatMemorySuggestionStore(fileURL: tempStoreFile())
        let suggestion = ChatMemorySuggestion(
            content: "Likes dark mode", kind: .preference, confidence: 0.9, rationale: "Mentioned directly"
        )

        let saved = try await store.upsert(suggestion)
        let all = await store.all()

        #expect(all.map(\.id) == [saved.id])
    }

    @Test
    func deleteRemovesTheSuggestionAndRecordsATombstone() async throws {
        let store = ChatMemorySuggestionStore(fileURL: tempStoreFile())
        let suggestion = try await store.upsert(
            ChatMemorySuggestion(content: "Temp", kind: .fact, confidence: 0.5, rationale: "r")
        )

        try await store.delete(id: suggestion.id)

        #expect(await store.all().isEmpty)
        #expect(await store.deletionTimestamps()[suggestion.id] != nil)
    }

    @Test
    func migratesFromTheOldSingleFileFormatWithoutLosingAnything() async throws {
        let fileURL = tempStoreFile()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let legacySuggestions = [
            ChatMemorySuggestion(content: "First", kind: .fact, confidence: 0.8, rationale: "a"),
            ChatMemorySuggestion(content: "Second", kind: .preference, confidence: 0.6, rationale: "b")
        ]
        try JSONEncoder.anvil.encode(legacySuggestions).write(to: fileURL)

        let store = ChatMemorySuggestionStore(fileURL: fileURL)
        let all = await store.all()

        #expect(Set(all.map(\.content)) == Set(["First", "Second"]))
    }
}
