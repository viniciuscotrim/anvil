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

        // Without this, a port a process held moments ago can spuriously
        // read as "in use" for a brief window right after that process
        // exits (the classic Local→Network restart race: `unload()`
        // just killed the old server and `load()` immediately re-probes
        // the same port) even though nothing else actually holds it —
        // `SO_REUSEADDR` is the standard fix for exactly this check.
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

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

    /// Retries `isFree` for up to `timeout` seconds instead of a single
    /// check — the real fix for the Local→Network "port already in
    /// use" restart race (`updateServerSettings` unloads the old server
    /// then immediately reloads on the same port): usually resolves in
    /// well under a second once the old process is actually gone, and
    /// still gives it real room on a slower teardown, rather than either
    /// failing immediately or blindly sleeping a fixed cooldown that's
    /// either too short or wastes time when it wasn't needed.
    static func waitUntilFree(_ port: Int, host: String = "127.0.0.1", timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if isFree(port, host: host) { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }
}
