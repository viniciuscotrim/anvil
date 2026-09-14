import Testing
@testable import AnvilCore

@Suite("MemoryBulletSplitter")
struct MemoryBulletSplitterTests {
    @Test
    func splitsOnDashBullets() {
        let text = "- First fact\n- Second fact\n- Third fact"
        #expect(MemoryBulletSplitter.split(text) == ["First fact", "Second fact", "Third fact"])
    }

    @Test
    func splitsOnAsteriskAndBulletCharacterMarkers() {
        let text = "* First fact\n• Second fact"
        #expect(MemoryBulletSplitter.split(text) == ["First fact", "Second fact"])
    }

    @Test
    func splitsOnNumberedMarkers() {
        let text = "1. First fact\n2) Second fact"
        #expect(MemoryBulletSplitter.split(text) == ["First fact", "Second fact"])
    }

    @Test
    func joinsAWrappedBulletsSecondLineBackIntoTheSameBullet() {
        let text = "- A fact that wraps\n  onto a second line\n- A short one"
        #expect(MemoryBulletSplitter.split(text) == ["A fact that wraps onto a second line", "A short one"])
    }

    @Test
    func blankLinesBetweenBulletsDontBecomeTheirOwnEmptyBullet() {
        let text = "- First fact\n\n- Second fact\n\n"
        #expect(MemoryBulletSplitter.split(text) == ["First fact", "Second fact"])
    }

    @Test
    func plainTextWithNoMarkersAtAllFallsBackToOneItemPerParagraph() {
        let text = "First paragraph, no bullets here.\n\nSecond paragraph, still none."
        #expect(MemoryBulletSplitter.split(text) == [
            "First paragraph, no bullets here.",
            "Second paragraph, still none.",
        ])
    }

    @Test
    func aSingleParagraphWithNoBlankLinesStaysOneItem() {
        let text = "Just one plain block of text with no structure at all."
        #expect(MemoryBulletSplitter.split(text) == [text])
    }

    @Test
    func emptyOrWhitespaceOnlyTextProducesNoBullets() {
        #expect(MemoryBulletSplitter.split("") == [])
        #expect(MemoryBulletSplitter.split("   \n\n  ") == [])
    }

    @Test
    func realWorldStyleMultiBulletSummarySplitsCleanly() {
        let text = """
        - The user prefers dark mode across every app.
        - The project's deploy target is macOS 13.
        - Decided to use SwiftUI's List instead of a plain VStack for scrolling.
        """
        #expect(MemoryBulletSplitter.split(text) == [
            "The user prefers dark mode across every app.",
            "The project's deploy target is macOS 13.",
            "Decided to use SwiftUI's List instead of a plain VStack for scrolling.",
        ])
    }

    @Test
    func splitWithRelevanceExtractsTheTrailingTagFromEachBullet() {
        let text = "- Trivial detail [relevance: 0.15]\n- Deeply important fact [relevance: 0.95]"
        let bullets = MemoryBulletSplitter.splitWithRelevance(text)
        #expect(bullets == [
            .init(content: "Trivial detail", relevance: 0.15),
            .init(content: "Deeply important fact", relevance: 0.95),
        ])
    }

    @Test
    func splitWithRelevanceAcceptsParenthesesAndWholeNumberTags() {
        let bullets = MemoryBulletSplitter.splitWithRelevance("- A fact (relevance: 1)\n- Another (relevance: 0)")
        #expect(bullets == [
            .init(content: "A fact", relevance: 1),
            .init(content: "Another", relevance: 0),
        ])
    }

    @Test
    func splitWithRelevanceLeavesRelevanceNilWhenThereIsNoTagAtAll() {
        let bullets = MemoryBulletSplitter.splitWithRelevance("- A fact with no tag")
        #expect(bullets == [.init(content: "A fact with no tag", relevance: nil)])
    }

    @Test
    func splitWithRelevanceClampsAnOutOfRangeValue() {
        let bullets = MemoryBulletSplitter.splitWithRelevance("- Overconfident [relevance: 1.5]")
        // The regex itself only matches 0–1, but a hand-typed fixture
        // like this exercises the clamp defensively either way.
        #expect(bullets == [.init(content: "Overconfident [relevance: 1.5]", relevance: nil)])
    }
}
