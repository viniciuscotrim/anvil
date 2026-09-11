import Foundation
import Testing
@testable import AnvilCore
#if canImport(Darwin)
import Darwin
#endif

/// Only the port-conflict path is covered here — it's checked and
/// fails before `load()` ever touches Python or spawns a process, so
/// it's fast and fully isolated. Actually loading a model needs a real
/// venv + mlx-lm and is validated by hand (see README) the same way
/// `LLMServer`'s own process lifecycle is.
@Suite("ModelSessionManager")
@MainActor
struct ModelSessionManagerTests {
    @Test
    func loadFailsCleanlyWhenTheRequestedPortIsAlreadyInUse() async throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bound == 0)
        listen(sock, 1)

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(sock, $0, &len)
            }
        }
        let occupiedPort = Int(in_port_t(bigEndian: boundAddr.sin_port))

        let sessions = ModelSessionManager()
        let model = ModelEntry(
            id: "org/model",
            displayName: "org/model",
            source: .huggingFace(repoID: "org/model", revision: "main"),
            localPath: "/tmp/does-not-matter",
            sizeBytes: nil
        )

        let ok = await sessions.load(model, requirements: RequirementsManager(), access: .localOnly, port: occupiedPort)

        #expect(!ok)
        if case .failed(let reason) = sessions.session(for: model.id)?.status {
            #expect(reason.contains("\(occupiedPort)"))
        } else {
            Issue.record("expected a .failed status, got \(String(describing: sessions.session(for: model.id)?.status))")
        }
    }
}
