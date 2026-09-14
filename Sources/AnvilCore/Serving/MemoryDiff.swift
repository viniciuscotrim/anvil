import Foundation

/// A word-level diff between two versions of a memory's text, plus the
/// similarity score that decides whether a freshly-extracted bullet is
/// the *same* fact (skip, don't duplicate), a *reworded* version of one
/// already known (offer as an update, needing approval), or something
/// genuinely new (suggest normally). Requested live, right after fixing
/// the vector store's own silent duplication: "se for 100% identico o
/// resultado novo em comparação com o antigo, pode ignorar imediatamente
/// /não duplicar, mas se houver uma reinterpretação que mude uma palavra
/// do resultado ... me mostre como precisando de aprovação, mas mostre
/// que é um update e mostrando o antigo e o novo em um formato de texto
/// hachurado se algo for deletado e negrito se for acrescentado."
public enum MemoryDiff {
    public enum Segment: Equatable, Sendable {
        case unchanged(String)
        case removed(String)
        case added(String)
    }

    /// Below this, two bullets are treated as unrelated facts (a brand
    /// new suggestion) rather than a reworded version of one already
    /// known — high enough that "changes one word" of a normal-length
    /// sentence clears it easily, low enough that a genuinely different
    /// fact doesn't accidentally get offered as an "update" to
    /// something it has nothing to do with.
    public static let updateSimilarityThreshold = 0.5

    /// Word-level diff via the longest common subsequence — the same
    /// core algorithm `difflib.SequenceMatcher` uses, simplified for
    /// equal-weight word tokens. Small enough inputs (one memory's
    /// worth of text, a sentence or two) that an O(n·m) DP table is
    /// plenty fast.
    public static func diff(from old: String, to new: String) -> [Segment] {
        let oldWords = old.split(separator: " ").map(String.init)
        let newWords = new.split(separator: " ").map(String.init)
        let pairs = longestCommonSubsequencePairs(oldWords, newWords)

        var segments: [Segment] = []
        var oldIndex = 0
        var newIndex = 0
        for (oldPairIndex, newPairIndex) in pairs {
            while oldIndex < oldPairIndex { segments.append(.removed(oldWords[oldIndex])); oldIndex += 1 }
            while newIndex < newPairIndex { segments.append(.added(newWords[newIndex])); newIndex += 1 }
            segments.append(.unchanged(oldWords[oldPairIndex]))
            oldIndex = oldPairIndex + 1
            newIndex = newPairIndex + 1
        }
        while oldIndex < oldWords.count { segments.append(.removed(oldWords[oldIndex])); oldIndex += 1 }
        while newIndex < newWords.count { segments.append(.added(newWords[newIndex])); newIndex += 1 }
        return mergeAdjacentSegmentsOfTheSameKind(segments)
    }

    /// `2 · |LCS| / (|old words| + |new words|)` — `1.0` for identical
    /// text word-for-word, `0.0` for completely disjoint. Two empty
    /// strings compare as identical (`1.0`) rather than dividing by
    /// zero.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let aWords = a.split(separator: " ").map(String.init)
        let bWords = b.split(separator: " ").map(String.init)
        guard !aWords.isEmpty || !bWords.isEmpty else { return 1.0 }
        let lcsLength = longestCommonSubsequencePairs(aWords, bWords).count
        return Double(2 * lcsLength) / Double(aWords.count + bWords.count)
    }

    /// Indices `(i, j)` where `a[i] == b[j]`, in reading order, forming
    /// the longest common subsequence — the classic bottom-up DP table
    /// plus a greedy backtrack.
    private static func longestCommonSubsequencePairs(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count
        let m = b.count
        guard n > 0, m > 0 else { return [] }

        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// Joins consecutive words of the same segment kind back into one
    /// span with single spaces between them, so a caller rendering
    /// this as styled `Text` doesn't have to reason about word-by-word
    /// spacing itself.
    private static func mergeAdjacentSegmentsOfTheSameKind(_ segments: [Segment]) -> [Segment] {
        var merged: [Segment] = []
        for segment in segments {
            switch (merged.last, segment) {
            case (.unchanged(let previous)?, .unchanged(let current)):
                merged[merged.count - 1] = .unchanged(previous + " " + current)
            case (.removed(let previous)?, .removed(let current)):
                merged[merged.count - 1] = .removed(previous + " " + current)
            case (.added(let previous)?, .added(let current)):
                merged[merged.count - 1] = .added(previous + " " + current)
            default:
                merged.append(segment)
            }
        }
        return merged
    }
}
