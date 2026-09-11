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
        maxTokens: Int = 1024
    ) async throws -> ChatMessage {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct RequestBody: Encodable {
            let model: String
            let messages: [ChatMessage]
            let max_tokens: Int
        }
        request.httpBody = try JSONEncoder().encode(
            RequestBody(model: model, messages: messages, max_tokens: maxTokens)
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServingError.requestFailed(error.localizedDescription)
        }

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
        return ChatMessage(role: .assistant, content: Self.resolveContent(from: choice.message))
    }

    /// Reasoning models (this server reports them via an extra
    /// `"reasoning"` field alongside `"content"`) can get cut off by
    /// `max_tokens` before `content` ever appears — `content` is then
    /// absent entirely, not just empty. Falling back to the reasoning
    /// text beats silently dropping the reply or throwing a decode
    /// error over a field most models don't even send.
    private static func resolveContent(from message: ChatCompletionResponse.Choice.Message) -> String {
        if let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            return content
        }
        if let reasoning = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoning.isEmpty {
            return "_(cut off before an answer — reply with more tokens)_\n\n" + reasoning
        }
        return ""
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
    let choices: [Choice]
}
