import Testing
@testable import AnvilCore

@Suite("ReasoningStreamSplitter")
struct ReasoningStreamSplitterTests {
    @Test
    func plainTextWithNoThinkTagIsAllContent() {
        var splitter = ReasoningStreamSplitter()
        let deltas = splitter.process("Just a normal answer, no thinking at all.")
        #expect(deltas == [.content("Just a normal answer, no thinking at all.")])
        #expect(splitter.finish().isEmpty)
    }

    @Test
    func splitsReasoningFromContentWithinOneChunk() {
        var splitter = ReasoningStreamSplitter()
        let deltas = splitter.process("<think>working it out</think>The answer is 4.")
        #expect(deltas == [.reasoning("working it out"), .content("The answer is 4.")])
    }

    @Test
    func handlesTheOpeningTagArrivingAcrossMultipleChunks() {
        var splitter = ReasoningStreamSplitter()
        var all: [ReasoningStreamSplitter.Delta] = []
        for chunk in ["<th", "ink>", "reasoning here", "</think>", "final answer"] {
            all += splitter.process(chunk)
        }
        #expect(all == [.reasoning("reasoning here"), .content("final answer")])
    }

    @Test
    func handlesTheOpeningTagSplitAtEveryPossibleByteBoundary() {
        let full = "<think>hello</think>world"
        for splitPoint in 1..<full.count {
            var splitter = ReasoningStreamSplitter()
            let index = full.index(full.startIndex, offsetBy: splitPoint)
            var deltas = splitter.process(String(full[full.startIndex..<index]))
            deltas += splitter.process(String(full[index...]))
            deltas += splitter.finish()

            let reasoningText = deltas.compactMap { if case .reasoning(let text) = $0 { text } else { nil } }.joined()
            let contentText = deltas.compactMap { if case .content(let text) = $0 { text } else { nil } }.joined()
            #expect(reasoningText == "hello", "split at \(splitPoint)")
            #expect(contentText == "world", "split at \(splitPoint)")
        }
    }

    @Test
    func textThatLooksLikeAPartialTagButIsntStaysAsContent() {
        var splitter = ReasoningStreamSplitter()
        // "<thinking about it>" is not the exact `<think>` tag this
        // splitter matches — the whole thing should pass through as
        // plain content, not get silently eaten.
        let deltas = splitter.process("I am <thinking about it> out loud.")
        let contentText = deltas.compactMap { if case .content(let text) = $0 { text } else { nil } }.joined()
        #expect(contentText == "I am <thinking about it> out loud.")
    }

    @Test
    func aStreamThatEndsInsideAnUnclosedThinkBlockFlushesItAsReasoningRatherThanDroppingIt() {
        var splitter = ReasoningStreamSplitter()
        var deltas = splitter.process("<think>cut off mid-thought")
        deltas += splitter.finish()
        #expect(deltas == [.reasoning("cut off mid-thought")])
    }

    @Test
    func aStreamThatEndsWithAnUnfinishedOpeningTagFlushesTheHeldTextAsContent() {
        var splitter = ReasoningStreamSplitter()
        // "<thi" never completes into "<think>" before the stream
        // ends — it was never really a tag, so it flushes as content,
        // not silently vanishing.
        var deltas = splitter.process("plain text <thi")
        deltas += splitter.finish()
        let contentText = deltas.compactMap { if case .content(let text) = $0 { text } else { nil } }.joined()
        #expect(contentText == "plain text <thi")
    }

    @Test
    func multipleThinkBlocksEachSplitCorrectly() {
        var splitter = ReasoningStreamSplitter()
        let deltas = splitter.process("<think>first</think>ok<think>second</think>done")
        let reasoningText = deltas.compactMap { if case .reasoning(let text) = $0 { text } else { nil } }.joined()
        let contentText = deltas.compactMap { if case .content(let text) = $0 { text } else { nil } }.joined()
        #expect(reasoningText == "firstsecond")
        #expect(contentText == "okdone")
    }
}
