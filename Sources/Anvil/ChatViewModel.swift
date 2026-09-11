import Foundation
import AnvilCore

/// Plain `ObservableObject` (not `@Observable`) — see the `@State`
/// toolchain note in README.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isLoadingModel = false
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var isServerReady = false

    let model: ModelEntry
    private let requirements: RequirementsManager
    private let server = LLMServer()
    private let client = ChatClient()

    init(model: ModelEntry, requirements: RequirementsManager) {
        self.model = model
        self.requirements = requirements
    }

    func start() async {
        guard !isServerReady, !isLoadingModel else { return }
        isLoadingModel = true
        errorMessage = nil
        defer { isLoadingModel = false }

        let ready = await requirements.ensure(TextModelRuntimeDependency())
        guard ready else {
            errorMessage = requirements.lastError ?? "Could not set up text generation"
            return
        }

        do {
            try await server.start(modelPath: model.localPath)
            isServerReady = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isServerReady, !isSending else { return }
        inputText = ""
        errorMessage = nil
        messages.append(ChatMessage(role: .user, content: text))
        isSending = true
        defer { isSending = false }

        do {
            let baseURL = await server.baseURL
            let reply = try await client.send(messages: messages, baseURL: baseURL, model: model.id)
            messages.append(reply)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() async {
        await server.stop()
        isServerReady = false
    }
}
