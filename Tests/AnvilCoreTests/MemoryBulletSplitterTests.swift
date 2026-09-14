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
}
