import Foundation

/// A durable fact or preference intentionally shared with future turns.
/// The store is local-only and independent from transcript history so a
/// long conversation can be compacted without losing important memory.
public enum ChatMemoryKind: String, Codable, CaseIterable, Sendable {
    case fact
    case preference
    case date
    case number
    case impression

    public var label: String {
        switch self {
        case .fact: return "Fact"
        case .preference: return "Preference"
        case .date: return "Date"
        case .number: return "Number"
        case .impression: return "Impression"
        }
    }
}

public enum ChatMemorySource: String, Codable, CaseIterable, Sendable {
    case explicit
    case inferred

    public var label: String {
        switch self {
        case .explicit: return "You told Anvil"
        case .inferred: return "Inferred"
        }
    }
}

public struct ChatMemory: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var content: String
    public var kind: ChatMemoryKind
    public var source: ChatMemorySource
    public var confidence: Double?
    public var profileID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        content: String,
        kind: ChatMemoryKind = .fact,
        source: ChatMemorySource = .explicit,
        confidence: Double? = nil,
        profileID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.kind = kind
        self.source = source
        self.confidence = confidence
        self.profileID = profileID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, content, kind, source, confidence, profileID, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)
        kind = try container.decodeIfPresent(ChatMemoryKind.self, forKey: .kind) ?? .fact
        source = try container.decodeIfPresent(ChatMemorySource.self, forKey: .source) ?? .explicit
        confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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
