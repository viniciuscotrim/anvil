import Foundation

/// Tracks which models are actually loaded into memory right now — the
/// thing the app was missing: a way to see what's loaded, load one, and
/// unload it, independent of any chat window. Each loaded model gets
/// its own `LLMServer` on its own port, so more than one can be
/// resident at once (a first step toward Phase 5's concurrent
/// residency; there's no memory-budget policy yet, just independent
/// per-model processes).
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
        public var status: Status
        public var id: String { model.id }
    }

    @Published public private(set) var sessions: [Session] = []

    private var servers: [String: LLMServer] = [:]

    public init() {
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

    public func chatEndpoint(for modelID: String) -> URL? {
        guard let session = sessions.first(where: { $0.id == modelID }), session.status == .ready else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(session.port)")
    }

    @discardableResult
    public func load(_ model: ModelEntry, requirements: RequirementsManager) async -> Bool {
        if let existing = sessions.first(where: { $0.id == model.id }) {
            if existing.status == .ready { return true }
            if case .loading = existing.status { return false }
        }

        let port = portForNewSession()
        upsert(Session(model: model, port: port, status: .loading))

        let ready = await requirements.ensure(TextModelRuntimeDependency())
        guard ready else {
            let reason = requirements.lastError ?? "Could not set up text generation"
            upsert(Session(model: model, port: port, status: .failed(reason)))
            return false
        }

        let server = LLMServer()
        do {
            try await server.start(modelPath: model.localPath, displayName: model.displayName, port: port)
            servers[model.id] = server
            upsert(Session(model: model, port: port, status: .ready))
            return true
        } catch {
            upsert(Session(model: model, port: port, status: .failed(error.localizedDescription)))
            return false
        }
    }

    public func unload(modelID: String) async {
        if let server = servers.removeValue(forKey: modelID) {
            await server.stop()
        }
        sessions.removeAll { $0.id == modelID }
    }

    /// Stops every loaded model — called on app quit so no
    /// `mlx_lm.server` process is left running in the background.
    public func unloadAll() async {
        for server in servers.values {
            await server.stop()
        }
        servers.removeAll()
        sessions.removeAll()
    }

    private func portForNewSession() -> Int {
        let used = Set(sessions.map(\.port))
        var candidate = 8000
        while used.contains(candidate) || !PortProbe.isFree(candidate) {
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
