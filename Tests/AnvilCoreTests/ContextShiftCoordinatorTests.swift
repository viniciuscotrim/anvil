import Foundation
import Testing
@testable import AnvilCore

/// Regression coverage for the v0.20.1 bug: `sendControl` used to encode
/// its acknowledgement with `JSONEncoder.anvil`, which applies
/// `.prettyPrinted` — fine for `writeStatus`'s whole-file writes, fatal
/// here, since the stdin pipe protocol is strictly one JSON object per
/// line (`sys.stdin.readline()` on the Python side). A pretty-printed
/// `{"event":"unload_complete"}` spans several lines, so the ack never
/// arrived as a single `readline()`, and `wait_for_control_event` timed
/// out after 60s on every real shift. No test caught it at the time —
/// this is that test, for that specific real bug, not the general
/// "does JSON round-trip" case.
@Suite("ContextShiftCoordinator")
struct ContextShiftCoordinatorTests {
    private func makeCoordinator() throws -> ContextShiftCoordinator {
        let dir = try makeTempDirectory(name: "anvil-context-shift-tests")
        return ContextShiftCoordinator(
            statusFilePath: dir.appendingPathComponent("status.json"),
            vectorStorePath: dir.appendingPathComponent("vectors"),
            relevanceFeedbackPath: dir.appendingPathComponent("relevance_feedback.json")
        )
    }

    @Test
    func sendControlWritesExactlyOneLineOfJSON() async throws {
        let coordinator = try makeCoordinator()
        let pipe = Pipe()
        await coordinator.setStdinHandle(pipe.fileHandleForWriting)

        await coordinator.sendControl(event: "unload_complete")

        let written = pipe.fileHandleForReading.availableData
        let text = String(decoding: written, as: UTF8.self)

        // The real contract: exactly one newline, at the very end —
        // matching `sys.stdin.readline()`'s expectation. `.prettyPrinted`
        // would put a newline after every key, failing this outright.
        #expect(text.hasSuffix("\n"))
        #expect(text.dropLast().contains("\n") == false)

        let decoded = try JSONDecoder().decode([String: String].self, from: written)
        #expect(decoded["event"] == "unload_complete")
    }
}

private extension ContextShiftCoordinator {
    /// Test-only convenience — `stdinHandle` itself is already
    /// internal (see its own doc comment), this just spells out the
    /// intent at the call site.
    func setStdinHandle(_ handle: FileHandle) {
        stdinHandle = handle
    }
}
