import Testing
@testable import AnvilCore

@Suite("MemoryDiff")
struct MemoryDiffTests {
    @Test
    func identicalTextHasSimilarityOne() {
        #expect(MemoryDiff.similarity("The user prefers dark mode.", "The user prefers dark mode.") == 1.0)
    }

    @Test
    func identicalTextDiffsToOneUnchangedSegment() {
        let segments = MemoryDiff.diff(from: "The user prefers dark mode.", to: "The user prefers dark mode.")
        #expect(segments == [.unchanged("The user prefers dark mode.")])
    }

    @Test
    func oneWordChangedStaysAboveTheUpdateThreshold() {
        let similarity = MemoryDiff.similarity(
            "The user prefers dark mode in every app.",
            "The user prefers light mode in every app.")
        #expect(similarity > MemoryDiff.updateSimilarityThreshold)
        #expect(similarity < 1.0)
    }

    @Test
    func oneWordChangedDiffsToRemovedOldAddedNew() {
        let segments = MemoryDiff.diff(from: "The user prefers dark mode.", to: "The user prefers light mode.")
        #expect(segments == [
            .unchanged("The user prefers"),
            .removed("dark"),
            .added("light"),
            .unchanged("mode."),
        ])
    }

    @Test
    func completelyUnrelatedTextHasLowSimilarity() {
        let similarity = MemoryDiff.similarity(
            "The user prefers dark mode.",
            "The project's deploy target is macOS 13.")
        #expect(similarity < MemoryDiff.updateSimilarityThreshold)
    }

    @Test
    func aWordAppendedAtTheEndIsPurelyAnAddition() {
        let segments = MemoryDiff.diff(from: "The user likes coffee", to: "The user likes coffee and tea")
        #expect(segments == [
            .unchanged("The user likes coffee"),
            .added("and tea"),
        ])
    }

    @Test
    func aWordRemovedFromTheEndIsPurelyARemoval() {
        let segments = MemoryDiff.diff(from: "The user likes coffee and tea", to: "The user likes coffee")
        #expect(segments == [
            .unchanged("The user likes coffee"),
            .removed("and tea"),
        ])
    }

    @Test
    func emptyStringsAreIdentical() {
        #expect(MemoryDiff.similarity("", "") == 1.0)
        #expect(MemoryDiff.diff(from: "", to: "").isEmpty)
    }

    @Test
    func fromEmptyToSomeTextIsAllAdded() {
        let segments = MemoryDiff.diff(from: "", to: "brand new fact")
        #expect(segments == [.added("brand new fact")])
    }
}
