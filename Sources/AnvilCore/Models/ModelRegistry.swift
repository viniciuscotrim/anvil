import Foundation

/// The single source of truth for "models this app knows about" — backed
/// by one JSON file so it's trivially inspectable (`cat registry.json`)
/// for gate verification, not just visible in the UI. An actor because
/// both the UI and any background download/import work touch it.
public actor ModelRegistry {
    private let fileURL: URL
    private var entries: [ModelEntry] = []
    private var loaded = false

    public init(fileURL: URL = RuntimePaths.modelsDirectory.appendingPathComponent("registry.json")) {
        self.fileURL = fileURL
    }

    public func all() async -> [ModelEntry] {
        loadIfNeeded()
        return entries.sorted { $0.addedAt < $1.addedAt }
    }

    public func contains(id: String) async -> Bool {
        loadIfNeeded()
        return entries.contains { $0.id == id }
    }

    @discardableResult
    public func upsert(_ entry: ModelEntry) throws -> ModelEntry {
        loadIfNeeded()
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        try persist()
        return entry
    }

    public func remove(id: String) throws {
        loadIfNeeded()
        entries.removeAll { $0.id == id }
        try persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        entries = (try? JSONDecoder.anvil.decode([ModelEntry].self, from: data)) ?? []
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}
