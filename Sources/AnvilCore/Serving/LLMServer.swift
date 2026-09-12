import Foundation

// macOS-only: this whole file is built around `Foundation.Process`,
// which doesn't exist on iOS at all (confirmed for real — even a
// bare `Process()` reference inside a function body fails to
// typecheck for an iOS target). The iOS port needs a genuinely
// different mechanism here (native `mlx-swift` inference in-process,
// not a subprocess server) rather than a port of this approach.
#if os(macOS)

/// Manages one `mlx_lm.server` subprocess — the same OpenAI-compatible
/// `/v1/chat/completions` + `/v1/models` shape oMLX serves today, so the
/// existing persona proxies need zero changes once this replaces it on
/// port 8000. The server's prefix KV cache is enabled explicitly so
/// repeated requests for the same thread reuse prefill work while the
/// existing tool-calling implementation remains intact.
public actor LLMServer {
    private var process: Process?
    private var launcherURL: URL?
    public private(set) var baseURL = URL(string: "http://127.0.0.1:8000")!
    /// The tail of the child process's combined stdout/stderr — see
    /// `ImageServer`'s matching property for why this exists (a startup
    /// failure needs to say *why*, not just that it failed).
    private var outputTail = OutputTail()

    public init() {}

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public var processIdentifier: pid_t? {
        process?.processIdentifier
    }

    /// `displayName` becomes this process's name in Activity Monitor
    /// ("Anvil - <displayName>") — see `NamedLauncher` for why that
    /// needs more than just picking a nice `arguments[0]`.
    public func start(
        modelPath: String,
        displayName: String,
        host: String = "127.0.0.1",
        port: Int = 8000,
        promptCacheSize: Int = 16,
        promptCacheBytes: String = "2G",
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws {
        if isRunning { await stop() }

        let script = RuntimePaths.venvDirectory.appendingPathComponent("bin/mlx_lm.server")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw ServingError.serverFailedToStart("mlx_lm.server isn't installed")
        }

        let launcher = await NamedLauncher.shared.makeLauncher(displayName: displayName)

        let proc = Process()
        proc.executableURL = launcher
        proc.arguments = [
            script.path,
            "--model", modelPath,
            "--host", host,
            "--port", String(port),
            "--prompt-cache-size", String(promptCacheSize),
            "--prompt-cache-bytes", promptCacheBytes
        ]

        outputTail = OutputTail()
        let tail = outputTail

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            tail.append(text)
            onLog?(text)
        }

        do {
            try proc.run()
        } catch {
            await NamedLauncher.shared.removeLauncher(at: launcher)
            throw ServingError.serverFailedToStart(error.localizedDescription)
        }
        ProcessWatchdog.attach(toPID: proc.processIdentifier)

        process = proc
        launcherURL = launcher
        baseURL = URL(string: "http://\(host):\(port)")!

        do {
            try await waitUntilReady(process: proc)
        } catch {
            await stop()
            throw error
        }
    }

    /// The real detail behind a startup failure — the process's own
    /// last few lines of output, when there are any.
    private func failureDetail(_ fallback: String) -> String {
        let captured = outputTail.text
        return captured.isEmpty ? fallback : "\(fallback)\n\n\(captured)"
    }

    public func stop() async {
        if let process, process.isRunning {
            process.terminate()
            for _ in 0..<20 {
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        self.process = nil

        if let launcherURL {
            await NamedLauncher.shared.removeLauncher(at: launcherURL)
        }
        self.launcherURL = nil
    }

    private func waitUntilReady(process: Process, timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let modelsURL = baseURL.appendingPathComponent("v1/models")

        while Date() < deadline {
            if !process.isRunning {
                throw ServingError.serverFailedToStart(failureDetail("process exited before becoming ready"))
            }
            if outputTail.containsAny(["application startup complete", "uvicorn running on", "listening on"]) {
                return
            }
            if let (_, response) = try? await URLSession.shared.data(from: modelsURL),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw ServingError.serverFailedToStart(failureDetail("timed out waiting for the server to become ready"))
    }
}

#endif
