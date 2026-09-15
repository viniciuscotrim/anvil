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

    /// A real, reproduced bug this guards against: `ChatViewModel` and
    /// `AnvilSyncServer` each hold their own long-lived `ChatThreadStore`
    /// instance pointed at the same file. The old implementation loaded
    /// the file once and cached it in memory forever, so a write made
    /// through one already-loaded instance was invisible to another
    /// already-loaded instance for the rest of the app session — an
    /// assistant reply the Mac had just saved through its own store
    /// never showed up in a `GET /threads` served from the sync
    /// server's separate, stale copy. This is the two-already-loaded-
    /// instances case `persistsAcrossSeparateStoreInstances` above
    /// doesn't cover (that one only re-opens a fresh instance *after*
    /// the write, which happened to work even with the old caching
    /// bug).
    @Test
    func aWriteThroughOneInstanceIsVisibleToAnotherAlreadyLoadedInstance() async throws {
        let fileURL = tempStoreFile()
        let writer = ChatThreadStore(fileURL: fileURL)
        let reader = ChatThreadStore(fileURL: fileURL)

        // Load both instances first — this is what used to poison the
        // cache; without it, the (bugged) lazy-load-once path would
        // coincidentally succeed just because `reader` hadn't cached
        // anything yet.
        _ = await writer.all()
        _ = await reader.all()

        let saved = try await writer.upsert(ChatThread(title: "From writer"))

        #expect(await reader.get(id: saved.id)?.title == "From writer")
        #expect(await reader.all().map(\.id) == [saved.id])
    }

    @Test
    func upsertStampsUpdatedAtToNowButPreservingVariantDoesNot() async throws {
        let store = ChatThreadStore(fileURL: tempStoreFile())
        let old = Date(timeIntervalSince1970: 1_700_000_000)

        let stamped = try await store.upsert(ChatThread(title: "A", updatedAt: old))
        #expect(stamped.updatedAt != old)

        let preserved = try await store.upsertPreservingTimestamp(ChatThread(title: "B", updatedAt: old))
        #expect(preserved.updatedAt == old)
    }

    /// The fix for "I delete a conversation and it comes back a few
    /// seconds later" (LAN sync's periodic merge is a plain union that
    /// can't otherwise tell "never existed on the other device" apart
    /// from "existed, but I just deleted it").
    @Test
    func deleteRecordsATombstone() async throws {
        let store = ChatThreadStore(fileURL: tempStoreFile())
        let thread = try await store.upsert(ChatThread(title: "Test"))

        try await store.delete(id: thread.id)

        #expect(await store.deletionTimestamps()[thread.id] != nil)
    }

    /// The store now keeps one file per thread instead of one big
    /// `threads.json`, migrated automatically the first time a store
    /// touches a directory that doesn't exist yet. This is the
    /// migration itself: a pre-existing legacy file, written in the old
    /// all-in-one-array shape by hand (simulating an install from
    /// before this change), must still read back byte-for-byte through
    /// the new store with nothing lost.
    @Test
    func migratesFromTheOldSingleFileFormatWithoutLosingAnything() async throws {
        let fileURL = tempStoreFile()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // `createdAt` is pinned to a whole second (not `Date()`'s default
        // sub-millisecond precision) so the equality check below isn't
        // comparing a pre-round-trip value against the ISO8601-with-
        // milliseconds precision `JSONEncoder.anvil` actually persists.
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let legacyThreads = [
            ChatThread(title: "First", messages: [ChatMessage(role: .user, content: "hi", createdAt: fixedDate)]),
            ChatThread(title: "Second", messages: [ChatMessage(role: .assistant, content: "hello", createdAt: fixedDate)])
        ]
        try JSONEncoder.anvil.encode(legacyThreads).write(to: fileURL)

        let store = ChatThreadStore(fileURL: fileURL)
        let all = await store.all()

        #expect(Set(all.map(\.title)) == Set(["First", "Second"]))
        for thread in legacyThreads {
            #expect(await store.get(id: thread.id)?.messages == thread.messages)
        }
        // The legacy file is kept as a backup, not deleted outright.
        #expect(FileManager.default.fileExists(
            atPath: fileURL.deletingLastPathComponent().appendingPathComponent("threads.json.pre-migration").path
        ))
    }
}
