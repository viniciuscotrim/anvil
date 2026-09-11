import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Checks whether a TCP port is actually free on a given host before
/// handing it to a new `LLMServer` — not just "not one of ours," since
/// a leftover process (a previous Anvil run, oMLX, anything else) can
/// already hold it. Binds and immediately releases; a real race with
/// something else grabbing the port between this check and the
/// server's own bind is possible but narrow enough not to worry about.
enum PortProbe {
    static func isFree(_ port: Int, host: String = "127.0.0.1") -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(sock, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
