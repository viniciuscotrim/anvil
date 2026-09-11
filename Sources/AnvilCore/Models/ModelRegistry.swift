import Foundation

/// The single source of truth for "models this app knows about" — backed
/// by one JSON file so it's trivially inspectable (`cat registry.json`)
/// for gate verification, not just visible in the UI. An actor because
/// both the UI and any background download/import work touch it.
///
/// Always re-reads the file rather than trusting an in-memory cache —
/// more than one `ModelRegistry` instance can exist at once (the model
/// manager and chat each hold their own), and a stale cache in one
/// would mean it never sees a model downloaded/imported through the
/// other, and — worse — a write from a stale instance could silently
/// drop entries the other one had already saved. The file is tiny and
/// reads are infrequent, so the cost of always re-reading is negligible
/// next to that correctness gap.
public actor ModelRegistry {
    private let fileURL: URL

    public init(fileURL: URL = RuntimePaths.modelsDirectory.appendingPathComponent("registry.json")) {
        self.fileURL = fileURL
    }

    public func all() async -> [ModelEntry] {
        load().sorted { $0.addedAt < $1.addedAt }
    }

    public func contains(id: String) async -> Bool {
        load().contains { $0.id == id }
    }

    @discardableResult
    public func upsert(_ entry: ModelEntry) throws -> ModelEntry {
        var entries = load()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        try persist(entries)
        return entry
    }

    public func remove(id: String) throws {
        var entries = load()
        entries.removeAll { $0.id == id }
        try persist(entries)
    }

    private func load() -> [ModelEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.anvil.decode([ModelEntry].self, from: data)) ?? []
    }

    private func persist(_ entries: [ModelEntry]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
