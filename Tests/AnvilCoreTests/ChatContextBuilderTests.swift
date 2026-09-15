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

    /// The degenerate case call out in `build`'s own comment: no
    /// `.user` message anywhere (so there's no "first turn" to seed
    /// `selected`), and the recent window's own messages are too big
    /// to fit the budget either — `selected` is still completely empty
    /// by the time the "middle" block gets inserted. The single bulk
    /// `insert(contentsOf:at:)` must still produce correct chronological
    /// order here, which the old per-message `insert(at: min(1,
    /// selected.count))` loop this replaced did not (each successive
    /// insert at a growing `selected.count` scrambled the order once it
    /// passed 1) — a real fix, not just an equivalent-but-faster
    /// rewrite.
    @Test
    func middleMessagesLandInChronologicalOrderEvenWithNoFirstUserTurn() {
        // `ChatContextBuilder.init` clamps `maxEstimatedTokens` to at
        // least 512, so the budget below is exactly that floor, not a
        // custom small value.
        //
        // Indices 0-9: ~100 tokens each (1000 total — more than fits).
        // Indices 10-11 (the `recentMessageCount: 2` window): ~1000
        // tokens each — too big to fit the 512-token budget, so
        // `recent` contributes nothing to `selected` either.
        let smallMessages = (0..<10).map { _ in
            ChatMessage(role: .assistant, content: String(repeating: "x", count: 400))
        }
        let largeMessages = (0..<2).map { _ in
            ChatMessage(role: .assistant, content: String(repeating: "x", count: 4_000))
        }
        let messages = smallMessages + largeMessages

        let result = ChatContextBuilder(maxEstimatedTokens: 512, recentMessageCount: 2).build(messages: messages)

        // Budget 512 fits exactly 5 of the ~100-token small messages —
        // the five most recent ones *not* in the (too-expensive) recent
        // window, i.e. indices 5-9 — in ascending (chronological) order.
        #expect(result.messages.map(\.id) == (5...9).map { messages[$0].id })
    }

    /// Pins the exact ordering `build`'s "middle" (non-recent, non-first)
    /// selection produces once more than one of those messages fits the
    /// budget — a regression guard for the O(n) rewrite of what used to
    /// be a per-message `array.insert(at:)`: both must land on the same
    /// oldest-to-newest order between the first turn and the recent
    /// window, not just the same *set* of messages.
    @Test
    func middleMessagesLandInChronologicalOrderBetweenFirstTurnAndRecentWindow() {
        let messages = (0..<20).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: String(repeating: "x", count: 400))
        }
        // Each message costs 100 estimated tokens. Budget 900 fits the
        // first turn (100) + the 4-message recent window (400) + four
        // more middle messages (400) — exactly indices 12-15.
        let result = ChatContextBuilder(maxEstimatedTokens: 900, recentMessageCount: 4).build(messages: messages)

        let expectedIndices = [0, 12, 13, 14, 15, 16, 17, 18, 19]
        #expect(result.messages.map(\.id) == expectedIndices.map { messages[$0].id })
    }

    /// Regression test for the real gap `batches` exists to fix: a
    /// conversation long enough that `build(messages:)`'s own bounded
    /// window would drop its middle turns must still have *every*
    /// message show up somewhere across the batches — this is the
    /// "digest the whole thread before it grows unusable" tool, so
    /// silently losing the middle here would defeat the entire point.
    @Test
    func coversEveryMessageAcrossBatchesEvenWhenLongerThanOneContextWindow() {
        let messages = (0..<40).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: String(repeating: "x", count: 400))
        }
        // Each message estimates to 100 tokens (400 bytes / 4); a
        // budget of 250 fits at most 2 per batch, so this genuinely
        // needs several batches to cover all 40 — the same shape a
        // real long-running thread that outgrew live chat's own
        // context budget would have.
        let batches = ChatContextBuilder.batches(messages, maxEstimatedTokensPerBatch: 250)

        #expect(batches.count > 1)
        #expect(batches.flatMap { $0 }.map(\.id) == messages.map(\.id))
        for batch in batches {
            let total = batch.reduce(0) { $0 + ChatContextBuilder.estimateTokens($1.content) }
            #expect(total <= 250)
        }
    }

    /// `.system`/`.tool` messages are dropped — they're not meant for
    /// this kind of analysis (matches `ChatViewModel.visibleMessages`'
    /// own filtering) — while a single message alone bigger than the
    /// whole per-batch budget still becomes its own batch rather than
    /// vanishing or looping.
    @Test
    func dropsNonConversationalRolesAndKeepsAnOversizedMessageAsItsOwnBatch() {
        let huge = ChatMessage(role: .user, content: String(repeating: "x", count: 4_000))
        let messages: [ChatMessage] = [
            ChatMessage(role: .system, content: "system prompt"),
            huge,
            ChatMessage(role: .tool, content: "tool result", toolCallID: "call-1"),
            ChatMessage(role: .assistant, content: "ok"),
        ]

        let batches = ChatContextBuilder.batches(messages, maxEstimatedTokensPerBatch: 50)

        #expect(batches.flatMap { $0 }.map(\.role) == [.user, .assistant])
        #expect(batches.first?.first?.id == huge.id)
    }
}
