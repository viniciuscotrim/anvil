import Foundation

/// Manages one `mlx_lm.server` subprocess — the same OpenAI-compatible
/// `/v1/chat/completions` + `/v1/models` shape oMLX serves today, so the
/// existing persona proxies need zero changes once this replaces it on
/// port 8000. One server per running Anvil process for now; Phase 5
/// introduces true concurrent multi-model residency.
public actor LLMServer {
    private var process: Process?
    public private(set) var baseURL = URL(string: "http://127.0.0.1:8000")!

    public init() {}

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public func start(
        modelPath: String,
        host: String = "127.0.0.1",
        port: Int = 8000,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws {
        if isRunning { await stop() }

        let executable = RuntimePaths.venvDirectory.appendingPathComponent("bin/mlx_lm.server")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ServingError.serverFailedToStart("mlx_lm.server isn't installed")
        }

        let proc = Process()
        proc.executableURL = executable
        proc.arguments = ["--model", modelPath, "--host", host, "--port", String(port)]

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
            throw ServingError.serverFailedToStart(error.localizedDescription)
        }

        process = proc
        baseURL = URL(string: "http://\(host):\(port)")!

        try await waitUntilReady(process: proc)
    }

    public func stop() async {
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        process.terminate()
        for _ in 0..<20 {
            if !process.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        self.process = nil
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
