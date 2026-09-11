import Foundation

/// Tracks which image models are actually loaded into memory — the
/// image-generation counterpart of `ModelSessionManager`, kept separate
/// because it wraps a different server (`ImageServer`/`mflux`, not
/// `LLMServer`/`mlx-lm`) with different load times and settings.
/// Same rules apply: local-only by default, network exposure and a
/// specific port are opt-in.
///
/// Plain `ObservableObject` (not `@Observable`) so it can be held with
/// `@StateObject` — see the `@State` toolchain note in README.
@MainActor
public final class ImageSessionManager: ObservableObject {
    public enum Status: Equatable, Sendable {
        case loading
        case ready
        case failed(String)
    }

    public struct Session: Identifiable, Equatable, Sendable {
        public let model: ModelEntry
        public let port: Int
        public let access: ServerAccess
        public var status: Status
        public var id: String { model.id }
    }

    @Published public private(set) var sessions: [Session] = []

    private var servers: [String: ImageServer] = [:]

    public init() {
        Task { await NamedLauncher.shared.cleanupStaleLaunchers() }
    }

    public var readySessions: [Session] {
        sessions.filter { $0.status == .ready }
    }

    public func isLoaded(modelID: String) -> Bool {
        sessions.contains { $0.id == modelID && $0.status == .ready }
    }

    public func session(for modelID: String) -> Session? {
        sessions.first { $0.id == modelID }
    }

    public func imageEndpoint(for modelID: String) -> URL? {
        guard let session = sessions.first(where: { $0.id == modelID }), session.status == .ready else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(session.port)")
    }

    public func suggestedPort() -> Int {
        // 8200 — the port flux_server.py used, kept as the meaningful
        // starting point here even though nothing is wired to the live
        // stack during this project.
        portForNewSession(access: .localOnly, startingAt: 8200)
    }

    @discardableResult
    public func load(
        _ model: ModelEntry,
        requirements: RequirementsManager,
        access: ServerAccess = .localOnly,
        port: Int? = nil,
        baseModel: String? = nil,
        quantizeBits: Int? = nil
    ) async -> Bool {
        if let existing = sessions.first(where: { $0.id == model.id }) {
            if existing.status == .ready { return true }
            if case .loading = existing.status { return false }
        }

        let resolvedPort = port ?? portForNewSession(access: access, startingAt: 8200)
        guard PortProbe.isFree(resolvedPort, host: access.host) else {
            upsert(Session(
                model: model, port: resolvedPort, access: access,
                status: .failed("Port \(resolvedPort) is already in use — pick another.")
            ))
            return false
        }

        upsert(Session(model: model, port: resolvedPort, access: access, status: .loading))

        let ready = await requirements.ensure(ImageModelRuntimeDependency())
        guard ready else {
            let reason = requirements.lastError ?? "Could not set up image generation"
            upsert(Session(model: model, port: resolvedPort, access: access, status: .failed(reason)))
            return false
        }

        let server = ImageServer()
        do {
            try await server.start(
                modelPath: model.localPath,
                displayName: model.displayName,
                baseModel: baseModel,
                quantizeBits: quantizeBits,
                host: access.host,
                port: resolvedPort
            )
            servers[model.id] = server
            upsert(Session(model: model, port: resolvedPort, access: access, status: .ready))
            return true
        } catch {
            upsert(Session(model: model, port: resolvedPort, access: access, status: .failed(error.localizedDescription)))
            return false
        }
    }

    @discardableResult
    public func updateServerSettings(
        modelID: String,
        requirements: RequirementsManager,
        access: ServerAccess,
        port: Int
    ) async -> Bool {
        guard let model = sessions.first(where: { $0.id == modelID })?.model else { return false }
        await unload(modelID: modelID)
        return await load(model, requirements: requirements, access: access, port: port)
    }

    public func unload(modelID: String) async {
        if let server = servers.removeValue(forKey: modelID) {
            await server.stop()
        }
        sessions.removeAll { $0.id == modelID }
    }

    /// Stops every loaded image model — called on app quit alongside
    /// `ModelSessionManager.unloadAll()` so nothing is left running.
    public func unloadAll() async {
        for server in servers.values {
            await server.stop()
        }
        servers.removeAll()
        sessions.removeAll()
    }

    private func portForNewSession(access: ServerAccess, startingAt: Int) -> Int {
        let used = Set(sessions.map(\.port))
        var candidate = startingAt
        while used.contains(candidate) || !PortProbe.isFree(candidate, host: access.host) {
            candidate += 1
        }
        return candidate
    }

    private func upsert(_ session: Session) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }
}
