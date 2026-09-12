import AnvilCore
import Foundation

/// One saved way to reach a model already loaded on a Mac on the same
/// network — the Mac side of this needs zero changes: every loaded
/// model already has its own `ServerAccess` (Local only / Network)
/// toggle and its own port (the gear icon next to it in the Mac's
/// Models tab), and setting that to "Network" is the only thing that
/// makes it reachable here. This just remembers host/port/kind so the
/// phone doesn't need retyping them every time.
struct RemoteMacConnection: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var host: String
    var port: Int
    var kind: ModelKind

    init(id: UUID = UUID(), displayName: String, host: String, port: Int, kind: ModelKind) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.kind = kind
    }

    var baseURL: URL? {
        URL(string: "http://\(host):\(port)")
    }
}

/// Its own small JSON file — deliberately not `AppSettings` (a macOS-
/// shared type under active development elsewhere) and not anything
/// else in `AnvilCore`, so this purely-iOS feature can't collide with
/// or need to wait on unrelated Mac-side changes.
@MainActor
final class RemoteMacConnectionStore {
    private let fileURL: URL

    init(fileURL: URL = RuntimePaths.applicationSupportDirectory
        .appendingPathComponent("remote_connections.json")) {
        self.fileURL = fileURL
    }

    func load() -> [RemoteMacConnection] {
        guard let data = try? Data(contentsOf: fileURL),
            let connections = try? JSONDecoder().decode([RemoteMacConnection].self, from: data)
        else { return [] }
        return connections
    }

    func save(_ connections: [RemoteMacConnection]) {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(connections) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
