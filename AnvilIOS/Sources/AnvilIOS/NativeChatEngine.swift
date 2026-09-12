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
@MainActor
final class NativeChatEngine: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadProgress: Double?
    @Published private(set) var loadedModelID: String?
    @Published var errorMessage: String?

    // Qualified explicitly: the vendored StableDiffusion sources
    // (`NativeImageEngine`'s `StableDiffusion/` directory) declare their
    // own, unrelated generic `ModelContainer<M>` in this same app
    // module, and an unqualified `ModelContainer` here resolves to that
    // one instead of MLXLMCommon's.
    private var container: MLXLMCommon.ModelContainer?
    private var session: ChatSession?

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
    func startSession(instructions: String? = nil, history: [ChatMessage] = []) {
        guard let container else { return }
        session = ChatSession(
            container, instructions: instructions, history: Self.chatHistory(from: history))
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
        return try await session.respond(to: text)
    }

    /// Token-by-token, for a real-time reply the way `mlx_lm.server`'s
    /// own streaming would look if the Mac app's `ChatClient` used it
    /// (today it doesn't — it waits for the full response).
    func streamSend(_ text: String) throws -> AsyncThrowingStream<String, Error> {
        guard let session else { throw NativeChatEngineError.notLoaded }
        return session.streamResponse(to: text)
    }

    /// Converts a persisted thread's messages into the wire format
    /// `ChatSession`'s history initializer expects. The system prompt
    /// is carried separately via `instructions` rather than as a stored
    /// message, and `.tool`/`.system` turns aren't replayed — iOS chat
    /// doesn't dispatch tools yet (`generate_image` isn't wired into
    /// `NativeChatEngine`), so none exist in a real persisted thread to
    /// skip today; guarding here just means one won't crash re-hydration
    /// once tool-calling does land.
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
