import Foundation

public struct ChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let id: UUID
    public var role: Role
    public var content: String

    public init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

// Wire format only needs role/content — `id` is a local UI concern, so
// this is Encodable-only rather than full Codable.
extension ChatMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case role
        case content
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
    }
}
