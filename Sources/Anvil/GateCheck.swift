import Foundation
import AnvilCore

/// Headless verification for the phase gates in docs/build-brief.md.
/// Run with `swift run Anvil -- --phase2-gate` (see main.swift — this
/// never creates a SwiftUI window). Prints the resulting model registry
/// as JSON to stdout and exits, so each gate is confirmed by an
/// inspectable artifact rather than "it looked fine in the UI."
enum GateCheck {
    private static func log(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    /// Cold download of one model + import of one already-on-disk model
    /// folder, both landing in the same registry. Configurable via env
    /// vars so a real run can target a real pre-existing directory
    /// without hardcoding a path into the binary.
    static func runPhase2GateIfRequested() async -> Bool {
        guard CommandLine.arguments.contains("--phase2-gate") else { return false }

        let env = ProcessInfo.processInfo.environment
        let downloadRepoID = env["ANVIL_GATE_DOWNLOAD_REPO"] ?? "mlx-community/SmolLM2-135M-Instruct-8bit"

        let registry = ModelRegistry()
        let python = PythonEnvironment()
        let downloader = ModelDownloader(registry: registry, python: python)
        let importer = ModelImporter(registry: registry)

        do {
            if !(await python.isPackageInstalled("huggingface_hub")) {
                log("Setting up model browser…")
                try await python.pipInstall(["huggingface_hub"])
            }

            log("Downloading \(downloadRepoID) from a cold state…")
            let downloaded = try await downloader.download(repoID: downloadRepoID) { log($0) }
            log("Downloaded to \(downloaded.localPath)")

            if let importPath = env["ANVIL_GATE_IMPORT_PATH"] {
                log("Importing existing model folder at \(importPath)…")
                let imported = try await importer.importModel(at: URL(fileURLWithPath: importPath))
                log("Imported without re-downloading: \(imported.localPath)")
            } else {
                log("ANVIL_GATE_IMPORT_PATH not set — skipping the import half of the gate")
            }
        } catch {
            log("Gate check failed: \(error.localizedDescription)")
        }

        let entries = await registry.all()
        if let data = try? JSONEncoder.anvil.encode(entries), let json = String(data: data, encoding: .utf8) {
            print(json)
        } else {
            print("[]")
        }

        return true
    }

    /// Loads one model into a real `mlx_lm.server` process and sends it
    /// a real chat completion — the mechanism the persona proxies will
    /// use unmodified once this replaces oMLX on port 8000. Doesn't
    /// touch the live proxies itself; that handoff is a separate,
    /// explicit step once this half is trusted.
    static func runPhase3GateIfRequested() async -> Bool {
        guard CommandLine.arguments.contains("--phase3-gate") else { return false }

        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["ANVIL_GATE_MODEL_PATH"] else {
            log("ANVIL_GATE_MODEL_PATH must be set to a local model directory")
            print("{}")
            return true
        }

        let python = PythonEnvironment()
        let server = LLMServer()
        let client = ChatClient()

        var result: [String: Any] = ["modelPath": modelPath]

        do {
            if !(await python.isPackageInstalled("mlx_lm")) {
                log("Setting up text generation…")
                try await python.pipInstall(["mlx-lm"])
            }

            log("Starting mlx_lm.server with \(modelPath)…")
            try await server.start(modelPath: modelPath) { log($0) }
            result["serverStarted"] = true

            let modelsURL = await server.baseURL.appendingPathComponent("v1/models")
            let (modelsData, _) = try await URLSession.shared.data(from: modelsURL)
            result["modelsEndpointResponse"] = String(data: modelsData, encoding: .utf8) ?? ""

            log("Sending a real chat completion…")
            let reply = try await client.send(
                messages: [ChatMessage(role: .user, content: "Say hello in exactly three words.")],
                baseURL: server.baseURL
            )
            result["chatReply"] = reply.content
            log("Reply: \(reply.content)")
        } catch {
            result["error"] = error.localizedDescription
            log("Gate check failed: \(error.localizedDescription)")
        }

        await server.stop()

        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        } else {
            print("{}")
        }

        return true
    }
}
