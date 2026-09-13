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
    /// Which device this thread was first created on (e.g. "Vinicius's
    /// MacBook Pro", "Vinicius's iPhone") — set once, at creation, never
    /// changed afterward even as later messages come from either device
    /// once Mac Sync merges it. Nil for a thread saved before this field
    /// existed, or if the creating platform didn't supply one. Purely
    /// informational — nothing here reads it to make a decision, it's
    /// only so the UI can show provenance instead of a two-way-synced
    /// list looking like everything came from nowhere in particular.
    public var originDeviceName: String?
    /// True once the user has explicitly renamed this thread — after
    /// that, nothing auto-generates its title anymore (not a profile
    /// change, not the old first-message-derived title). False (the
    /// default, including for threads saved before this field existed)
    /// means the title is still the auto-generated "Profile · created
    /// date" the UI keeps in sync with `profileID`.
    public var isTitleCustom: Bool

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        profileID: UUID? = nil,
        originDeviceName: String? = nil,
        isTitleCustom: Bool = false
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.profileID = profileID
        self.originDeviceName = originDeviceName
        self.isTitleCustom = isTitleCustom
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, createdAt, updatedAt, profileID, originDeviceName, isTitleCustom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID)
        originDeviceName = try container.decodeIfPresent(String.self, forKey: .originDeviceName)
        isTitleCustom = try container.decodeIfPresent(Bool.self, forKey: .isTitleCustom) ?? false
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
