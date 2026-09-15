import Foundation

extension Process {
    /// Sends `terminate()`, gives the process up to 2 seconds (20 polls,
    /// 100ms apart) to actually exit, then `SIGKILL`s it if it's still
    /// running — shared by `LLMServer`, `ImageServer`, and
    /// `ContextShiftCoordinator`, each of which used to implement this
    /// identically. A no-op if the process was never started or has
    /// already exited.
    func terminateAndWaitOrKill() async {
        guard isRunning else { return }
        terminate()
        for _ in 0..<20 {
            if !isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if isRunning {
            kill(processIdentifier, SIGKILL)
        }
    }
}
