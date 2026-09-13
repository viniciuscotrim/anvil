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
        // POST /v1/anvil/threads/{id}/generate — a 5-segment route, ahead
        // of the general dispatch below (which only ever looks at a
        // 4th segment).
        if request.method == "POST", segments.count == 5, segments[2] == "threads", segments[4] == "generate",
            let threadID = UUID(uuidString: segments[3]) {
            return try await handleGenerate(threadID: threadID, body: request.body)
        }

        let collection = segments[2]
        let idSegment = segments.count > 3 ? segments[3] : nil

        switch (request.method, collection, idSegment) {
        case ("GET", "threads", nil):
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await threadStore.all()))
        case ("GET", "threads", .some("deleted")):
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await threadStore.deletionTimestamps()))
        case ("PUT", "threads", nil):
            // `upsertPreservingTimestamp`, not `upsert`: this is a
            // replicated write, not a local edit — the incoming
            // `updatedAt` is the actual moment that content was
            // created, on whichever device sent it. Restamping it to
            // "now" here is exactly the bug that let a stale copy look
            // newer than genuinely newer content on a later comparison
            // — see `ChatThreadStore.upsertPreservingTimestamp`'s doc
            // comment. A recency guard on top: don't let an
            // out-of-order/stale PUT regress content we already have.
            let thread = try JSONDecoder.anvil.decode(ChatThread.self, from: request.body)
            if let existing = await threadStore.get(id: thread.id), existing.updatedAt >= thread.updatedAt {
                return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(existing))
            }
            let saved = try await threadStore.upsertPreservingTimestamp(thread)
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(saved))
        case ("DELETE", "threads", .some(let idString)):
            guard let id = UUID(uuidString: idString) else { return RouteResponse(status: 400, body: nil) }
            try await threadStore.delete(id: id)
            return RouteResponse(status: 204, body: nil)

        case ("GET", "profiles", nil):
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await profileStore.all()))
        case ("GET", "profiles", .some("deleted")):
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await profileStore.deletionTimestamps()))
        case ("PUT", "profiles", nil):
            // No recency guard here: `ChatProfile` carries no
            // `updatedAt` to arbitrate a same-ID edit conflict with
            // (see `ProfilesViewModel.mergeSync`'s own doc comment) —
            // a genuinely rare case for something usually created once,
            // not repeatedly edited from two devices at once.
            let profile = try JSONDecoder.anvil.decode(ChatProfile.self, from: request.body)
            let saved = try await profileStore.upsert(profile)
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(saved))
        case ("DELETE", "profiles", .some(let idString)):
            guard let id = UUID(uuidString: idString) else { return RouteResponse(status: 400, body: nil) }
            try await profileStore.delete(id: id)
            return RouteResponse(status: 204, body: nil)

        case ("GET", "memories", nil):
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await memoryStore.all()))
        case ("GET", "memories", .some("deleted")):
            return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(await memoryStore.deletionTimestamps()))
        case ("PUT", "memories", nil):
            let memory = try JSONDecoder.anvil.decode(ChatMemory.self, from: request.body)
            if let existing = await memoryStore.all().first(where: { $0.id == memory.id }), existing.updatedAt >= memory.updatedAt {
                return RouteResponse(status: 200, body: try JSONEncoder.anvil.encode(existing))
            }
            let saved = try await memoryStore.upsertPreservingTimestamp(memory)
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

    /// Triggers a reply on this Mac's own hardware, against its own
    /// loopback address — never the connection this request arrived
    /// over. That's the entire point: once this returns, generation
    /// keeps running as a plain background `Task`, completely detached
    /// from whichever phone (or Mac window) asked for it, so it
    /// survives that device losing its network connection, backgrounding
    /// the app, or closing it outright — the same guarantee the Mac's
    /// own interactive chat already has for free (it's never depended
    /// on a phone's connection to begin with). The caller gets the
    /// thread back immediately with the pending assistant placeholder
    /// already in it; the real content shows up once this Mac's own
    /// `ChatThreadStore` is updated, picked up by the ordinary merge/
    /// polling path like any other change to a thread.
    ///
    /// Deliberately narrower than the Mac's own interactive chat for
    /// now: no `generate_image` tool-calling here (that needs an image
    /// session to route to, and this endpoint doesn't take one) — a
    /// reasonable v1 scope cut given the actual ask ("keep generating
    /// even if my phone disconnects"), not an oversight.
    private struct GenerateRequest: Decodable { let modelID: String }

    private func handleGenerate(threadID: UUID, body: Data) async throws -> RouteResponse {
        guard let sessions else { return RouteResponse(status: 404, body: nil) }
        let payload = try JSONDecoder().decode(GenerateRequest.self, from: body)
        guard var thread = await threadStore.get(id: threadID) else {
            return RouteResponse(status: 404, body: try JSONEncoder.anvil.encode(["error": "no such thread"]))
        }
        guard let endpoint = await sessions.chatEndpoint(for: payload.modelID) else {
            return RouteResponse(status: 404, body: try JSONEncoder.anvil.encode(["error": "that model isn't loaded on this Mac"]))
        }
        let modelDisplayName = await sessions.session(for: payload.modelID)?.model.displayName ?? payload.modelID

        let placeholder = ChatMessage(role: .assistant, content: "", modelDisplayName: modelDisplayName)
        thread.messages.append(placeholder)
        thread = try await threadStore.upsert(thread)

        let threadStoreRef = threadStore
        let profileStoreRef = profileStore
        let memoryStoreRef = memoryStore
        let capturedThreadID = thread.id
        let placeholderID = placeholder.id
        Task.detached {
            await Self.runBackgroundGeneration(
                threadID: capturedThreadID, placeholderID: placeholderID, endpoint: endpoint,
                modelDisplayName: modelDisplayName, threadStore: threadStoreRef,
                profileStore: profileStoreRef, memoryStore: memoryStoreRef)
        }

        return RouteResponse(status: 202, body: try JSONEncoder.anvil.encode(thread))
    }

    /// Runs entirely independent of `AnvilSyncServer`'s own actor and
    /// of any live `NWConnection` — a `static` function taking only
    /// plain values/actors it needs, specifically so nothing here can
    /// accidentally capture (and so depend on the lifetime of) the
    /// connection that originally triggered it.
    private static func runBackgroundGeneration(
        threadID: UUID, placeholderID: UUID, endpoint: URL, modelDisplayName: String,
        threadStore: ChatThreadStore, profileStore: ChatProfileStore, memoryStore: ChatMemoryStore
    ) async {
        guard let thread = await threadStore.get(id: threadID) else { return }
        var profile: ChatProfile?
        if let profileID = thread.profileID {
            profile = await profileStore.get(id: profileID)
        }
        let allMemories = await memoryStore.all()
        let scopedMemories = allMemories.filter { $0.profileID == nil || $0.profileID == thread.profileID }

        let settings = AppSettings.load()
        let contextBuilder = ChatContextBuilder(
            maxEstimatedTokens: settings.chatMaxEstimatedContextTokens, recentMessageCount: settings.chatRecentMessageCount)
        // Excludes the placeholder itself — it's empty and would
        // otherwise become the "current" message the context builder
        // preserves, the same class of bug already fixed in the
        // interactive chat loops (a request must end with the user's
        // real latest message).
        let historyMessages = thread.messages.filter { $0.id != placeholderID }
        let context = contextBuilder.build(messages: historyMessages, memories: scopedMemories)

        var systemPromptParts: [String] = []
        if let prompt = profile?.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            systemPromptParts.append(prompt)
        }
        if let memoryPrompt = context.memoryPrompt, !memoryPrompt.isEmpty {
            systemPromptParts.append(memoryPrompt)
        }
        let systemPrompt = systemPromptParts.isEmpty ? nil : systemPromptParts.joined(separator: "\n\n")

        do {
            // A real, reproduced bug this bounded timeout fixes: this
            // placeholder is written to disk immediately, and nothing
            // else ever revisits it — if the detached task below never
            // throws and never returns (a genuinely stuck network call,
            // confirmed against a live conversation: both this Mac's
            // model server and the app itself fully idle, no crash, no
            // log line, just an empty placeholder sitting there
            // indefinitely), the placeholder was stuck that way
            // forever, indistinguishable from "still generating" to
            // whoever's looking at it. `ChatClient.send`'s own
            // 1800s/30-minute URLSession timeout is meant to be the
            // backstop for a slow-but-progressing request, not "the
            // longest a user should ever wait to find out this failed
            // silently" — so this races it against a much shorter,
            // user-reasonable bound and always resolves the placeholder
            // either way.
            var reply = try await Self.withTimeout(seconds: 300) {
                try await ChatClient().send(
                    messages: context.messages, baseURL: endpoint, modelDisplayName: modelDisplayName,
                    settings: .default, systemPrompt: systemPrompt, conversationID: threadID.uuidString)
            }
            if reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (reply.toolCalls?.isEmpty ?? true) {
                throw ServingError.requestFailed("The model returned an empty response.")
            }
            reply.responderName = profile?.name
            reply.memoryIDsUsed = context.memoryIDs
            await Self.replacePlaceholder(threadID: threadID, placeholderID: placeholderID, with: reply, threadStore: threadStore)
        } catch {
            let failure = ChatMessage(
                role: .assistant, content: "Error: \(error.localizedDescription)", modelDisplayName: modelDisplayName)
            await Self.replacePlaceholder(threadID: threadID, placeholderID: placeholderID, with: failure, threadStore: threadStore)
        }
    }

    /// Races `operation` against a plain `Task.sleep` — whichever
    /// finishes first wins, and the loser is cancelled. Generic enough
    /// to reuse anywhere a background call needs a harder, more
    /// user-reasonable bound than whatever timeout the underlying
    /// transport (URLSession here) already has.
    private static func withTimeout<T: Sendable>(
        seconds: UInt64, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw ServingError.requestFailed("Timed out after \(seconds)s with no response.")
            }
            guard let result = try await group.next() else {
                throw ServingError.requestFailed("Timed out after \(seconds)s with no response.")
            }
            group.cancelAll()
            return result
        }
    }

    /// Re-reads the thread fresh right before writing back rather than
    /// reusing an earlier snapshot — something else (the Mac's own
    /// interactive chat, another sync write) could plausibly have
    /// changed this same thread while generation was running; this way
    /// only the one placeholder message this call owns gets touched.
    private static func replacePlaceholder(
        threadID: UUID, placeholderID: UUID, with message: ChatMessage, threadStore: ChatThreadStore
    ) async {
        guard var latest = await threadStore.get(id: threadID) else { return }
        if let index = latest.messages.firstIndex(where: { $0.id == placeholderID }) {
            latest.messages[index] = message
        } else {
            latest.messages.append(message)
        }
        _ = try? await threadStore.upsert(latest)
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
