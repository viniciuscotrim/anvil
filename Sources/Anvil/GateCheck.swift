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

            let port = env["ANVIL_GATE_PORT"].flatMap(Int.init) ?? 8000
            let host = env["ANVIL_GATE_HOST"] ?? "127.0.0.1"
            log("Starting mlx_lm.server with \(modelPath) on \(host):\(port)…")
            let displayName = URL(fileURLWithPath: modelPath).lastPathComponent
            try await server.start(modelPath: modelPath, displayName: displayName, host: host, port: port) { log($0) }
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

            if let holdSeconds = env["ANVIL_GATE_HOLD_SECONDS"].flatMap(Double.init) {
                log("Holding server open for \(holdSeconds)s…")
                try? await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
            }
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

    /// The full Phase 4 loop, for real: a real text model with the
    /// `generate_image` tool offered, a real Flux model behind it, one
    /// chat message that should make the text model call the tool, the
    /// image actually generated, and a follow-up reply that references
    /// it — the same round trip `ChatViewModel.send()` runs, exercised
    /// headlessly end to end.
    static func runPhase4GateIfRequested() async -> Bool {
        guard CommandLine.arguments.contains("--phase4-gate") else { return false }

        let env = ProcessInfo.processInfo.environment
        guard let textModelPath = env["ANVIL_GATE_TEXT_MODEL_PATH"] else {
            log("ANVIL_GATE_TEXT_MODEL_PATH must be set to a local text model directory")
            print("{}")
            return true
        }
        guard let imageModelPath = env["ANVIL_GATE_IMAGE_MODEL_PATH"] else {
            log("ANVIL_GATE_IMAGE_MODEL_PATH must be set to a local Flux model directory")
            print("{}")
            return true
        }
        let baseModel = env["ANVIL_GATE_IMAGE_BASE_MODEL"]
        let prompt = env["ANVIL_GATE_PROMPT"] ?? "Please generate an image of a red apple on a white table."

        let textServer = LLMServer()
        let imageServer = ImageServer()
        let chatClient = ChatClient()
        let imageClient = ImageClient()

        var result: [String: Any] = [
            "textModelPath": textModelPath,
            "imageModelPath": imageModelPath
        ]

        do {
            let python = PythonEnvironment()
            if !(await python.isPackageInstalled("mlx_lm")) {
                log("Setting up text generation…")
                try await python.pipInstall(["mlx-lm"])
            }
            if !(await python.isPackageInstalled("mflux")) {
                log("Setting up image generation…")
                try await python.pipInstall(["mflux"])
            }

            log("Starting text server with \(textModelPath)…")
            try await textServer.start(
                modelPath: textModelPath,
                displayName: URL(fileURLWithPath: textModelPath).lastPathComponent,
                port: env["ANVIL_GATE_TEXT_PORT"].flatMap(Int.init) ?? 8000
            ) { log($0) }

            log("Starting image server with \(imageModelPath)…")
            try await imageServer.start(
                modelPath: imageModelPath,
                displayName: URL(fileURLWithPath: imageModelPath).lastPathComponent,
                baseModel: baseModel,
                port: env["ANVIL_GATE_IMAGE_PORT"].flatMap(Int.init) ?? 8200
            ) { log($0) }

            log("Sending: \(prompt)")
            var messages = [ChatMessage(role: .user, content: prompt)]
            var reply = try await chatClient.send(
                messages: messages,
                baseURL: textServer.baseURL,
                tools: [.generateImage]
            )
            result["firstReplyToolCalls"] = reply.toolCalls?.map(\.name) ?? []

            if let call = reply.toolCalls?.first(where: { $0.name == "generate_image" }) {
                log("Model called generate_image with: \(call.argumentsJSON)")
                messages.append(reply)

                struct Arguments: Decodable { let prompt: String }
                let arguments = try JSONDecoder().decode(
                    Arguments.self,
                    from: Data(call.argumentsJSON.utf8)
                )

                log("Generating image for real…")
                let imageResult = try await imageClient.generate(prompt: arguments.prompt, baseURL: imageServer.baseURL)
                result["generatedImagePath"] = imageResult.localPath
                result["generatedImageFileExists"] = FileManager.default.fileExists(atPath: imageResult.localPath)

                messages.append(ChatMessage(
                    role: .tool,
                    content: "Image generated successfully and is already displayed to the user in this chat. "
                        + "Do not include a URL or Markdown image syntax — just briefly acknowledge it in plain text.",
                    toolCallID: call.id
                ))

                log("Sending follow-up for the model's narration…")
                reply = try await chatClient.send(messages: messages, baseURL: textServer.baseURL)
                result["finalReply"] = reply.content
                log("Final reply: \(reply.content)")
            } else {
                log("Model did not call generate_image — recording its plain reply instead.")
                result["finalReply"] = reply.content
            }
        } catch {
            result["error"] = error.localizedDescription
            log("Gate check failed: \(error.localizedDescription)")
        }

        await textServer.stop()
        await imageServer.stop()

        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        } else {
            print("{}")
        }

        return true
    }
}
