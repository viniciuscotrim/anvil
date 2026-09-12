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
    /// Which device this profile was created on — see
    /// `ChatThread.originDeviceName`'s doc comment for the same purpose
    /// and the same "set once, purely informational" contract. This is
    /// what lets the UI show "1 profile from your Mac, 1 from your
    /// iPhone" instead of a merged list with no indication either ever
    /// existed as two separate things.
    public var originDeviceName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        defaultForModelID: String? = nil,
        createdAt: Date = Date(),
        originDeviceName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.defaultForModelID = defaultForModelID
        self.createdAt = createdAt
        self.originDeviceName = originDeviceName
    }
}
