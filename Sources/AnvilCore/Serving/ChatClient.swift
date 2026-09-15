import Foundation

/// Talks to an OpenAI-compatible `/v1/chat/completions` endpoint — the
/// same client code path works against Anvil's own `LLMServer` today
/// and, unmodified, against the persona proxies' expectations once
/// Anvil is the thing listening on port 8000.
public struct ChatClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// `model` defaults to `"default_model"` — the key `mlx_lm.server`
    /// always maps back to whatever path it was launched with via
    /// `--model`. Since `LLMServer` gives every loaded model its own
    /// dedicated process/port, that default is always correct for our
    /// own sessions and sidesteps a real bug: sending a model's registry
    /// `id` here (a repo id, or `imported:/…` for local imports) makes
    /// the server try to resolve it as a Hugging Face repo id instead of
    /// using the already-loaded model, which 404s for anything that
    /// isn't shaped like `namespace/name`. Only override this once
    /// talking to something other than our own per-model server (e.g.
    /// the eventual shared port-8000 server for the persona proxies).
    /// `systemPrompt`, if given, is prepended as a `.system` message on
    /// the wire only — never written into `messages`/thread history, so
    /// a profile's prompt (or the tool-use discipline instruction) can
    /// change or disappear between turns without leaving stale system
    /// messages baked into a saved conversation.
    public func send(
        messages: [ChatMessage],
        baseURL: URL,
        model: String = "default_model",
        modelDisplayName: String = "",
        settings: GenerationSettings = .default,
        tools: [ChatTool] = [],
        systemPrompt: String? = nil,
        conversationID: String? = nil
    ) async throws -> ChatMessage {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Generous enough to cover a full `wireMaxTokens` budget even
        // on a slow model — with no explicit cap that budget is now
        // `GenerationSettings.effectivelyUnlimited` (8192 tokens; see
        // its doc comment for why that isn't larger), and a slower
        // model could genuinely take several minutes to either answer
        // or exhaust that budget. The default 60s was never close.
        request.timeoutInterval = 1800

        var wireMessages = messages.map(Self.wireMessage)
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            wireMessages.insert(WireMessage(role: "system", content: systemPrompt), at: 0)
        }

        let body = ChatCompletionRequest(
            model: model,
            messages: wireMessages,
            max_tokens: settings.wireMaxTokens,
            temperature: settings.temperature,
            top_p: settings.topP,
            top_k: settings.topK,
            min_p: settings.minP,
            tools: tools.isEmpty ? nil : tools.map(\.wireRepresentation),
            conversation_id: conversationID,
            stream: nil,
            stream_options: nil
        )
        request.httpBody = try JSONEncoder().encode(body)

        let start = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServingError.requestFailed(error.localizedDescription)
        }
        let elapsedSeconds = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw ServingError.requestFailed("HTTP \(statusCode): \(bodyText)")
        }

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw ServingError.requestFailed("Could not parse response: \(error.localizedDescription)")
        }

        guard let choice = decoded.choices.first else {
            throw ServingError.requestFailed("Response had no choices")
        }

        let completionTokens = decoded.usage?.completionTokens ?? 0
        let cachedPromptTokens = decoded.usage?.promptTokensDetails?.cachedTokens
        let tokensPerSecond = (completionTokens > 0 && elapsedSeconds > 0)
            ? Double(completionTokens) / elapsedSeconds
            : nil

        let toolCalls = choice.message.tool_calls?.map {
            ChatMessage.ToolCall(id: $0.id, name: $0.function.name, argumentsJSON: $0.function.arguments)
        }

        return ChatMessage(
            role: .assistant,
            content: choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            reasoning: choice.message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            modelDisplayName: modelDisplayName.nilIfEmpty,
            tokensPerSecond: tokensPerSecond,
            cachedPromptTokens: cachedPromptTokens,
            toolCalls: (toolCalls?.isEmpty ?? true) ? nil : toolCalls
        )
    }

    /// One incremental event from a streamed `/v1/chat/completions` call
    /// — a real, reported problem this exists to fix: `send()` blocks
    /// silently until the *entire* reply is ready, up to its own 1800s
    /// timeout, with nothing on screen to tell a caller it's still alive
    /// versus stuck. `contentDelta`/`reasoningDelta` arrive as the model
    /// actually generates; `done` carries the final assembled message
    /// (same shape `send` returns), built from everything streamed in.
    public enum ChatStreamEvent: Sendable {
        case contentDelta(String)
        case reasoningDelta(String)
        case done(ChatMessage)
    }

    /// Same request `send` makes, with `"stream": true` — reads Server-
    /// Sent Events off `URLSession.bytes(for:)`, which honors Swift's
    /// own cooperative cancellation: cancelling the `Task` iterating
    /// this stream (or the `Task` that owns the caller of this function)
    /// aborts the underlying HTTP connection instead of continuing to
    /// wait for the rest of a reply nobody wants anymore — the other
    /// real half of the same problem: no way to actually stop a
    /// generation that won't be needed once started.
    /// `stallInterval` — how long the connection can go completely
    /// silent before this gives up — defaults to a real 120s for actual
    /// callers; overridable only so a test can use a fraction of a
    /// second instead of actually waiting two real minutes to exercise
    /// the watchdog below.
    public func streamSend(
        messages: [ChatMessage],
        baseURL: URL,
        model: String = "default_model",
        modelDisplayName: String = "",
        settings: GenerationSettings = .default,
        tools: [ChatTool] = [],
        systemPrompt: String? = nil,
        conversationID: String? = nil,
        stallInterval: TimeInterval = 120
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 1800

                    var wireMessages = messages.map(Self.wireMessage)
                    if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        wireMessages.insert(WireMessage(role: "system", content: systemPrompt), at: 0)
                    }
                    let body = ChatCompletionRequest(
                        model: model,
                        messages: wireMessages,
                        max_tokens: settings.wireMaxTokens,
                        temperature: settings.temperature,
                        top_p: settings.topP,
                        top_k: settings.topK,
                        min_p: settings.minP,
                        tools: tools.isEmpty ? nil : tools.map(\.wireRepresentation),
                        conversation_id: conversationID,
                        stream: true,
                        stream_options: StreamOptions(include_usage: true)
                    )
                    request.httpBody = try JSONEncoder().encode(body)

                    let start = Date()
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await self.session.bytes(for: request)
                    } catch {
                        throw ServingError.requestFailed(error.localizedDescription)
                    }
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        throw ServingError.requestFailed("HTTP \(statusCode): \(errorBody)")
                    }

                    var contentSoFar = ""
                    var reasoningSoFar = ""
                    var toolCallAccumulators: [Int: ToolCallAccumulator] = [:]
                    var completionTokens = 0
                    var cachedPromptTokens: Int?

                    // A real, reported failure mode this exists to fix:
                    // the underlying model server can stop actually
                    // working mid-generation (a hung/crashed inference
                    // loop, an MLX/Metal-side stall) without closing the
                    // connection or sending anything else — reported
                    // live as memory/GPU use visibly dropping in
                    // Activity Monitor while Chat just sat on
                    // "Thinking…" indefinitely. `request.timeoutInterval`
                    // (1800s) is deliberately generous for a genuinely
                    // slow model that's still actively producing output,
                    // so it's the wrong tool for catching *this* — a
                    // connection that goes completely silent. This
                    // watchdog tracks time since the last byte actually
                    // arrived (ticked on every line, even one that
                    // parses to nothing) and cancels the read the moment
                    // that silence — not the total reply time — exceeds
                    // a much shorter bound, so a real hang surfaces in
                    // ~2 minutes with a clear message instead of only
                    // ever failing (if at all) after the full 1800s.
                    let lastActivity = ActivityClock()
                    // At most 5s between checks, but never longer than
                    // the interval itself — otherwise a short test-only
                    // `stallInterval` would wait a fixed 5s regardless.
                    let pollInterval = min(5, stallInterval / 4)
                    let watchdog = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: UInt64(max(0, pollInterval) * 1_000_000_000))
                            guard !Task.isCancelled else { return }
                            if lastActivity.secondsSinceLastTick() >= stallInterval {
                                // Finishing the continuation here (rather
                                // than throwing from inside the `for try
                                // await` loop below, which is exactly
                                // what's stuck) is what actually unblocks
                                // it: `continuation.onTermination` below
                                // already cancels `task` once the stream
                                // terminates, and that cancellation is
                                // what `bytes.lines`'s blocked read
                                // actually responds to.
                                continuation.finish(throwing: ServingError.requestFailed(
                                    "The model stopped responding (no output for over \(Int(stallInterval))s) "
                                    + "— it may have crashed or hung. Try again, or reload the model."
                                ))
                                return
                            }
                        }
                    }
                    defer { watchdog.cancel() }

                    for try await line in bytes.lines {
                        lastActivity.tick()
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let chunkData = payload.data(using: .utf8),
                            let chunk = try? JSONDecoder().decode(ChatCompletionChunk.self, from: chunkData)
                        else { continue }

                        if let usage = chunk.usage {
                            completionTokens = usage.completionTokens
                            cachedPromptTokens = usage.promptTokensDetails?.cachedTokens
                        }
                        guard let choice = chunk.choices.first else { continue }
                        if let contentDelta = choice.delta.content, !contentDelta.isEmpty {
                            contentSoFar += contentDelta
                            continuation.yield(.contentDelta(contentDelta))
                        }
                        if let reasoningDelta = choice.delta.reasoning, !reasoningDelta.isEmpty {
                            reasoningSoFar += reasoningDelta
                            continuation.yield(.reasoningDelta(reasoningDelta))
                        }
                        if let toolCallDeltas = choice.delta.tool_calls {
                            for delta in toolCallDeltas {
                                var accumulator = toolCallAccumulators[delta.index] ?? ToolCallAccumulator()
                                if let id = delta.id { accumulator.id = id }
                                if let name = delta.function?.name { accumulator.name = name }
                                if let argumentsDelta = delta.function?.arguments {
                                    accumulator.arguments += argumentsDelta
                                }
                                toolCallAccumulators[delta.index] = accumulator
                            }
                        }
                    }

                    let elapsedSeconds = Date().timeIntervalSince(start)
                    let tokensPerSecond = (completionTokens > 0 && elapsedSeconds > 0)
                        ? Double(completionTokens) / elapsedSeconds
                        : nil

                    let toolCalls: [ChatMessage.ToolCall]? = toolCallAccumulators.isEmpty ? nil :
                        toolCallAccumulators.keys.sorted().compactMap { index in
                            let accumulator = toolCallAccumulators[index]!
                            guard let id = accumulator.id, let name = accumulator.name else { return nil }
                            return ChatMessage.ToolCall(id: id, name: name, argumentsJSON: accumulator.arguments)
                        }

                    let finalMessage = ChatMessage(
                        role: .assistant,
                        content: contentSoFar.trimmingCharacters(in: .whitespacesAndNewlines),
                        reasoning: reasoningSoFar.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                        modelDisplayName: modelDisplayName.nilIfEmpty,
                        tokensPerSecond: tokensPerSecond,
                        cachedPromptTokens: cachedPromptTokens,
                        toolCalls: (toolCalls?.isEmpty ?? true) ? nil : toolCalls
                    )
                    continuation.yield(.done(finalMessage))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct ToolCallAccumulator {
        var id: String?
        var name: String?
        var arguments: String = ""
    }

    /// A lock-protected "last seen" timestamp — `streamSend`'s stall
    /// watchdog (a separate `Task`) reads it while the line-reading loop
    /// (a different `Task`) writes it on every line, so a plain `Date`
    /// var isn't safe here.
    private final class ActivityClock: @unchecked Sendable {
        private let lock = NSLock()
        private var lastTick = Date()

        func tick() {
            lock.lock()
            lastTick = Date()
            lock.unlock()
        }

        func secondsSinceLastTick() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            return Date().timeIntervalSince(lastTick)
        }
    }

    /// Wire shape stays intentionally narrow: role/content always, plus
    /// `tool_call_id` for a `.tool` result and `tool_calls` for an
    /// assistant message that made one — never the other locally-only
    /// fields (id, reasoning, modelDisplayName, tokensPerSecond,
    /// generatedImagePath) that make `ChatMessage` fully `Codable` for
    /// disk persistence.
    private static func wireMessage(_ message: ChatMessage) -> WireMessage {
        WireMessage(
            role: message.role.rawValue,
            content: message.content,
            tool_call_id: message.toolCallID,
            tool_calls: (message.toolCalls?.isEmpty ?? true) ? nil : message.toolCalls?.map {
                WireOutgoingToolCall(id: $0.id, function: .init(name: $0.name, arguments: $0.argumentsJSON))
            }
        )
    }
}

