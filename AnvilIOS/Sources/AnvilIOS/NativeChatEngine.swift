import AnvilCore
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Native, in-process text generation for iOS — the real replacement
/// for what the Mac app does with `LLMServer` (spawning `mlx_lm.server`
/// or `llama_cpp.server` as a subprocess and talking to it over HTTP),
/// which can't exist on iOS at all: there is no `Process` there. This
/// runs the model directly inside the app, via `mlx-swift-lm` (Apple/
/// ml-explore's own, actively maintained Swift port of MLX's LLM
/// stack) for MLX-format weights, or `GGUFChatBackend` (wrapping
/// `LLM.swift`, itself over `ggml-org/llama.cpp`'s own runtime) for
/// GGUF — no server, no port, no separate process to manage or clean
/// up either way. `load` picks the backend from what's actually on
/// disk (see its own doc comment); `container`/`session` and
/// `ggufBackend` are mutually exclusive, one active backend at a time.
///
/// Downloads route through the exact same `HFRepoDownloader`/
/// `ModelRegistry` pipeline the Models tab uses (`resolveLocalDirectory`),
/// not `MLXHuggingFace`'s own `#huggingFaceLoadModelContainer` macro —
/// that macro downloads into a completely separate cache the Models tab
/// never sees, a real reported bug: typing a model ID directly here and
/// loading it used to leave it invisible and unmanageable (couldn't be
/// inspected, freed, or deleted) anywhere else in the app. Loading the
/// already-local files afterward uses `LLMModelFactory`'s own plain
/// `loadContainer(from: directory:)`, no macro, no network. `ChatSession`
/// (from `MLXLMCommon`) then provides the actual multi-turn conversation —
/// tracking history and reusing the KV cache across turns, the same
/// thing `ChatThread`'s message list gives the Mac app's HTTP-based
/// `ChatClient`.
///
/// The loaded model weights (`container`) and the live conversation
/// (`session`) are tracked separately so switching which `ChatThread`
/// is active doesn't require re-downloading or reloading anything —
/// `startSession(instructions:history:)` rebuilds just the session, the
/// same "Prompt Re-hydration" `ChatSession` itself documents for
/// persistent chat apps, restoring a saved conversation's turns instead
/// of starting the model over with no memory of what was said.
///
/// `generate_image` tool-calling is wired directly to `imageEngine`
/// (injected, the same instance `NativeImageView` and Prompt to Model
/// share) — `ChatSession.tools`/`toolDispatch` handle the whole
/// call-then-continue round trip internally, so unlike the Mac app's
/// two-request dance (`ChatViewModel.send` detecting a tool call, then
/// sending a follow-up itself), a single `streamSend`/`send` call here
/// already carries the tool call, its result, and the model's narrated
/// follow-up in one stream.
@MainActor
final class NativeChatEngine: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadProgress: Double?
    @Published private(set) var loadedModelID: String?
    @Published var errorMessage: String?
    /// Generation parameters — same cross-platform `GenerationSettings`
    /// type the Mac app's Chat sidebar edits, applied to
    /// `session.generateParameters` fresh before every request (see
    /// `applyGenerationSettings`) so a change takes effect on the very
    /// next turn without needing to reload the model or rebuild the
    /// session.
    @Published var settings = GenerationSettings.default
    /// Set by the `generate_image` tool dispatch when a call completes
    /// during the current `send`/`streamSend` — the caller reads it
    /// once the stream finishes to attach the image to the visible
    /// reply (`ChatMessage.generatedImagePath`), mirroring
    /// `ChatViewModel.runGenerateImageTool`'s returned path on the Mac.
    @Published private(set) var lastGeneratedImagePath: String?
    /// Set once `streamSend`'s stream finishes, from the real measured
    /// completion stats `ChatSession.streamDetails` reports — the same
    /// number the Mac app's header shows via `ChatMessage.tokensPerSecond`.
    /// Read-once via `consumeLastTokensPerSecond()`.
    @Published private(set) var lastTokensPerSecond: Double?

    // Qualified explicitly: the vendored StableDiffusion sources
    // (`NativeImageEngine`'s `StableDiffusion/` directory) declare their
    // own, unrelated generic `ModelContainer<M>` in this same app
    // module, and an unqualified `ModelContainer` here resolves to that
    // one instead of MLXLMCommon's.
    private var container: MLXLMCommon.ModelContainer?
    private var session: ChatSession?
    /// The GGUF/llama.cpp counterpart to `container`/`session` — set
    /// instead of them when `load` detects a `.gguf` file rather than
    /// an MLX-format directory. Never both at once; see `load`'s own
    /// detection and `GGUFChatBackend`'s header comment for why this
    /// is a genuinely separate backend rather than a second branch
    /// inside `ChatSession`'s own machinery.
    private var ggufBackend: GGUFChatBackend?
    private let imageEngine: NativeImageEngine
    // Qualified explicitly: `MLXLLM` exports its own public
    // `ModelRegistry` typealias (`= LLMRegistry`), which collides with
    // AnvilCore's unrelated one now that both modules are imported here.
    private let registry: AnvilCore.ModelRegistry
    private let catalog = HuggingFaceCatalog()
    private let downloader: HFRepoDownloader

    init(imageEngine: NativeImageEngine, registry: AnvilCore.ModelRegistry = AnvilCore.ModelRegistry()) {
        self.imageEngine = imageEngine
        self.registry = registry
        self.downloader = HFRepoDownloader(registry: registry)
    }

    /// Whether a model's weights are currently resident — gates the
    /// Load/Unload button and the model-ID field, same meaning it had
    /// before the container/session split. True for either backend.
    var isLoaded: Bool { container != nil || ggufBackend != nil }

    /// Downloads/loads `modelID`'s weights if they aren't already
    /// resident (skipped entirely if the same model is already loaded —
    /// switching threads on the same model is then just
    /// `startSession`'s cheap rebuild), then starts a session against
    /// them with `history` restored.
    ///
    /// `instructions`, when given, becomes the session's system prompt —
    /// a registered model's default `ChatProfile`, the same "loading
    /// this model applies its bound profile automatically" behavior the
    /// Mac app's `ChatViewModel` gives.
    ///
    /// Picks the backend from what's actually on disk, not from any
    /// registry-declared "kind" — a `.gguf` file present means
    /// `GGUFChatBackend` (llama.cpp), same detection `LLMServer.swift`
    /// uses on the Mac side for the same reason: it's the one signal
    /// that can't be stale or unset.
    func load(modelID: String, instructions: String? = nil, history: [ChatMessage] = []) async {
        guard !isLoading else { return }
        errorMessage = nil

        if !isLoaded || loadedModelID != modelID {
            isLoading = true
            loadProgress = 0
            do {
                let directory = try await resolveLocalDirectory(modelID: modelID)
                if let ggufFile = try Self.ggufFile(in: directory) {
                    guard let backend = GGUFChatBackend(
                        modelPath: ggufFile, instructions: instructions, history: history)
                    else {
                        throw NativeChatEngineError.loadFailed(modelID)
                    }
                    container = nil
                    session = nil
                    ggufBackend = backend
                } else {
                    ggufBackend = nil
                    container = try await LLMModelFactory.shared.loadContainer(
                        from: directory, using: #huggingFaceTokenizerLoader())
                }
                loadedModelID = modelID
            } catch {
                errorMessage = error.localizedDescription
                container = nil
                session = nil
                ggufBackend = nil
                loadedModelID = nil
                isLoading = false
                loadProgress = nil
                return
            }
            isLoading = false
            loadProgress = nil
        }

        startSession(instructions: instructions, history: history)
    }

    /// The one `.gguf` file in a downloaded model's directory, if any —
    /// same simple "first match" heuristic `LLMServer.swift` uses on
    /// the Mac side (a GGUF repo is realistically ever one file per
    /// registered download; Anvil doesn't support multi-part GGUF
    /// shards on either platform today).
    private static func ggufFile(in directory: URL) throws -> URL? {
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard let name = files.first(where: { $0.lowercased().hasSuffix(".gguf") }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// Resolves `modelID` to a local directory of already-downloaded
    /// files, reusing a registry entry's files when they're already on
    /// disk, or downloading through `HFRepoDownloader` (the same
    /// pipeline the Models tab's own downloads use, registering into
    /// `ModelRegistry` along the way) otherwise. This is what makes a
    /// model loaded by typing its ID here show up, later, in the Models
    /// tab too — see this type's own header comment.
    private func resolveLocalDirectory(modelID: String) async throws -> URL {
        if let entry = await registry.all().first(where: { $0.id == modelID }) {
            let url = URL(fileURLWithPath: entry.localPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let summary = try await catalog.modelInfo(id: modelID)
        guard let filePaths = summary.filePaths, !filePaths.isEmpty else {
            throw NativeChatEngineError.noFilesAvailable(modelID)
        }
        let entry = try await downloader.download(repoID: modelID, filePaths: filePaths) { [weak self] progress in
            Task { @MainActor in self?.loadProgress = progress }
        }
        return URL(fileURLWithPath: entry.localPath)
    }

    /// Rebuilds the live conversation from `history` without touching
    /// the loaded model at all — what makes switching `ChatThread`s
    /// while a model is already loaded cheap, instead of re-downloading
    /// or reloading anything. A no-op if nothing is loaded yet; the
    /// next `load(modelID:instructions:history:)` call starts a session
    /// once it finishes.
    ///
    /// If the image engine is already loaded, the `generate_image`
    /// usage-discipline reminder (see `ChatTool`) is folded into the
    /// system prompt right away — this only takes effect for the
    /// thread's very first turn (once the KV cache is non-empty, a
    /// later `session.instructions` change can't retroactively rewrite
    /// what's already baked into it), but `refreshTools` still keeps
    /// `tools`/`toolDispatch` current on every turn regardless.
    func startSession(instructions: String? = nil, history: [ChatMessage] = []) {
        // The GGUF backend never offers `generate_image` (see
        // `GGUFChatBackend`'s header comment on why that's out of
        // scope for now), so — unlike the MLX branch below — its
        // instructions are never extended with the tool's usage
        // discipline reminder; doing so would just confuse a model
        // that's never actually offered the tool.
        if let ggufBackend {
            ggufBackend.restart(instructions: instructions, history: history)
            return
        }
        guard let container else { return }
        var parts: [String] = []
        if let instructions, !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(instructions)
        }
        if imageEngine.isLoaded {
            parts.append(ChatTool.generateImageUsageDiscipline)
        }
        let composedInstructions = parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        session = ChatSession(
            container, instructions: composedInstructions, history: Self.chatHistory(from: history))
    }

    func unload() {
        container = nil
        session = nil
        ggufBackend = nil
        loadedModelID = nil
    }

    /// One full reply — the same "wait for the whole thing" shape
    /// `ChatClient.send` gives the macOS app.
    func send(_ text: String) async throws -> String {
        if let ggufBackend {
            applyGenerationSettings()
            return await ggufBackend.send(text)
        }
        guard let session else { throw NativeChatEngineError.notLoaded }
        refreshTools()
        applyGenerationSettings()
        return try await session.respond(to: text)
    }

    /// Token-by-token, for a real-time reply the way `mlx_lm.server`'s
    /// own streaming would look if the Mac app's `ChatClient` used it
    /// (today it doesn't — it waits for the full response). Built on
    /// `streamDetails` rather than the plainer `streamResponse` so the
    /// completion's real measured tokens/sec (its `.info` case) can be
    /// captured into `lastTokensPerSecond` once the stream ends, instead
    /// of only ever yielding text.
    func streamSend(_ text: String) throws -> AsyncThrowingStream<String, Error> {
        if let ggufBackend {
            applyGenerationSettings()
            let (backendStream, tokensPerSecond) = ggufBackend.streamSend(text)
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            let forwardingTask = Task { [weak self] in
                do {
                    for try await chunk in backendStream {
                        if case .terminated = continuation.yield(chunk) { break }
                    }
                    let measured = tokensPerSecond()
                    Task { @MainActor in self?.lastTokensPerSecond = measured }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Unlike the MLX branch below, cancelling `forwardingTask`
            // alone isn't enough to actually stop generation — `LLM`
            // doesn't check Swift's cooperative cancellation inside its
            // own decode loop, only its own `interrupt()` flag (what
            // `GGUFChatBackend.stop()` sets) — so the Stop button needs
            // this explicit call to have any effect on this backend.
            continuation.onTermination = { [weak self] _ in
                forwardingTask.cancel()
                Task { @MainActor in self?.ggufBackend?.stop() }
            }
            return stream
        }

        guard let session else { throw NativeChatEngineError.notLoaded }
        refreshTools()
        applyGenerationSettings()

        let detailStream = session.streamDetails(to: text)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let forwardingTask = Task { [weak self] in
            do {
                for try await item in detailStream {
                    switch item {
                    case .chunk(let text):
                        if case .terminated = continuation.yield(text) { break }
                    case .info(let info):
                        let tokensPerSecond = info.tokensPerSecond
                        Task { @MainActor in self?.lastTokensPerSecond = tokensPerSecond }
                    case .toolCall:
                        break
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in forwardingTask.cancel() }
        return stream
    }

    /// Consumes whatever the last `streamSend` measured — read-once so a
    /// later, unrelated reply doesn't inherit a stale number, mirroring
    /// `consumeLastGeneratedImagePath`.
    func consumeLastTokensPerSecond() -> Double? {
        defer { lastTokensPerSecond = nil }
        return lastTokensPerSecond
    }

    /// Maps `settings` onto `ChatSession.generateParameters`, applied
    /// fresh before every request (like `refreshTools`) rather than
    /// only at session creation, so a mid-conversation change takes
    /// effect on the very next turn without reloading anything.
    /// `maxTokens: nil` gets the same generous, effectively-unlimited
    /// budget `GenerationSettings.wireMaxTokens` gives the Mac app's
    /// HTTP request instead of `mlx-swift-lm`'s own smaller default.
    private func applyGenerationSettings() {
        session?.generateParameters = GenerateParameters(
            maxTokens: settings.wireMaxTokens,
            temperature: Float(settings.temperature),
            topP: Float(settings.topP),
            topK: settings.topK,
            minP: Float(settings.minP)
        )
        ggufBackend?.applyGenerationSettings(settings)
    }

    /// Offers `generate_image` only once the on-device image engine has
    /// actually been loaded at least once (in Images or Prompt to
    /// Model) — re-checked before every request rather than only at
    /// session creation, since the user can load it from another tab
    /// mid-conversation. Deliberately conservative: unlike the Mac app
    /// (which can check a whole registry of already-downloaded image
    /// models before offering the tool), NativeImageEngine's one preset
    /// downloads several GB on first load, so a chat message alone
    /// should never be what silently kicks that off.
    private func refreshTools() {
        guard let session else { return }
        guard imageEngine.isLoaded else {
            session.tools = nil
            session.toolDispatch = nil
            return
        }
        session.tools = [Self.generateImageToolSpec]
        session.toolDispatch = { [weak self] call in
            guard let self else { return "Error: chat engine unavailable." }
            return await self.handleGenerateImageToolCall(call)
        }
    }

    /// Runs a `generate_image` tool call for real against the shared
    /// `NativeImageEngine` — the same engine, gallery, and
    /// `GeneratedImageStore` the Images tab and Prompt to Model use.
    /// Unlike the Mac app's `runGenerateImageTool` (which loads a
    /// registered image model on demand), the tool is only ever offered
    /// once `imageEngine.isLoaded` is already true (see `refreshTools`),
    /// so no on-demand load happens here.
    private func handleGenerateImageToolCall(_ call: MLXLMCommon.ToolCall) async -> String {
        guard case .string(let prompt)? = call.function.arguments["prompt"],
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "Error: missing or empty prompt argument."
        }
        await imageEngine.generate(prompt: prompt)
        if let error = imageEngine.errorMessage {
            return "Error generating image: \(error)"
        }
        lastGeneratedImagePath = imageEngine.selectedImage?.localPath
        return "Image generated successfully and is already displayed to the user in this chat. "
            + "Do not include a URL or Markdown image syntax — just briefly acknowledge it in plain text."
    }

    /// Consumes whatever `handleGenerateImageToolCall` set during the
    /// last `send`/`streamSend` — read-once so a later, unrelated reply
    /// doesn't accidentally re-attach an old image.
    func consumeLastGeneratedImagePath() -> String? {
        defer { lastGeneratedImagePath = nil }
        return lastGeneratedImagePath
    }

    /// JSON-Schema tool spec for `generate_image`, built from
    /// `ChatTool.generateImage` (AnvilCore) so the name/description/
    /// wording stay a single source of truth with the Mac app's HTTP
    /// tool-call shape — just re-serialized into `ToolSpec`
    /// (`ChatSession`'s native format) instead of `ChatTool`'s own
    /// `wireRepresentation` (internal to AnvilCore, and shaped for
    /// `ChatClient`'s HTTP request body rather than `ChatSession`).
    private static var generateImageToolSpec: ToolSpec {
        let tool = ChatTool.generateImage
        var properties: [String: any Sendable] = [:]
        for parameter in tool.parameters {
            properties[parameter.name] = ["type": parameter.type, "description": parameter.description]
        }
        return [
            "type": "function",
            "function": [
                "name": tool.name,
                "description": tool.description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": tool.parameters.map(\.name),
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }

    /// A one-off, stateless completion using whichever model is already
    /// loaded — a fresh, throwaway `ChatSession` built from the same
    /// container, not the ongoing conversation, so it neither pollutes
    /// nor is affected by chat history. Mirrors the Mac app's Prompt to
    /// Model feature reusing a loaded text model's `ChatClient.send`
    /// for a single isolated request instead of going through the
    /// active thread.
    func respondOnce(to prompt: String) async throws -> String {
        guard let container else { throw NativeChatEngineError.notLoaded }
        return try await ChatSession(container).respond(to: prompt)
    }

    /// Converts a persisted thread's messages into the wire format
    /// `ChatSession`'s history initializer expects. The system prompt
    /// is carried separately via `instructions` rather than as a stored
    /// message, and `.tool`/`.system` turns aren't replayed — a
    /// `generate_image` round trip's tool-call/tool-result messages
    /// exist only transiently inside `ChatSession`'s own KV cache during
    /// a single `send`/`streamSend` call (see `refreshTools`), never in
    /// a persisted `ChatThread`, so there's nothing of that shape to
    /// restore on rehydration.
    private static func chatHistory(from messages: [ChatMessage]) -> [Chat.Message] {
        messages.compactMap { message in
            switch message.role {
            case .user: .user(message.content)
            case .assistant: .assistant(message.content)
            case .system, .tool: nil
            }
        }
    }
}

enum NativeChatEngineError: LocalizedError {
    case notLoaded
    case noFilesAvailable(String)
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            "No model is loaded."
        case .noFilesAvailable(let modelID):
            "No file list available for \(modelID)."
        case .loadFailed(let modelID):
            "Could not load \(modelID) — the GGUF file may be corrupt or an unsupported format."
        }
    }
}
