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
    public func send(
        messages: [ChatMessage],
        baseURL: URL,
        model: String = "default_model",
        modelDisplayName: String = "",
        settings: GenerationSettings = .default
    ) async throws -> ChatMessage {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct WireMessage: Encodable {
            let role: String
            let content: String
        }
        struct RequestBody: Encodable {
            let model: String
            let messages: [WireMessage]
            let max_tokens: Int
            let temperature: Double
            let top_p: Double
            let top_k: Int
            let min_p: Double
        }
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: model,
                messages: messages.map { WireMessage(role: $0.role.rawValue, content: $0.content) },
                max_tokens: settings.maxTokens,
                temperature: settings.temperature,
                top_p: settings.topP,
                top_k: settings.topK,
                min_p: settings.minP
            )
        )

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
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ServingError.requestFailed("HTTP \(statusCode): \(body)")
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
        let tokensPerSecond = (completionTokens > 0 && elapsedSeconds > 0)
            ? Double(completionTokens) / elapsedSeconds
            : nil

        return ChatMessage(
            role: .assistant,
            content: choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            reasoning: choice.message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            modelDisplayName: modelDisplayName.nilIfEmpty,
            tokensPerSecond: tokensPerSecond
        )
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
            let reasoning: String?
        }
        let message: Message
    }
    struct Usage: Decodable {
        let completionTokens: Int
        enum CodingKeys: String, CodingKey {
            case completionTokens = "completion_tokens"
        }
    }
    let choices: [Choice]
    let usage: Usage?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
