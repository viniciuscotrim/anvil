import Foundation
import Testing
@testable import AnvilCore

@Suite("ChatMessage")
struct ChatMessageTests {
    @Test
    func encodesOnlyRoleAndContent() throws {
        let message = ChatMessage(role: .user, content: "hello")

        let data = try JSONEncoder().encode(message)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]

        #expect(object?.count == 2)
        #expect(object?["role"] == "user")
        #expect(object?["content"] == "hello")
    }

    @Test
    func encodesAnArrayOfMessagesInOrder() throws {
        let messages = [
            ChatMessage(role: .system, content: "You are helpful."),
            ChatMessage(role: .user, content: "Hi")
        ]

        let data = try JSONEncoder().encode(messages)
        let array = try JSONSerialization.jsonObject(with: data) as? [[String: String]]

        #expect(array?.count == 2)
        #expect(array?[0]["role"] == "system")
        #expect(array?[1]["role"] == "user")
    }
}

// Serialized: tests below share MockURLProtocol's mutable static state.
@Suite("ChatClient", .serialized)
struct ChatClientTests {
    @Test
    func surfacesAConnectionFailureAsRequestFailed() async throws {
        // Nothing listens on this loopback port — a fast, deterministic
        // connection failure without needing a real server.
        let client = ChatClient()
        let unreachable = URL(string: "http://127.0.0.1:1")!

        await #expect(throws: ServingError.self) {
            _ = try await client.send(
                messages: [ChatMessage(role: .user, content: "hi")],
                baseURL: unreachable,
                model: "test-model"
            )
        }
    }

    /// Regression test for a real bug: sending a registry `id` (a repo
    /// id, or `imported:/…` for local imports) as `model` makes
    /// `mlx_lm.server` try to resolve it as a Hugging Face repo id and
    /// 404 for anything not shaped like `namespace/name`. Every one of
    /// our own per-model server sessions must default to
    /// `"default_model"`, the one key that always maps back to
    /// whatever `--model` it was actually launched with.
    @Test
    func defaultsModelFieldToDefaultModel() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.onRequest = { request in recorder.record(request) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = ChatClient(session: URLSession(configuration: config))

        _ = try? await client.send(
            messages: [ChatMessage(role: .user, content: "hi")],
            baseURL: URL(string: "http://127.0.0.1:9")!
        )

        let body = recorder.capturedBody
        let object = try #require(body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(object["model"] as? String == "default_model")
    }

    /// Regression test for a real bug seen against a reasoning model:
    /// when `max_tokens` cuts the response off before the model reaches
    /// its final answer, `mlx_lm.server` sends `"reasoning"` but omits
    /// `"content"` entirely (not even an empty string) — decoding must
    /// not throw, and the reasoning text should surface rather than
    /// silently vanishing.
    @Test
    func fallsBackToReasoningWhenContentIsAbsent() async throws {
        MockURLProtocol.responseBody = Data(
            #"{"choices":[{"message":{"role":"assistant","reasoning":"still thinking…"}}]}"#.utf8
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = ChatClient(session: URLSession(configuration: config))

        let reply = try await client.send(
            messages: [ChatMessage(role: .user, content: "hi")],
            baseURL: URL(string: "http://127.0.0.1:9")!
        )

        #expect(reply.content.contains("still thinking…"))
    }

    @Test
    func prefersContentOverReasoningWhenBothArePresent() async throws {
        MockURLProtocol.responseBody = Data(
            #"{"choices":[{"message":{"role":"assistant","content":"the answer","reasoning":"how I got there"}}]}"#.utf8
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = ChatClient(session: URLSession(configuration: config))

        let reply = try await client.send(
            messages: [ChatMessage(role: .user, content: "hi")],
            baseURL: URL(string: "http://127.0.0.1:9")!
        )

        #expect(reply.content == "the answer")
    }
}

/// Plain lock-backed recorder (not an actor) so the URLProtocol's
/// synchronous `startLoading()` can record into it directly.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _capturedBody: Data?

    var capturedBody: Data? {
        lock.lock(); defer { lock.unlock() }
        return _capturedBody
    }

    func record(_ request: URLRequest) {
        let body = request.httpBodyStreamData() ?? request.httpBody
        lock.lock()
        _capturedBody = body
        lock.unlock()
    }
}

private extension URLRequest {
    func httpBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Intercepts requests instead of hitting the network, so this test is
/// fast and deterministic regardless of what's listening on port 9.
private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var onRequest: ((URLRequest) -> Void)?
    nonisolated(unsafe) static var responseBody = Data(#"{"choices":[{"message":{"content":"ok"}}]}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.onRequest?(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
