import AnvilCore
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Native, in-process text generation for iOS — the real replacement
/// for what the Mac app does with `LLMServer` (spawning `mlx_lm.server`
/// as a subprocess and talking to it over HTTP), which can't exist on
/// iOS at all: there is no `Process` there. This runs the model
/// directly inside the app via `mlx-swift-lm` (Apple/ml-explore's own,
/// actively maintained Swift port of MLX's LLM stack) — no server, no
/// port, no separate process to manage or clean up.
///
/// `#huggingFaceLoadModelContainer` (from `MLXHuggingFace`, backed by
/// `swift-huggingface`'s `HubClient`) downloads and caches the model
/// itself — a real, separate download path from `HFRepoDownloader`
/// (which exists for the Models tab's own registry/browsing, mirroring
/// the Mac app), not yet unified with it. `ChatSession` (from
/// `MLXLMCommon`) then provides the actual multi-turn conversation —
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
    /// Set by the `generate_image` tool dispatch when a call completes
    /// during the current `send`/`streamSend` — the caller reads it
    /// once the stream finishes to attach the image to the visible
    /// reply (`ChatMessage.generatedImagePath`), mirroring
    /// `ChatViewModel.runGenerateImageTool`'s returned path on the Mac.
    @Published private(set) var lastGeneratedImagePath: String?

    // Qualified explicitly: the vendored StableDiffusion sources
    // (`NativeImageEngine`'s `StableDiffusion/` directory) declare their
    // own, unrelated generic `ModelContainer<M>` in this same app
    // module, and an unqualified `ModelContainer` here resolves to that
    // one instead of MLXLMCommon's.
    private var container: MLXLMCommon.ModelContainer?
    private var session: ChatSession?
    private let imageEngine: NativeImageEngine

    init(imageEngine: NativeImageEngine) {
        self.imageEngine = imageEngine
    }

    /// Whether a model's weights are currently resident — gates the
    /// Load/Unload button and the model-ID field, same meaning it had
    /// before the container/session split.
    var isLoaded: Bool { container != nil }

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
    func load(modelID: String, instructions: String? = nil, history: [ChatMessage] = []) async {
        guard !isLoading else { return }
        errorMessage = nil

        if container == nil || loadedModelID != modelID {
            isLoading = true
            loadProgress = 0
            do {
                let configuration = ModelConfiguration(id: modelID)
                container = try await #huggingFaceLoadModelContainer(configuration: configuration) { [weak self] progress in
                    Task { @MainActor in self?.loadProgress = progress.fractionCompleted }
                }
                loadedModelID = modelID
            } catch {
                errorMessage = error.localizedDescription
                container = nil
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
        loadedModelID = nil
    }

    /// One full reply — the same "wait for the whole thing" shape
    /// `ChatClient.send` gives the macOS app.
    func send(_ text: String) async throws -> String {
        guard let session else { throw NativeChatEngineError.notLoaded }
        refreshTools()
        return try await session.respond(to: text)
    }

    /// Token-by-token, for a real-time reply the way `mlx_lm.server`'s
    /// own streaming would look if the Mac app's `ChatClient` used it
    /// (today it doesn't — it waits for the full response).
    func streamSend(_ text: String) throws -> AsyncThrowingStream<String, Error> {
        guard let session else { throw NativeChatEngineError.notLoaded }
        refreshTools()
        return session.streamResponse(to: text)
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
    var errorDescription: String? { "No model is loaded." }
}
