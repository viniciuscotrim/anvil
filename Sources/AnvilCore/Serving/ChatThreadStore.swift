import Foundation

/// Persists chat threads to one JSON file — same pattern as
/// `ModelRegistry`. A temporary/incognito conversation never passes
/// through here; it's the caller's job to keep that one in memory only.
public actor ChatThreadStore {
    private let fileURL: URL
    private var threads: [ChatThread] = []
    private var loaded = false

    public init(
        fileURL: URL = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent("threads.json")
    ) {
        self.fileURL = fileURL
    }

    /// Newest-updated first.
    public func all() -> [ChatThread] {
        loadIfNeeded()
        return threads.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func get(id: UUID) -> ChatThread? {
        loadIfNeeded()
        return threads.first { $0.id == id }
    }

    @discardableResult
    public func upsert(_ thread: ChatThread) throws -> ChatThread {
        loadIfNeeded()
        var thread = thread
        thread.updatedAt = Date()
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            threads[index] = thread
        } else {
            threads.append(thread)
        }
        try persist()
        return thread
    }

    public func delete(id: UUID) throws {
        loadIfNeeded()
        threads.removeAll { $0.id == id }
        try persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        threads = (try? JSONDecoder.anvil.decode([ChatThread].self, from: data)) ?? []
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(threads)
        try data.write(to: fileURL, options: .atomic)
    }
}
