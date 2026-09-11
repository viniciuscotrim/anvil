import Foundation
import Testing
@testable import AnvilCore

@Suite("ChatMessage")
struct ChatMessageTests {
    @Test
    func encodesOnlyRoleAndContent() throws {
        let message = ChatMessage(role: .user, content: "hello")

        let data = try JSONEncoder().encode(message)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]

        #expect(object?.count == 2)
        #expect(object?["role"] == "user")
        #expect(object?["content"] == "hello")
    }

    @Test
    func encodesAnArrayOfMessagesInOrder() throws {
        let messages = [
            ChatMessage(role: .system, content: "You are helpful."),
            ChatMessage(role: .user, content: "Hi")
        ]

        let data = try JSONEncoder().encode(messages)
        let array = try JSONSerialization.jsonObject(with: data) as? [[String: String]]

        #expect(array?.count == 2)
        #expect(array?[0]["role"] == "system")
        #expect(array?[1]["role"] == "user")
    }
}

@Suite("ChatClient")
struct ChatClientTests {
    @Test
    func surfacesAConnectionFailureAsRequestFailed() async throws {
        // Nothing listens on this loopback port — a fast, deterministic
        // connection failure without needing a real server.
        let client = ChatClient()
        let unreachable = URL(string: "http://127.0.0.1:1")!

        await #expect(throws: ServingError.self) {
            _ = try await client.send(
                messages: [ChatMessage(role: .user, content: "hi")],
                baseURL: unreachable,
                model: "test-model"
            )
        }
    }
}
