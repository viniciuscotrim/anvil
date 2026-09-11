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
    /// The tail of the child process's combined stdout/stderr — kept
    /// regardless of whether a caller passes `onLog`, specifically so a
    /// startup failure can report *why*, not just that it failed. A
    /// real, reported bug: a model with a real, informative Python
    /// traceback ("No safetensors files found in .../vae" — an mflux
    /// pipeline shape mismatch) surfaced to the user as nothing but a
    /// generic "process exited before becoming ready", because nothing
    /// captured that traceback when no `onLog` closure happened to be
    /// listening.
    private var outputTail = OutputTail()

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
            // Flux weights are large and slow to load (dequantizing on
            // the fly for a quantized checkpoint isn't instant either),
            // so this gets a longer runway than LLMServer's default.
            try await waitUntilReady(process: proc, timeout: 300)
        } catch {
            await stop()
            throw error
        }
    }

    /// The real detail behind a startup failure — the Python process's
    /// own last few lines of output, when there are any. Falls back to
    /// a generic phrase otherwise (e.g. the process never printed
    /// anything before dying, or hasn't been started at all).
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

    private func waitUntilReady(process: Process, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let modelsURL = baseURL.appendingPathComponent("v1/models")

        while Date() < deadline {
            if !process.isRunning {
                throw ServingError.serverFailedToStart(failureDetail("process exited before becoming ready"))
            }
            if let (_, response) = try? await URLSession.shared.data(from: modelsURL),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ServingError.serverFailedToStart(failureDetail("timed out waiting for the server to become ready"))
    }
}
