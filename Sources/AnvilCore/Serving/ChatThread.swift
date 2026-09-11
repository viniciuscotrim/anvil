import Foundation

/// A saved conversation. Messages can span more than one model — the
/// thread itself doesn't pin one; each message already records which
/// model answered it (`ChatMessage.modelDisplayName`), so switching
/// which model you're talking to mid-thread only affects new messages.
public struct ChatThread: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var createdAt: Date
    public var updatedAt: Date
    /// Which `ChatProfile` shapes this thread's system prompt, if any.
    /// Only meaningful to change while `messages` is still empty — once
    /// the model has answered under a given profile, switching it would
    /// contaminate how the conversation reads without actually changing
    /// any of the history already generated under the old one. The UI
    /// enforces that; this type doesn't.
    public var profileID: UUID?

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        profileID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.profileID = profileID
    }

    /// A short preview for a threads list — the first user message, or
    /// a placeholder for an empty thread.
    public var preview: String {
        guard let firstUserMessage = messages.first(where: { $0.role == .user }) else {
            return "Empty conversation"
        }
        let oneLine = firstUserMessage.content.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
    }
}
