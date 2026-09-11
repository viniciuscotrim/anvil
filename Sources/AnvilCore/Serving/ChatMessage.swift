import Foundation

/// A single turn in a conversation, fully persisted (not just the wire
/// fields) — which model answered, its reasoning/thinking text if any,
/// measured tokens/sec, and any tool-call round trip involved, so the
/// UI can show them long after the request that produced them.
public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    /// One `generate_image`-style call the model asked for — captured
    /// on the assistant message that requested it so the exact request
    /// (including its arguments) can be replayed back to the server
    /// alongside the tool's result.
    public struct ToolCall: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// Raw JSON string, as the wire format carries it — parsed on
        /// demand rather than eagerly, since today only one tool exists.
        public let argumentsJSON: String

        public init(id: String, name: String, argumentsJSON: String) {
            self.id = id
            self.name = name
            self.argumentsJSON = argumentsJSON
        }
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
    /// Set on an assistant message that asked to call a tool.
    public var toolCalls: [ToolCall]?
    /// Set on a `.tool`-role message: which call this is the result of.
    public var toolCallID: String?
    /// Set on the assistant's follow-up message once a `generate_image`
    /// tool call resolved — the UI renders this inline in the bubble.
    public var generatedImagePath: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoning: String? = nil,
        modelDisplayName: String? = nil,
        tokensPerSecond: Double? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallID: String? = nil,
        generatedImagePath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.modelDisplayName = modelDisplayName
        self.tokensPerSecond = tokensPerSecond
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.generatedImagePath = generatedImagePath
        self.createdAt = createdAt
    }
}
