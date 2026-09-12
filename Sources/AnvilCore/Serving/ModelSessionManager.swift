import Foundation

// macOS-only: wraps LLMServer/ImageServer, both Process-based (see
// their own file headers) — doesn't exist on iOS at all today. The
// iOS chat/image UI will need an iOS-native session manager backed
// by in-process mlx-swift inference instead of this subprocess-
// server model.
#if os(macOS)

/// Tracks which models are actually loaded into memory right now — the
/// thing the app was missing: a way to see what's loaded, load one, and
/// unload it, independent of any chat window. Each loaded model gets
/// its own `LLMServer` on its own port, so more than one can be
/// resident at once (a first step toward Phase 5's concurrent
/// residency; there's no memory-budget policy yet, just independent
/// per-model processes).
///
/// Every load is local-only (127.0.0.1) with an auto-picked port unless
/// the caller explicitly asks otherwise — network exposure and a
/// specific port are opt-in, never the default.
///
/// Plain `ObservableObject` (not `@Observable`) so it can be held with
/// `@StateObject` — see the `@State` toolchain note in README.
@MainActor
public final class ModelSessionManager: ObservableObject {
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

    private var servers: [String: LLMServer] = [:]
    private let residency: ResidencyPlanner
    private let gateway: OpenAIGateway?

    public init(residency: ResidencyPlanner = ResidencyPlanner(), gateway: OpenAIGateway? = nil) {
        self.residency = residency
        self.gateway = gateway
        // Best-effort: clean up launcher symlinks a previous run left
        // behind (a crash, a force-quit) — harmless either way, each
        // gets recreated the next time that model loads.
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

    /// Always the loopback address for Anvil's own in-app chat — a
    /// server bound to 0.0.0.0 still answers on 127.0.0.1, so the app
    /// never needs to care which access mode a session is using.
    public func chatEndpoint(for modelID: String) -> URL? {
        guard let session = sessions.first(where: { $0.id == modelID }), session.status == .ready else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(session.port)")
    }

    public func gatewayEndpoint(for modelID: String) -> URL? {
        guard gateway != nil, isLoaded(modelID: modelID) else { return nil }
        return OpenAIGateway.sharedEndpoint
    }

    /// Suggests the next free local port, starting at 8000 — a
    /// starting point for a settings UI to offer, not a value forced
    /// on the user.
    public func suggestedPort() -> Int {
        portForNewSession(access: .localOnly)
    }

    @discardableResult
    public func load(
        _ model: ModelEntry,
        requirements: RequirementsManager,
        access: ServerAccess = .localOnly,
        port: Int? = nil
    ) async -> Bool {
        if let existing = sessions.first(where: { $0.id == model.id }) {
            if existing.status == .ready { return true }
            if case .loading = existing.status { return false }
        }

        guard residency.reserve(model) else {
            upsert(Session(
                model: model,
                port: port ?? portForNewSession(access: access),
                access: access,
                status: .failed("Not enough unified memory for this model. Unload another model first."
                    + " Estimated need: \(ByteCountFormatter.string(fromByteCount: residency.estimate(for: model), countStyle: .memory)).")
            ))
            return false
        }

        let resolvedPort = port ?? portForNewSession(access: access)
        guard PortProbe.isFree(resolvedPort, host: access.host) else {
            residency.release(modelID: model.id)
            upsert(Session(
                model: model, port: resolvedPort, access: access,
                status: .failed("Port \(resolvedPort) is already in use — pick another.")
            ))
            return false
        }

        upsert(Session(model: model, port: resolvedPort, access: access, status: .loading))

        let ready = await requirements.ensure(TextModelRuntimeDependency())
        guard ready else {
            residency.release(modelID: model.id)
            let reason = requirements.lastError ?? "Could not set up text generation"
            upsert(Session(model: model, port: resolvedPort, access: access, status: .failed(reason)))
            return false
        }

        let server = LLMServer()
        do {
            try await server.start(
                modelPath: model.localPath,
                displayName: model.displayName,
                host: access.host,
                port: resolvedPort
            )
            servers[model.id] = server
            if let gateway {
                await gateway.register(
                    modelID: model.id,
                    endpoint: URL(string: "http://127.0.0.1:\(resolvedPort)")!
                )
            }
            if let pid = await server.processIdentifier {
                residency.updateMeasuredResidentBytes(
                    modelID: model.id,
                    bytes: ProcessMemoryUsage.residentBytes(pid: pid)
                )
            }
            upsert(Session(model: model, port: resolvedPort, access: access, status: .ready))
            return true
        } catch {
            residency.release(modelID: model.id)
            upsert(Session(model: model, port: resolvedPort, access: access, status: .failed(error.localizedDescription)))
            return false
        }
    }

    /// Stops and reloads an already-loaded model under new server
    /// settings (port and/or access). A no-op port/access change still
    /// does a full restart — simplest correct behavior, and reloading a
    /// model that's already resident in the OS file cache is fast.
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
        if let gateway { await gateway.unregister(modelID: modelID) }
        sessions.removeAll { $0.id == modelID }
        residency.release(modelID: modelID)
    }

    /// Stops every loaded model — called on app quit so no
    /// `mlx_lm.server` process is left running in the background.
    public func unloadAll() async {
        let modelIDs = sessions.map(\.id)
        for server in servers.values {
            await server.stop()
        }
        servers.removeAll()
        if let gateway {
            for modelID in modelIDs {
                await gateway.unregister(modelID: modelID)
            }
        }
        sessions.removeAll()
        for modelID in modelIDs {
            residency.release(modelID: modelID)
        }
    }

    private func portForNewSession(access: ServerAccess) -> Int {
        let used = Set(sessions.map(\.port))
        var candidate = 8100
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

#endif
