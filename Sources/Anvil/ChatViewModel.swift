import Foundation
import AnvilCore

/// Chat is an app-level feature, not tied to any one model — you pick
/// which currently-loaded model you're talking to, and each one keeps
/// its own conversation history so switching between them doesn't lose
/// anything. Plain `ObservableObject` (not `@Observable`) — see the
/// `@State` toolchain note in README.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var selectedModelID: String?
    @Published private(set) var conversations: [String: [ChatMessage]] = [:]
    @Published var inputText: String = ""
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var isExportPresented = false

    private let sessions: ModelSessionManager
    private let client = ChatClient()

    init(sessions: ModelSessionManager) {
        self.sessions = sessions
    }

    var messages: [ChatMessage] {
        guard let id = selectedModelID else { return [] }
        return conversations[id] ?? []
    }

    var selectedModelDisplayName: String? {
        sessions.sessions.first { $0.id == selectedModelID }?.model.displayName
    }

    /// Keeps the selection pointed at a loaded model whenever possible —
    /// called on appear and whenever the set of loaded models changes
    /// (e.g. the one you were talking to got unloaded from the Models tab).
    func syncSelection() {
        if let id = selectedModelID, sessions.isLoaded(modelID: id) { return }
        selectedModelID = sessions.readySessions.first?.id
    }

    func exportMarkdown() -> String {
        TranscriptFormatter.markdown(
            modelName: selectedModelDisplayName ?? "model",
            messages: messages
        )
    }

    func send() async {
        guard let id = selectedModelID, let endpoint = sessions.chatEndpoint(for: id) else {
            errorMessage = "Pick a loaded model first"
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        inputText = ""
        errorMessage = nil

        var history = conversations[id] ?? []
        history.append(ChatMessage(role: .user, content: text))
        conversations[id] = history

        isSending = true
        defer { isSending = false }

        do {
            let reply = try await client.send(messages: history, baseURL: endpoint)
            conversations[id, default: []].append(reply)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
