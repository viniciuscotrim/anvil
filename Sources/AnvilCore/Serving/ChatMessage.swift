import Foundation

/// A single turn in a conversation, fully persisted (not just the wire
/// fields) — which model answered, its reasoning/thinking text if any,
/// and measured tokens/sec, so the UI can show them long after the
/// request that produced them.
public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let id: UUID
    public var role: Role
    public var content: String
    /// A reasoning/"thinking" model's separate chain-of-thought text,
    /// if the server sent one. Independent of `content` so the UI can
    /// show/hide it without losing the actual answer.
    public var reasoning: String?
    /// Which loaded model produced this reply — nil for user messages.
    public var modelDisplayName: String?
    public var tokensPerSecond: Double?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoning: String? = nil,
        modelDisplayName: String? = nil,
        tokensPerSecond: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.modelDisplayName = modelDisplayName
        self.tokensPerSecond = tokensPerSecond
        self.createdAt = createdAt
    }
}
