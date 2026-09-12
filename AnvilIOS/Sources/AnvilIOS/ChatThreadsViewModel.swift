import AnvilCore
import Foundation

/// Which Mac (if any) this phone is actively merge-syncing with and
/// sending chat requests to. Unlike Phase 2's first cut, picking a Mac
/// does **not** switch Chat/Profiles/Memory to "look at the Mac's data
/// instead" — every screen always reads this phone's own local stores;
/// picking a Mac just starts a background merge that keeps this
/// phone's local copy and that Mac's copy as the same union, each side
/// pushing what the other's missing and pulling what it's missing,
/// last-write-wins on genuine same-ID conflicts. A profile created on
/// the Mac and a different one created on the phone both end up on
/// both, exactly like the user asked for a "handover" to mean — no
/// manual curating required.
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
    var currentThread = ChatThread(originDeviceName: DeviceIdentity.currentName)
    private(set) var allThreads: [ChatThread] = []
    private(set) var memories: [ChatMemory] = []
    private(set) var memorySuggestions: [ChatMemorySuggestion] = []
    private(set) var isSuggestingMemories = false
    /// "This iPhone" or a specific Mac — see `ChatSourceSelection`.
    /// Change it via `selectSource(_:)`, not directly, so the switch
    /// actually kicks off (and keeps running) the background merge.
    private(set) var activeSource: ChatSourceSelection = .local
    /// False whenever the active Mac's last merge attempt failed —
    /// overwhelmingly just because Mac Sync is an opt-in feature the
    /// user hasn't turned on for that Mac yet, not a real error. Chat
    /// still works fine without it (send/receive don't need sync at
    /// all, and every read here is always this phone's own local data
    /// regardless); this only means that Mac's own threads/profiles/
    /// memories aren't being merged in right now.
    private(set) var isMacSyncAvailable = true
    /// Memory-suggestion errors only — a real failure worth surfacing
    /// loudly, unlike a Mac simply not having sync turned on.
    var errorMessage: String?
    /// While on, the active conversation is never saved to disk — same
    /// restriction and behavior as the Mac app's own temporary mode:
    /// blocks `newThread`/`selectThread` (turn it off first) and every
    /// persist call becomes a no-op until it's off again.
    private(set) var isTemporaryModeActive = false
    private var threadBeforeTemporaryMode: ChatThread?
    /// True for the whole span of a send — from appending the user's
    /// message through the reply finishing (or failing/cancelling).
    /// The periodic Mac merge (`mergeSyncNow`) checks this before ever
    /// touching `currentThread`: a real, reproduced crash otherwise —
    /// a durability-save partway through a reply persists a snapshot
    /// *without* that still-streaming reply yet, which gets a fresh,
    /// newer `updatedAt` from `ChatThreadStore.upsert` than the
    /// in-memory thread carries (that save never reassigns
    /// `currentThread` itself, by design, so its own `updatedAt` never
    /// advances to match). If the periodic merge's next tick lands in
    /// that window, it sees the disk copy as "newer" and swaps
    /// `currentThread` out for that shorter snapshot — out from under
    /// whichever engine is still writing `messages[replyIndex]` by
    /// position, an immediate index-out-of-bounds crash the moment the
    /// next token arrives.
    private(set) var isSendInFlight = false

    func markSendStarted() { isSendInFlight = true }
    func markSendFinished() { isSendInFlight = false }

    private let store = ChatThreadStore()
    private let memoryStore = ChatMemoryStore()
    private let syncClient = AnvilSyncClient()
    private var syncLoopTask: Task<Void, Never>?
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
            currentThread = allThreads.first ?? ChatThread(originDeviceName: DeviceIdentity.currentName)
            hasLoadedInitialState = true
        }
    }

    /// The one place `activeSource` changes — starts (or stops) a
    /// background merge loop with the newly-picked Mac. `profilesViewModel`
    /// merges in lock-step so a profile picked up from the Mac (or
    /// pushed to it) shows up the same moment threads/memories do.
    func selectSource(_ source: ChatSourceSelection, profilesViewModel: ProfilesViewModel) async {
        activeSource = source
        errorMessage = nil
        syncLoopTask?.cancel()
        syncLoopTask = nil
        guard case .mac(let connection) = source else { return }

        await mergeSyncNow(with: connection, profilesViewModel: profilesViewModel)
        syncLoopTask = Task { [weak self, weak profilesViewModel] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, let self, let profilesViewModel else { return }
                guard case .mac(let current) = self.activeSource, current.id == connection.id else { return }
                await self.mergeSyncNow(with: current, profilesViewModel: profilesViewModel)
            }
        }
    }

    /// One full merge pass with `connection`: threads, memories, and
    /// (via `profilesViewModel`) profiles — each a two-way union by ID,
    /// last-write-wins on a genuine same-ID conflict (by `updatedAt`).
    /// After this, this phone's own local stores hold the same set the
    /// Mac does, and vice versa — reads never need to reach across the
    /// network at all; this is what keeps them that way.
    private func mergeSyncNow(with connection: RemoteMacConnection, profilesViewModel: ProfilesViewModel) async {
        // Never merge mid-send — see `isSendInFlight`'s own doc comment
        // for the exact crash this prevents. The next tick, 3 seconds
        // later, catches up once the send has actually finished.
        guard !isSendInFlight else { return }
        do {
            try await Self.mergeThreads(local: store, remote: syncClient, host: connection.host)
            try await Self.mergeMemories(local: memoryStore, remote: syncClient, host: connection.host)
            await profilesViewModel.mergeSync(host: connection.host)
            isMacSyncAvailable = true
        } catch {
            isMacSyncAvailable = false
        }
        allThreads = await store.all()
        memories = await memoryStore.all()
        // If the thread being actively viewed just got a same-ID update
        // from the other side (e.g. the Mac itself answered a message
        // sent from here, or vice versa), pick that up immediately
        // rather than waiting for the user to leave and reopen it.
        if let refreshed = allThreads.first(where: { $0.id == currentThread.id }), refreshed.updatedAt > currentThread.updatedAt {
            currentThread = refreshed
        }
    }

    private static func mergeThreads(local: ChatThreadStore, remote: AnvilSyncClient, host: String) async throws {
        let localAll = await local.all()
        let remoteAll = try await remote.threads(host: host)
        let localByID = Dictionary(uniqueKeysWithValues: localAll.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteAll.map { ($0.id, $0) })
        for id in Set(localByID.keys).union(remoteByID.keys) {
            switch (localByID[id], remoteByID[id]) {
            case let (l?, r?) where l.updatedAt > r.updatedAt:
                _ = try? await remote.upsertThread(l, host: host)
            case let (l?, r?) where r.updatedAt > l.updatedAt:
                _ = try? await local.upsert(r)
            case (.some, .some):
                break // identical timestamps — already in sync
            case let (l?, nil):
                _ = try? await remote.upsertThread(l, host: host)
            case let (nil, r?):
                _ = try? await local.upsert(r)
            case (nil, nil):
                break
            }
        }
    }

    private static func mergeMemories(local: ChatMemoryStore, remote: AnvilSyncClient, host: String) async throws {
        let localAll = await local.all()
        let remoteAll = try await remote.memories(host: host)
        let localByID = Dictionary(uniqueKeysWithValues: localAll.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteAll.map { ($0.id, $0) })
        for id in Set(localByID.keys).union(remoteByID.keys) {
            switch (localByID[id], remoteByID[id]) {
            case let (l?, r?) where l.updatedAt > r.updatedAt:
                _ = try? await remote.upsertMemory(l, host: host)
            case let (l?, r?) where r.updatedAt > l.updatedAt:
                _ = try? await local.upsert(r)
            case (.some, .some):
                break
            case let (l?, nil):
                _ = try? await remote.upsertMemory(l, host: host)
            case let (nil, r?):
                _ = try? await local.upsert(r)
            case (nil, nil):
                break
            }
        }
    }

    // MARK: - Memory

    func addMemory(
        _ content: String,
        kind: ChatMemoryKind = .fact,
        source: ChatMemorySource = .explicit,
        confidence: Double? = nil,
        profileID: UUID? = nil,
        createdFromMessageID: UUID? = nil
    ) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let memory = ChatMemory(
            content: trimmed, kind: kind, source: source, confidence: confidence, profileID: profileID,
            originDeviceName: DeviceIdentity.currentName, createdFromMessageID: createdFromMessageID)
        _ = try? await memoryStore.upsert(memory)
        memories = await memoryStore.all()
        await pushMemoryIfMacActive(memory)
    }

    func updateMemory(_ memory: ChatMemory) async {
        _ = try? await memoryStore.upsert(memory)
        memories = await memoryStore.all()
        await pushMemoryIfMacActive(memory)
    }

    func deleteMemory(_ memory: ChatMemory) async {
        try? await memoryStore.delete(id: memory.id)
        memories = await memoryStore.all()
        if case .mac(let connection) = activeSource {
            try? await syncClient.deleteMemory(id: memory.id, host: connection.host)
        }
    }

    /// Best-effort, immediate push so a new/edited memory reaches the
    /// Mac right away instead of waiting for the next periodic merge
    /// tick — the periodic merge is the safety net, this is what makes
    /// it feel instant.
    private func pushMemoryIfMacActive(_ memory: ChatMemory) async {
        guard case .mac(let connection) = activeSource else { return }
        _ = try? await syncClient.upsertMemory(memory, host: connection.host)
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
            confidence: suggestion.confidence, profileID: currentThread.profileID,
            createdFromMessageID: currentThread.messages.last?.id)
        memorySuggestions.removeAll { $0.id == suggestion.id }
    }

    // MARK: - Editing/deleting a sent message

    /// Deletes `message` and every message that came after it in
    /// `currentThread` — an in-progress conversation only makes sense
    /// as a straight line, so removing something from the middle can't
    /// leave a dangling reply that was actually about the thing just
    /// removed. Also deletes any memory that traces back
    /// (`createdFromMessageID`) to one of the removed messages, so
    /// deleting the question that led to a "remembered" fact doesn't
    /// leave that fact behind with nothing to justify it.
    func deleteMessage(_ message: ChatMessage) async {
        guard let index = currentThread.messages.firstIndex(where: { $0.id == message.id }) else { return }
        await truncate(from: index)
    }

    /// Same truncation as `deleteMessage`, but returns the removed
    /// message's own content first so the caller can drop it back into
    /// the composer — "editing" a sent message here means resending it
    /// in its place, reusing the exact same send path a brand-new
    /// message already goes through rather than a separate in-place
    /// regenerate mechanism.
    func beginEditingMessage(_ message: ChatMessage) async -> String? {
        guard let index = currentThread.messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        let content = message.content
        await truncate(from: index)
        return content
    }

    private func truncate(from index: Int) async {
        let removedIDs = Set(currentThread.messages[index...].map(\.id))
        currentThread.messages.removeSubrange(index...)
        let orphaned = memories.filter { memory in
            guard let sourceID = memory.createdFromMessageID else { return false }
            return removedIDs.contains(sourceID)
        }
        for memory in orphaned {
            await deleteMemory(memory)
        }
        await persistCurrentThread()
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
        currentThread = ChatThread(originDeviceName: DeviceIdentity.currentName)
    }

    func selectThread(_ thread: ChatThread) {
        guard !isTemporaryModeActive else { return }
        currentThread = thread
    }

    func deleteThread(_ thread: ChatThread) async {
        try? await store.delete(id: thread.id)
        if case .mac(let connection) = activeSource {
            try? await syncClient.deleteThread(id: thread.id, host: connection.host)
        }
        allThreads.removeAll { $0.id == thread.id }
        if currentThread.id == thread.id {
            currentThread = allThreads.first ?? ChatThread(originDeviceName: DeviceIdentity.currentName)
        }
    }

    /// Only the caller flips this — nothing else enters or exits
    /// temporary mode on its own. Turning it back off restores whatever
    /// thread was active before, exactly where it was left.
    func toggleTemporaryMode() {
        if isTemporaryModeActive {
            isTemporaryModeActive = false
            currentThread = threadBeforeTemporaryMode ?? allThreads.first ?? ChatThread(originDeviceName: DeviceIdentity.currentName)
            threadBeforeTemporaryMode = nil
        } else {
            threadBeforeTemporaryMode = currentThread
            currentThread = ChatThread(title: "Temporary Chat", originDeviceName: DeviceIdentity.currentName)
            isTemporaryModeActive = true
        }
    }

    /// Saves and reassigns `currentThread` to the persisted copy (its
    /// `updatedAt` included) — use once a turn is fully done. Always
    /// writes this phone's own local store first (the single source of
    /// truth this app reads from); when a Mac is active, also pushes
    /// the same save there right away so the Mac doesn't have to wait
    /// for the next periodic merge tick to see it. A no-op while
    /// temporary mode is active.
    func persistCurrentThread() async {
        guard !isTemporaryModeActive else { return }
        guard let saved = try? await store.upsert(currentThread) else { return }
        if currentThread.id == saved.id {
            currentThread = saved
        }
        allThreads = await store.all()
        if case .mac(let connection) = activeSource {
            _ = try? await syncClient.upsertThread(saved, host: connection.host)
        }
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
            guard let saved = try? await store.upsert(threadToSave) else { return }
            if case .mac(let connection) = source {
                _ = try? await syncClient.upsertThread(saved, host: connection.host)
            }
        }
    }
}
