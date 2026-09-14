import CloudKit
import Foundation
import AnvilCore

/// App-level chat state — owned once by `AppState`, not recreated when
/// the Chat tab is hidden and shown again (that was the earlier bug:
/// a view-local `@StateObject` was torn down on navigation, losing the
/// conversation). Plain `ObservableObject` (not `@Observable`) — see
/// the `@State` toolchain note in README.
@MainActor
final class ChatViewModel: ObservableObject {
    /// Asked before ever unloading another model to make room for the
    /// one "Suggest from Thread" needs — see
    /// `suggestMemoriesFromCurrentThread`'s doc comment.
    struct PendingModelUnloadConfirmation: Identifiable {
        let id = UUID()
        let modelToLoadName: String
        let modelsToUnloadNames: [String]
    }

    enum GenerationPhase: Equatable {
        case idle
        case preparing
        case reasoning
        case generating
        case generatingImage
        case cancelled
        case failed

        var label: String? {
            switch self {
            case .idle: return nil
            case .preparing: return "Preparing…"
            case .reasoning: return "Thinking…"
            case .generating: return "Generating response…"
            case .generatingImage: return "Generating image…"
            case .cancelled: return "Generation stopped"
            case .failed: return "Generation failed"
            }
        }
    }

    @Published var currentThread: ChatThread
    @Published private(set) var allThreads: [ChatThread] = []
    @Published private(set) var availableProfiles: [ChatProfile] = []
    @Published private(set) var memories: [ChatMemory] = []
    @Published private(set) var memorySuggestions: [ChatMemorySuggestion] = []
    @Published private(set) var isSuggestingMemories = false
    /// `(completed batches, total batches)` while `isSuggestingMemories`
    /// is true, `nil` otherwise — a long thread now takes several
    /// sequential model calls, and with no visible sign one of them is
    /// actually in flight, a multi-minute run looked exactly like it
    /// had silently failed.
    @Published private(set) var memorySuggestionProgress: (completed: Int, total: Int)?
    /// Which text model "Suggest from Thread" uses — nil means
    /// "whichever model Chat currently has selected". Unlike
    /// `selectedModelID`, this can (and often will) name a model
    /// that isn't loaded right now: see `availableTextModels`.
    @Published var memorySuggestionModelID: String?
    /// Every registered text model (`ModelRegistry.all()`, filtered to
    /// `.text`) — not just the ones currently loaded — so the Memory
    /// screen's picker can offer anything mapped in the models folder,
    /// same as the Models tab itself does. Refreshed on every
    /// `loadInitialState()`.
    @Published private(set) var availableTextModels: [ModelEntry] = []
    /// Set when "Suggest from Thread" needs to load a model that
    /// doesn't fit in the remaining memory budget alongside whatever's
    /// already loaded — never unloads anything on its own; `MemoryView`
    /// shows this as a confirmation dialog and calls
    /// `resolveModelUnloadConfirmation` with the user's choice.
    @Published var pendingModelUnloadConfirmation: PendingModelUnloadConfirmation?
    @Published private(set) var isTemporaryModeActive = false
    @Published var selectedModelID: String?
    @Published var inputText: String = ""
    @Published var chatMessageWaitSeconds: Double
    @Published var maxEstimatedContextTokens: Int
    @Published var recentMessageCount: Int
    /// Off by default — see `AnvilSyncServer`'s own header comment for
    /// why this exists at all: nothing the Mac already runs exposes
    /// threads/profiles/memories over the network, so "the iPhone can
    /// resume this Mac's own conversation" needs this explicit opt-in.
    @Published var isMacSyncEnabled: Bool
    @Published var macSyncAccess: ServerAccess
    /// Off by default — see `CloudSyncEngine`'s own header comment.
    /// Independent of `isMacSyncEnabled`/`AnvilSyncServer`: this one
    /// works from anywhere, no Mac reachability required, through the
    /// user's own private iCloud database.
    @Published var isCloudSyncEnabled: Bool
    @Published private(set) var cloudAccountStatus: CKAccountStatus?
    @Published private(set) var lastEstimatedContextTokens: Int = 0
    @Published var isSending = false
    @Published private(set) var isWaitingToSend = false
    @Published private(set) var generationPhase: GenerationPhase = .idle
    @Published var errorMessage: String?
    @Published var hideReasoning = true
    @Published var settings = GenerationSettings.default
    @Published var isExportPresented = false
    @Published var isSidebarOpen = false
    /// The left threads column — on by default since it's the main way
    /// to navigate between conversations (unlike the right sidebar's
    /// settings, which stay tucked away until asked for).
    @Published var isThreadsSidebarOpen = true
    /// True while the "pop out" window (`ChatView(isPopout: true)`) is
    /// on screen — the main window's `ChatView` uses this to blank its
    /// own conversation pane (keeping only the threads column) instead
    /// of showing the same conversation twice at once. Set/cleared from
    /// that window's own `onAppear`/`onDisappear`, so closing it is the
    /// only way back — there's no separate "undo" action for this.
    @Published var isPoppedOut = false
    @Published private(set) var lastTokensPerSecond: Double?
    @Published private(set) var lastCachedPromptTokens: Int?
    /// Set while a `generate_image` tool call is actively generating —
    /// nil the rest of the time, including while just waiting on the
    /// text model itself.
    @Published private(set) var imageToolProgress: Double?
    /// Live status from `ContextShiftCoordinator`'s background watcher
    /// — non-nil the moment a compaction pass starts (`isPaused`
    /// becomes true right away), updated continuously with real
    /// memory numbers throughout, and cleared once the pass finishes
    /// or fails. `ChatView` renders this as a status banner distinct
    /// from `errorMessage` (this isn't a failure, just informational)
    /// while it's non-nil with `isPaused == true`.
    @Published private(set) var contextShiftStatus: ContextShiftCoordinator.Status?

    private let sessions: ModelSessionManager
    private let threadStore: ChatThreadStore
    private let imageSessions: ImageSessionManager
    private let generatedImageStore: GeneratedImageStore
    private let profileStore: ChatProfileStore
    private let memoryStore: ChatMemoryStore
    private let suggestionStore: ChatMemorySuggestionStore
    private let contextShift: ContextShiftCoordinator
    private let modelRegistry: ModelRegistry
    private let requirements: RequirementsManager
    private let client = ChatClient()
    private let imageClient = ImageClient()
    private let syncServer: AnvilSyncServer
    private let cloudSync: CloudSyncEngine
    private var threadBeforeTemporaryMode: ChatThread?
    private var temporaryThreads: [UUID: ChatThread] = [:]
    /// `.task { loadInitialState() }` on `ChatView` reruns every time the
    /// view re-enters the hierarchy (switching tabs and back) — this
    /// used to reset `currentThread` to whatever was last persisted on
    /// disk *every single time*, silently discarding an in-flight,
    /// not-yet-persisted send (the real bug behind a message vanishing
    /// after navigating away mid-generation and back). Only the first
    /// call is allowed to pick the initial thread; every later call just
    /// refreshes the thread/profile lists.
    private var hasLoadedInitialState = false
    /// Per-thread memory of the last `generate_image` tool call, so a
    /// sequential request ("same character, different clothes") can
    /// carry the previous prompt and seed forward instead of starting
    /// from nothing each time — a real, reported bug where consecutive
    /// generations drifted in skin tone, hair, eyes, and body type even
    /// though only the clothing was meant to change.
    private var lastImageGenerationByThread: [UUID: (seed: Int, prompt: String)] = [:]
    private var generationTask: Task<Void, Never>?
    private var bufferedSendTask: Task<Void, Never>?
    /// Resumed by `resolveModelUnloadConfirmation` once the user
    /// answers the dialog `pendingModelUnloadConfirmation` describes.
    private var modelUnloadContinuation: CheckedContinuation<Bool, Never>?
    /// Guards `startContextShiftMonitoringIfNeeded()` so it only ever
    /// tries once per launch — a missing embedding/summarization model
    /// isn't retried on every `loadInitialState()` re-run (switching
    /// tabs and back), only after downloading one and relaunching.
    private var hasAttemptedContextShiftStart = false

