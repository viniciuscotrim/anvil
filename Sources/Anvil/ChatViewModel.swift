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
    private let imageSessions: ImageSessionManager
    private let generatedImageStore: GeneratedImageStore
    private let client = ChatClient()
    private let imageClient = ImageClient()
    private var threadBeforeTemporaryMode: ChatThread?

    init(
        sessions: ModelSessionManager,
        threadStore: ChatThreadStore,
        imageSessions: ImageSessionManager,
        generatedImageStore: GeneratedImageStore
    ) {
        self.sessions = sessions
        self.threadStore = threadStore
        self.imageSessions = imageSessions
        self.generatedImageStore = generatedImageStore
        self.currentThread = ChatThread()
    }

    var messages: [ChatMessage] { currentThread.messages }

    /// What the chat bubbles actually show — tool-call plumbing
    /// (the assistant's `generate_image` request, the `.tool` result
    /// message that answers it) stays in `messages`/history for the
    /// server's context but isn't meant for a human to read directly;
    /// the generated image ends up attached to the assistant's next
    /// real reply instead (see `send()`).
    var visibleMessages: [ChatMessage] {
        currentThread.messages.filter {
            $0.role != .tool && !($0.role == .assistant && $0.content.isEmpty && $0.toolCalls != nil)
        }
    }

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
        // Only offered when an image model is actually loaded — no
        // point advertising a tool that would just fail.
        let tools: [ChatTool] = imageSessions.readySessions.isEmpty ? [] : [.generateImage]

        isSending = true
        defer { isSending = false }

        do {
            var reply = try await client.send(
                messages: currentThread.messages,
                baseURL: endpoint,
                modelDisplayName: modelDisplayName,
                settings: settings,
                tools: tools
            )

            if let toolCall = reply.toolCalls?.first(where: { $0.name == "generate_image" }) {
                currentThread.messages.append(reply)
                let (toolResult, generatedPath) = await runGenerateImageTool(toolCall)
                currentThread.messages.append(toolResult)

                // No `tools` on the follow-up — the model just needs to
                // narrate the result, not call anything else.
                reply = try await client.send(
                    messages: currentThread.messages,
                    baseURL: endpoint,
                    modelDisplayName: modelDisplayName,
                    settings: settings
                )
                reply.generatedImagePath = generatedPath
            }

            currentThread.messages.append(reply)
            lastTokensPerSecond = reply.tokensPerSecond
            if !isTemporaryModeActive {
                persistCurrentThread()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs a `generate_image` tool call for real — actual generation
    /// through the loaded image model's server, not a stub. Returns the
    /// `.tool`-role message to feed back to the chat model, plus the
    /// generated file's path (if any) for the caller to attach to the
    /// visible reply that follows.
    private func runGenerateImageTool(_ call: ChatMessage.ToolCall) async -> (ChatMessage, String?) {
        struct Arguments: Decodable { let prompt: String }

        guard let data = call.argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: data) else {
            return (ChatMessage(role: .tool, content: "Error: could not parse tool arguments.", toolCallID: call.id), nil)
        }
        guard let imageModelID = imageSessions.readySessions.first?.id,
              let imageEndpoint = imageSessions.imageEndpoint(for: imageModelID) else {
            return (ChatMessage(role: .tool, content: "Error: no image model is loaded.", toolCallID: call.id), nil)
        }
        let imageModelName = imageSessions.session(for: imageModelID)?.model.displayName ?? imageModelID

        do {
            let result = try await imageClient.generate(prompt: arguments.prompt, baseURL: imageEndpoint)
            let saved = try await generatedImageStore.add(GeneratedImage(
                prompt: arguments.prompt,
                modelDisplayName: imageModelName,
                localPath: result.localPath,
                width: result.width,
                height: result.height,
                seed: result.seed
            ))
            let toolMessage = ChatMessage(
                role: .tool,
                content: "Image generated successfully and is already displayed to the user in this chat. "
                    + "Do not include a URL or Markdown image syntax — just briefly acknowledge it in plain text.",
                toolCallID: call.id
            )
            return (toolMessage, saved.localPath)
        } catch {
            let toolMessage = ChatMessage(
                role: .tool,
                content: "Error generating image: \(error.localizedDescription)",
                toolCallID: call.id
            )
            return (toolMessage, nil)
        }
    }

    func exportMarkdown() -> String {
        TranscriptFormatter.markdown(modelName: currentThread.title, messages: visibleMessages)
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
