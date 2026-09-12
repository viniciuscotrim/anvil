import Testing
@testable import AnvilCore

#if os(macOS)
import Darwin

@Suite("ProcessMemoryUsage")
struct ProcessMemoryUsageTests {
    @Test
    func readsResidentBytesWithoutDereferencingAnInvalidPointer() {
        #expect(ProcessMemoryUsage.residentBytes(pid: getpid()) != nil)
    }
}
#endif