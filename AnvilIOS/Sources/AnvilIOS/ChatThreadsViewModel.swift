import AnvilCore
import CloudKit
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
    /// `(completed batches, total batches)` while `isSuggestingMemories`
    /// is true — see Mac's own `ChatViewModel.memorySuggestionProgress`
    /// doc comment for the real reported problem this fixes.
    private(set) var memorySuggestionProgress: (completed: Int, total: Int)?
    /// Which text model "Suggest from Thread" should use — nil means
    /// "whatever `NativeChatEngine` currently has loaded". Unlike Mac
    /// (which can run several models concurrently), iOS's engine loads
    /// one model at a time, so picking a different one here means
    /// `MemoryView` swaps the engine over to it before analyzing —
    /// after asking, since that also affects whatever Chat itself
    /// would use next.
    private(set) var memorySuggestionModelID: String? = AppSettings.load().memorySuggestionModelID
    /// Every registered text model, loaded or not — same "offer
    /// everything mapped in the folder, not just what's resident"
    /// requested for Mac's own picker.
    private(set) var availableTextModels: [ModelEntry] = []
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
    /// On by default, mirroring the Mac app's own `ChatViewModel
    /// .hideReasoning` — a reasoning model's `<think>…</think>` block
    /// is always captured into `ChatMessage.reasoning` regardless
    /// (`NativeChatEngine.streamSend`/`RemoteChatEngine` both split it
    /// out already), this only controls whether `NativeChatView` shows
    /// it. Reported live: "Precisamos colocar no iPhone agora o botão
    /// de ocultar o Thinking do modelo. Não dá pra conversar como
    /// está" — the whole point of turning this on by default, the same
    /// as Mac, since an unfiltered thinking block is what actually
    /// made the phone unusable for chat before this existed at all.
    var hideReasoning = true
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
    private let suggestionStore = ChatMemorySuggestionStore()
    private let modelRegistry = ModelRegistry()
    private let syncClient = AnvilSyncClient()
    private var syncLoopTask: Task<Void, Never>?
    private let cloudSync = CloudSyncEngine()
    /// Off by default — see `CloudSyncEngine`'s own header comment.
    /// Independent of `activeSource`/`AnvilSyncServer`: this one works
    /// from anywhere, no Mac reachability required at all, through the
    /// user's own private iCloud database.
    private(set) var isCloudSyncEnabled = AppSettings.load().isCloudSyncEnabled
    private(set) var cloudAccountStatus: CKAccountStatus?

    /// Called once at launch — starts the cloud sync engine if it was
    /// left on from a previous launch, after confirming the account is
    /// actually usable. Degrades to "just doesn't sync" otherwise,
    /// never blocks or errors the rest of the app.
    func applyCloudSyncSettingsIfNeeded() async {
        guard isCloudSyncEnabled else { return }
        cloudAccountStatus = await cloudSync.accountStatus()
        guard cloudAccountStatus == .available else { return }
        try? await cloudSync.start()
    }

    func setCloudSyncEnabled(_ enabled: Bool) {
        isCloudSyncEnabled = enabled
        var settings = AppSettings.load()
        settings.isCloudSyncEnabled = enabled
        try? settings.save()
        Task {
            if enabled {
                await applyCloudSyncSettingsIfNeeded()
            } else {
                await cloudSync.stop()
            }
        }
    }
    /// `.task` on the view reruns every time it re-enters the hierarchy
    /// (switching tabs and back) — only the first call should pick the
    /// initial thread; later calls just refresh `allThreads`, the same
    /// distinction `ChatViewModel.loadInitialState` draws and for the
    /// same reason (don't silently discard the active conversation).
    private var hasLoadedInitialState = false

    func loadInitialState() async {
        allThreads = await store.all()
        memories = await memoryStore.all()
        if !isSuggestingMemories {
            memorySuggestions = await suggestionStore.all()
        }
        availableTextModels = await modelRegistry.all().filter { $0.kind == .text }
        if !hasLoadedInitialState {
            currentThread = allThreads.first ?? ChatThread(originDeviceName: DeviceIdentity.currentName)
            hasLoadedInitialState = true
        }
    }

    /// The one place `activeSource` changes — starts (or stops) a
    /// background merge loop with the newly-picked Mac. `profilesViewModel`
    /// merges in lock-step so a profile picked up from the Mac (or
    /// pushed to it) shows up the same moment threads/memories do.
    /// Also persists the pick (see `lastMacConnectionIDKey`) — a real,
    /// reported bug otherwise: `activeSource` only ever lived in
    /// memory, defaulting back to `.local` on every fresh launch, which
    /// silently killed the sync loop until the user happened to notice
    /// and reselect the Mac by hand. `resumeLastMacSourceIfNeeded`
    /// reads this back on the next launch.
    func selectSource(_ source: ChatSourceSelection, profilesViewModel: ProfilesViewModel) async {
        activeSource = source
        errorMessage = nil
        syncLoopTask?.cancel()
        syncLoopTask = nil
        switch source {
        case .local:
            UserDefaults.standard.removeObject(forKey: Self.lastMacConnectionIDKey)
            return
        case .mac(let connection):
            UserDefaults.standard.set(connection.id.uuidString, forKey: Self.lastMacConnectionIDKey)
        }
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

    private static let lastMacConnectionIDKey = "AnvilLastMacConnectionID"

    /// Called once, at launch, after connections have loaded — restores
    /// whichever Mac was last selected (if any, and if it's still among
    /// the saved connections) so sync resumes automatically instead of
    /// staying silently off until the user reopens the source menu and
    /// picks it again by hand.
    func resumeLastMacSourceIfNeeded(connections: [RemoteMacConnection], profilesViewModel: ProfilesViewModel) async {
        guard case .local = activeSource else { return }
        guard let idString = UserDefaults.standard.string(forKey: Self.lastMacConnectionIDKey),
            let id = UUID(uuidString: idString),
            let connection = connections.first(where: { $0.id == id })
        else { return }
        await selectSource(.mac(connection), profilesViewModel: profilesViewModel)
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

    /// A real, reproduced bug this fixes: this used to be a plain union
    /// (whichever side is missing a thread gets it pushed to it), which
    /// cannot tell "never existed on the other side yet" apart from
    /// "existed, but was just deleted" — every ~3s merge tick after a
    /// delete would see the thread "missing" here and immediately
    /// restore it from whichever device still had it. IDs are UUIDs
    /// that are never reused, so a tombstone's mere presence (no
    /// timestamp arbitration needed) safely distinguishes the two
    /// cases. Pulls/pushes that DO carry real content now go through
    /// `upsertPreservingTimestamp` rather than `upsert` — seee
    /// `ChatThreadStore`'s own doc comment for why stamping "now" on a
    /// replicated write breaks every future recency comparison.
    private static func mergeThreads(local: ChatThreadStore, remote: AnvilSyncClient, host: String) async throws {
        let localAll = await local.all()
        let remoteAll = try await remote.threads(host: host)
        let localByID = Dictionary(uniqueKeysWithValues: localAll.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteAll.map { ($0.id, $0) })
        let localTombstones = await local.deletionTimestamps()
        let remoteTombstones = (try? await remote.deletedThreadIDs(host: host)) ?? [:]
        for id in Set(localByID.keys).union(remoteByID.keys) {
            switch (localByID[id], remoteByID[id]) {
            case let (l?, r?) where l.updatedAt > r.updatedAt:
                _ = try? await remote.upsertThread(l, host: host)
            case let (l?, r?) where r.updatedAt > l.updatedAt:
                _ = try? await local.upsertPreservingTimestamp(r)
            case (.some, .some):
                break // identical timestamps — already in sync
            case let (l?, nil):
                if remoteTombstones[id] != nil {
                    try? await local.delete(id: id)
                } else {
                    _ = try? await remote.upsertThread(l, host: host)
                }
            case let (nil, r?):
                if localTombstones[id] != nil {
                    try? await remote.deleteThread(id: id, host: host)
                } else {
                    _ = try? await local.upsertPreservingTimestamp(r)
                }
            case (nil, nil):
                break
            }
        }
    }

    /// Same real bug, same fix — see `mergeThreads`'s doc comment.
    private static func mergeMemories(local: ChatMemoryStore, remote: AnvilSyncClient, host: String) async throws {
        let localAll = await local.all()
        let remoteAll = try await remote.memories(host: host)
        let localByID = Dictionary(uniqueKeysWithValues: localAll.map { ($0.id, $0) })
        let remoteByID = Dictionary(uniqueKeysWithValues: remoteAll.map { ($0.id, $0) })
        let localTombstones = await local.deletionTimestamps()
        let remoteTombstones = (try? await remote.deletedMemoryIDs(host: host)) ?? [:]
        for id in Set(localByID.keys).union(remoteByID.keys) {
            switch (localByID[id], remoteByID[id]) {
            case let (l?, r?) where l.updatedAt > r.updatedAt:
                _ = try? await remote.upsertMemory(l, host: host)
            case let (l?, r?) where r.updatedAt > l.updatedAt:
                _ = try? await local.upsertPreservingTimestamp(r)
            case (.some, .some):
                break
            case let (l?, nil):
                if remoteTombstones[id] != nil {
                    try? await local.delete(id: id)
                } else {
                    _ = try? await remote.upsertMemory(l, host: host)
                }
            case let (nil, r?):
                if localTombstones[id] != nil {
                    try? await remote.deleteMemory(id: id, host: host)
                } else {
                    _ = try? await local.upsertPreservingTimestamp(r)
                }
            case (nil, nil):
                break
            }
        }
    }

    // MARK: - Memory

    /// `MemoryView`'s own picker routes through here rather than
    /// setting `memorySuggestionModelID` directly, so the choice
    /// survives an app relaunch — matches Mac's own
    /// `ChatViewModel.setMemorySuggestionModelID`.
    func setMemorySuggestionModelID(_ id: String?) {
        memorySuggestionModelID = id
        var settings = AppSettings.load()
        settings.memorySuggestionModelID = id
        try? settings.save()
    }

    /// `originThreadID`/`isGlobal` default to thread-scoped, tied to
    /// whichever thread is current — requested live: "Temos que deixar
    /// memórias por thread/conversa. E elas são geradas e consumidas
    /// dentro do thread que foram geradas." Mirrors Mac's own
    /// `ChatViewModel.addMemory`.
    func addMemory(
        _ content: String,
        kind: ChatMemoryKind = .fact,
        source: ChatMemorySource = .explicit,
        confidence: Double? = nil,
        profileID: UUID? = nil,
        createdFromMessageID: UUID? = nil,
        originThreadID: UUID? = nil,
        isGlobal: Bool = false
    ) async {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let memory = ChatMemory(
            content: trimmed, kind: kind, source: source, confidence: confidence, profileID: profileID,
            originDeviceName: DeviceIdentity.currentName, createdFromMessageID: createdFromMessageID,
            originThreadID: originThreadID ?? currentThread.id, isGlobal: isGlobal)
        _ = try? await memoryStore.upsert(memory)
        memories = await memoryStore.all()
        await pushMemoryIfMacActive(memory)
        await pushMemoryToCloudIfEnabled(memory)
    }

    func updateMemory(_ memory: ChatMemory) async {
        _ = try? await memoryStore.upsert(memory)
        memories = await memoryStore.all()
        await pushMemoryIfMacActive(memory)
        await pushMemoryToCloudIfEnabled(memory)
    }

    /// Flips whether `memory` applies everywhere or only within the
    /// thread it was originally generated in — mirrors Mac's own
    /// `ChatViewModel.toggleMemoryGlobal`.
    func toggleMemoryGlobal(_ memory: ChatMemory) async {
        var updated = memory
        updated.isGlobal.toggle()
        await updateMemory(updated)
    }

    /// Rewrites a memory's own text in place — mirrors Mac's own
    /// `ChatViewModel.editMemoryContent`. Requested live (both
    /// platforms): "também poder editar/reescrever uma memoria
    /// capturada."
    func editMemoryContent(_ memory: ChatMemory, to newContent: String) async {
        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != memory.content else { return }
        var updated = memory
        updated.content = trimmed
        await updateMemory(updated)
    }

    func deleteMemory(_ memory: ChatMemory) async {
        try? await memoryStore.delete(id: memory.id)
        memories = await memoryStore.all()
        if case .mac(let connection) = activeSource {
            try? await syncClient.deleteMemory(id: memory.id, host: connection.host)
        }
        if isCloudSyncEnabled {
            await cloudSync.markMemoryDeleted(id: memory.id)
            await cloudSync.syncNow()
        }
    }

    private func pushMemoryToCloudIfEnabled(_ memory: ChatMemory) async {
        guard isCloudSyncEnabled else { return }
        await cloudSync.markMemoryChanged(memory)
        await cloudSync.syncNow()
    }

    /// Best-effort, immediate push so a new/edited memory reaches the
    /// Mac right away instead of waiting for the next periodic merge
    /// tick — the periodic merge is the safety net, this is what makes
    /// it feel instant.
    private func pushMemoryIfMacActive(_ memory: ChatMemory) async {
        guard case .mac(let connection) = activeSource else { return }
        _ = try? await syncClient.upsertMemory(memory, host: connection.host)
    }

    /// Reads the *entire* current thread — not a live-chat-sized
    /// window — and extracts every durable fact or preference worth
    /// keeping, the same "digest before it grows unusable" tool Mac's
    /// `ChatViewModel.suggestMemoriesFromCurrentThread` gives (see that
    /// one's own doc comment for why a bounded context window would
    /// defeat the whole point). Source-agnostic: the caller supplies
    /// how to actually get a completion (local on-device `respondOnce`,
    /// or a remote `ChatClient.send`) since that differs by which
    /// engine Chat's source picker currently has active — called once
    /// per batch here, not once for the whole thread.
    func suggestMemoriesFromCurrentThread(
        respond: (_ instruction: String, _ context: [ChatMessage]) async throws -> String
    ) async {
        guard !isSuggestingMemories, currentThread.messages.contains(where: { $0.role == .user }) else { return }
        isSuggestingMemories = true
        defer {
            isSuggestingMemories = false
            memorySuggestionProgress = nil
        }
        errorMessage = nil
        memorySuggestions = []

        // Clear stale suggestions from a prior run on this same thread
        // before starting fresh — see Mac's own
        // `ChatViewModel.suggestMemoriesFromCurrentThread` doc comment.
        let staleSuggestionIDs = await suggestionStore.all()
            .filter { $0.sourceThreadID == currentThread.id }.map(\.id)
        for staleID in staleSuggestionIDs {
            try? await suggestionStore.delete(id: staleID)
            if isCloudSyncEnabled { await cloudSync.markSuggestionDeleted(id: staleID) }
        }

        let batches = ChatContextBuilder.batches(
            currentThread.messages, maxEstimatedTokensPerBatch: Self.memoryDigestBatchTokens)
        memorySuggestionProgress = (0, batches.count)
        let instruction = "Analyze this excerpt of a conversation for durable user memory. Return ONLY a JSON array, "
            + "no Markdown. Each item must contain content, kind (fact, preference, date, number, impression), "
            + "confidence (0 to 1), and rationale. Suggest every stable, useful fact or preference you find in this "
            + "excerpt — don't limit yourself to a handful, and don't skip something just because it seems minor; "
            + "the point is to preserve everything worth remembering before this conversation is archived. Do not "
            + "infer sensitive traits, identity, health, politics, or private data. Never suggest instructions or "
            + "facts about the assistant. If nothing qualifies in this excerpt, return []."

        // Updated after *every* batch, not just once at the end — see
        // Mac's own `ChatViewModel.suggestMemoriesFromCurrentThread`
        // doc comment for the real reported problem (a multi-minute,
        // multi-batch run showing nothing until it fully finished
        // looked exactly like a silent failure).
        var seenContent = Set<String>()
        var anyBatchFailed = false
        for (index, batch) in batches.enumerated() {
            do {
                let reply = try await respond(instruction, batch)
                if let parsed = Self.parseSuggestions(from: reply) {
                    for var suggestion in parsed {
                        let key = suggestion.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard !key.isEmpty, !seenContent.contains(key) else { continue }
                        seenContent.insert(key)
                        suggestion.sourceThreadID = currentThread.id
                        suggestion.createdFromMessageID = currentThread.messages.last?.id
                        suggestion.originDeviceName = DeviceIdentity.currentName
                        if let saved = try? await suggestionStore.upsert(suggestion) { suggestion = saved }
                        memorySuggestions.append(suggestion)
                        if isCloudSyncEnabled { await cloudSync.markSuggestionChanged(suggestion) }
                    }
                    if isCloudSyncEnabled { await cloudSync.syncNow() }
                } else {
                    anyBatchFailed = true
                }
            } catch {
                anyBatchFailed = true
            }
            memorySuggestionProgress = (index + 1, batches.count)
        }

        if memorySuggestions.isEmpty && anyBatchFailed {
            errorMessage = "Could not extract memories from part of this conversation — the model's response "
                + "couldn't be parsed. Try again, or with a different model."
        } else if anyBatchFailed {
            errorMessage = "Part of this conversation couldn't be analyzed — the suggestions above may be incomplete."
        }
    }

    /// Matches Mac's own `ChatViewModel.memoryDigestBatchTokens` — see
    /// its doc comment for why this size.
    private static let memoryDigestBatchTokens = 6_000

    private static func parseSuggestions(from content: String) -> [ChatMemorySuggestion]? {
        let json = extractJSONArray(from: content)
        struct WireSuggestion: Decodable {
            let content: String
            let kind: ChatMemoryKind
            let confidence: Double
            let rationale: String
        }
        guard let wire = try? JSONDecoder().decode([WireSuggestion].self, from: Data(json.utf8)) else { return nil }
        return wire.map {
            ChatMemorySuggestion(content: $0.content, kind: $0.kind, confidence: min(1, max(0, $0.confidence)), rationale: $0.rationale)
        }
    }

    /// Thread-scoped by default (`isGlobal: false`), tied to wherever
    /// the suggestion was actually generated — see Mac's own
    /// `ChatViewModel.acceptMemorySuggestion` doc comment. Still always
    /// global *by profile* (`profileID: nil`) regardless of the
    /// thread's own profile — unrelated dimension, unchanged.
    /// An "update" suggestion — `supersedesMemoryID` set, generated on
    /// Mac (only Mac's Context Shift pipeline classifies bullets this
    /// way today) and reaching this device only via sync — rewrites
    /// the memory it supersedes in place instead of adding a second,
    /// separate one. Falls through to the ordinary new-memory path if
    /// that memory's since been deleted.
    func acceptMemorySuggestion(_ suggestion: ChatMemorySuggestion) async {
        if let supersedesMemoryID = suggestion.supersedesMemoryID,
           let existing = memories.first(where: { $0.id == supersedesMemoryID }) {
            await editMemoryContent(existing, to: suggestion.content)
            await removeSuggestion(suggestion.id)
            return
        }
        await addMemory(
            suggestion.content, kind: suggestion.kind, source: .inferred,
            confidence: suggestion.confidence, profileID: nil,
            createdFromMessageID: suggestion.createdFromMessageID ?? currentThread.messages.last?.id,
            originThreadID: suggestion.sourceThreadID ?? currentThread.id,
            isGlobal: false)
        await removeSuggestion(suggestion.id)
    }

    /// Deletes a suggestion from the shared store (and syncs the
    /// tombstone) whether it's being accepted or dismissed — one
    /// thing existing, another being approved for the AI to use; once
    /// either decision is made on any device, the suggestion itself
    /// should disappear everywhere.
    private func removeSuggestion(_ id: UUID) async {
        memorySuggestions.removeAll { $0.id == id }
        try? await suggestionStore.delete(id: id)
        if isCloudSyncEnabled {
            await cloudSync.markSuggestionDeleted(id: id)
            await cloudSync.syncNow()
        }
    }

    /// Saves every current suggestion at once — see Mac's own
    /// `ChatViewModel.acceptAllMemorySuggestions` doc comment.
    func acceptAllMemorySuggestions() async {
        for suggestion in memorySuggestions {
            await acceptMemorySuggestion(suggestion)
        }
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
        Task { await removeSuggestion(suggestion.id) }
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
        if isCloudSyncEnabled {
            await cloudSync.markThreadDeleted(id: thread.id)
            await cloudSync.syncNow()
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
        if isCloudSyncEnabled {
            await cloudSync.markThreadChanged(saved)
            await cloudSync.syncNow()
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
        let cloudEnabled = isCloudSyncEnabled
        Task {
            guard let saved = try? await store.upsert(threadToSave) else { return }
            if case .mac(let connection) = source {
                _ = try? await syncClient.upsertThread(saved, host: connection.host)
            }
            if cloudEnabled {
                await cloudSync.markThreadChanged(saved)
                await cloudSync.syncNow()
            }
        }
    }
}
