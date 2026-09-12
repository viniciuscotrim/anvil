import Testing
@testable import AnvilCore

@Suite("ChatContextBuilder")
struct ChatContextBuilderTests {
    @Test
    func injectsDurableMemoriesSeparatelyFromTranscript() {
        let memory = ChatMemory(content: "The user prefers concise answers.")
        let result = ChatContextBuilder(maxEstimatedTokens: 2_000).build(
            messages: [ChatMessage(role: .user, content: "Hello")],
            memories: [memory]
        )

        #expect(result.messages.count == 1)
        #expect(result.memoryPrompt?.contains("concise answers") == true)
    }

    @Test
    func keepsFirstUserTurnAndRecentMessagesUnderBound() {
        let messages = (0..<20).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: String(repeating: "x", count: 400))
        }
        let result = ChatContextBuilder(maxEstimatedTokens: 600, recentMessageCount: 4).build(messages: messages)

        #expect(result.messages.first?.id == messages.first?.id)
        #expect(result.messages.suffix(4).map(\.id) == messages.suffix(4).map(\.id))
        #expect(result.messages.count < messages.count)
    }
}
