import Foundation

/// Splits a bulleted (or numbered) block of text — what
/// `ContextShiftScript.summarize`'s own prompt already asks Phi-4 to
/// produce ("Return only the bullet points, nothing else") — into one
/// string per bullet. Requested live, after a full Context Shift
/// compaction pass landed as one single, all-or-nothing memory
/// suggestion: "Na Memoria tudo que o processo rodou veio em uma unica
/// memoria gigante ... eu quero cada topico/bullet em uma memoria pra
/// aceitar individualmente." A line with no bullet marker at all
/// (Phi-4 ignoring its own instructions, or a caller handing this a
/// plain paragraph) is appended to whichever bullet is currently being
/// built, so a bullet that wraps onto a second line doesn't get cut in
/// half; if nothing in the whole text ever looks like a bullet, the
/// text is instead split on blank-line-separated paragraphs, falling
/// back to the whole trimmed text as a single item only if that too
/// finds nothing to split on — never fewer suggestions than before
/// this existed, only ever more.
public enum MemoryBulletSplitter {
    private static let bulletMarkerPattern = #"^(?:[-*•]|\d+[.)])\s+"#

    public static func split(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        var bullets: [String] = []
        var current: String?
        var sawAnyMarker = false

        func flush() {
            if let value = current?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                bullets.append(value)
            }
            current = nil
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: bulletMarkerPattern, options: .regularExpression) {
                sawAnyMarker = true
                flush()
                current = String(line[range.upperBound...])
            } else if line.isEmpty {
                // Inside a bulleted list, a blank line is just spacing
                // between items, not a new item — don't flush a bullet
                // that might still continue below it. Before any
                // marker's been seen at all, it's the only signal this
                // is plain-paragraph text, so it does mark a break.
                if !sawAnyMarker {
                    flush()
                }
            } else if current != nil {
                current = (current ?? "") + " " + line
            } else {
                current = line
            }
        }
        flush()

        if !bullets.isEmpty { return bullets }
        let trimmedWhole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedWhole.isEmpty ? [] : [trimmedWhole]
    }

    /// One bullet, plus whatever relevance score Phi-4 tagged it with
    /// — see `splitWithRelevance`'s own doc comment.
    public struct Bullet: Equatable, Sendable {
        public let content: String
        /// `nil` when no `[relevance: …]` tag was found on this bullet
        /// at all, or it didn't parse — callers should treat that as
        /// "unscored", not as zero/trivial.
        public let relevance: Double?

        public init(content: String, relevance: Double?) {
            self.content = content
            self.relevance = relevance
        }
    }

    private static let relevanceTagPattern = #"\s*[\[(]\s*relevance:\s*(0(?:\.\d+)?|1(?:\.0+)?)\s*[\])]\s*$"#

    /// Same splitting as `split(_:)`, additionally pulling a trailing
    /// `[relevance: 0.0-1.0]` tag off each bullet — requested live,
    /// after a first real digest surfaced 100+ suggestions in one
    /// pass: "ao revisar manualmente algumas eram triviais, outras
    /// interessantes e algumas imperdíveis. Então ao invés de
    /// simplesmente aceitar ou recusar temos que ter uma avaliação da
    /// IA do quão relevante a memória parece ser." `HIDDEN_SYSTEM_PROMPT`
    /// is what actually asks Phi-4 to append this tag; a bullet with no
    /// tag at all (an older summary generated before this existed, or
    /// the model simply not following the format for one line) still
    /// splits correctly, just with `relevance: nil`.
    public static func splitWithRelevance(_ text: String) -> [Bullet] {
        split(text).map { bullet in
            guard let range = bullet.range(of: relevanceTagPattern, options: .regularExpression) else {
                return Bullet(content: bullet, relevance: nil)
            }
            let tag = String(bullet[range])
            guard let numberRange = tag.range(of: #"(0(?:\.\d+)?|1(?:\.0+)?)"#, options: .regularExpression),
                  let value = Double(tag[numberRange]) else {
                return Bullet(content: bullet, relevance: nil)
            }
            let content = String(bullet[bullet.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Bullet(content: content, relevance: min(1, max(0, value)))
        }
    }
}