    init(
        sessions: ModelSessionManager,
        threadStore: ChatThreadStore,
        imageSessions: ImageSessionManager,
        generatedImageStore: GeneratedImageStore,
        profileStore: ChatProfileStore,
        memoryStore: ChatMemoryStore,
        suggestionStore: ChatMemorySuggestionStore = ChatMemorySuggestionStore(),
        contextShift: ContextShiftCoordinator = ContextShiftCoordinator(),
        modelRegistry: ModelRegistry,
        requirements: RequirementsManager
    ) {
        self.sessions = sessions
        self.threadStore = threadStore
        self.imageSessions = imageSessions
        self.generatedImageStore = generatedImageStore
        self.profileStore = profileStore
        self.memoryStore = memoryStore
        self.suggestionStore = suggestionStore
        self.contextShift = contextShift
        self.modelRegistry = modelRegistry
        self.requirements = requirements
        self.currentThread = ChatThread(originDeviceName: DeviceIdentity.currentName)
        let appSettings = AppSettings.load()
        self.chatMessageWaitSeconds = max(0, appSettings.chatMessageWaitSeconds)
        self.maxEstimatedContextTokens = max(512, appSettings.chatMaxEstimatedContextTokens)
        self.recentMessageCount = max(2, appSettings.chatRecentMessageCount)
        self.isMacSyncEnabled = appSettings.isMacSyncEnabled
        self.macSyncAccess = appSettings.macSyncAccess
        self.isCloudSyncEnabled = appSettings.isCloudSyncEnabled
        self.memorySuggestionModelID = appSettings.memorySuggestionModelID
        self.syncServer = AnvilSyncServer(
            threadStore: threadStore, profileStore: profileStore, memoryStore: memoryStore,
            modelRegistry: modelRegistry, sessions: sessions, imageSessions: imageSessions, requirements: requirements)
        self.cloudSync = CloudSyncEngine(
            threadStore: threadStore, profileStore: profileStore, memoryStore: memoryStore,
            suggestionStore: suggestionStore)
    }

    // MARK: - iCloud sync

    /// Called once from `ChatView`'s own `.task` — starts the cloud
    /// sync engine if it was left on from a previous launch, after
    /// confirming the account is actually usable (signed in, iCloud
    /// Drive on for this app). Off (and silent) otherwise — this is
    /// meant to degrade to "just doesn't sync," never to block or
    /// error the rest of the app.
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

    // MARK: - iPhone sync

    /// Called once from `ChatView`'s own `.task` — starts the sync
    /// server if it was left on from a previous launch. A no-op
    /// otherwise; nothing about existing chat behavior depends on this.
    func applyMacSyncSettingsIfNeeded() async {
        guard isMacSyncEnabled else { return }
        try? await syncServer.start(access: macSyncAccess)
    }

    func setMacSyncEnabled(_ enabled: Bool) {
        isMacSyncEnabled = enabled
        var settings = AppSettings.load()
        settings.isMacSyncEnabled = enabled
        try? settings.save()
        Task {
            if enabled {
                try? await syncServer.start(access: macSyncAccess)
            } else {
                await syncServer.stop()
            }
        }
    }