private struct WireOutgoingToolCall: Encodable {
    struct Function: Encodable {
        let name: String
        let arguments: String
    }
    let id: String
    let type = "function"
    let function: Function
}

private struct WireMessage: Encodable {
    let role: String
    let content: String
    var tool_call_id: String?
    var tool_calls: [WireOutgoingToolCall]?

    init(role: String, content: String, tool_call_id: String? = nil, tool_calls: [WireOutgoingToolCall]? = nil) {
        self.role = role
        self.content = content
        self.tool_call_id = tool_call_id
        self.tool_calls = tool_calls
    }
}

private struct StreamOptions: Encodable {
    let include_usage: Bool
}

/// Typed request body for `/v1/chat/completions` — replaces a
/// `[String: Any]` dictionary encoded via `JSONSerialization`, where a
/// misspelled key (e.g. `"top_P"`) would only ever fail silently at
/// runtime. Optional fields are omitted from the wire payload when nil
/// (Swift's synthesized `Encodable` conformance calls `encodeIfPresent`
/// for `Optional`-typed properties), matching the old dictionary's
/// conditional-key-insertion exactly.
private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let max_tokens: Int
    let temperature: Double
    let top_p: Double
    let top_k: Int
    let min_p: Double
    let tools: [ChatTool.WireToolDefinition]?
    let conversation_id: String?
    let stream: Bool?
    let stream_options: StreamOptions?
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            struct ToolCallWire: Decodable {
                struct Function: Decodable {
                    let name: String
                    let arguments: String
                }
                let id: String
                let function: Function
            }
            let content: String?
            let reasoning: String?
            let tool_calls: [ToolCallWire]?
        }
        let message: Message
    }
    let choices: [Choice]
    let usage: WireUsage?
}

