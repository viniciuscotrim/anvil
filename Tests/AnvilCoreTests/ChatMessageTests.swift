import Foundation
import Testing
@testable import AnvilCore

@Suite("ChatMessage")
struct ChatMessageTests {
    /// Full round trip through JSON — this is the shape persisted to a
    /// thread's file on disk, so every field (not just role/content)
    /// must survive. The wire format sent to `mlx_lm.server` is a
    /// separate, narrower thing `ChatClient` builds itself; see
    /// `ChatClientTests`.
    @Test
    func roundTripsAllFieldsThroughJSON() throws {
        let message = ChatMessage(
            role: .assistant,
            content: "hello",
            reasoning: "because you said hi",
            modelDisplayName: "SmolLM2-135M",
            responderName: "Sofia",
            tokensPerSecond: 42.5,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder.anvil.encode(message)
        let decoded = try JSONDecoder.anvil.decode(ChatMessage.self, from: data)

        #expect(decoded == message)
    }

    @Test
    func preservesResponderNameWhenPersisted() throws {
        let message = ChatMessage(
            role: .assistant,
            content: "hello",
            responderName: "Sofia"
        )

        let data = try JSONEncoder.anvil.encode(message)
        let decoded = try JSONDecoder.anvil.decode(ChatMessage.self, from: data)

        #expect(decoded.responderName == "Sofia")
    }

    @Test
    func preservesMemoryProvenanceWhenPersisted() throws {
        let used = UUID()
        let created = UUID()
        let message = ChatMessage(
            role: .assistant,
            content: "answer",
            memoryIDsUsed: [used],
            memoryIDsCreated: [created]
        )

        let data = try JSONEncoder.anvil.encode(message)
        let decoded = try JSONDecoder.anvil.decode(ChatMessage.self, from: data)

        #expect(decoded.memoryIDsUsed == [used])
        #expect(decoded.memoryIDsCreated == [created])
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

    @Test
    func sendsConversationIDAsAnOptionalRoutingHint() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.onRequest = { request in recorder.record(request) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = ChatClient(session: URLSession(configuration: config))

        _ = try? await client.send(
            messages: [ChatMessage(role: .user, content: "hi")],
            baseURL: URL(string: "http://127.0.0.1:9")!,
            conversationID: "thread-123"
        )

        let body = recorder.capturedBody
        let object = try #require(body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(object["conversation_id"] as? String == "thread-123")
    }

    /// The wire format `ChatClient` actually sends is narrower than the
    /// full `ChatMessage` model — only role/content per message, none
    /// of the locally-persisted extras (id, reasoning, modelDisplayName,
    /// tokensPerSecond, createdAt).
    @Test
    func wireMessagesCarryOnlyRoleAndContent() async throws {
        let recorder = RequestRecorder()
        MockURLProtocol.onRequest = { request in recorder.record(request) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = ChatClient(session: URLSession(configuration: config))

        _ = try? await client.send(
            messages: [ChatMessage(role: .user, content: "hi", reasoning: "irrelevant")],
            baseURL: URL(string: "http://127.0.0.1:9")!
        )

        let body = recorder.capturedBody
        let object = try #require(body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let wireMessages = try #require(object["messages"] as? [[String: String]])
        #expect(wireMessages == [["role": "user", "content": "hi"]])
    }

    /// Regression test for a real bug seen against a reasoning model:
    /// when `max_tokens` cuts the response off before the model reaches
    /// its final answer, `mlx_lm.server` sends `"reasoning"` but omits
    /// `"content"` entirely (not even an empty string) — decoding must
    /// not throw. `content` and `reasoning` are kept as separate fields
    /// (the UI has its own hide/show toggle for reasoning) rather than
    /// merged, so a truncated reply surfaces as empty content with the
    /// reasoning preserved on the side.
    @Test
    func keepsReasoningSeparateWhenContentIsAbsent() async throws {
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

        #expect(reply.content.isEmpty)
        #expect(reply.reasoning == "still thinking…")
    }

    @Test
    func keepsBothContentAndReasoningWhenBothArePresent() async throws {
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
        #expect(reply.reasoning == "how I got there")
    }

    @Test
    func recordsWhichModelAnsweredAndAMeasuredTokensPerSecond() async throws {
        MockURLProtocol.responseBody = Data(
            #"{"choices":[{"message":{"role":"assistant","content":"hi"}}],"usage":{"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":7}}}"#.utf8
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = ChatClient(session: URLSession(configuration: config))

        let reply = try await client.send(
            messages: [ChatMessage(role: .user, content: "hi")],
            baseURL: URL(string: "http://127.0.0.1:9")!,
            modelDisplayName: "SmolLM2-135M"
        )

        #expect(reply.modelDisplayName == "SmolLM2-135M")
        #expect(reply.tokensPerSecond != nil)
        #expect(reply.cachedPromptTokens == 7)
    }

    /// Regression test for a real, reported bug: the underlying model
    /// server can stop actually working mid-generation (a hung/crashed
    /// inference loop) without closing the connection or sending
    /// anything else — reported live as memory/GPU use dropping while
    /// Chat sat on "Thinking…" indefinitely. `StallingURLProtocol`
    /// reproduces exactly that shape (one real chunk, then a connection
    /// that never sends anything else and never closes); a tiny
    /// `stallInterval` (0.3s, not the real 120s default) is what keeps
    /// this test fast rather than an actual two-minute wait.
    @Test
    func stallWatchdogSurfacesAHungConnectionInsteadOfWaitingForever() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StallingURLProtocol.self]
        let client = ChatClient(session: URLSession(configuration: config))

        let stream = client.streamSend(
            messages: [ChatMessage(role: .user, content: "hi")],
            baseURL: URL(string: "http://127.0.0.1:9")!,
            stallInterval: 0.3
        )

        var caughtError: Error?
        do {
            for try await _ in stream {}
        } catch {
            caughtError = error
        }

        let servingError = try #require(caughtError as? ServingError)
        guard case .requestFailed(let message) = servingError else {
            Issue.record("expected .requestFailed, got \(servingError)")
            return
        }
        #expect(message.contains("stopped responding"))
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

/// Simulates the exact hang `stallWatchdogSurfacesAHungConnectionInsteadOfWaitingForever`
/// tests: one real SSE chunk, then a connection that never delivers
/// anything else and never closes — `didLoad` is called exactly once,
/// `urlProtocolDidFinishLoading` never at all.
private final class StallingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Data((#"data: {"choices":[{"delta":{"content":"hi"}}]}"# + "\n\n").utf8)
        client?.urlProtocol(self, didLoad: chunk)
        // Deliberately nothing further — no more `didLoad`, no
        // `urlProtocolDidFinishLoading`. `stopLoading()` below still
        // gets called once the watchdog's cancellation reaches this
        // task; that's fine, there's nothing to clean up.
    }

    override func stopLoading() {}
}
