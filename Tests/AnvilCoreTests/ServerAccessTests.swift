import Testing
@testable import AnvilCore

@Suite("ServerAccess")
struct ServerAccessTests {
    @Test
    func localOnlyMapsToLoopback() {
        #expect(ServerAccess.localOnly.host == "127.0.0.1")
    }

    @Test
    func networkMapsToAllInterfaces() {
        #expect(ServerAccess.network.host == "0.0.0.0")
    }
}
