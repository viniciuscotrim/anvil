import Foundation
import Testing
@testable import AnvilCore
#if canImport(Darwin)
import Darwin
#endif

@Suite("PortProbe")
struct PortProbeTests {
    @Test
    func reportsAnOccupiedPortAsNotFree() {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ask the OS for an ephemeral free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)
        listen(sock, 1)

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(sock, $0, &len)
            }
        }
        let boundPort = Int(in_port_t(bigEndian: boundAddr.sin_port))

        #expect(!PortProbe.isFree(boundPort))
    }

    @Test
    func reportsAHighRandomPortAsFree() {
        // Not perfectly deterministic (another process could be on it),
        // but astronomically unlikely for a random high port.
        #expect(PortProbe.isFree(Int.random(in: 40000...60000)))
    }
}
