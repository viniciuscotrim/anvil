import Foundation

/// Manages one `mlx_lm.server` subprocess — the same OpenAI-compatible
/// `/v1/chat/completions` + `/v1/models` shape oMLX serves today, so the
/// existing persona proxies need zero changes once this replaces it on
/// port 8000. One server per running Anvil process for now; Phase 5
/// introduces true concurrent multi-model residency.
public actor LLMServer {
    private var process: Process?
    private var launcherURL: URL?
    public private(set) var baseURL = URL(string: "http://127.0.0.1:8000")!

    public init() {}

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    /// `displayName` becomes this process's name in Activity Monitor
    /// ("Anvil - <displayName>") — see `NamedLauncher` for why that
    /// needs more than just picking a nice `arguments[0]`.
    public func start(
        modelPath: String,
        displayName: String,
        host: String = "127.0.0.1",
        port: Int = 8000,
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
        proc.arguments = [script.path, "--model", modelPath, "--host", host, "--port", String(port)]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            onLog?(text)
        }

        do {
            try proc.run()
        } catch {
            await NamedLauncher.shared.removeLauncher(at: launcher)
            throw ServingError.serverFailedToStart(error.localizedDescription)
        }

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
                throw ServingError.serverFailedToStart("process exited before becoming ready")
            }
            if let (_, response) = try? await URLSession.shared.data(from: modelsURL),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        throw ServingError.serverFailedToStart("timed out waiting for the server to become ready")
    }
}
