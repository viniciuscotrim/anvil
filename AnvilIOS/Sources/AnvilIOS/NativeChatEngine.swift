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
@MainActor
final class NativeChatEngine: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var loadProgress: Double?
    @Published private(set) var loadedModelID: String?
    @Published var errorMessage: String?

    private var session: ChatSession?

    var isLoaded: Bool { session != nil }

    /// `instructions`, when given, becomes the session's system prompt —
    /// a registered model's default `ChatProfile`, the same "loading
    /// this model applies its bound profile automatically" behavior the
    /// Mac app's `ChatViewModel` gives.
    func load(modelID: String, instructions: String? = nil) async {
        guard !isLoading else { return }
        errorMessage = nil
        isLoading = true
        loadProgress = 0
        defer { isLoading = false }

        do {
            let configuration = ModelConfiguration(id: modelID)
            let container = try await #huggingFaceLoadModelContainer(configuration: configuration) { [weak self] progress in
                Task { @MainActor in self?.loadProgress = progress.fractionCompleted }
            }
            session = ChatSession(container, instructions: instructions)
            loadedModelID = modelID
        } catch {
            errorMessage = error.localizedDescription
        }
        loadProgress = nil
    }

    func unload() {
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
}

enum NativeChatEngineError: LocalizedError {
    case notLoaded
    var errorDescription: String? { "No model is loaded." }
}
