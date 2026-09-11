import Foundation

/// Manages one Anvil-authored image-generation server (`ImageServerScript`)
/// wrapping `mflux` — the Draw Things / `flux_server.py` replacement.
/// Same lifecycle shape as `LLMServer` (start/stop, readability polling,
/// named launcher, clean teardown); a separate type because the two
/// wrap genuinely different Python processes with different startup
/// times (Flux models are slow to load) and request shapes.
public actor ImageServer {
    private var process: Process?
    private var launcherURL: URL?
    public private(set) var baseURL = URL(string: "http://127.0.0.1:8200")!

    public init() {}

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public func start(
        modelPath: String,
        displayName: String,
        baseModel: String? = nil,
        quantizeBits: Int? = nil,
        host: String = "127.0.0.1",
        port: Int = 8200,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws {
        if isRunning { await stop() }

        let scriptURL: URL
        do {
            scriptURL = try ImageServerScript.ensureWrittenToDisk()
        } catch {
            throw ServingError.serverFailedToStart("could not write the image server script: \(error.localizedDescription)")
        }

        let outputDirectory = RuntimePaths.applicationSupportDirectory.appendingPathComponent("images", isDirectory: true)

        var arguments = [
            scriptURL.path,
            "--model", modelPath,
            "--host", host,
            "--port", String(port),
            "--output-dir", outputDirectory.path
        ]
        if let baseModel {
            arguments += ["--base-model", baseModel]
        }
        if let quantizeBits {
            arguments += ["--quantize", String(quantizeBits)]
        }

        let launcher = await NamedLauncher.shared.makeLauncher(displayName: displayName)

        let proc = Process()
        proc.executableURL = launcher
        proc.arguments = arguments

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
            // Flux weights are large and slow to load (dequantizing on
            // the fly for a quantized checkpoint isn't instant either),
            // so this gets a longer runway than LLMServer's default.
            try await waitUntilReady(process: proc, timeout: 300)
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

    private func waitUntilReady(process: Process, timeout: TimeInterval) async throws {
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
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ServingError.serverFailedToStart("timed out waiting for the server to become ready")
    }
}
