import Foundation
import Testing
@testable import AnvilCore

@Suite("ChatTool")
struct ChatToolTests {
    @Test
    func generateImageWireShapeMatchesOpenAIToolFormat() throws {
        let data = try JSONEncoder().encode(ChatTool.generateImage.wireRepresentation)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["type"] as? String == "function")
        let function = object?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "generate_image")
        let parameters = function?["parameters"] as? [String: Any]
        #expect(parameters?["type"] as? String == "object")
        #expect((parameters?["required"] as? [String])?.contains("prompt") == true)
        let properties = parameters?["properties"] as? [String: Any]
        #expect((properties?["prompt"] as? [String: Any])?["type"] as? String == "string")
    }
}

@Suite("ChatClient tools", .serialized)
struct ChatClientToolTests {
    @Test
    func sendsToolsOnlyWhenProvided() async throws {
        let recorder = ToolCallRecorder()
        MockToolURLProtocol.onRequest = { request in recorder.record(request) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockToolURLProtocol.self]
        let client = ChatClient(session: URLSession(configuration: config))

        _ = try? await client.send(
            messages: [ChatMessage(role: .user, content: "hi")],
            baseURL: URL(string: "http://127.0.0.1:9")!
        )

        let body = recorder.capturedBody
        let object = try #require(body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(object["tools"] == nil)
    }

    @Test
    func decodesToolCallsFromTheResponse() async throws {
        MockToolURLProtocol.responseBody = Data(
            #"""
            {"choices":[{"message":{"role":"assistant","content":"",
            "tool_calls":[{"id":"call_1","type":"function","function":{"name":"generate_image","arguments":"{\"prompt\":\"a red apple\"}"}}]
            }}]}
            """#.utf8
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockToolURLProtocol.self]
        let client = ChatClient(session: URLSession(configuration: config))

        let reply = try await client.send(
            messages: [ChatMessage(role: .user, content: "draw a red apple")],
            baseURL: URL(string: "http://127.0.0.1:9")!,
            tools: [.generateImage]
        )

        let call = try #require(reply.toolCalls?.first)
        #expect(call.name == "generate_image")
        #expect(call.argumentsJSON.contains("a red apple"))
    }
}

private final class ToolCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _capturedBody: Data?
    var capturedBody: Data? {
        lock.lock(); defer { lock.unlock() }
        return _capturedBody
    }
    func record(_ request: URLRequest) {
        let body = request.httpBodyStreamData() ?? request.httpBody
        lock.lock(); _capturedBody = body; lock.unlock()
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

private final class MockToolURLProtocol: URLProtocol, @unchecked Sendable {
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
