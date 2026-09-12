import AnvilCore
import Foundation

/// Talks to `AnvilSyncServer` (Mac-only, opt-in) — the phone's half of
/// "resume the same Mac conversation from the iPhone, with profiles and
/// memories inherited and updated on the Mac." Same encoding the Mac's
/// own stores already use (`JSONEncoder.anvil`/`JSONDecoder.anvil`, ISO
/// 8601 dates), so a thread/profile/memory round-tripped through here is
/// byte-for-byte the same shape the Mac would have written itself.
struct AnvilSyncClient {
    private let session: URLSession
    /// Fixed, independent of which model port a `RemoteMacConnection`
    /// happens to use — the sync server is a separate listener on the
    /// same Mac, not tied to any one model's own port.
    static let port = 8090

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func baseURL(host: String) -> URL? {
        URL(string: "http://\(host):\(port)")
    }

    // MARK: - Threads

    func threads(host: String) async throws -> [ChatThread] {
        try await get([ChatThread].self, host: host, path: "threads")
    }

    @discardableResult
    func upsertThread(_ thread: ChatThread, host: String) async throws -> ChatThread {
        try await put(thread, returning: ChatThread.self, host: host, path: "threads")
    }

    func deleteThread(id: UUID, host: String) async throws {
        try await delete(host: host, path: "threads/\(id.uuidString)")
    }

    // MARK: - Profiles

    func profiles(host: String) async throws -> [ChatProfile] {
        try await get([ChatProfile].self, host: host, path: "profiles")
    }

    @discardableResult
    func upsertProfile(_ profile: ChatProfile, host: String) async throws -> ChatProfile {
        try await put(profile, returning: ChatProfile.self, host: host, path: "profiles")
    }

    func deleteProfile(id: UUID, host: String) async throws {
        try await delete(host: host, path: "profiles/\(id.uuidString)")
    }

    // MARK: - Memories

    func memories(host: String) async throws -> [ChatMemory] {
        try await get([ChatMemory].self, host: host, path: "memories")
    }

    @discardableResult
    func upsertMemory(_ memory: ChatMemory, host: String) async throws -> ChatMemory {
        try await put(memory, returning: ChatMemory.self, host: host, path: "memories")
    }

    func deleteMemory(id: UUID, host: String) async throws {
        try await delete(host: host, path: "memories/\(id.uuidString)")
    }

    // MARK: - Model management

    /// Every model registered on the Mac (`ModelRegistry`) — downloaded
    /// or imported there, whether currently loaded or not.
    func models(host: String) async throws -> [ModelEntry] {
        try await get([ModelEntry].self, host: host, path: "models")
    }

    /// Every model actually loaded on the Mac right now, text and image
    /// together — the same live state the Mac's own Models tab shows.
    func sessions(host: String) async throws -> [ModelSessionWire] {
        try await get([ModelSessionWire].self, host: host, path: "sessions")
    }

    private struct LoadBody: Encodable { let modelID: String; let access: ServerAccess; let port: Int? }
    private struct UnloadBody: Encodable { let modelID: String }
    private struct SettingsBody: Encodable { let modelID: String; let access: ServerAccess; let port: Int }

    /// Loads a registered model on the Mac — returns the Mac's full,
    /// current session list afterward (not just this one), so a caller
    /// can refresh its whole view from one response.
    @discardableResult
    func loadModel(modelID: String, access: ServerAccess, port: Int? = nil, host: String) async throws -> [ModelSessionWire] {
        try await post(LoadBody(modelID: modelID, access: access, port: port), path: "sessions/load", host: host)
    }

    @discardableResult
    func unloadModel(modelID: String, host: String) async throws -> [ModelSessionWire] {
        try await post(UnloadBody(modelID: modelID), path: "sessions/unload", host: host)
    }

    /// Reloads an already-loaded model under new Server Settings
    /// (access/port) on the Mac — the same "stop, then start again with
    /// the new settings" the Mac's own gear-icon sheet does. Switching a
    /// Network model to Local-only here means this exact request is the
    /// last one that will ever reach it at that address: the response
    /// itself still arrives (the old connection was already open), but
    /// nothing new will connect afterward.
    @discardableResult
    func updateSessionSettings(modelID: String, access: ServerAccess, port: Int, host: String) async throws -> [ModelSessionWire] {
        try await put(SettingsBody(modelID: modelID, access: access, port: port), returning: [ModelSessionWire].self, host: host, path: "sessions/settings")
    }

    // MARK: - Plumbing

    private func get<Response: Decodable>(_ type: Response.Type, host: String, path: String) async throws -> Response {
        guard let url = Self.baseURL(host: host)?.appendingPathComponent("v1/anvil/\(path)") else {
            throw AnvilSyncClientError.invalidHost
        }
        let (data, response) = try await session.data(from: url)
        try Self.checkStatus(response)
        return try JSONDecoder.anvil.decode(Response.self, from: data)
    }

    private func put<Body: Encodable, Response: Decodable>(
        _ body: Body, returning: Response.Type, host: String, path: String
    ) async throws -> Response {
        guard let url = Self.baseURL(host: host)?.appendingPathComponent("v1/anvil/\(path)") else {
            throw AnvilSyncClientError.invalidHost
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.anvil.encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response)
        return try JSONDecoder.anvil.decode(Response.self, from: data)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ body: Body, path: String, host: String
    ) async throws -> Response {
        guard let url = Self.baseURL(host: host)?.appendingPathComponent("v1/anvil/\(path)") else {
            throw AnvilSyncClientError.invalidHost
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response)
        return try JSONDecoder.anvil.decode(Response.self, from: data)
    }

    private func delete(host: String, path: String) async throws {
        guard let url = Self.baseURL(host: host)?.appendingPathComponent("v1/anvil/\(path)") else {
            throw AnvilSyncClientError.invalidHost
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        try Self.checkStatus(response)
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AnvilSyncClientError.requestFailed(
                "Can't reach Mac sync (HTTP \(statusCode)) — check it's enabled in Settings on the Mac.")
        }
    }
}

enum AnvilSyncClientError: LocalizedError {
    case invalidHost
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "Invalid Mac host."
        case .requestFailed(let reason): return reason
        }
    }
}
