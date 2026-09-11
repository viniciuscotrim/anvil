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
    @Published private(set) var availableProfiles: [ChatProfile] = []
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
    /// Set while a `generate_image` tool call is actively generating —
    /// nil the rest of the time, including while just waiting on the
    /// text model itself.
    @Published private(set) var imageToolProgress: Double?

    private let sessions: ModelSessionManager
    private let threadStore: ChatThreadStore
    private let imageSessions: ImageSessionManager
    private let generatedImageStore: GeneratedImageStore
    private let profileStore: ChatProfileStore
    private let modelRegistry: ModelRegistry
    private let requirements: RequirementsManager
    private let client = ChatClient()
    private let imageClient = ImageClient()
    private var threadBeforeTemporaryMode: ChatThread?
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

    init(
        sessions: ModelSessionManager,
        threadStore: ChatThreadStore,
        imageSessions: ImageSessionManager,
        generatedImageStore: GeneratedImageStore,
        profileStore: ChatProfileStore,
        modelRegistry: ModelRegistry,
        requirements: RequirementsManager
    ) {
        self.sessions = sessions
        self.threadStore = threadStore
        self.imageSessions = imageSessions
        self.generatedImageStore = generatedImageStore
        self.profileStore = profileStore
        self.modelRegistry = modelRegistry
        self.requirements = requirements
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
        availableProfiles = await profileStore.all()
        if !hasLoadedInitialState {
            currentThread = allThreads.first ?? ChatThread()
            hasLoadedInitialState = true
        }
        syncSelectedModel()
    }

    /// Keeps the selection pointed at a loaded model — called on
    /// appear and whenever the set of loaded models changes.
    func syncSelectedModel() {
        if let id = selectedModelID, sessions.isLoaded(modelID: id) {
            applyDefaultProfileIfNeeded(forModelID: id)
            return
        }
        selectedModelID = sessions.readySessions.first?.id
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

    // MARK: - Profiles

    var activeProfile: ChatProfile? {
        guard let id = currentThread.profileID else { return nil }
        return availableProfiles.first { $0.id == id }
    }

    /// Only true before the first message — see `ChatThread.profileID`.
    var canChangeProfile: Bool { currentThread.messages.isEmpty }

    func setProfile(_ profile: ChatProfile?) {
        guard canChangeProfile else { return }
        currentThread.profileID = profile?.id
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
    }

    // MARK: - Threads

    /// Blocked while temporary mode is active — the user has to turn
    /// that off first (an explicit action) — or while a message is
    /// still in flight, so a background send doesn't land on a thread
    /// the user has since switched away from.
    func newThread() {
        guard !isTemporaryModeActive, !isSending else { return }
        currentThread = ChatThread()
    }

    func selectThread(_ thread: ChatThread) {
        guard !isTemporaryModeActive, !isSending else { return }
        currentThread = thread
    }

    func deleteThread(_ thread: ChatThread) async {
        if isSending, currentThread.id == thread.id { return }
        try? await threadStore.delete(id: thread.id)
        allThreads.removeAll { $0.id == thread.id }
        lastImageGenerationByThread.removeValue(forKey: thread.id)
        if currentThread.id == thread.id {
            currentThread = allThreads.first ?? ChatThread()
        }
    }

    /// Empties the active conversation without deleting the thread
    /// entry itself.
    func clearCurrentConversation() {
        currentThread.messages.removeAll()
        lastTokensPerSecond = nil
        lastImageGenerationByThread.removeValue(forKey: currentThread.id)
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
        // Saved right away — not just after the full round trip
        // completes — so the message survives even if something else
        // interrupts before the assistant answers. A durability-only
        // save (no reassignment back onto `currentThread`): it could
        // resolve after later mutations in this same `send()` call and
        // must not clobber them if it does.
        if !isTemporaryModeActive {
            persistCurrentThreadForDurability()
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
        let systemPrompt = composedSystemPrompt(offeringTools: !tools.isEmpty)

        isSending = true
        defer { isSending = false }

        do {
            var reply = try await client.send(
                messages: currentThread.messages,
                baseURL: endpoint,
                modelDisplayName: modelDisplayName,
                settings: settings,
                tools: tools,
                systemPrompt: systemPrompt
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
                    settings: settings,
                    systemPrompt: systemPrompt
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

    /// The active profile's prompt, plus (whenever the image tool is on
    /// offer) an explicit instruction to only call it when actually
    /// asked for an image — a real bug found in testing: without this,
    /// some local models called `generate_image` on nearly every
    /// message, tool or not.
    private func composedSystemPrompt(offeringTools: Bool) -> String? {
        var parts: [String] = []
        if let prompt = activeProfile?.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            parts.append(prompt)
        }
        if offeringTools {
            parts.append(ChatTool.generateImageUsageDiscipline)
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
        Task {
            guard let saved = try? await threadStore.upsert(threadToSave) else { return }
            if currentThread.id == saved.id {
                currentThread = saved
            }
            allThreads = await threadStore.all()
        }
    }

    /// Write-only: saves to disk without reassigning `currentThread` —
    /// see the call site in `send()` for why that distinction matters.
    private func persistCurrentThreadForDurability() {
        let threadToSave = currentThread
        Task {
            _ = try? await threadStore.upsert(threadToSave)
        }
    }
}
