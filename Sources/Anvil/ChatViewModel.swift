import Foundation
import AnvilCore

/// App-level chat state — owned once by `AppState`, not recreated when
/// the Chat tab is hidden and shown again (that was the earlier bug:
/// a view-local `@StateObject` was torn down on navigation, losing the
/// conversation). Plain `ObservableObject` (not `@Observable`) — see
/// the `@State` toolchain note in README.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var currentThread: ChatThread
    @Published private(set) var allThreads: [ChatThread] = []
    @Published private(set) var isTemporaryModeActive = false
    @Published var selectedModelID: String?
    @Published var inputText: String = ""
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var hideReasoning = true
    @Published var settings = GenerationSettings.default
    @Published var isExportPresented = false
    @Published var isSidebarOpen = false
    @Published private(set) var lastTokensPerSecond: Double?

    private let sessions: ModelSessionManager
    private let threadStore: ChatThreadStore
    private let client = ChatClient()
    private var threadBeforeTemporaryMode: ChatThread?

    init(sessions: ModelSessionManager, threadStore: ChatThreadStore) {
        self.sessions = sessions
        self.threadStore = threadStore
        self.currentThread = ChatThread()
    }

    var messages: [ChatMessage] { currentThread.messages }

    func loadInitialState() async {
        allThreads = await threadStore.all()
        currentThread = allThreads.first ?? ChatThread()
        syncSelectedModel()
    }

    /// Keeps the selection pointed at a loaded model — called on
    /// appear and whenever the set of loaded models changes.
    func syncSelectedModel() {
        if let id = selectedModelID, sessions.isLoaded(modelID: id) { return }
        selectedModelID = sessions.readySessions.first?.id
    }

    // MARK: - Threads

    /// Blocked while temporary mode is active — the user has to turn
    /// that off first (an explicit action) before starting or switching
    /// to anything persisted.
    func newThread() {
        guard !isTemporaryModeActive else { return }
        currentThread = ChatThread()
    }

    func selectThread(_ thread: ChatThread) {
        guard !isTemporaryModeActive else { return }
        currentThread = thread
    }

    func deleteThread(_ thread: ChatThread) async {
        try? await threadStore.delete(id: thread.id)
        allThreads.removeAll { $0.id == thread.id }
        if currentThread.id == thread.id {
            currentThread = allThreads.first ?? ChatThread()
        }
    }

    /// Empties the active conversation without deleting the thread
    /// entry itself.
    func clearCurrentConversation() {
        currentThread.messages.removeAll()
        lastTokensPerSecond = nil
        if !isTemporaryModeActive {
            persistCurrentThread()
        }
    }

    /// Only the user flips this — nothing else enters or exits
    /// temporary mode on its own. While active, the conversation never
    /// touches disk; turning it off restores whatever thread was active
    /// before.
    func toggleTemporaryMode() {
        if isTemporaryModeActive {
            isTemporaryModeActive = false
            currentThread = threadBeforeTemporaryMode ?? allThreads.first ?? ChatThread()
            threadBeforeTemporaryMode = nil
        } else {
            threadBeforeTemporaryMode = currentThread
            currentThread = ChatThread(title: "Temporary Chat")
            isTemporaryModeActive = true
        }
    }

    // MARK: - Sending

    func send() async {
        guard let id = selectedModelID, let endpoint = sessions.chatEndpoint(for: id) else {
            errorMessage = "Pick a loaded model first"
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        inputText = ""
        errorMessage = nil

        currentThread.messages.append(ChatMessage(role: .user, content: text))
        if currentThread.title == "New Chat" || currentThread.title == "Temporary Chat" {
            if currentThread.messages.count == 1 {
                let title = String(text.prefix(48))
                currentThread.title = isTemporaryModeActive ? "Temporary: \(title)" : title
            }
        }

        let modelDisplayName = sessions.sessions.first { $0.id == id }?.model.displayName ?? id

        isSending = true
        defer { isSending = false }

        do {
            let reply = try await client.send(
                messages: currentThread.messages,
                baseURL: endpoint,
                modelDisplayName: modelDisplayName,
                settings: settings
            )
            currentThread.messages.append(reply)
            lastTokensPerSecond = reply.tokensPerSecond
            if !isTemporaryModeActive {
                persistCurrentThread()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportMarkdown() -> String {
        TranscriptFormatter.markdown(modelName: currentThread.title, messages: currentThread.messages)
    }

    private func persistCurrentThread() {
        let threadToSave = currentThread
        Task {
            guard let saved = try? await threadStore.upsert(threadToSave) else { return }
            if currentThread.id == saved.id {
                currentThread = saved
            }
            allThreads = await threadStore.all()
        }
    }
}
