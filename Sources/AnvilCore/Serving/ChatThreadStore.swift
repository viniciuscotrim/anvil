import Foundation

/// Persists chat threads to one JSON file — same pattern as
/// `ModelRegistry`. A temporary/incognito conversation never passes
/// through here; it's the caller's job to keep that one in memory only.
///
/// Always re-reads the file rather than caching in memory across calls
/// — matching `ChatProfileStore`/`ChatMemoryStore`'s own (already
/// correct) pattern, which this type had drifted from. A real,
/// reproduced bug this fixes: `ChatViewModel` and `AnvilSyncServer` each
/// construct their own separate `ChatThreadStore` instance pointed at
/// the same file (confirmed — `AnvilSyncServer`'s `threadStore:`
/// parameter was never even passed the shared one). With the old
/// load-once-then-cache-forever design, whichever instance loaded first
/// simply never saw writes the OTHER instance made — so a reply the Mac
/// had just generated and saved through its own `ChatViewModel`-owned
/// store was invisible to `AnvilSyncServer`'s `GET /threads` (serving a
/// different, stale, long-cached copy to the iPhone), and a push
/// arriving from the iPhone via `PUT /threads` landed only in
/// `AnvilSyncServer`'s own cache, invisible to `ChatViewModel`'s. Two
/// in-memory forks of the same file, silently diverging for the entire
/// app session. Re-reading every time costs nothing that matters here
/// (small file, infrequent access) and removes this whole class of bug
/// outright, regardless of how many separate instances end up existing.
public actor ChatThreadStore {
    private let fileURL: URL

    public init(
        fileURL: URL = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent("threads.json")
    ) {
        self.fileURL = fileURL
    }

    /// Newest-updated first.
    public func all() -> [ChatThread] {
        load().sorted { $0.updatedAt > $1.updatedAt }
    }

    public func get(id: UUID) -> ChatThread? {
        load().first { $0.id == id }
    }

    /// Local-edit entry point — stamps `updatedAt` to now. Use
    /// `upsertPreservingTimestamp` instead when replicating a record
    /// that already carries a meaningful `updatedAt` from elsewhere
    /// (an incoming sync/merge write) — see that method's doc comment
    /// for the real bug stamping-on-every-write caused.
    @discardableResult
    public func upsert(_ thread: ChatThread) throws -> ChatThread {
        var thread = thread
        thread.updatedAt = Date()
        return try store(thread)
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
    public func upsertPreservingTimestamp(_ thread: ChatThread) throws -> ChatThread {
        try store(thread)
    }

    private func store(_ thread: ChatThread) throws -> ChatThread {
        var threads = load()
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[index] = thread
        } else {
            threads.append(thread)
        }
        try persist(threads)
        return thread
    }

    public func delete(id: UUID) throws {
        var threads = load()
        threads.removeAll { $0.id == id }
        try persist(threads)
        try recordDeletion(id: id)
    }

    /// IDs deleted here, with when — so a periodic union-style merge
    /// (LAN sync's `mergeThreads`) can tell "genuinely never existed on
    /// the other side yet" apart from "existed, but I deleted it since"
    /// instead of treating both as the same "missing" case and silently
    /// resurrecting a deliberate delete. See `ProfilesViewModel.mergeSync`
    /// on iOS for the same real bug reproduced with profiles, and the
    /// fix's write-up there for the full story.
    public func deletionTimestamps() -> [UUID: Date] {
        loadTombstones()
    }

    private var tombstoneFileURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("threads_deleted.json")
    }

    private func recordDeletion(id: UUID) throws {
        var tombstones = loadTombstones()
        tombstones[id] = Date()
        try persistTombstones(tombstones)
    }

    private func loadTombstones() -> [UUID: Date] {
        guard let data = try? Data(contentsOf: tombstoneFileURL) else { return [:] }
        return (try? JSONDecoder.anvil.decode([UUID: Date].self, from: data)) ?? [:]
    }

    private func persistTombstones(_ tombstones: [UUID: Date]) throws {
        let data = try JSONEncoder.anvil.encode(tombstones)
        try data.write(to: tombstoneFileURL, options: .atomic)
    }

    private func load() -> [ChatThread] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.anvil.decode([ChatThread].self, from: data)) ?? []
    }

    private func persist(_ threads: [ChatThread]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(threads)
        try data.write(to: fileURL, options: .atomic)
    }
}
