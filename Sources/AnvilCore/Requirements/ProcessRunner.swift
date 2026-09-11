import Foundation

public enum ProcessRunnerError: Error, LocalizedError, Sendable {
    case nonZeroExit(Int32, String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nonZeroExit(let code, let output):
            return "Process exited with code \(code): \(output)"
        case .launchFailed(let reason):
            return "Failed to launch process: \(reason)"
        }
    }
}

/// Runs subprocesses in the background. This is how Anvil drives `uv`,
/// `tar`, and Python — as a child process of the app, never as a visible
/// Terminal window.
public enum ProcessRunner {
    /// Cooperatively cancellable: cancelling the calling `Task` (e.g. a
    /// Stop/Pause button cancelling a download's `Task`) sends the
    /// child process `SIGTERM` and the call throws `CancellationError`
    /// instead of a non-zero-exit error — the mechanism behind
    /// `ModelDownloader`'s pause/cancel.
    @discardableResult
    public static func run(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let cancelledByUs = CancelFlag()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let collector = OutputCollector(onLine: onOutputLine)

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.append(handle.availableData)
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    collector.append(handle.availableData)
                }

                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let finalOutput = collector.finalText()
                    if proc.terminationStatus == 0 {
                        continuation.resume(returning: finalOutput)
                    } else if cancelledByUs.value {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: ProcessRunnerError.nonZeroExit(proc.terminationStatus, finalOutput))
                    }
                }

                // The Task could already be cancelled by the time we get
                // here (a fast Stop click racing the launch) — check
                // before spending the cost of actually starting it.
                guard !Task.isCancelled else {
                    cancelledByUs.value = true
                    continuation.resume(throwing: CancellationError())
                    return
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            cancelledByUs.value = true
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Tiny thread-safe box — `onCancel` fires on an arbitrary thread,
    /// not necessarily the one running the continuation body.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    /// Thread-safe accumulator for a process's combined stdout/stderr,
    /// forwarding whole lines to a caller-supplied handler as they arrive.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var pending = Data()
        private let onLine: (@Sendable (String) -> Void)?

        init(onLine: (@Sendable (String) -> Void)?) {
            self.onLine = onLine
        }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            buffer.append(data)
            pending.append(data)
            var lines: [String] = []
            while let newlineRange = pending.range(of: Data([0x0A])) {
                let lineData = pending.subdata(in: pending.startIndex..<newlineRange.lowerBound)
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line)
                }
                pending.removeSubrange(pending.startIndex..<newlineRange.upperBound)
            }
            lock.unlock()
            for line in lines {
                onLine?(line)
            }
        }

        func finalText() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: buffer, encoding: .utf8) ?? ""
        }
    }
}
