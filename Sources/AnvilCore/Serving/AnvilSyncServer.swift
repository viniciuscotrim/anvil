import Foundation

#if os(macOS)
import Network

/// A small, separate, **opt-in** REST server exposing the Mac's own
/// already-existing `ChatThreadStore`/`ChatProfileStore`/`ChatMemoryStore`
/// over the network — the only way "resume the same Mac conversation
/// from the iPhone, with profiles/memories inherited and updated on the
/// Mac even though the iPhone is the input device" can be real, since
/// nothing else the Mac already runs does this: `OpenAIGateway` only
/// routes model requests, has no notion of threads/profiles/memories at
/// all, and always talks to itself over its own fixed loopback URL
/// regardless of any model's own Network setting.
///
/// Off by default, its own separate listener on its own port — starting
/// or stopping this never touches any existing route, server, or
/// behavior `OpenAIGateway`/`LLMServer`/`ImageServerScript` already
/// provide. No new persistence or data model either: this is a thin
/// network wrapper directly over the three stores already on disk, so a
/// thread/profile/memory read or written here is the exact same one the
/// Mac app's own Chat/Profiles/Memory tabs already show.
///
/// Also the control surface for remote model management: which models
/// are registered, which are loaded, and loading/unloading/reconfiguring
/// one — all through the exact same shared `ModelSessionManager`/
/// `ImageSessionManager` instances the Mac app's own Models tab already
/// uses, never a separate/parallel set of sessions the Mac's own UI
/// wouldn't see. Changing a loaded model's access from Network to Local
/// here does exactly what doing it from the Mac's own gear-icon sheet
/// does — the server actually rebinds to loopback-only — so a phone
/// connected to it over the network genuinely loses that connection,
/// not just a UI label change.
///
/// Routes (JSON in/out, the same `JSONEncoder.anvil`/`JSONDecoder.anvil`
/// the stores already use for persistence):
/// ```
/// GET    /v1/anvil/threads          -> [ChatThread]
/// PUT    /v1/anvil/threads          <- ChatThread   (upsert one)
/// DELETE /v1/anvil/threads/{id}
/// GET    /v1/anvil/profiles         -> [ChatProfile]
/// PUT    /v1/anvil/profiles         <- ChatProfile  (upsert one)
/// DELETE /v1/anvil/profiles/{id}
/// GET    /v1/anvil/memories         -> [ChatMemory]
/// PUT    /v1/anvil/memories         <- ChatMemory   (upsert one)
/// DELETE /v1/anvil/memories/{id}
/// GET    /v1/anvil/models           -> [ModelEntry]           (every registered model)
/// GET    /v1/anvil/sessions         -> [ModelSessionWire]      (every currently loaded one)
/// POST   /v1/anvil/sessions/load    <- {modelID, access, port?}
/// POST   /v1/anvil/sessions/unload  <- {modelID}
/// PUT    /v1/anvil/sessions/settings <- {modelID, access, port} (reload under new access/port)
/// ```
/// Last-write-wins on conflicting edits, matching the stores' own
/// `upsert` semantics already — no new merge/CRDT logic, an
/// appropriately scoped simplification for a single-user, two-device
/// setup.
public actor AnvilSyncServer {
    public static let port = 8090

    private let threadStore: ChatThreadStore
    private let profileStore: ChatProfileStore
    private let memoryStore: ChatMemoryStore
    private let modelRegistry: ModelRegistry?
    private let sessions: ModelSessionManager?
    private let imageSessions: ImageSessionManager?
    private let requirements: RequirementsManager?
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    /// `modelRegistry`/`sessions`/`imageSessions`/`requirements` are the
    /// app's own shared instances (from `AppState`) — nil only makes the
    /// model-management routes answer 404 instead of crashing; the
    /// thread/profile/memory routes above work regardless, unaffected.
    public init(
        threadStore: ChatThreadStore = ChatThreadStore(),
        profileStore: ChatProfileStore = ChatProfileStore(),
        memoryStore: ChatMemoryStore = ChatMemoryStore(),
        modelRegistry: ModelRegistry? = nil,
        sessions: ModelSessionManager? = nil,
        imageSessions: ImageSessionManager? = nil,
        requirements: RequirementsManager? = nil
    ) {
        self.threadStore = threadStore
        self.profileStore = profileStore
        self.memoryStore = memoryStore
        self.modelRegistry = modelRegistry
        self.sessions = sessions
        self.imageSessions = imageSessions
        self.requirements = requirements
    }

    /// `access` genuinely restricts the bind address (unlike a bare
    /// `NWListener`, which listens on every interface by default) —
    /// `.localOnly` sets `requiredLocalEndpoint` to loopback explicitly,
    /// the same real boundary every per-model server already gives the
    /// user via its own Local-only/Network toggle.
    public func start(access: ServerAccess) throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(Self.port)) else { return }
        let parameters = NWParameters.tcp
        if access == .localOnly {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        }
        let listener = try NWListener(using: parameters, on: port)
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { await self?.listenerFailed() }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: DispatchQueue(label: "anvil.sync-server"))
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }

    public var isRunning: Bool { listener != nil }

    private func listenerFailed() {
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: DispatchQueue(label: "anvil.sync-server.connection"))
        Task { await handle(connection) }
    }

    private func handle(_ connection: NWConnection) async {
        defer {
            connection.cancel()
            connections.removeAll { $0 === connection }
        }
        do {
            let request = try await receiveRequest(connection)
            let response = try await route(request)
            try await send(connection, status: response.status, payload: response.body)
        } catch {
            try? await send(connection, status: 500, payload: try? JSONEncoder.anvil.encode(["error": error.localizedDescription]))
        }
    }

    // MARK: - Routing

    private struct RouteResponse { let status: Int; let body: Data? }

    private func route(_ request: IncomingRequest) async throws -> RouteResponse {
        let segments = request.path.split(separator: "/").map(String.init)
        // Expect ["v1", "anvil", "<collection>"] or [...,"<collection>", "<id>"]
        guard segments.count >= 3, segments[0] == "v1", segments[1] == "anvil" else {
            return RouteResponse(status: 404, body: try JSONEncoder.anvil.encode(["error": "not found"]))
        }
        let collection = segments[2]
        let idSegment = segments.count > 3 ? segments[3] : nil

        switch (request.method, collection, idSegment) {
        case ("GET", "threads", nil):
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await threadStore.all()))
        case ("PUT", "threads", nil):
            let thread = try JSONDecoder.anvil.decode(ChatThread.self, from: request.body)
            let saved = try await threadStore.upsert(thread)
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(saved))
        case ("DELETE", "threads", .some(let idString)):
            guard let id = UUID(uuidString: idString) else { return RouteResponse(status: 400, body: nil) }
            try await threadStore.delete(id: id)
            return RouteResponse(status: 204, body: nil)

        case ("GET", "profiles", nil):
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await profileStore.all()))
        case ("PUT", "profiles", nil):
            let profile = try JSONDecoder.anvil.decode(ChatProfile.self, from: request.body)
            let saved = try await profileStore.upsert(profile)
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(saved))
        case ("DELETE", "profiles", .some(let idString)):
            guard let id = UUID(uuidString: idString) else { return RouteResponse(status: 400, body: nil) }
            try await profileStore.delete(id: id)
            return RouteResponse(status: 204, body: nil)

        case ("GET", "memories", nil):
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await memoryStore.all()))
        case ("PUT", "memories", nil):
            let memory = try JSONDecoder.anvil.decode(ChatMemory.self, from: request.body)
            let saved = try await memoryStore.upsert(memory)
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(saved))
        case ("DELETE", "memories", .some(let idString)):
            guard let id = UUID(uuidString: idString) else { return RouteResponse(status: 400, body: nil) }
            try await memoryStore.delete(id: id)
            return RouteResponse(status: 204, body: nil)

        case ("GET", "models", nil):
            guard let modelRegistry else { return RouteResponse(status: 404, body: nil) }
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await modelRegistry.all()))

        case ("GET", "sessions", nil):
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await allSessionWires()))

        case ("POST", "sessions", .some("load")):
            return try await handleLoad(request.body)

        case ("POST", "sessions", .some("unload")):
            return try await handleUnload(request.body)

        case ("PUT", "sessions", .some("settings")):
            return try await handleUpdateSettings(request.body)

        default:
            return RouteResponse(status: 404, body: try JSONEncoder.anvil.encode(["error": "not found"]))
        }
    }

    // MARK: - Model management

    private struct LoadRequest: Decodable { let modelID: String; let access: ServerAccess; let port: Int? }
    private struct UnloadRequest: Decodable { let modelID: String }
    private struct SettingsRequest: Decodable { let modelID: String; let access: ServerAccess; let port: Int }

    private func allSessionWires() async -> [ModelSessionWire] {
        var wires: [ModelSessionWire] = []
        if let sessions {
            for session in await sessions.sessions {
                wires.append(Self.wire(id: session.id, name: session.model.displayName, kind: .text, port: session.port, access: session.access, status: session.status))
            }
        }
        if let imageSessions {
            for session in await imageSessions.sessions {
                wires.append(Self.wire(id: session.id, name: session.model.displayName, kind: .image, port: session.port, access: session.access, status: session.status))
            }
        }
        return wires
    }

    private static func wire(id: String, name: String, kind: ModelKind, port: Int, access: ServerAccess, status: ModelSessionManager.Status) -> ModelSessionWire {
        switch status {
        case .loading: return ModelSessionWire(modelID: id, displayName: name, kind: kind, port: port, access: access, statusLabel: "loading", statusDetail: nil)
        case .ready: return ModelSessionWire(modelID: id, displayName: name, kind: kind, port: port, access: access, statusLabel: "ready", statusDetail: nil)
        case .failed(let reason): return ModelSessionWire(modelID: id, displayName: name, kind: kind, port: port, access: access, statusLabel: "failed", statusDetail: reason)
        }
    }

    private static func wire(id: String, name: String, kind: ModelKind, port: Int, access: ServerAccess, status: ImageSessionManager.Status) -> ModelSessionWire {
        switch status {
        case .loading: return ModelSessionWire(modelID: id, displayName: name, kind: kind, port: port, access: access, statusLabel: "loading", statusDetail: nil)
        case .ready: return ModelSessionWire(modelID: id, displayName: name, kind: kind, port: port, access: access, statusLabel: "ready", statusDetail: nil)
        case .failed(let reason): return ModelSessionWire(modelID: id, displayName: name, kind: kind, port: port, access: access, statusLabel: "failed", statusDetail: reason)
        }
    }

    private func handleLoad(_ body: Data) async throws -> RouteResponse {
        guard let modelRegistry, let sessions, let imageSessions, let requirements else {
            return RouteResponse(status: 404, body: nil)
        }
        let payload = try JSONDecoder().decode(LoadRequest.self, from: body)
        guard let entry = await modelRegistry.all().first(where: { $0.id == payload.modelID }) else {
            return RouteResponse(status: 404, body: try JSONEncoder.anvil.encode(["error": "no such registered model"]))
        }
        let ok: Bool
        switch entry.kind {
        case .text:
            ok = await sessions.load(entry, requirements: requirements, access: payload.access, port: payload.port)
        case .image:
            ok = await imageSessions.load(entry, requirements: requirements, access: payload.access, port: payload.port)
        }
        return RouteResponse(status: ok ? 200 : 502, body: try JSONEncoder.anvil.encode(await allSessionWires()))
    }

    private func handleUnload(_ body: Data) async throws -> RouteResponse {
        guard let sessions, let imageSessions else { return RouteResponse(status: 404, body: nil) }
        let payload = try JSONDecoder().decode(UnloadRequest.self, from: body)
        await sessions.unload(modelID: payload.modelID)
        await imageSessions.unload(modelID: payload.modelID)
        return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await allSessionWires()))
    }

    private func handleUpdateSettings(_ body: Data) async throws -> RouteResponse {
        guard let sessions, let imageSessions, let requirements else { return RouteResponse(status: 404, body: nil) }
        let payload = try JSONDecoder().decode(SettingsRequest.self, from: body)
        let ok: Bool
        if await sessions.session(for: payload.modelID) != nil {
            ok = await sessions.updateServerSettings(modelID: payload.modelID, requirements: requirements, access: payload.access, port: payload.port)
        } else if await imageSessions.session(for: payload.modelID) != nil {
            ok = await imageSessions.updateServerSettings(modelID: payload.modelID, requirements: requirements, access: payload.access, port: payload.port)
        } else {
            return RouteResponse(status: 404, body: try JSONEncoder.anvil.encode(["error": "that model isn't loaded"]))
        }
        return RouteResponse(status: ok ? 200 : 502, body: try JSONEncoder.anvil.encode(await allSessionWires()))
    }

    // MARK: - Minimal HTTP over NWConnection
    //
    // Same raw request-parsing/response-writing shape `OpenAIGateway`
    // already uses (deliberately not shared code — that type forwards
    // to an upstream server, this one answers directly, and duplicating
    // ~40 lines of parsing here is a smaller risk than coupling two
    // independent servers to one shared helper for a single-file win).

    private struct IncomingRequest {
        let method: String
        let path: String
        let body: Data
    }

    private func receiveRequest(_ connection: NWConnection) async throws -> IncomingRequest {
        var data = Data()
        var headerEnd: Range<Data.Index>?
        var contentLength = 0
        var method = ""
        var path = ""
        while headerEnd == nil || data.count < (headerEnd!.upperBound + contentLength) {
            let chunk = try await receive(connection, maximumLength: 65_536)
            guard !chunk.isEmpty else { throw ServingError.requestFailed("empty sync-server request") }
            data.append(chunk)
            if headerEnd == nil, let range = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range
                let headerText = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
                guard let first = lines.first else { throw ServingError.requestFailed("invalid HTTP request") }
                let parts = first.split(separator: " ")
                guard parts.count >= 2 else { throw ServingError.requestFailed("invalid request line") }
                let headers = Dictionary(uniqueKeysWithValues: lines.dropFirst().compactMap { line -> (String, String)? in
                    let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
                    guard pieces.count == 2 else { return nil }
                    return (pieces[0].lowercased(), pieces[1].trimmingCharacters(in: .whitespaces))
                })
                contentLength = Int(headers["content-length"] ?? "0") ?? 0
                method = String(parts[0])
                path = String(parts[1])
            }
            if let headerEnd, data.count >= headerEnd.upperBound + contentLength {
                let bodyStart = headerEnd.upperBound
                return IncomingRequest(method: method, path: path, body: data[bodyStart..<bodyStart + contentLength])
            }
            if data.count > 8 * 1024 * 1024 { throw ServingError.requestFailed("sync-server request is too large") }
        }
        throw ServingError.requestFailed("incomplete HTTP request")
    }

    private func send(_ connection: NWConnection, status: Int, payload: Data?) async throws {
        let body = payload ?? Data()
        let header = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        try await send(connection, data: Data(header.utf8) + body)
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
