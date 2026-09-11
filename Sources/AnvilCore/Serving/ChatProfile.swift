import Foundation

/// A reusable system prompt — oMLX called this a "persona" — that shapes
/// how a loaded model responds. Optionally claimed as the default for
/// one specific registered model: once that model is loaded, selecting
/// it for a still-empty thread (new or existing) applies this profile
/// automatically, the same way oMLX's per-model persona binding worked.
public struct ChatProfile: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var prompt: String
    /// The registered model's `ModelEntry.id` this profile applies to
    /// by default, if any. At most one profile claims a given model —
    /// `ChatProfileStore.upsert` releases it from any previous holder.
    public var defaultForModelID: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        defaultForModelID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.defaultForModelID = defaultForModelID
        self.createdAt = createdAt
    }
}
