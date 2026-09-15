import Foundation

/// Persists chat threads — see `PerItemJSONStore`'s doc comment for the
/// on-disk shape and why it replaced one JSON file holding every
/// thread's entire message history.
public actor ChatThreadStore {
    private let storage: PerItemJSONStore<ChatThread>
    private let tombstones: TombstoneLog

    public init(
        fileURL: URL = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent("threads.json")
    ) {
        storage = PerItemJSONStore(legacyFileURL: fileURL, idOf: \.id)
        tombstones = TombstoneLog(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("threads_deleted.json")
        )
    }

    /// Newest-updated first.
    public func all() async -> [ChatThread] {
        await storage.all().sorted { $0.updatedAt > $1.updatedAt }
    }

    public func get(id: UUID) async -> ChatThread? {
        await storage.get(id: id)
    }

    /// Local-edit entry point — stamps `updatedAt` to now. Use
    /// `upsertPreservingTimestamp` instead when replicating a record
    /// that already carries a meaningful `updatedAt` from elsewhere
    /// (an incoming sync/merge write) — see that method's doc comment
    /// for the real bug stamping-on-every-write caused.
    @discardableResult
    public func upsert(_ thread: ChatThread) async throws -> ChatThread {
        var thread = thread
        thread.updatedAt = Date()
        return try await storage.store(thread)
    }

    /// Sync/merge entry point — keeps the caller-supplied `updatedAt`
    /// exactly as given, instead of stamping "now". A real, reproduced
    /// bug this fixes: every sync path (LAN `AnvilSyncServer`/
    /// `AnvilSyncClient`, `CloudSyncEngine`) ultimately called the same
    /// `upsert` local edits use, which unconditionally overwrote
    /// `updatedAt` with the CURRENT device's clock at the moment of
    /// replication. That breaks the "last-write-wins by `updatedAt`"
    /// rule every merge/conflict check in this app depends on — a
    /// stale copy that merely got *replicated* later looks newer than
    /// content that was genuinely edited earlier, letting it win a
    /// future comparison and silently clobber real, newer content
    /// (reproduced: an assistant reply mid-generation on the Mac,
    /// permanently overwritten back to just the user's message by a
    /// phone's periodic re-sync of its own stale copy, because that
    /// copy kept getting re-stamped "now" on every hop).
    @discardableResult
    public func upsertPreservingTimestamp(_ thread: ChatThread) async throws -> ChatThread {
        try await storage.store(thread)
    }

    public func delete(id: UUID) async throws {
        try await storage.delete(id: id)
        try await tombstones.record(id)
    }

    /// IDs deleted here, with when — so a periodic union-style merge
    /// (LAN sync's `mergeThreads`) can tell "genuinely never existed on
    /// the other side yet" apart from "existed, but I deleted it since"
    /// instead of treating both as the same "missing" case and silently
    /// resurrecting a deliberate delete. See `ProfilesViewModel.mergeSync`
    /// on iOS for the same real bug reproduced with profiles, and the
    /// fix's write-up there for the full story.
    public func deletionTimestamps() async -> [UUID: Date] {
        await tombstones.all()
    }
}
