import AnvilCore
import Foundation

/// Which data Chat/Profiles/Memory currently read and write — "This
/// iPhone" (this device's own local files) or a specific Mac with
/// `AnvilSyncServer` turned on, in which case the Mac's own threads,
/// profiles, and memories become the ones shown here, updated on the
/// Mac even though the iPhone is doing the typing. Switching this is the
/// one action (Chat's source menu) that puts every one of those three
/// tabs into "Mac mode" together, and back, symmetrically.
enum ChatSourceSelection: Equatable {
    case local
    case mac(RemoteMacConnection)

    var host: String? {
        if case .mac(let connection) = self { return connection.host }
        return nil
    }
}

/// Chat's thread list + persistence, mirroring the threading half of
/// the Mac app's `ChatViewModel` (the model-serving half stays in
/// `NativeChatEngine`/`RemoteChatEngine` here since iOS talks to either
/// an in-process `ChatSession` or an HTTP `ChatClient` depending on the
/// chosen source). Owned once at the app level (`AnvilIOSApp`) and
/// shared via `.environment`, not per-view — Memory and Profiles need to
/// see the exact same `activeSource`/`currentThread` Chat does.
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
    /// "This iPhone" or a specific Mac — see `ChatSourceSelection`.
    /// Change it via `selectSource(_:)`, not directly, so the switch
    /// actually reloads threads/memories from the newly active side.
    private(set) var activeSource: ChatSourceSelection = .local
    /// Memory-suggestion / source-switch errors. Each engine (local/
    /// remote) tracks its own send errors separately.
    var errorMessage: String?
    /// While on, the active conversation is never saved to disk — same
    /// restriction and behavior as the Mac app's own temporary mode:
    /// blocks `newThread`/`selectThread` (turn it off first) and every
    /// persist call becomes a no-op until it's off again. Only
    /// meaningful for `.local` — a Mac source is never temporary, since
    /// the whole point of picking one is durable continuity with the Mac.
    private(set) var isTemporaryModeActive = false
    private var threadBeforeTemporaryMode: ChatThread?

    private let store = ChatThreadStore()
    private let memoryStore = ChatMemoryStore()
    private let syncClient = AnvilSyncClient()
    /// `.task` on the view reruns every time it re-enters the hierarchy
    /// (switching tabs and back) — only the first call should pick the
    /// initial thread; later calls just refresh `allThreads`, the same
    /// distinction `ChatViewModel.loadInitialState` draws and for the
    /// same reason (don't silently discard the active conversation).
    private var hasLoadedInitialState = false

    func loadInitialState() async {
        await reloadThreadsAndMemories()
        if !hasLoadedInitialState {
            currentThread = allThreads.first ?? ChatThread()
            hasLoadedInitialState = true
        }
    }

    /// The one place `activeSource` changes — reloads threads and
    /// memories from the newly active side and points `currentThread`
    /// at its most-recent thread (or a blank one), same as a fresh
    /// launch would. `profilesViewModel` is updated in lock-step so all
    /// three tabs agree on which side they're showing.
    func selectSource(_ source: ChatSourceSelection, profilesViewModel: ProfilesViewModel) async {
        activeSource = source
        errorMessage = nil
        await profilesViewModel.setActiveHost(source.host)
        await reloadThreadsAndMemories()
        currentThread = allThreads.first ?? ChatThread()
    }

    private func reloadThreadsAndMemories() async {
        switch activeSource {
        case .local:
            allThreads = await store.all()
            memories = await memoryStore.all()
        case .mac(let connection):
            do {
                allThreads = try await syncClient.threads(host: connection.host)
                memories = try await syncClient.memories(host: connection.host)
            } catch {
                errorMessage = error.localizedDescription
            }
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
        let memory = ChatMemory(content: trimmed, kind: kind, source: source, confidence: confidence, profileID: profileID)
        await upsertMemory(memory)
    }

    func updateMemory(_ memory: ChatMemory) async {
        await upsertMemory(memory)
    }

    private func upsertMemory(_ memory: ChatMemory) async {
        switch activeSource {
        case .local:
            _ = try? await memoryStore.upsert(memory)
        case .mac(let connection):
            _ = try? await syncClient.upsertMemory(memory, host: connection.host)
        }
        await reloadThreadsAndMemories()
    }

    func deleteMemory(_ memory: ChatMemory) async {
        switch activeSource {
        case .local:
            try? await memoryStore.delete(id: memory.id)
        case .mac(let connection):
            try? await syncClient.deleteMemory(id: memory.id, host: connection.host)
        }
        await reloadThreadsAndMemories()
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

    // MARK: - Threads

    func newThread() {
        guard !isTemporaryModeActive else { return }
        currentThread = ChatThread()
    }

    func selectThread(_ thread: ChatThread) {
        guard !isTemporaryModeActive else { return }
        currentThread = thread
    }

    func deleteThread(_ thread: ChatThread) async {
        switch activeSource {
        case .local:
            try? await store.delete(id: thread.id)
        case .mac(let connection):
            try? await syncClient.deleteThread(id: thread.id, host: connection.host)
        }
        allThreads.removeAll { $0.id == thread.id }
        if currentThread.id == thread.id {
            currentThread = allThreads.first ?? ChatThread()
        }
    }

    /// Only the caller flips this — nothing else enters or exits
    /// temporary mode on its own. Turning it back off restores whatever
    /// thread was active before, exactly where it was left. A no-op
    /// while a Mac source is active (see `isTemporaryModeActive`'s own
    /// doc comment).
    func toggleTemporaryMode() {
        guard activeSource == .local else { return }
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
        let threadToSave = currentThread
        let saved: ChatThread?
        switch activeSource {
        case .local:
            saved = try? await store.upsert(threadToSave)
        case .mac(let connection):
            saved = try? await syncClient.upsertThread(threadToSave, host: connection.host)
        }
        guard let saved else { return }
        if currentThread.id == saved.id {
            currentThread = saved
        }
        await reloadThreadsAndMemories()
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
        let source = activeSource
        Task {
            switch source {
            case .local:
                _ = try? await store.upsert(threadToSave)
            case .mac(let connection):
                _ = try? await syncClient.upsertThread(threadToSave, host: connection.host)
            }
        }
    }
}
