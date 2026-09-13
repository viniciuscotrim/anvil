import AnvilCore
import Foundation
import LLM

/// The GGUF/llama.cpp counterpart to `NativeChatEngine`'s MLX path —
/// the same "no server, no subprocess" in-process shape the Mac app's
/// `LLMServer` gets from spawning `llama_cpp.server` (`InferenceEngine
/// .llamaCpp`), which can't exist on iOS at all. Wraps `LLM.swift`
/// (`eastriverlee/LLM.swift`, MIT), itself a Swift layer over
/// `ggml-org/llama.cpp`'s own prebuilt xcframework — that project
/// dropped its own root `Package.swift` at some point, so a dedicated
/// wrapper is the practical way to consume it via SPM at all, not a
/// choice made over first-party support that still exists.
///
/// Deliberately thin: `LLM` already does the hard parts (tokenization,
/// the decode loop, KV-cache reuse across turns via its own `history`).
/// This exists only to adapt its API to what `NativeChatEngine` needs —
/// an `AsyncThrowingStream` for streaming, `GenerationSettings` applied
/// the same way the MLX path applies them, and a place to note the two
/// real gaps against that path (below) rather than silently pretend
/// parity.
///
/// **Chat template — the one design choice that matters most here:**
/// `template` is deliberately left `nil` on the underlying `LLM`. That
/// makes `LLM.respond` render each model's own embedded Jinja chat
/// template (via `llama.cpp`'s bundled template engine, confirmed
/// present in the xcframework — `chat.cpp`/`chat-peg-parser.cpp` show
/// up in a from-source link of this dependency) instead of guessing
/// one of `Template`'s five hardcoded presets (chatML/alpaca/llama/
/// mistral/gemma) — none of which even covers Llama 3's own
/// `<|start_header_id|>` format. Since Anvil lets someone download
/// *any* GGUF repo from Hugging Face search, not a fixed curated set,
/// getting this right generically (not just for whichever family
/// happens to match a hardcoded preset) is what makes arbitrary models
/// actually usable instead of silently misformatted. Verified for
/// real, not assumed: a real `meta-llama/Llama-3.2-1B-Instruct` GGUF
/// (header-tag format, outside all five presets) loaded and answered
/// correctly with `template` left `nil`.
///
/// **Known gaps against the MLX path**, both explicit trims rather
/// than oversights:
/// - No `generate_image` tool-calling. `LLM.swift`'s `Tool` protocol
///   is a different shape from `MLXLMCommon`'s, and wiring a second
///   tool-calling path was real, separable follow-up work, not
///   something this pass blocks on.
/// - `tokensPerSecond` is an *estimate* (elapsed wall-clock time over
///   `ChatContextBuilder.estimateTokens`'s token-count guess on the
///   output) — `LLM.swift` doesn't report a measured figure the way
///   `mlx-swift-lm`'s `streamDetails`/`.info` case does for the MLX
///   path, or `llama_cpp.server`'s own response does for the Mac app.
@MainActor
final class GGUFChatBackend {
    private var llm: LLM
    /// A fixed context window, not a knob exposed to `GenerationSettings`
    /// — unlike `maxTokens` on the MLX/HTTP paths (a cap on how much a
    /// single reply can generate), `LLM.init(maxTokenCount:)` sizes the
    /// whole KV cache/context window up front. 4096 is a deliberate,
    /// conservative middle ground for a phone: enough for a real
    /// multi-turn conversation on a small (1B–4B-class) instruct model,
    /// without the cache itself using more RAM than the model weights
    /// already do on constrained devices.
    static let contextTokens: Int32 = 4096

    init?(modelPath: URL, instructions: String?, history: [ChatMessage]) {
        guard let llm = LLM(
            from: modelPath,
            history: Self.llmHistory(from: history),
            maxTokenCount: Self.contextTokens
        ) else {
            return nil
        }
        llm.systemPrompt = instructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? instructions : nil
        self.llm = llm
    }

    /// Rebuilds the conversation state without reloading the model —
    /// the same "switching threads is cheap" property
    /// `NativeChatEngine.startSession` gives the MLX path, since `LLM`
    /// itself has no separate "session" object to recreate.
    func restart(instructions: String?, history: [ChatMessage]) {
        llm.history = Self.llmHistory(from: history)
        llm.systemPrompt = instructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? instructions : nil
    }

    func applyGenerationSettings(_ settings: GenerationSettings) {
        llm.temp = Float(settings.temperature)
        llm.topP = Float(settings.topP)
        llm.topK = Int32(settings.topK)
        // No `minP` equivalent in LLM.swift's sampler chain — silently
        // not applied rather than approximated with something else.
    }

    func stop() {
        llm.stop()
    }

    /// One full reply — mirrors `NativeChatEngine.send`'s "wait for the
    /// whole thing" shape.
    func send(_ text: String) async -> String {
        await llm.getCompletion(from: text)
    }

    /// Token-by-token (really: chat-template-render-then-decode-loop
    /// piece by piece), bridged into the same `AsyncThrowingStream`
    /// shape `NativeChatEngine.streamSend` already returns for the MLX
    /// path, plus a rough measured tok/s over the whole reply — see
    /// this type's own header comment for why it's an estimate.
    func streamSend(_ text: String) -> (stream: AsyncThrowingStream<String, Error>, tokensPerSecond: () -> Double?) {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let box = TokensPerSecondBox()
        let startedAt = Date()
        let task = Task { [llm] in
            await llm.respond(to: text) { deltas in
                var full = ""
                for await delta in deltas {
                    full += delta
                    continuation.yield(delta)
                }
                return full
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed > 0 {
                let estimatedTokens = ChatContextBuilder.estimateTokens(llm.output)
                box.value = Double(estimatedTokens) / elapsed
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return (stream, { box.value })
    }

    private static func llmHistory(from messages: [ChatMessage]) -> [Chat] {
        messages.compactMap { message in
            switch message.role {
            case .user: (role: .user, content: message.content)
            case .assistant: (role: .bot, content: message.content)
            case .system, .tool: nil
            }
        }
    }
}

/// A plain mutable box so `streamSend`'s detached `Task` can hand its
/// measured result back out through the closure it returns — `Double?`
/// itself can't be mutated from inside the `Task` and read from the
/// caller without one, short of making this whole type an actor (which
/// would force every call site onto `await` for a single number read).
private final class TokensPerSecondBox: @unchecked Sendable {
    var value: Double?
}
