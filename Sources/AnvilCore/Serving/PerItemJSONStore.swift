import Foundation

/// Records which ids were deleted, and when — shared by every store that
/// needs a periodic union-style sync merge to tell "genuinely never
/// existed on the other side yet" apart from "existed, but was deleted
/// since" (otherwise a merge just resurrects a deliberate delete the
/// next time it runs). Extracted from what `ChatThreadStore`,
/// `ChatMemoryStore`, `ChatMemorySuggestionStore`, and `ChatProfileStore`
/// each used to implement identically.
actor TombstoneLog {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(_ id: UUID) throws {
        var tombstones = load()
        tombstones[id] = Date()
        try persist(tombstones)
    }

    func all() -> [UUID: Date] {
        load()
    }

    private func load() -> [UUID: Date] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder.anvil.decode([UUID: Date].self, from: data)) ?? [:]
    }

    private func persist(_ tombstones: [UUID: Date]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(tombstones)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Generic actor-backed storage for a collection of `Codable`,
/// `Identifiable` (by `UUID`) items — one JSON file per item under a
/// directory, migrated automatically and idempotently from a legacy
/// single-file whole-array JSON blob the first time a store touches a
/// directory that doesn't exist yet.
///
/// This replaced one-big-file storage for `ChatThreadStore`,
/// `ChatMemoryStore`, and `ChatMemorySuggestionStore`: with a single
/// array in one file, saving *any one* item meant re-encoding and
/// rewriting *every* item's full content, growing without bound since
/// Context Shift stopped ever compacting history (v0.24.0). A per-item
/// file makes a single write's cost proportional to that one item.
///
/// Always re-reads from disk rather than caching in memory — the same
/// reasoning as before this change: multiple long-lived instances (e.g.
/// `ChatViewModel` and `AnvilSyncServer`, each holding their own) must
/// see each other's writes without either restarting.
actor PerItemJSONStore<Item: Codable & Sendable> {
    private let legacyFileURL: URL
    private let directoryURL: URL
    private let idOf: @Sendable (Item) -> UUID
    private var didEnsureMigration = false

    init(legacyFileURL: URL, idOf: @escaping @Sendable (Item) -> UUID) {
        self.legacyFileURL = legacyFileURL
        self.directoryURL = legacyFileURL.deletingPathExtension()
        self.idOf = idOf
    }

    func all() -> [Item] {
        ensureMigrated()
        return loadAll()
    }

    func get(id: UUID) -> Item? {
        ensureMigrated()
        return load(id: id)
    }

    @discardableResult
    func store(_ item: Item) throws -> Item {
        ensureMigrated()
        try ensureDirectoryExists()
        let data = try JSONEncoder.anvil.encode(item)
        try data.write(to: fileURL(for: idOf(item)), options: .atomic)
        return item
    }

    func delete(id: UUID) throws {
        ensureMigrated()
        try ensureDirectoryExists()
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func ensureDirectoryExists() throws {
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }

    private func load(id: UUID) -> Item? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? JSONDecoder.anvil.decode(Item.self, from: data)
    }

    private func loadAll() -> [Item] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path) else { return [] }
        return names.compactMap { name -> Item? in
            guard name.hasSuffix(".json"),
                  let data = try? Data(contentsOf: directoryURL.appendingPathComponent(name)) else { return nil }
            return try? JSONDecoder.anvil.decode(Item.self, from: data)
        }
    }

    /// One-time, idempotent migration from the old single-file format.
    /// Safe to call from multiple already-loaded instances racing at
    /// app launch: each checks the directory's existence before
    /// touching anything, and a legacy file already renamed by another
    /// instance by the time this one gets to it is simply ignored —
    /// the migration itself, not this guard, is what actually matters
    /// for correctness.
    private func ensureMigrated() {
        guard !didEnsureMigration else { return }
        didEnsureMigration = true
        guard !FileManager.default.fileExists(atPath: directoryURL.path) else { return }
        guard let data = try? Data(contentsOf: legacyFileURL),
              let items = try? JSONDecoder.anvil.decode([Item].self, from: data) else { return }
        guard (try? ensureDirectoryExists()) != nil else { return }
        for item in items {
            guard let encoded = try? JSONEncoder.anvil.encode(item) else { continue }
            try? encoded.write(to: fileURL(for: idOf(item)), options: .atomic)
        }
        // Kept as a backup rather than deleted — if the migration above
        // missed something, the original data is still on disk to
        // recover from by hand.
        let backupName = legacyFileURL.lastPathComponent + ".pre-migration"
        try? FileManager.default.moveItem(
            at: legacyFileURL,
            to: legacyFileURL.deletingLastPathComponent().appendingPathComponent(backupName)
        )
    }
}
