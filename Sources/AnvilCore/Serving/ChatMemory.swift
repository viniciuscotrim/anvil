import Foundation

/// A durable fact or preference intentionally shared with future turns.
/// The store is local-only and independent from transcript history so a
/// long conversation can be compacted without losing important memory.
public struct ChatMemory: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var content: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        content: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public actor ChatMemoryStore {
    private let fileURL: URL

    public init(
        fileURL: URL = RuntimePaths.applicationSupportDirectory
            .appendingPathComponent("chats", isDirectory: true)
            .appendingPathComponent("memories.json")
    ) {
        self.fileURL = fileURL
    }

    public func all() -> [ChatMemory] {
        load().sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func upsert(_ memory: ChatMemory) throws -> ChatMemory {
        var memories = load()
        var updated = memory
        updated.updatedAt = Date()
        if let index = memories.firstIndex(where: { $0.id == memory.id }) {
            memories[index] = updated
        } else {
            memories.append(updated)
        }
        try persist(memories)
        return updated
    }

    public func delete(id: UUID) throws {
        var memories = load()
        memories.removeAll { $0.id == id }
        try persist(memories)
    }

    private func load() -> [ChatMemory] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.anvil.decode([ChatMemory].self, from: data)) ?? []
    }

    private func persist(_ memories: [ChatMemory]) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder.anvil.encode(memories)
        try data.write(to: fileURL, options: .atomic)
    }
}
