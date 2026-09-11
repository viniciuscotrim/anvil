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

    public func send(
        messages: [ChatMessage],
        baseURL: URL,
        model: String,
        maxTokens: Int = 512
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
        return ChatMessage(role: .assistant, content: choice.message.content)
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }
    let choices: [Choice]
}
