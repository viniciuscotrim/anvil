import Foundation
import Testing
@testable import AnvilCore

@Suite("TranscriptFormatter")
struct TranscriptFormatterTests {
    @Test
    func rendersHeadingAndEachTurnInOrder() {
        let messages = [
            ChatMessage(role: .user, content: "Hi there"),
            ChatMessage(role: .assistant, content: "Hello! How can I help?")
        ]

        let markdown = TranscriptFormatter.markdown(
            modelName: "SmolLM2-135M-Instruct-8bit",
            messages: messages,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(markdown.hasPrefix("# Conversation with SmolLM2-135M-Instruct-8bit"))
        #expect(markdown.contains("**You:**"))
        #expect(markdown.contains("Hi there"))
        #expect(markdown.contains("**Assistant:**"))
        #expect(markdown.contains("Hello! How can I help?"))

        // "You" turn must precede "Assistant" turn — order preserved.
        let youRange = markdown.range(of: "**You:**")!
        let assistantRange = markdown.range(of: "**Assistant:**")!
        #expect(youRange.lowerBound < assistantRange.lowerBound)
    }

    @Test
    func handlesAnEmptyConversation() {
        let markdown = TranscriptFormatter.markdown(modelName: "test-model", messages: [])

        #expect(markdown.hasPrefix("# Conversation with test-model"))
        #expect(!markdown.contains("**You:**"))
    }
}
