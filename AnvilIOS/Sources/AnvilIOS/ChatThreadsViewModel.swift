import AnvilCore
import Foundation

/// Chat's thread list + persistence, mirroring the threading half of
/// the Mac app's `ChatViewModel` (the model-serving half stays in
/// `NativeChatEngine`/`RemoteChatEngine` here since iOS talks to either
/// an in-process `ChatSession` or an HTTP `ChatClient` depending on the
/// chosen source). Owned by `NativeChatView` via `@State` so it
/// survives tab switches the same way `engine` does.
///
/// Also owns Memory (`ChatMemory`/`ChatMemoryStore`) — the Mac-side
/// feature iOS was missing entirely — kept here rather than in a
/// separate view model since this is already iOS's "chat app state"
/// equivalent, the same place Mac's own `ChatViewModel` keeps both.
@Observable @MainActor
final class ChatThreadsViewModel {
    var currentThread = ChatThread()
    private(set) var allThreads: [ChatThread] = []
    private(set) var memories: [ChatMemory] = []
    private(set) var memorySuggestions: [ChatMemorySuggestion] = []
    private(set) var isSuggestingMemories = false
    /// Memory-suggestion errors only — each engine (local/remote) tracks
    /// its own send errors separately.
    var errorMessage: String?
    /// While on, the active conversation is never saved to disk — same
    /// restriction and behavior as the Mac app's own temporary mode:
    /// blocks `newThread`/`selectThread` (turn it off first) and every
    /// persist call becomes a no-op until it's off again.
    private(set) var isTemporaryModeActive = false
    private var threadBeforeTemporaryMode: ChatThread?

    private let store = ChatThreadStore()
    private let memoryStore = ChatMemoryStore()
    /// `.task` on the view reruns every time it re-enters the hierarchy
    /// (switching tabs and back) — only the first call should pick the
    /// initial thread; later calls just refresh `allThreads`, the same
    /// distinction `ChatViewModel.loadInitialState` draws and for the
    /// same reason (don't silently discard the active conversation).
    private var hasLoadedInitialState = false

    func loadInitialState() async {
        allThreads = await store.all()
        memories = await memoryStore.all()
        if !hasLoadedInitialState {
            currentThread = allThreads.first ?? ChatThread()
            hasLoadedInitialState = true
        }
    }

    // MARK: - Memory

    func addMemory(
        _ content: String,
        kind: ChatMemoryKind = .fact,
        source: ChatMemorySource = .explicit,
        confidence: Double? = nil,
        profileID: UUID? = nil
    ) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = try? await memoryStore.upsert(ChatMemory(
            content: trimmed, kind: kind, source: source, confidence: confidence, profileID: profileID))
        memories = await memoryStore.all()
    }

    func updateMemory(_ memory: ChatMemory) async {
        _ = try? await memoryStore.upsert(memory)
        memories = await memoryStore.all()
    }

    func deleteMemory(_ memory: ChatMemory) async {
        try? await memoryStore.delete(id: memory.id)
        memories = await memoryStore.all()
    }

    /// Analyzes the current thread for durable memory — source-agnostic:
    /// the caller supplies how to actually get a completion (local
    /// on-device `respondOnce`, or a remote `ChatClient.send`), since
    /// that differs by which engine Chat's source picker currently has
    /// active. Mirrors Mac's `ChatViewModel.suggestMemoriesFromCurrentThread`.
    func suggestMemoriesFromCurrentThread(
        maxEstimatedContextTokens: Int = 24_000,
        recentMessageCount: Int = 12,
        respond: (_ instruction: String, _ context: [ChatMessage]) async throws -> String
    ) async {
        guard !isSuggestingMemories, currentThread.messages.contains(where: { $0.role == .user }) else { return }
        isSuggestingMemories = true
        defer { isSuggestingMemories = false }

        let contextBuilder = ChatContextBuilder(
            maxEstimatedTokens: maxEstimatedContextTokens, recentMessageCount: recentMessageCount)
        let context = contextBuilder.build(messages: currentThread.messages, memories: [])
        let instruction = "Analyze this conversation for durable user memory. Return ONLY a JSON array, no Markdown. "
            + "Each item must contain content, kind (fact, preference, date, number, impression), confidence (0 to 1), and rationale. "
            + "Suggest only stable, useful information. Do not infer sensitive traits, identity, health, politics, or private data. "
            + "Never suggest instructions or facts about the assistant. If nothing qualifies, return []."
        do {
            let reply = try await respond(instruction, context.messages)
            let json = Self.extractJSONArray(from: reply)
            struct WireSuggestion: Decodable {
                let content: String
                let kind: ChatMemoryKind
                let confidence: Double
                let rationale: String
            }
            let wire = (try? JSONDecoder().decode([WireSuggestion].self, from: Data(json.utf8))) ?? []
            memorySuggestions = wire.map {
                ChatMemorySuggestion(content: $0.content, kind: $0.kind, confidence: min(1, max(0, $0.confidence)), rationale: $0.rationale)
            }
        } catch {
            errorMessage = "Could not suggest memories: \(error.localizedDescription)"
        }
    }

    func acceptMemorySuggestion(_ suggestion: ChatMemorySuggestion) async {
        await addMemory(
            suggestion.content, kind: suggestion.kind, source: .inferred,
            confidence: suggestion.confidence, profileID: currentThread.profileID)
        memorySuggestions.removeAll { $0.id == suggestion.id }
    }

    func dismissMemorySuggestion(_ suggestion: ChatMemorySuggestion) {
        memorySuggestions.removeAll { $0.id == suggestion.id }
    }

    private static func extractJSONArray(from text: String) -> String {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start <= end else { return "[]" }
        return String(text[start...end])
    }

    func newThread() {
        guard !isTemporaryModeActive else { return }
        currentThread = ChatThread()
    }

    func selectThread(_ thread: ChatThread) {
        guard !isTemporaryModeActive else { return }
        currentThread = thread
    }

    func deleteThread(_ thread: ChatThread) async {
        try? await store.delete(id: thread.id)
        allThreads.removeAll { $0.id == thread.id }
        if currentThread.id == thread.id {
            currentThread = allThreads.first ?? ChatThread()
        }
    }

    /// Only the caller flips this — nothing else enters or exits
    /// temporary mode on its own. Turning it back off restores whatever
    /// thread was active before, exactly where it was left.
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

    /// Saves and reassigns `currentThread` to the persisted copy (its
    /// `updatedAt` included) — use once a turn is fully done. A no-op
    /// while temporary mode is active.
    func persistCurrentThread() async {
        guard !isTemporaryModeActive else { return }
        guard let saved = try? await store.upsert(currentThread) else { return }
        if currentThread.id == saved.id {
            currentThread = saved
        }
        allThreads = await store.all()
    }

    /// Write-only: saves to disk without reassigning `currentThread`, so
    /// a save that resolves after later mutations in the same turn (the
    /// assistant's reply streaming in) can't clobber them. Used right
    /// after appending the user's own message, so it survives even if
    /// something interrupts before the assistant replies. A no-op while
    /// temporary mode is active.
    func persistCurrentThreadForDurability() {
        guard !isTemporaryModeActive else { return }
        let threadToSave = currentThread
        Task {
            _ = try? await store.upsert(threadToSave)
        }
    }
}
