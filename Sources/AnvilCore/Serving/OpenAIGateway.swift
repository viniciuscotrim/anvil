import Foundation

#if os(macOS)
import Network

/// Local OpenAI-compatible router for resident model servers. The model
/// processes remain isolated; this listener only forwards HTTP requests to
/// the endpoint registered for the requested model.
public actor OpenAIGateway {
    public enum RouteKind: Sendable {
        case text
        case image
    }

    public static let port = 8000
    public static let sharedEndpoint = URL(string: "http://127.0.0.1:8000")!
    public let endpoint = OpenAIGateway.sharedEndpoint

    private struct Route: Sendable {
        let endpoint: URL
        let kind: RouteKind
    }

    private var routes: [String: Route] = [:]
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    public init() {}

    public func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(Self.port)) else { return }
        let listener = try NWListener(using: .tcp, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { await self?.listenerFailed(error) }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: DispatchQueue(label: "anvil.openai-gateway"))
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
        routes.removeAll()
    }

    public func register(modelID: String, endpoint: URL, kind: RouteKind = .text) {
        routes[modelID] = Route(endpoint: endpoint, kind: kind)
    }

    public func unregister(modelID: String) {
        routes.removeValue(forKey: modelID)
    }

    public func hasRoute(for modelID: String, kind: RouteKind = .text) -> Bool {
        resolve(modelID: modelID, kind: kind) != nil
    }

    private func listenerFailed(_ error: NWError) {
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: DispatchQueue(label: "anvil.openai-gateway.connection"))
        Task { await handle(connection) }
    }

    private func handle(_ connection: NWConnection) async {
        defer {
            connection.cancel()
            connections.removeAll { $0 === connection }
        }
        do {
            let request = try await receiveRequest(connection)
            guard let route = resolve(modelID: request.model, kind: request.kind) else {
                try await sendJSON(connection, status: 404, payload: ["error": "No resident model matches '\(request.model)'"])
                return
            }
            try await forward(request, to: route.endpoint, over: connection)
        } catch {
            try? await sendJSON(connection, status: 502, payload: ["error": error.localizedDescription])
        }
    }

    private struct IncomingRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        let model: String
        let kind: RouteKind
    }

    private func receiveRequest(_ connection: NWConnection) async throws -> IncomingRequest {
        var data = Data()
        var headerEnd: Range<Data.Index>?
        var contentLength = 0
        while headerEnd == nil || data.count < (headerEnd!.upperBound + contentLength) {
            let chunk = try await receive(connection, maximumLength: 65_536)
            guard !chunk.isEmpty else { throw ServingError.requestFailed("empty gateway request") }
            data.append(chunk)
            if headerEnd == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range
                let headerText = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
                guard let first = lines.first else { throw ServingError.requestFailed("invalid HTTP request") }
                let parts = first.split(separator: " ")
                guard parts.count >= 2 else { throw ServingError.requestFailed("invalid request line") }
                let parsedHeaders = Dictionary(uniqueKeysWithValues: lines.dropFirst().compactMap { line -> (String, String)? in
                    let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
                    guard pieces.count == 2 else { return nil }
                    return (pieces[0].lowercased(), pieces[1].trimmingCharacters(in: .whitespaces))
                })
                contentLength = Int(parsedHeaders["content-length"] ?? "0") ?? 0
                let path = String(parts[1])
                let bodyStart = range.upperBound
                if data.count >= bodyStart + contentLength {
                    return makeRequest(method: String(parts[0]), path: path, headers: parsedHeaders, body: data[bodyStart..<bodyStart + contentLength])
                }
                continue
            }
            if data.count > 8 * 1024 * 1024 { throw ServingError.requestFailed("gateway request is too large") }
        }
        throw ServingError.requestFailed("incomplete HTTP request")
    }

    private func makeRequest(method: String, path: String, headers: [String: String], body: Data) -> IncomingRequest {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let model = object?["model"] as? String ?? "default_model"
        let kind: RouteKind = path.contains("/images/") ? .image : .text
        return IncomingRequest(method: method, path: path, headers: headers, body: body, model: model, kind: kind)
    }

    private func resolve(modelID: String, kind: RouteKind) -> Route? {
        if let route = routes[modelID], sameKind(route.kind, kind) { return route }
        guard modelID == "default_model" else { return nil }
        return routes.values.first { sameKind($0.kind, kind) }
    }

    private func sameKind(_ lhs: RouteKind, _ rhs: RouteKind) -> Bool {
        switch (lhs, rhs) {
        case (.text, .text), (.image, .image): return true
        default: return false
        }
    }

    private func forward(_ request: IncomingRequest, to endpoint: URL, over connection: NWConnection) async throws {
        var urlRequest = URLRequest(url: endpoint.appendingPathComponent(request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = 1800
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accept = request.headers["accept"] { urlRequest.setValue(accept, forHTTPHeaderField: "Accept") }

        if request.headers["accept"]?.contains("text/event-stream") == true {
            let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ServingError.requestFailed("invalid upstream response")
            }
            let header = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
            try await send(connection, data: Data(header.utf8))
            for try await line in bytes.lines {
                try await send(connection, data: Data((line + "\n").utf8))
            }
            return
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw ServingError.requestFailed("invalid upstream response") }
        var header = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\nContent-Type: \(http.value(forHTTPHeaderField: "Content-Type") ?? "application/json")\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        if header.isEmpty { header = "HTTP/1.1 502 Bad Gateway\r\n\r\n" }
        try await send(connection, data: Data(header.utf8) + data)
    }

    private func sendJSON(_ connection: NWConnection, status: Int, payload: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        let header = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        try await send(connection, data: Data(header.utf8) + data)
    }

    private func receive(_ connection: NWConnection, maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if isComplete, data == nil { continuation.resume(returning: Data()) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
#endif
