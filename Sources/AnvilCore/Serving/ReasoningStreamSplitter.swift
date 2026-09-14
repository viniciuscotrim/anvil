import Foundation

/// Splits a raw, unseparated model token stream into reasoning vs.
/// answer deltas by tracking `<think>…</think>` tags — the client-side
/// equivalent of what `mlx_lm.server`/`llama_cpp.server` already do on
/// Mac (exposed there as a separate `reasoning` SSE field
/// `ChatClient` reads directly, never mixed into `content`). Needed on
/// iOS specifically because the on-device engines
/// (`NativeChatEngine`'s `mlx-swift-lm` `ChatSession`, and
/// `GGUFChatBackend`'s `LLM.swift`) stream nothing but plain text —
/// without this, a reasoning model's entire `<think>` block used to
/// land straight in the visible bubble ahead of the real answer.
/// Reported live: "Precisamos colocar no iPhone agora o botão de
/// ocultar o Thinking do modelo. Não dá pra conversar como está."
///
/// A single tag pair, not a general XML/HTML parser — every reasoning
/// model this app targets (DeepSeek-R1-distill, Qwen3's thinking
/// models, …) uses exactly this lowercase `<think>`/`</think>` pair,
/// matching OpenAI's own `reasoning_content` convention that
/// `mlx_lm.server` itself parses server-side.
public struct ReasoningStreamSplitter: Sendable {
    public enum Delta: Equatable, Sendable {
        case reasoning(String)
        case content(String)
    }

    private enum State: Sendable {
        /// Scanning for `<think>` — the starting state, and also
        /// where a closed think block returns to, so a model that
        /// emits more than one `<think>…</think>` segment (some
        /// tool-calling/multi-step reasoning models do) still splits
        /// every one of them correctly rather than only the first.
        case beforeThink
        case inThink
    }

    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var state: State = .beforeThink
    /// Whatever's been read but not yet safely emitted — either it's
    /// still being checked against the tag it might be the start of,
    /// or (once in `.afterThink`) it's just held until `finish()`
    /// flushes it, since nothing more can change how it's classified.
    private var buffer = ""

    public init() {}

    /// Feed one chunk of raw streamed text in, get back zero or more
    /// deltas — usually one, but a chunk that itself contains an
    /// opening or closing tag produces both a reasoning delta and a
    /// content delta from the same call.
    public mutating func process(_ chunk: String) -> [Delta] {
        guard !chunk.isEmpty else { return [] }
        buffer += chunk
        var deltas: [Delta] = []

        // Bounded by `buffer`'s own shrinking length each iteration —
        // every branch below either consumes a prefix of `buffer` and
        // loops, or returns having consumed nothing further this call.
        while true {
            switch state {
            case .beforeThink:
                if let range = buffer.range(of: Self.openTag) {
                    let before = String(buffer[buffer.startIndex..<range.lowerBound])
                    if !before.isEmpty { deltas.append(.content(before)) }
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    state = .inThink
                    continue
                }
                if let (safe, held) = Self.splitOnPossiblePrefix(of: buffer, tag: Self.openTag) {
                    if !safe.isEmpty { deltas.append(.content(safe)) }
                    buffer = held
                } else if !buffer.isEmpty {
                    // No suffix of `buffer` could be the start of
                    // `<think>` — the whole thing is safe to emit now,
                    // nothing left to hold back.
                    deltas.append(.content(buffer))
                    buffer = ""
                }
                return deltas

            case .inThink:
                if let range = buffer.range(of: Self.closeTag) {
                    let before = String(buffer[buffer.startIndex..<range.lowerBound])
                    if !before.isEmpty { deltas.append(.reasoning(before)) }
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    state = .beforeThink
                    continue
                }
                if let (safe, held) = Self.splitOnPossiblePrefix(of: buffer, tag: Self.closeTag) {
                    if !safe.isEmpty { deltas.append(.reasoning(safe)) }
                    buffer = held
                } else if !buffer.isEmpty {
                    deltas.append(.reasoning(buffer))
                    buffer = ""
                }
                return deltas
            }
        }
    }

    /// Call once the stream ends — flushes anything still held back.
    /// The only way this actually holds real, meaningful text (rather
    /// than an empty buffer) is a stream that got cut off mid-tag
    /// (cancelled generation, a truncated response): whatever's left
    /// is classified by whichever state it was in when the stream
    /// stopped, the same as any other content in that state, rather
    /// than silently discarded.
    public mutating func finish() -> [Delta] {
        guard !buffer.isEmpty else { return [] }
        let remaining = buffer
        buffer = ""
        switch state {
        case .beforeThink:
            return [.content(remaining)]
        case .inThink:
            return [.reasoning(remaining)]
        }
    }

    /// `buffer`'s own trailing run of characters might be the start of
    /// `tag` (e.g. buffer ends in "<", "<th", "</thi", …) — that
    /// suffix has to stay held back until either it's disproven (more
    /// text arrives that doesn't continue the tag) or confirmed (the
    /// full tag completes, handled by the caller's own `range(of:)`
    /// check before this is ever reached). Returns `nil` when nothing
    /// in the buffer could possibly be a partial tag — the common
    /// case, letting the caller just emit the whole thing.
    private static func splitOnPossiblePrefix(of buffer: String, tag: String) -> (safe: String, held: String)? {
        let maxCheck = min(buffer.count, tag.count - 1)
        guard maxCheck > 0 else { return nil }
        for length in stride(from: maxCheck, through: 1, by: -1) {
            let suffixStart = buffer.index(buffer.endIndex, offsetBy: -length)
            let suffix = String(buffer[suffixStart...])
            if tag.hasPrefix(suffix) {
                let safe = String(buffer[buffer.startIndex..<suffixStart])
                return (safe, suffix)
            }
        }
        return nil
    }
}
