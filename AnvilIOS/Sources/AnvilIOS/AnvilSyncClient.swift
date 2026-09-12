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