    /// Notices a thread this Mac's own UI is showing getting updated
    /// from somewhere else — the iPhone, over `AnvilSyncServer`, writing
    /// to the exact same `ChatThreadStore` file this actor also reads.
    /// Nothing here watches the filesystem for changes on its own, so
    /// without this, a message sent from the iPhone would only ever
    /// show up on the Mac after the user manually left and reopened the
    /// thread. Runs for the lifetime of `ChatView` (its own `.task`),
    /// skips a poll while this Mac is itself mid-send (never clobber an
    /// in-flight local generation) or in temporary mode (never touches
    /// disk at all).
    func pollForExternalThreadUpdates() async {
        // Two different cadences, not one: the 2s check only ever looks
        // at the thread already open, so it's fast for "is my current
        // conversation still being answered" but blind to anything else
        // — a brand-new thread created on the iPhone, a profile or
        // memory added there, none of that touches `currentThread` and
        // so never tripped the old, single check at all. The ~60s full
        // reload is what makes this *actually* in sync rather than just
        // "on disk somewhere, until you happen to reopen that list" —
        // every screen that reads `allThreads`/`availableProfiles`/
        // `memories` sees a change made on the phone within a minute,
        // not "whenever I next navigate away and back."
        var ticksSinceFullRefresh = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            ticksSinceFullRefresh += 1

            if ticksSinceFullRefresh >= 30 {
                ticksSinceFullRefresh = 0
                allThreads = await threadStore.all()
                availableProfiles = await profileStore.all()
                memories = await memoryStore.all()
                // Same reasoning as the others: a suggestion generated
                // on another device syncs into this store in the
                // background, and this is what makes it show up here
                // without restarting the app — skipped while this
                // device's own analysis is actively appending to the
                // same array (see `loadInitialState`'s matching guard).
                if !isSuggestingMemories {
                    memorySuggestions = await suggestionStore.all()
                }
                if !isSending, !isTemporaryModeActive,
                    let refreshed = allThreads.first(where: { $0.id == currentThread.id }),
                    refreshed.updatedAt > currentThread.updatedAt {
                    currentThread = refreshed
                }
                continue
            }

            guard !isSending, !isTemporaryModeActive else { continue }
            let id = currentThread.id
            guard let updated = await threadStore.get(id: id), updated.updatedAt > currentThread.updatedAt else { continue }
            currentThread = updated
            allThreads = await threadStore.all()
        }
    }

    func setMacSyncAccess(_ access: ServerAccess) {
        macSyncAccess = access
        var settings = AppSettings.load()
        settings.macSyncAccess = access
        try? settings.save()
        guard isMacSyncEnabled else { return }
        Task {
            await syncServer.stop()
            try? await syncServer.start(access: access)
        }
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
        let savedThreads = await threadStore.all()
        let temporary = temporaryThreads.values.sorted { $0.updatedAt > $1.updatedAt }
        allThreads = temporary + savedThreads.filter { temporaryThreads[$0.id] == nil }
        availableProfiles = await profileStore.all()
        memories = await memoryStore.all()
        // Loaded here (not just after this device's own "Suggest from
        // Thread" run) so a suggestion synced in from another device —
        // the whole point of persisting/syncing these at all — is
        // already visible without needing to trigger a new analysis
        // locally first. Only while nothing is actively being analyzed
        // right now: a mid-run refresh would otherwise stomp on
        // suggestions this device's own loop is still appending.
        if !isSuggestingMemories {
            memorySuggestions = await suggestionStore.all()
        }
        if !hasLoadedInitialState {
            currentThread = allThreads.first ?? ChatThread(originDeviceName: DeviceIdentity.currentName)
            hasLoadedInitialState = true
        }
        // Every registered text model, loaded or not — both this
        // picker and the memory digest's own can name a model that
        // isn't resident right now, so this needs the full registry,
        // not just `sessions.readySessions`. Populated before
        // `syncSelectedModel()` below, which falls back to it.
        availableTextModels = await modelRegistry.all().filter { $0.kind == .text }
        syncSelectedModel()
        await startContextShiftMonitoringIfNeeded()
    }

    // MARK: - Context shift (conversation compaction)

    /// Starts `ContextShiftCoordinator`'s background watcher the first
    /// time all three models its pipeline needs — nomic-embed-text-v2
    /// -moe, CodeRankEmbed, Phi-4-mini-instruct — are actually
    /// registered. Silently stays inactive otherwise (no error shown):
    /// this is a background safety net, not something the user
    /// explicitly asked to turn on, so a missing model shouldn't nag on
    /// every launch — downloading the three in the Search tab and
    /// relaunching is what turns it on.
    ///
    /// Called from `RootView`'s own always-running `.task` (like
    /// iPhone/iCloud sync), not gated behind ever opening the Chat
    /// tab — resolves the three model paths directly from
    /// `modelRegistry` rather than `availableTextModels`, which only
    /// `loadInitialState()` (itself only ever called once Chat has
    /// appeared) populates.
    func startContextShiftMonitoringIfNeeded() async {
        guard !hasAttemptedContextShiftStart, !(await contextShift.isWatching) else { return }
        hasAttemptedContextShiftStart = true

        let textModels = await modelRegistry.all().filter { $0.kind == .text }
        func firstRegisteredModel(matching keyword: String) -> ModelEntry? {
            textModels.first { $0.id.lowercased().contains(keyword) }
        }
        guard let nomic = firstRegisteredModel(matching: "nomic-embed-text"),
              let coderank = firstRegisteredModel(matching: "coderankembed"),
              let phi4 = firstRegisteredModel(matching: "phi-4-mini-instruct") else {
            return
        }

        await contextShift.configureCallbacks(
            onPauseRequested: { [weak self] in
                await self?.handleContextShiftPauseRequested()
            },
            onUnloadRequested: { [weak self] modelID in
                await self?.handleContextShiftUnloadRequested(modelID)
            },
            onShiftReady: { [weak self] result in
                await self?.handleContextShiftReady(result)
            },
            onShiftFailed: { [weak self] reason in
                await self?.handleContextShiftFailed(reason)
            },
            onStatusChanged: { [weak self] status in
                await self?.updateContextShiftStatus(status)
            }
        )

        try? await contextShift.startWatchingIfNeeded(
            nomicModelPath: nomic.localPath,
            coderankModelPath: coderank.localPath,
            phi4ModelPath: phi4.localPath,
            requirements: requirements
        )
    }

    @MainActor
    private func updateContextShiftStatus(_ status: ContextShiftCoordinator.Status) {
        contextShiftStatus = status
    }

    @MainActor
    private func handleContextShiftPauseRequested() {
        contextShiftStatus = ContextShiftCoordinator.Status(isPaused: true)
    }

    /// The active model this pipeline unloads is whichever one the
    /// Python side read from the status file `send()` wrote — always
    /// resolved back through `sessions`, never assumed still loaded
    /// (the user could have unloaded it manually in the moment between
    /// the trigger firing and this callback running).
    private func handleContextShiftUnloadRequested(_ modelID: String?) async {
        guard let modelID, sessions.isLoaded(modelID: modelID) else { return }
        // A "Stop-and-Swap" unload can land while this exact model is
        // mid-response to the very turn that pushed the thread over 90%
        // of its context window (`writeStatus` runs, then `send()` kicks
        // off `generationTask` — the watcher's own 1-second poll and the
        // handshake back to here can easily land while that request is
        // still open). Reported live: a raw "Could not connect to the
        // server" (a `URLError.cannotConnectToHost`) surfaced straight
        // to the user once the model's server process was killed out
        // from under the open HTTP connection, instead of the friendly
        // "Compacting…" message `send()`'s own `isPaused` guard shows
        // for a *new* send. Cancelling the in-flight generation first
        // lets `runChatLoop`'s existing `CancellationError` path tear
        // the request down cleanly (silently drops the empty
        // in-progress assistant bubble, no scary error text) before the
        // process actually goes away, instead of racing it.
        if isSending, let currentModelID = selectedModelID, currentModelID == modelID {
            stopGeneration()
            await generationTask?.value
        }
        await sessions.unload(modelID: modelID)
    }

    /// Phase 4: reconstructs the thread from the compacted payload —
    /// `[Instruções de Sistema] + [Resumo] + [últimas 5 mensagens
    /// intactas]` — reloads the model that was active before, saves
    /// the summary as a suggestion needing the same explicit approval
    /// "Suggest from Thread" already requires (requested live: "todos
    /// os resultados gerados de memória devem ser alocados e
    /// solicitados aprovação como já acontece hoje no menu Memórias"),
    /// and un-pauses sending.
    @MainActor
    private func handleContextShiftReady(_ result: ContextShiftCoordinator.ShiftResult) async {
        let recap = ChatMessage(
            role: .assistant,
            content: "🗜️ This conversation was compacted to stay within memory limits. Summary of what came before:\n\n\(result.summary)",
            modelDisplayName: "Context Shift"
        )
        currentThread.messages = [recap] + result.intactMessages
        if !isTemporaryModeActive {
            persistCurrentThread()
        }

        var suggestion = ChatMemorySuggestion(
            content: result.summary,
            kind: .summary,
            confidence: 1,
            rationale: "Automatic context-shift compaction — \(result.textChunksIndexed) text and \(result.codeChunksIndexed) code chunks indexed alongside it."
        )
        suggestion.sourceThreadID = currentThread.id
        suggestion.createdFromMessageID = recap.id
        suggestion.originDeviceName = DeviceIdentity.currentName
        if let saved = try? await suggestionStore.upsert(suggestion) { suggestion = saved }
        memorySuggestions.append(suggestion)
        if isCloudSyncEnabled {
            await cloudSync.markSuggestionChanged(suggestion)
            await cloudSync.syncNow()
        }

        contextShiftStatus = nil
        errorMessage = nil

        if let modelID = selectedModelID,
           let entry = await modelRegistry.all().first(where: { $0.id == modelID }) {
            _ = await sessions.load(entry, requirements: requirements)
        }
    }

    @MainActor
    private func handleContextShiftFailed(_ reason: String) {
        contextShiftStatus = nil
        errorMessage = "Conversation compaction failed (\(reason)) — the model may need to be reloaded manually."
    }

    /// Keeps the selection pointed at a loaded model — called on
    /// appear and whenever the set of loaded models changes.
    func syncSelectedModel() {
        // A selection no longer needs to *stay* loaded to stay valid —
        // requested live: picking a model that isn't currently
        // resident is now a perfectly good choice (`send()` loads it
        // on demand), so this used to undo exactly that the moment any
        // session's status changed (this is called from `ChatView`'s
        // `.onChange(of: sessions.sessions)`), snapping the picker back
        // to whatever was already loaded. Only fills in a default —
        // the first ready session, same as before — when nothing at
        // all has been picked yet.
        if let id = selectedModelID {
            applyDefaultProfileIfNeeded(forModelID: id)
            return
        }
        // Prefer an already-loaded model when defaulting (no load
        // needed to start chatting immediately), but fall back to any
        // registered one so a brand-new thread's picker isn't just
        // empty when nothing happens to be resident yet.
        selectedModelID = sessions.readySessions.first?.id ?? availableTextModels.first?.id
        if let id = selectedModelID {
            applyDefaultProfileIfNeeded(forModelID: id)
        }
    }

    /// The header model picker routes through here instead of setting
    /// `selectedModelID` directly, so picking a model also applies its
    /// default profile (if any) to a thread that doesn't have one yet.
    func selectModel(_ id: String?) {
        selectedModelID = id
        if let id { applyDefaultProfileIfNeeded(forModelID: id) }
    }

    /// The Memory screen's own model picker routes through here rather
    /// than setting `memorySuggestionModelID` directly, so the choice
    /// survives an app relaunch — `nil` (its "Current chat model"
    /// option) intentionally isn't persisted as a specific id, so it
    /// keeps tracking whatever's selected in Chat later too.
    func setMemorySuggestionModelID(_ id: String?) {
        memorySuggestionModelID = id
        var settings = AppSettings.load()
        settings.memorySuggestionModelID = id
        try? settings.save()
    }

    // MARK: - Profiles

    var activeProfile: ChatProfile? {
        guard let id = currentThread.profileID else { return nil }
        return availableProfiles.first { $0.id == id }
    }

    /// Only true before the first message — see `ChatThread.profileID`.
    /// Also gates the Temporary Chat toggle: both only make sense to
    /// change before the conversation has actually started.
    var canChangeProfile: Bool { currentThread.messages.isEmpty }

    func setProfile(_ profile: ChatProfile?) {
        guard canChangeProfile else { return }
        currentThread.profileID = profile?.id
        if !currentThread.isTitleCustom {
            currentThread.title = autoTitle(profileID: profile?.id, createdAt: currentThread.createdAt, temporary: isTemporaryModeActive)
        }
    }

    // MARK: - Thread title

    /// "Profile name · created date", regenerated any time the profile
    /// changes (only possible pre-first-message) — until the user
    /// renames the thread, at which point `isTitleCustom` locks it and
    /// nothing here touches it again.
    private func autoTitle(profileID: UUID?, createdAt: Date, temporary: Bool) -> String {
        let dateString = Self.titleDateFormatter.string(from: createdAt)
        let base = profileID.flatMap { id in availableProfiles.first { $0.id == id }?.name } ?? "New Chat"
        return temporary ? "Temporary: \(base) · \(dateString)" : "\(base) · \(dateString)"
    }

    private static let titleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Live-updates the title as the user types in the header's title
    /// field — not yet persisted (see `commitThreadTitle`), so a rename
    /// abandoned mid-edit (e.g. the app quits) never partially saves.
    func updateThreadTitleDraft(_ text: String) {
        currentThread.title = text
        currentThread.isTitleCustom = true
    }

    /// Called when the title field is submitted or loses focus. An
    /// empty title reverts to the auto-generated one instead of saving
    /// a blank thread name.
    func commitThreadTitle() {
        let trimmed = currentThread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            currentThread.title = autoTitle(
                profileID: currentThread.profileID, createdAt: currentThread.createdAt, temporary: isTemporaryModeActive)
            currentThread.isTitleCustom = false
        } else {
            currentThread.title = trimmed
        }
        if isTemporaryModeActive {
            rememberTemporaryThread()
        } else {
            persistCurrentThread()
        }
    }

    /// `originThreadID`/`isGlobal` default to thread-scoped, tied to
    /// whichever thread is current — requested live: "Temos que deixar
    /// memórias por thread/conversa. E elas são geradas e consumidas
    /// dentro do thread que foram geradas." A caller with a more
    /// specific origin in mind (`acceptMemorySuggestion`, tied to
    /// whichever thread the suggestion actually came from) passes its
    /// own `originThreadID` explicitly instead of relying on this
    /// default.
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
            content: trimmed,
            kind: kind,
            source: source,
            confidence: confidence,
            profileID: profileID,
            originDeviceName: DeviceIdentity.currentName,
            createdFromMessageID: createdFromMessageID,
            originThreadID: originThreadID ?? currentThread.id,
            isGlobal: isGlobal
        )
        guard let saved = try? await memoryStore.upsert(memory) else { return }
        memories = await memoryStore.all()
        if isCloudSyncEnabled {
            await cloudSync.markMemoryChanged(saved)
            await cloudSync.syncNow()
        }
    }

    func updateMemory(_ memory: ChatMemory) async {
        guard let saved = try? await memoryStore.upsert(memory) else { return }
        memories = await memoryStore.all()
        if isCloudSyncEnabled {
            await cloudSync.markMemoryChanged(saved)
            await cloudSync.syncNow()
        }
    }

    /// Flips whether `memory` applies everywhere or only within the
    /// thread it was originally generated in. Requested live: "criar
    /// um botão pra cada memória no menu Memórias que pode transformar
    /// ela em Global ou voltar apenas pra conversa onde foi gerada."
    func toggleMemoryGlobal(_ memory: ChatMemory) async {
        var updated = memory
        updated.isGlobal.toggle()
        await updateMemory(updated)
    }

    func deleteMemory(_ memory: ChatMemory) async {
        try? await memoryStore.delete(id: memory.id)
        memories = await memoryStore.all()
        if isCloudSyncEnabled {
            await cloudSync.markMemoryDeleted(id: memory.id)
            await cloudSync.syncNow()
        }
    }

    /// Reads the *entire* current thread — not the same trimmed window
    /// `send()` uses for a live turn — and extracts every durable fact
    /// or preference worth keeping, so a conversation can be picked back
    /// up from a fresh thread once this one's grown too large to keep
    /// using directly. Reusing the live-chat context budget here would
    /// defeat that exact purpose: it's built to drop a long thread's
    /// *middle*, which is precisely what this needs to actually read.
    /// Instead, `ChatContextBuilder.batches` splits the whole thing into
    /// several bounded excerpts, each analyzed on its own turn, so
    /// coverage doesn't depend on how long the conversation got.
    func suggestMemoriesFromCurrentThread() async {
        guard !isSuggestingMemories,
              let modelID = memorySuggestionModelID ?? selectedModelID,
              currentThread.messages.contains(where: { $0.role == .user }) else { return }

        isSuggestingMemories = true
        defer {
            isSuggestingMemories = false
            memorySuggestionProgress = nil
        }
        errorMessage = nil
        memorySuggestions = []

        guard await ensureModelLoadedForSuggestions(modelID) else { return }
        guard let endpoint = sessions.gatewayEndpoint(for: modelID) ?? sessions.chatEndpoint(for: modelID) else {
            errorMessage = "That model isn't ready to use."
            return
        }

        // A fresh run for this thread supersedes whatever it last
        // suggested — without clearing these first, re-running "Suggest
        // from Thread" on the same conversation would pile up a second,
        // near-duplicate copy of everything already sitting unreviewed
        // from a previous run (dedup below only ever compares *within*
        // this run, not against what's already persisted). Suggestions
        // from other threads, or synced in from another device, are
        // untouched.
        let staleSuggestionIDs = await suggestionStore.all()
            .filter { $0.sourceThreadID == currentThread.id }
            .map(\.id)
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

        // A real, reported problem this exists to fix: a genuinely long
        // thread now takes several sequential model calls (one per
        // batch), each of which can take a real reasoning model a
        // while — the whole run finishing after several minutes with
        // nothing shown until then looked exactly like it had silently
        // failed. `memorySuggestions` is now updated after *every*
        // batch (not just once at the very end) and `memorySuggestionProgress`
        // tracks which one is in flight, so the list fills in as it
        // actually goes instead of appearing frozen.
        var seenContent = Set<String>()
        var anyBatchFailed = false
        for (index, batch) in batches.enumerated() {
            do {
                let reply = try await client.send(
                    messages: batch,
                    baseURL: endpoint,
                    model: idForEndpoint(endpoint, modelID: modelID),
                    modelDisplayName: "Memory extraction",
                    // A far larger budget than a single chat reply ever
                    // needs — this response is a JSON array that can
                    // legitimately run long for a batch mentioning many
                    // facts, and the old fixed 1200-token cap silently
                    // truncated exactly that case: a cut-off JSON array
                    // fails to parse, and the previous `try?` swallowed
                    // that into an empty result with no explanation.
                    settings: GenerationSettings(maxTokens: 4000, temperature: 0),
                    systemPrompt: instruction,
                    conversationID: currentThread.id.uuidString + ":memory-suggestions:\(index)"
                )
                guard let parsed = Self.parseSuggestions(from: reply.content) else {
                    anyBatchFailed = true
                    memorySuggestionProgress = (index + 1, batches.count)
                    continue
                }
                // The same fact can legitimately turn up in more than
                // one excerpt (mentioned early, reiterated later) —
                // collapse exact repeats rather than showing the same
                // suggestion twice.
                for var suggestion in parsed {
                    let key = suggestion.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    guard !key.isEmpty, !seenContent.contains(key) else { continue }
                    seenContent.insert(key)
                    // Persisted (and, if enabled, synced) immediately,
                    // not just held in this in-memory array — the whole
                    // point of a suggestion existing is to be reviewable
                    // from any device, on either side of an app
                    // relaunch, not only for as long as this one run's
                    // Task stays alive.
                    suggestion.sourceThreadID = currentThread.id
                    suggestion.createdFromMessageID = currentThread.messages.last?.id
                    suggestion.originDeviceName = DeviceIdentity.currentName
                    if let saved = try? await suggestionStore.upsert(suggestion) {
                        suggestion = saved
                    }
                    memorySuggestions.append(suggestion)
                    if isCloudSyncEnabled { await cloudSync.markSuggestionChanged(suggestion) }
                }
                if isCloudSyncEnabled { await cloudSync.syncNow() }
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

    /// Loads `modelID` on demand for `send()` if it isn't already
    /// resident, unloading every other currently-loaded model (text
    /// and image both — they share one `ResidencyPlanner` budget)
    /// first if that's what it takes to fit. Requested live: once the
    /// header's model picker started offering every registered model
    /// rather than just an already-loaded one, sending had to be able
    /// to bring the chosen one up itself. Unlike
    /// `ensureModelLoadedForSuggestions` below, this never asks first —
    /// the user picked this model to chat with, same as picking an
    /// already-loaded one always implied "just use it," so swapping
    /// what's resident to honor that should just happen. Returns
    /// `false` (setting `errorMessage`) when the model still isn't
    /// usable afterward.
    private func ensureModelLoadedForSending(_ modelID: String) async -> Bool {
        if sessions.isLoaded(modelID: modelID) { return true }
        guard let entry = await modelRegistry.all().first(where: { $0.id == modelID }) else {
            errorMessage = "That model is no longer registered."
            return false
        }
        if await sessions.load(entry, requirements: requirements) { return true }

        guard case .failed(let reason)? = sessions.session(for: modelID)?.status,
              reason.contains("Not enough unified memory") else {
            errorMessage = "Could not load \(entry.displayName)."
            return false
        }

        for session in sessions.readySessions { await sessions.unload(modelID: session.id) }
        for session in imageSessions.readySessions { await imageSessions.unload(modelID: session.id) }

        guard await sessions.load(entry, requirements: requirements) else {
            if case .failed(let retryReason)? = sessions.session(for: modelID)?.status {
                errorMessage = retryReason
            } else {
                errorMessage = "Could not load \(entry.displayName)."
            }
            return false
        }
        return true
    }

    /// Loads `modelID` on demand if it isn't already resident — the
    /// whole point of letting the digest use any registered model, not
    /// just whichever one Chat happens to have loaded, is that it
    /// shouldn't require switching Chat's own model first. If loading
    /// fails for lack of unified memory and something else is
    /// currently loaded (text or image — they share one budget), asks
    /// the user before unloading it and retrying once; never unloads
    /// anything silently. Returns `false` (setting `errorMessage`,
    /// unless the user simply declined) when the model still isn't
    /// usable afterward.
    private func ensureModelLoadedForSuggestions(_ modelID: String) async -> Bool {
        if sessions.isLoaded(modelID: modelID) { return true }
        guard let entry = await modelRegistry.all().first(where: { $0.id == modelID }) else {
            errorMessage = "That model is no longer registered."
            return false
        }
        if await sessions.load(entry, requirements: requirements) { return true }

        guard case .failed(let reason)? = sessions.session(for: modelID)?.status,
              reason.contains("Not enough unified memory") else {
            errorMessage = "Could not load \(entry.displayName)."
            return false
        }

        let otherTextSessions = sessions.readySessions
        let otherImageSessions = imageSessions.readySessions
        let namesToUnload = (otherTextSessions.map { $0.model.displayName } + otherImageSessions.map { $0.model.displayName })
        guard !namesToUnload.isEmpty else {
            // Nothing else is loaded to free up, so the estimate itself
            // is simply larger than the whole budget — asking to
            // unload "nothing" would be meaningless.
            errorMessage = reason
            return false
        }

        guard await confirmUnloadingOtherModels(toLoad: entry.displayName, currentlyLoaded: namesToUnload) else {
            return false
        }

        for session in otherTextSessions { await sessions.unload(modelID: session.id) }
        for session in otherImageSessions { await imageSessions.unload(modelID: session.id) }

        guard await sessions.load(entry, requirements: requirements) else {
            if case .failed(let retryReason)? = sessions.session(for: modelID)?.status {
                errorMessage = retryReason
            } else {
                errorMessage = "Could not load \(entry.displayName)."
            }
            return false
        }
        return true
    }

    /// Suspends until `resolveModelUnloadConfirmation` answers the
    /// dialog `pendingModelUnloadConfirmation` describes.
    private func confirmUnloadingOtherModels(toLoad: String, currentlyLoaded: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            modelUnloadContinuation = continuation
            pendingModelUnloadConfirmation = PendingModelUnloadConfirmation(
                modelToLoadName: toLoad, modelsToUnloadNames: currentlyLoaded)
        }
    }

    /// Called from `MemoryView`'s confirmation dialog with the user's
    /// answer — `true` to go ahead and unload/retry, `false` to leave
    /// everything as it is (the digest simply doesn't run this time).
    /// Guarded so it's safe to call more than once for the same
    /// dialog: both an explicit button (Unload/Cancel) and the
    /// dialog's own dismissal (Escape, clicking outside) call this,
    /// and only the first should actually resume the waiting task —
    /// without the guard, a second resume would crash.
    func resolveModelUnloadConfirmation(unload: Bool) {
        guard pendingModelUnloadConfirmation != nil else { return }
        pendingModelUnloadConfirmation = nil
        modelUnloadContinuation?.resume(returning: unload)
        modelUnloadContinuation = nil
    }

    /// Conservative enough to leave real headroom below a typical small
    /// local model's own context window (instruction + this batch +
    /// the up-to-4000-token JSON reply all have to fit inside it) while
    /// still keeping the number of separate model calls reasonable for
    /// a genuinely long thread.
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
            ChatMemorySuggestion(
                content: $0.content,
                kind: $0.kind,
                confidence: min(1, max(0, $0.confidence)),
                rationale: $0.rationale
            )
        }
    }

    /// Thread-scoped by default (`isGlobal: false`), tied to wherever
    /// the suggestion was actually generated — requested live: "Temos
    /// que deixar memórias por thread/conversa. E elas são geradas e
    /// consumidas dentro do thread que foram geradas." The button next
    /// to it in the Memory screen promotes it to Global whenever a fact
    /// genuinely ought to follow the user into a brand-new conversation
    /// (`toggleMemoryGlobal`). Still always global *by profile*
    /// (`profileID: nil`) regardless of the thread's own profile — that
    /// dimension is unrelated to this one and unchanged from before.
    func acceptMemorySuggestion(_ suggestion: ChatMemorySuggestion) async {
        await addMemory(
            suggestion.content,
            kind: suggestion.kind,
            source: .inferred,
            confidence: suggestion.confidence,
            profileID: nil,
            // The suggestion's own origin, captured when it was first
            // generated — not `currentThread`, which could be a
            // different conversation entirely by the time this
            // suggestion is actually reviewed (possibly on another
            // device, once suggestions sync).
            createdFromMessageID: suggestion.createdFromMessageID,
            originThreadID: suggestion.sourceThreadID ?? currentThread.id,
            isGlobal: false
        )
        await removeSuggestion(suggestion.id)
    }

    /// Deletes a suggestion from the persisted/synced store, not just
    /// the in-memory list — reviewed (accepted or dismissed) is meant
    /// to stick everywhere, the same way accepting or dismissing it on
    /// one device shouldn't leave it sitting there to review all over
    /// again on another.
    private func removeSuggestion(_ id: UUID) async {
        memorySuggestions.removeAll { $0.id == id }
        try? await suggestionStore.delete(id: id)
        if isCloudSyncEnabled {
            await cloudSync.markSuggestionDeleted(id: id)
            await cloudSync.syncNow()
        }
    }

    /// Saves every current suggestion at once — a proper digest of a
    /// long thread can easily surface a few dozen, and clicking each
    /// one individually defeats the point of asking for "everything
    /// worth remembering" in one pass. Still goes through the exact
    /// same `acceptMemorySuggestion` (global scope, `.inferred` source,
    /// traceable back to the thread) one at a time, sequentially — no
    /// new persistence path, just a bulk trigger for the existing one.
    func acceptAllMemorySuggestions() async {
        for suggestion in memorySuggestions {
            await acceptMemorySuggestion(suggestion)
        }
    }

    // MARK: - Editing/deleting a sent message

    /// Deletes `message` and every message that came after it — see
    /// iOS's `ChatThreadsViewModel.deleteMessage`'s matching doc comment
    /// for why (a conversation only makes sense as a straight line).
    /// Also deletes any memory that traces back (`createdFromMessageID`)
    /// to one of the removed messages.
    func deleteMessage(_ message: ChatMessage) async {
        guard let index = currentThread.messages.firstIndex(where: { $0.id == message.id }) else { return }
        await truncateThread(from: index)
    }

    /// Same truncation as `deleteMessage`, returning the removed
    /// message's content so the caller can drop it back into the
    /// composer — "editing" here means resending it in its place.
    func beginEditingMessage(_ message: ChatMessage) async -> String? {
        guard let index = currentThread.messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        let content = message.content
        await truncateThread(from: index)
        return content
    }

    private func truncateThread(from index: Int) async {
        let removedIDs = Set(currentThread.messages[index...].map(\.id))
        currentThread.messages.removeSubrange(index...)
        let orphaned = memories.filter { memory in
            guard let sourceID = memory.createdFromMessageID else { return false }
            return removedIDs.contains(sourceID)
        }
        for memory in orphaned {
            await deleteMemory(memory)
        }
        if !isTemporaryModeActive {
            persistCurrentThread()
        }
    }

    func dismissMemorySuggestion(_ suggestion: ChatMemorySuggestion) {
        Task { await removeSuggestion(suggestion.id) }
    }

    private static func extractJSONArray(from text: String) -> String {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start <= end else { return "[]" }
        return String(text[start...end])
    }

    /// Applies `modelID`'s default profile to the current thread only
    /// if it's still empty (safe to change) and doesn't already have a
    /// profile — never overrides a manual choice or an already-applied
    /// default, even if the model selection is re-synced later for
    /// unrelated reasons.
    private func applyDefaultProfileIfNeeded(forModelID modelID: String) {
        guard canChangeProfile, currentThread.profileID == nil else { return }
        guard let defaultProfile = availableProfiles.first(where: { $0.defaultForModelID == modelID }) else { return }
        currentThread.profileID = defaultProfile.id
        if !currentThread.isTitleCustom {
            currentThread.title = autoTitle(profileID: defaultProfile.id, createdAt: currentThread.createdAt, temporary: isTemporaryModeActive)
        }
    }

    // MARK: - Threads

    /// Blocked while temporary mode is active — the user has to turn
    /// that off first (an explicit action) — or while a message is
    /// still in flight, so a background send doesn't land on a thread
    /// the user has since switched away from.
    func newThread() {
        guard !isSending else { return }
        if isTemporaryModeActive { rememberTemporaryThread() }
        var thread = ChatThread(originDeviceName: DeviceIdentity.currentName)
        thread.title = autoTitle(profileID: nil, createdAt: thread.createdAt, temporary: false)
        currentThread = thread
        isTemporaryModeActive = false
    }

    func selectThread(_ thread: ChatThread) {
        guard !isSending else { return }
        if isTemporaryModeActive { rememberTemporaryThread() }
        if let temporary = temporaryThreads[thread.id] {
            currentThread = temporary
            isTemporaryModeActive = true
        } else {
            currentThread = thread
            isTemporaryModeActive = false
        }
    }

    private func rememberTemporaryThread() {
        var snapshot = currentThread
        snapshot.updatedAt = Date()
        temporaryThreads[snapshot.id] = snapshot
        if let index = allThreads.firstIndex(where: { $0.id == currentThread.id }) {
            allThreads[index] = snapshot
        } else {
            allThreads.insert(snapshot, at: 0)
        }
    }

    func deleteThread(_ thread: ChatThread) async {
        if isSending, currentThread.id == thread.id { return }
        try? await threadStore.delete(id: thread.id)
        if isCloudSyncEnabled {
            await cloudSync.markThreadDeleted(id: thread.id)
            await cloudSync.syncNow()
        }
        allThreads.removeAll { $0.id == thread.id }
        lastImageGenerationByThread.removeValue(forKey: thread.id)
        temporaryThreads.removeValue(forKey: thread.id)
        if currentThread.id == thread.id {
            currentThread = allThreads.first ?? ChatThread(originDeviceName: DeviceIdentity.currentName)
        }
    }

    /// Only the user flips this — nothing else enters or exits
    /// temporary mode on its own — and only before the current thread's
    /// first message (see `canChangeProfile`, reused as the same gate;
    /// the UI disables the toggle once that's false). While active, the
    /// conversation never touches disk; turning it off restores
    /// whatever thread was active before.
    func toggleTemporaryMode() {
        guard canChangeProfile else { return }
        cancelBufferedSend()
        if isTemporaryModeActive {
            rememberTemporaryThread()
            isTemporaryModeActive = false
            currentThread = allThreads.first(where: { temporaryThreads[$0.id] == nil }) ?? ChatThread(originDeviceName: DeviceIdentity.currentName)
            threadBeforeTemporaryMode = nil
        } else {
            threadBeforeTemporaryMode = currentThread
            var thread = ChatThread(originDeviceName: DeviceIdentity.currentName)
            thread.title = autoTitle(profileID: nil, createdAt: thread.createdAt, temporary: true)
            currentThread = thread
            isTemporaryModeActive = true
            rememberTemporaryThread()
        }
    }

    // MARK: - Sending

    func handleSubmit() {
        if chatMessageWaitSeconds <= 0 {
            Task { await send() }
            return
        }
        guard !isSending else { return }
        if !inputText.hasSuffix("\n") {
            inputText.append("\n")
        }
        scheduleBufferedSend()
    }

    func scheduleBufferedSend() {
        bufferedSendTask?.cancel()
        isWaitingToSend = false
        guard chatMessageWaitSeconds > 0,
              !isSending,
              !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let delay = chatMessageWaitSeconds
        isWaitingToSend = true
        bufferedSendTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.isWaitingToSend = false
                await self.send()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func saveChatMessageWaitSeconds() {
        chatMessageWaitSeconds = max(0, min(chatMessageWaitSeconds, 300))
        var settings = AppSettings.load()
        settings.chatMessageWaitSeconds = chatMessageWaitSeconds
        try? settings.save()
        if chatMessageWaitSeconds <= 0 {
            cancelBufferedSend()
        } else {
            scheduleBufferedSend()
        }
    }

    func saveContextSettings() {
        maxEstimatedContextTokens = max(512, min(maxEstimatedContextTokens, 128_000))
        recentMessageCount = max(2, min(recentMessageCount, 100))
        var settings = AppSettings.load()
        settings.chatMaxEstimatedContextTokens = maxEstimatedContextTokens
        settings.chatRecentMessageCount = recentMessageCount
        try? settings.save()
    }

    private func cancelBufferedSend() {
        bufferedSendTask?.cancel()
        bufferedSendTask = nil
        isWaitingToSend = false
    }

    func send() async {
        cancelBufferedSend()
        guard let id = selectedModelID else {
            errorMessage = "Pick a model first."
            return
        }
        // "pausar o recebimento de novos prompts na API local" — a
        // context-shift compaction pass is in progress (the active
        // model is being unloaded/reloaded out from under this
        // conversation), so a new send has nothing to actually talk to
        // right now.
        guard contextShiftStatus?.isPaused != true else {
            errorMessage = "Compacting conversation history to free up memory — try again in a moment."
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        // A real, reproduced failure mode (confirmed against a raw
        // persisted thread — two messages, distinct IDs, each with its
        // own reply): a dropped/flaky connection (e.g. an iPhone on the
        // same thread over Mac Sync) makes a send look like it silently
        // went nowhere, so the same question gets resent verbatim as a
        // second, separate turn. Block an exact repeat of the last
        // thing the user just asked instead of quietly duplicating it.
        if currentThread.messages.last(where: { $0.role == .user })?.content == text {
            errorMessage = "You just sent this — give it a moment before sending it again."
            return
        }

        isSending = true
        generationPhase = .preparing
        errorMessage = nil
        // Loads the selected model on demand — requested live: since
        // the picker now offers every registered model, not just an
        // already-loaded one, sending has to be able to bring the
        // chosen one up itself, unloading whatever's currently running
        // first if that's what it takes to fit. Never asks first —
        // see `ensureModelLoadedForSending`'s own doc comment for how
        // this differs from the memory digest's own, confirming
        // version of the same idea.
        guard await ensureModelLoadedForSending(id),
              let endpoint = sessions.gatewayEndpoint(for: id) ?? sessions.chatEndpoint(for: id) else {
            isSending = false
            generationPhase = .idle
            if errorMessage == nil { errorMessage = "That model isn't ready." }
            return
        }

        inputText = ""

        currentThread.messages.append(ChatMessage(role: .user, content: text))
        // Saved right away — not just after the full round trip
        // completes — so the message survives even if something else
        // interrupts before the assistant answers. A durability-only
        // save (no reassignment back onto `currentThread`): it could
        // resolve after later mutations in this same `send()` call and
        // must not clobber them if it does.
        if !isTemporaryModeActive {
            persistCurrentThreadForDurability()
        } else {
            rememberTemporaryThread()
        }

        let modelDisplayName = sessions.sessions.first { $0.id == id }?.model.displayName ?? id
        // Offered whenever an image model is either already loaded or
        // registered at all (and can be loaded on demand — see
        // `runGenerateImageTool`) — no point advertising a tool that
        // would just fail with nothing to back it.
        var hasAnyImageModel = !imageSessions.readySessions.isEmpty
        if !hasAnyImageModel {
            let registeredImageModels = await modelRegistry.all().filter { $0.kind == .image }
            hasAnyImageModel = !registeredImageModels.isEmpty
        }
        let tools: [ChatTool] = hasAnyImageModel ? [.generateImage] : []
        let contextBuilder = ChatContextBuilder(
            maxEstimatedTokens: maxEstimatedContextTokens,
            recentMessageCount: recentMessageCount
        )
        let activeProfileID = currentThread.profileID
        let contextMemories = memories.filter {
            ($0.profileID == nil || $0.profileID == activeProfileID) && $0.appliesTo(threadID: currentThread.id)
        }
        let context = contextBuilder.build(messages: currentThread.messages, memories: contextMemories)
        lastEstimatedContextTokens = context.messages.reduce(0) { $0 + ChatContextBuilder.estimateTokens($1.content) }
        let systemPrompt = composedSystemPrompt(offeringTools: !tools.isEmpty, memoryPrompt: context.memoryPrompt)
        let responderName = activeProfile?.name

        // Rewritten after every turn — the one piece of state
        // `ContextShiftCoordinator`'s background watcher actually
        // reads (see its own doc comment for why the 90%-of-context
        // trigger decision genuinely lives in that Python process, not
        // duplicated here): this Mac's own estimate of how full the
        // active model's context window is, plus a fresh export of the
        // thread to compact if that watcher decides to act on it.
        //
        // Deliberately the *full* thread's own token estimate
        // (`currentThread.messages`), not `lastEstimatedContextTokens`
        // (`context.messages` — already windowed down to
        // `maxEstimatedContextTokens`, 24,000 by default, by
        // `ChatContextBuilder.build` a few lines up). A real, reported
        // bug this fixes: feeding the watcher the *post-truncation*
        // number meant it could never actually reflect how long the
        // real conversation had grown — once a thread passed that
        // budget, this number effectively stopped growing at all, so
        // the 90%-of-context-window trigger could go unreached forever
        // for any model whose real context window is bigger than
        // ~26,700 tokens (24,000 ÷ 0.9), no matter how long the
        // conversation actually got. Reported live: "o contexto deve
        // estar bem longo já… mas não estou vendo ele executando o
        // fluxo de memoria, parece que simplesmente está travado de
        // fundo" — confirmed directly: the model server for that
        // conversation was genuinely deadlocked (unresponsive even to
        // a brand-new, five-token test request) with the compaction
        // pipeline never having triggered even once all session.
        let fullThreadEstimatedTokens = currentThread.messages.reduce(0) { $0 + ChatContextBuilder.estimateTokens($1.content) }
        if let modelPath = sessions.session(for: id)?.model.localPath {
            await contextShift.writeStatus(
                activeModelID: id,
                activeModelPath: modelPath,
                estimatedTokens: fullThreadEstimatedTokens,
                systemPrompt: systemPrompt,
                messages: currentThread.messages
            )
        }

        generationTask = Task { [weak self] in
            await self?.runChatLoop(
                endpoint: endpoint,
                modelDisplayName: modelDisplayName,
            responderName: responderName,
                tools: tools,
                systemPrompt: systemPrompt,
                contextMessages: context.messages,
                memoryIDsUsed: context.memoryIDs
            )
            guard let self else { return }
            self.isSending = false
            if self.generationPhase == .preparing || self.generationPhase == .reasoning || self.generationPhase == .generating {
                self.generationPhase = .idle
            }
            self.generationTask = nil
        }
    }

    func stopGeneration() {
        generationPhase = .cancelled
        generationTask?.cancel()
    }

    private func runChatLoop(
        endpoint: URL,
        modelDisplayName: String,
        responderName: String?,
        tools: [ChatTool],
        systemPrompt: String?,
        contextMessages: [ChatMessage],
        memoryIDsUsed: [UUID]
    ) async {
        do {
            currentThread.messages.append(ChatMessage(
                role: .assistant,
                content: "",
                modelDisplayName: modelDisplayName,
                responderName: responderName
            ))
            let replyIndex = currentThread.messages.count - 1
            // `contextMessages` already ends with the user's own current
            // message (`ChatContextBuilder.build` above ran before this
            // assistant placeholder existed) — no `dropLast()` here.
            // Confirmed for real against a running mlx_lm.server:
            // dropping it produces an empty `messages` array on a
            // thread's first turn, which the server rejects outright
            // ("Cannot apply chat template to an empty conversation").
            // A real, reproduced regression — this used to be correct
            // back when `contextMessages` was read fresh from
            // `currentThread.messages` *after* the placeholder append
            // (dropping the empty placeholder itself), before
            // `ChatContextBuilder` was introduced and this call site
            // started receiving a pre-built snapshot instead.
            let historyForRequest = contextMessages
            let stream = client.streamSend(
                messages: historyForRequest,
                baseURL: endpoint,
                model: idForEndpoint(endpoint, modelID: selectedModelID),
                modelDisplayName: modelDisplayName,
                settings: settings,
                tools: tools,
                systemPrompt: systemPrompt,
                conversationID: currentThread.id.uuidString
            )

            generationPhase = .reasoning
            var reply: ChatMessage?
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case .contentDelta(let delta):
                    generationPhase = .generating
                    currentThread.messages[replyIndex].content += delta
                case .reasoningDelta(let delta):
                    generationPhase = .reasoning
                    currentThread.messages[replyIndex].reasoning =
                        (currentThread.messages[replyIndex].reasoning ?? "") + delta
                case .done(let message):
                    reply = message
                }
            }
            // A real, reproduced bug this replaces: silently returning
            // here left an empty assistant placeholder on screen and on
            // disk forever, with no error shown and nothing to retry —
            // exactly what happened to a live conversation (confirmed
            // by reading its persisted state directly: an untouched
            // empty placeholder, both the app and the model server
            // fully idle, no crash, no log line anywhere). `.done`
            // should always fire once `streamSend`'s byte-reading loop
            // ends, by that method's own design — but "should always"
            // isn't a guarantee a user should ever pay for with a
            // silent hang. Treat its absence as the failure it is.
            guard var reply else {
                generationPhase = .failed
                errorMessage = "The response ended with no content — nothing to show. Try sending again."
                currentThread.messages[replyIndex] = ChatMessage(
                    role: .assistant,
                    content: "⚠️ No response was received — the connection may have dropped. Try sending again.",
                    modelDisplayName: modelDisplayName,
                    responderName: responderName
                )
                if !isTemporaryModeActive {
                    persistCurrentThread()
                }
                return
            }
            reply.responderName = responderName
            reply.memoryIDsUsed = memoryIDsUsed
            currentThread.messages[replyIndex] = reply

            if let toolCall = reply.toolCalls?.first(where: { $0.name == "generate_image" }) {
                generationPhase = .generatingImage
                let (toolResult, generatedPath) = await runGenerateImageTool(toolCall)
                currentThread.messages.append(toolResult)
                let followUpBuilder = ChatContextBuilder(
                    maxEstimatedTokens: maxEstimatedContextTokens,
                    recentMessageCount: recentMessageCount
                )
                let followUpMemories = memories.filter {
                    ($0.profileID == nil || $0.profileID == currentThread.profileID) && $0.appliesTo(threadID: currentThread.id)
                }
                let followUpContext = followUpBuilder.build(messages: currentThread.messages, memories: followUpMemories)
                lastEstimatedContextTokens = followUpContext.messages.reduce(0) { $0 + ChatContextBuilder.estimateTokens($1.content) }
                let followUpStream = client.streamSend(
                    messages: followUpContext.messages,
                    baseURL: endpoint,
                    model: idForEndpoint(endpoint, modelID: selectedModelID),
                    modelDisplayName: modelDisplayName,
                    settings: settings,
                    systemPrompt: systemPrompt,
                    conversationID: currentThread.id.uuidString
                )
                currentThread.messages.append(ChatMessage(
                    role: .assistant,
                    content: "",
                    modelDisplayName: modelDisplayName,
                    responderName: responderName
                ))
                let followUpIndex = currentThread.messages.count - 1
                var followUpReply: ChatMessage?
                for try await event in followUpStream {
                    try Task.checkCancellation()
                    switch event {
                    case .contentDelta(let delta):
                        generationPhase = .generating
                        currentThread.messages[followUpIndex].content += delta
                    case .reasoningDelta(let delta):
                        currentThread.messages[followUpIndex].reasoning =
                            (currentThread.messages[followUpIndex].reasoning ?? "") + delta
                    case .done(let message):
                        followUpReply = message
                    }
                }
                if var followUpReply {
                    followUpReply.generatedImagePath = generatedPath
                    followUpReply.responderName = responderName
                    followUpReply.memoryIDsUsed = followUpContext.memoryIDs
                    currentThread.messages[followUpIndex] = followUpReply
                } else {
                    // Same real bug as the `guard var reply` case above,
                    // same fix — this is the follow-up turn after a
                    // `generate_image` tool call, and it silently left
                    // an empty placeholder behind exactly the same way.
                    generationPhase = .failed
                    errorMessage = "The follow-up response after generating the image ended with no content. Try sending again."
                    currentThread.messages[followUpIndex] = ChatMessage(
                        role: .assistant,
                        content: "⚠️ The image generated, but the follow-up reply never arrived — the connection may have dropped. Try sending again.",
                        modelDisplayName: modelDisplayName,
                        responderName: responderName
                    )
                }
            }

            if let finalMessage = currentThread.messages.last(where: { $0.role == .assistant }) {
                lastTokensPerSecond = finalMessage.tokensPerSecond
                lastCachedPromptTokens = finalMessage.cachedPromptTokens
            }
            if !isTemporaryModeActive {
                persistCurrentThread()
            }
        } catch is CancellationError {
            if let last = currentThread.messages.last,
               last.role == .assistant,
               last.content.isEmpty,
               last.toolCalls == nil {
                currentThread.messages.removeLast()
            }
            if !isTemporaryModeActive {
                persistCurrentThread()
            }
        } catch {
            if let last = currentThread.messages.last,
               last.role == .assistant,
               last.content.isEmpty,
               last.toolCalls == nil {
                currentThread.messages.removeLast()
            }
            generationPhase = .failed
            errorMessage = error.localizedDescription
            if !isTemporaryModeActive {
                persistCurrentThread()
            }
        }
    }

    private func idForEndpoint(_ endpoint: URL, modelID: String?) -> String {
        endpoint.port == OpenAIGateway.port ? (modelID ?? "default_model") : "default_model"
    }

    /// The active profile's prompt, plus (whenever the image tool is on
    /// offer) an explicit instruction to only call it when actually
    /// asked for an image — a real bug found in testing: without this,
    /// some local models called `generate_image` on nearly every
    /// message, tool or not.
    private func composedSystemPrompt(offeringTools: Bool, memoryPrompt: String? = nil) -> String? {
        var parts: [String] = []
        if let prompt = activeProfile?.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            parts.append(prompt)
        }
        if offeringTools {
            parts.append(ChatTool.generateImageUsageDiscipline)
        }
        if let memoryPrompt, !memoryPrompt.isEmpty {
            parts.append(memoryPrompt)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// Runs a `generate_image` tool call for real — actual generation
    /// through an image model's server, not a stub. Loads a registered
    /// image model on demand if none is currently resident (and, per
    /// that model's own chat setting, unloads it again afterward to
    /// free memory). Returns the `.tool`-role message to feed back to
    /// the chat model, plus the generated file's path (if any) for the
    /// caller to attach to the visible reply that follows.
    private func runGenerateImageTool(_ call: ChatMessage.ToolCall) async -> (ChatMessage, String?) {
        struct Arguments: Decodable { let prompt: String }

        guard let data = call.argumentsJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: data) else {
            return (ChatMessage(role: .tool, content: "Error: could not parse tool arguments.", toolCallID: call.id), nil)
        }

        let imageModelID: String
        let preferredID = AppSettings.load().defaultChatImageModelID
        let registeredImageModels = await modelRegistry.all().filter { $0.kind == .image }

        if let preferredID, imageSessions.isLoaded(modelID: preferredID) {
            // The configured default is already resident — use it even
            // if some other image model also happens to be loaded.
            imageModelID = preferredID
        } else if let ready = imageSessions.readySessions.first {
            // No configured default (or it isn't loaded) but something
            // else already is — use that rather than loading a second
            // image model just to honor an unmet preference.
            imageModelID = ready.id
        } else if let entry = registeredImageModels.first(where: { $0.id == preferredID }) ?? registeredImageModels.first {
            let loaded = await imageSessions.load(entry, requirements: requirements)
            guard loaded else {
                let reason = imageSessions.session(for: entry.id)?.status
                let detail: String
                if case .failed(let message) = reason { detail = message } else { detail = "load failed" }
                return (ChatMessage(role: .tool, content: "Error loading the image model: \(detail)", toolCallID: call.id), nil)
            }
            imageModelID = entry.id
        } else {
            return (ChatMessage(role: .tool, content: "Error: no image model is registered.", toolCallID: call.id), nil)
        }

        guard let imageEndpoint = imageSessions.imageEndpoint(for: imageModelID) else {
            return (ChatMessage(role: .tool, content: "Error: the image model isn't ready.", toolCallID: call.id), nil)
        }
        let model = imageSessions.session(for: imageModelID)?.model
        let imageModelName = model?.displayName ?? imageModelID

        // Carry the previous generation's prompt + seed forward within
        // this thread for consistency, or fall back to the active
        // profile's own character description on the first image.
        let previous = lastImageGenerationByThread[currentThread.id]
        var effectivePrompt = arguments.prompt
        var seed: Int?
        if let previous {
            seed = previous.seed
            effectivePrompt = "\(previous.prompt). Keep the same character appearance — skin tone, hair "
                + "color and style, eye color, body type — unless this request clearly changes them: "
                + arguments.prompt
        } else if let profilePrompt = activeProfile?.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !profilePrompt.isEmpty {
            effectivePrompt = "\(profilePrompt). \(arguments.prompt)"
        }

        let imageSettings = ImageGenerationSettings(
            width: model?.defaultImageWidth ?? ImageGenerationSettings.default.width,
            height: model?.defaultImageHeight ?? ImageGenerationSettings.default.height
        )

        imageToolProgress = nil
        defer { imageToolProgress = nil }

        do {
            let result = try await imageClient.generate(
                prompt: effectivePrompt,
                baseURL: imageEndpoint,
                settings: imageSettings,
                seed: seed
            ) { [weak self] progress in
                Task { @MainActor in self?.imageToolProgress = progress.fraction }
            }
            lastImageGenerationByThread[currentThread.id] = (seed: result.seed, prompt: arguments.prompt)

            let saved = try await generatedImageStore.add(GeneratedImage(
                prompt: arguments.prompt,
                modelDisplayName: imageModelName,
                localPath: result.localPath,
                width: result.width,
                height: result.height,
                seed: result.seed
            ))

            if model?.keepImageModelLoadedInChat == false {
                await imageSessions.unload(modelID: imageModelID)
            }

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
        let cloudEnabled = isCloudSyncEnabled
        Task {
            guard let saved = try? await threadStore.upsert(threadToSave) else { return }
            if currentThread.id == saved.id {
                currentThread = saved
            }
            allThreads = await threadStore.all()
            if cloudEnabled {
                await cloudSync.markThreadChanged(saved)
                await cloudSync.syncNow()
            }
        }
    }

    /// Write-only: saves to disk without reassigning `currentThread` —
    /// see the call site in `send()` for why that distinction matters.
    private func persistCurrentThreadForDurability() {
        let threadToSave = currentThread
        let cloudEnabled = isCloudSyncEnabled
        Task {
            guard let saved = try? await threadStore.upsert(threadToSave) else { return }
            if cloudEnabled {
                await cloudSync.markThreadChanged(saved)
                await cloudSync.syncNow()
            }
        }
    }
}