/// One `data:` line's JSON payload from a streamed
/// `/v1/chat/completions` response — the standard OpenAI-compatible
/// "chat.completion.chunk" shape `mlx_lm.server` follows. `delta` only
/// ever carries whatever's new in *this* chunk (a content fragment, a
/// piece of one tool call's arguments, …) — `streamSend` accumulates
/// these into the final message itself.
private struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCallDelta: Decodable {
                struct FunctionDelta: Decodable {
                    let name: String?
                    let arguments: String?
                }
                let index: Int
                let id: String?
                let function: FunctionDelta?
            }
            let content: String?
            let reasoning: String?
            let tool_calls: [ToolCallDelta]?
        }
        let delta: Delta
    }
    let choices: [Choice]
    let usage: WireUsage?
}

/// Shared by `ChatCompletionResponse` (a full, non-streamed reply) and
/// `ChatCompletionChunk` (one piece of a streamed one) — both report
/// the same usage shape, just at different points in the response.
private struct WireUsage: Decodable {
    let completionTokens: Int
    let promptTokensDetails: PromptTokensDetails?
    enum CodingKeys: String, CodingKey {
        case completionTokens = "completion_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }
}

private struct PromptTokensDetails: Decodable {
    let cachedTokens: Int?

    enum CodingKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
