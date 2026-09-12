import SwiftUI
import MLXLMCommon
import AnvilCore

/// A real chat screen — either on-device inference via `NativeChatEngine`
/// (no server, no network round trip once the model is loaded) or a
/// model already loaded on a Mac on the same network via
/// `RemoteChatEngine` (the same `ChatClient` the Mac app's own Chat uses)
/// — picked with the source menu next to the model bar instead of a
/// second, separate chat screen. Conversations persist via
/// `ChatThreadsViewModel`/`ChatThreadStore`, the same cross-platform
/// store the Mac app's Chat uses, and Memory/Profiles apply to either
/// source identically. Picking a Mac with sync enabled (`AnvilSyncServer`
/// running there) goes further: `ChatThreadsViewModel.activeSource`
/// governs Profiles/Memory too, so all three tabs show that Mac's own
/// data — the same threads, profiles, and memories the Mac app itself
/// would show, kept in sync there even though the iPhone is typing. The
/// model ID field takes any Hugging Face MLX-format repo (e.g.
/// `mlx-community/Qwen3-0.6B-4bit`), or pick one already downloaded in
/// the Models tab from the menu next to it.
struct NativeChatView: View {
    @Environment(ModelsViewModel.self) private var modelsViewModel
    @Environment(ProfilesViewModel.self) private var profilesViewModel
    @Environment(ChatThreadsViewModel.self) private var threads
    @EnvironmentObject private var engine: NativeChatEngine
    @StateObject private var remoteEngine = RemoteChatEngine()
    @StateObject private var connectionsModel = RemoteConnectionsViewModel()
    @State private var selectedImageConnectionID: UUID?
    @State private var isConnectionsSheetPresented = false
    @State private var modelID = "mlx-community/Qwen3-0.6B-4bit"
    @State private var inputText = ""
    @State private var isLocalGenerating = false
    @State private var isThreadListPresented = false
    /// The user's own explicit pick, made before hitting Load — takes
    /// priority over the model's bound default. `nil` means "haven't
    /// touched the picker", which falls back to that model's default
    /// profile (if any) the same way it always did; `.some(nil)` isn't
    /// representable here, so an explicit "no profile" pick is tracked
    /// separately via `manualProfileChoiceMade`.
    @State private var selectedProfile: ChatProfile?
    @State private var manualProfileChoiceMade = false
    @State private var isSettingsPresented = false
    @State private var lastTokensPerSecond: Double?

    private var source: ChatSourceSelection { threads.activeSource }

    /// Only true before the first message — same restriction
    /// `ChatViewModel.canChangeProfile` documents: once a reply exists
    /// under a given profile, switching it would mix instructions with
    /// history that never saw them.
    private var canChangeProfile: Bool { threads.currentThread.messages.isEmpty }

    private var activeProfile: ChatProfile? {
        guard let id = threads.currentThread.profileID else { return nil }
        return profilesViewModel.profiles.first { $0.id == id }
    }

    private var isGenerating: Bool {
        switch source {
        case .local: return isLocalGenerating
        case .mac: return remoteEngine.isSending
        }
    }

    private var selectedImageConnection: RemoteMacConnection? {
        connectionsModel.imageConnections.first { $0.id == selectedImageConnectionID }
    }

    private var canSend: Bool {
        switch source {
        case .local: return engine.isLoaded
        case .mac: return true
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sourceBar
                if canChangeProfile {
                    profileBar
                } else if let activeProfile {
                    Text("Profile: \(activeProfile.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
                Divider()

                if let errorMessage = source == .local ? engine.errorMessage : remoteEngine.errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption).padding(8)
                } else if let syncError = threads.errorMessage {
                    Text(syncError).foregroundStyle(.red).font(.caption).padding(8)
                }

                if threads.isTemporaryModeActive {
                    Label("Temporary — not saved", systemImage: "eyeglasses")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(threads.currentThread.messages) { message in
                                bubble(message).id(message.id)
                            }
                            if isLocalGenerating {
                                ProgressView().padding(.leading, 8)
                            } else if case .mac = source, remoteEngine.generationPhase != .idle {
                                remoteGeneratingIndicator
                            }
                        }
                        .padding()
                    }
                    .onChange(of: threads.currentThread.messages.count) { _, _ in
                        guard let lastID = threads.currentThread.messages.last?.id else { return }
                        withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .dismissKeyboardOnTap()
                }

                Divider()
                inputBar
            }
            .navigationTitle(threads.currentThread.title)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { isThreadListPresented = true } label: {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .disabled(threads.isTemporaryModeActive)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 4) {
                        if let tps = source == .local ? lastTokensPerSecond : remoteEngine.lastTokensPerSecond {
                            Text(String(format: "%.1f tok/s", tps))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button { threads.toggleTemporaryMode() } label: {
                            Image(systemName: threads.isTemporaryModeActive ? "eyeglasses" : "eyeglasses.slash")
                        }
                        .disabled(isGenerating || source != .local)
                        exportMenu
                        Button { isSettingsPresented = true } label: { Image(systemName: "slider.horizontal.3") }
                        Button { newChat() } label: { Image(systemName: "square.and.pencil") }
                            .disabled(threads.isTemporaryModeActive)
                            .disabled(isGenerating)
                    }
                }
            }
            .sheet(isPresented: $isThreadListPresented) { threadListSheet }
            .sheet(isPresented: $isSettingsPresented) { settingsSheet }
            .sheet(isPresented: $isConnectionsSheetPresented) { connectionsSheet }
            .task { await profilesViewModel.load() }
            .task { await threads.loadInitialState() }
            .task { await connectionsModel.refreshConnections() }
        }
    }

    // MARK: - Threads

    private var threadListSheet: some View {
        NavigationStack {
            List {
                if threads.allThreads.isEmpty {
                    Text("No saved conversations yet.").foregroundStyle(.secondary)
                }
                ForEach(threads.allThreads) { thread in
                    Button {
                        selectThread(thread)
                        isThreadListPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(thread.title).foregroundStyle(.primary)
                            Text(thread.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task { await threads.deleteThread(thread) }
                        }
                    }
                }
            }
            .navigationTitle("Conversations")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isThreadListPresented = false }
                }
            }
        }
    }

    /// Copy or share the current conversation as Markdown — same
    /// `TranscriptFormatter` (cross-platform) the Mac app's "Copy All"/
    /// "Export…" buttons use.
    private var exportMenu: some View {
        let markdown = TranscriptFormatter.markdown(
            modelName: threads.currentThread.title, messages: threads.currentThread.messages)
        return Menu {
            Button {
                UIPasteboard.general.string = markdown
            } label: {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }
            ShareLink(item: markdown, preview: SharePreview(threads.currentThread.title)) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(threads.currentThread.messages.isEmpty)
    }

    /// Generation parameters — same fields the Mac app's Chat sidebar
    /// edits (`GenerationSettings`, cross-platform), applied fresh
    /// before every request regardless of which engine (local or
    /// remote) is currently answering.
    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("Generation") {
                    LabeledContent("Max Tokens") {
                        TextField("Unlimited", text: Binding(
                            get: { engine.settings.maxTokens.map(String.init) ?? "" },
                            set: { engine.settings.maxTokens = Int($0.trimmingCharacters(in: .whitespaces)) }
                        ))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Temperature") {
                        TextField("", value: $engine.settings.temperature, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Top P") {
                        TextField("", value: $engine.settings.topP, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Top K") {
                        TextField("", value: $engine.settings.topK, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Min P") {
                        TextField("", value: $engine.settings.minP, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Generation Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isSettingsPresented = false }
                }
            }
            .dismissKeyboardOnTap()
        }
    }

    private func newChat() {
        guard !isGenerating else { return }
        threads.newThread()
        manualProfileChoiceMade = false
        selectedProfile = nil
        if source == .local, engine.isLoaded {
            Task { await applyCurrentProfileChoice(startFreshSessionIfLoaded: true) }
        }
    }

    /// Switches the visible conversation and, if a local model is
    /// already loaded, immediately rehydrates the session with this
    /// thread's history — no re-download, no reload, just a fresh
    /// `ChatSession` built from the saved turns (see
    /// `NativeChatEngine.startSession`). A no-op for the remote engine,
    /// which is stateless per request and just replays history on the
    /// next send.
    private func selectThread(_ thread: ChatThread) {
        guard !isGenerating else { return }
        threads.selectThread(thread)
        manualProfileChoiceMade = thread.profileID != nil
        selectedProfile = activeProfile
        if source == .local, engine.isLoaded {
            engine.startSession(instructions: composedLocalInstructions(profile: activeProfile), history: thread.messages)
        }
    }

    // MARK: - Profile picker

    /// Lets the user explicitly pick which profile shapes the
    /// conversation before starting it, instead of only ever getting
    /// whichever one is bound to the model as its default.
    private var profileBar: some View {
        HStack {
            Text("Profile").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button {
                    Task { await choose(profile: nil, manual: false) }
                } label: {
                    Label("Automatic (model default)", systemImage: "wand.and.stars")
                }
                Button {
                    Task { await choose(profile: nil, manual: true) }
                } label: {
                    Label("None", systemImage: "slash.circle")
                }
                if !profilesViewModel.profiles.isEmpty {
                    Divider()
                    ForEach(profilesViewModel.profiles) { profile in
                        Button(profile.name) {
                            Task { await choose(profile: profile, manual: true) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(profileBarLabel)
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private var profileBarLabel: String {
        if manualProfileChoiceMade {
            return selectedProfile?.name ?? "None"
        }
        return "Automatic"
    }

    /// Records the pick and, if a local model is already loaded, applies
    /// it right away by rebuilding the session — so choosing a profile
    /// for a brand-new thread doesn't require pressing Load again when
    /// one is already resident. A no-op session rebuild for the remote
    /// engine (stateless per request; the next send just picks it up).
    private func choose(profile: ChatProfile?, manual: Bool) async {
        manualProfileChoiceMade = manual
        selectedProfile = profile
        await applyCurrentProfileChoice(startFreshSessionIfLoaded: true)
    }

    /// Resolves the picker's current choice into `currentThread.profileID`
    /// — a no-op once the thread already has messages, since the profile
    /// is fixed at that point (`canChangeProfile`). Optionally rebuilds
    /// the live local session immediately so a loaded model picks it up.
    private func applyCurrentProfileChoice(startFreshSessionIfLoaded: Bool) async {
        guard canChangeProfile else { return }
        let profile: ChatProfile?
        if manualProfileChoiceMade {
            profile = selectedProfile
        } else {
            let lookupModelID = engine.isLoaded ? (engine.loadedModelID ?? modelID) : modelID
            profile = await profilesViewModel.defaultProfile(forModelID: lookupModelID)
        }
        threads.currentThread.profileID = profile?.id
        if startFreshSessionIfLoaded, source == .local, engine.isLoaded {
            engine.startSession(instructions: composedLocalInstructions(profile: profile), history: threads.currentThread.messages)
        }
    }

    /// Folds durable memory into the local engine's fixed-at-session-
    /// start `instructions`, alongside the active profile's prompt — the
    /// same content the remote engine injects as a system-prompt on
    /// every request, just applied once here since an on-device
    /// `ChatSession`'s instructions can't change mid-session (see
    /// `NativeChatEngine.startSession`'s own doc comment).
    private func composedLocalInstructions(profile: ChatProfile?) -> String? {
        var parts: [String] = []
        if let prompt = profile?.prompt.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            parts.append(prompt)
        }
        let scopedMemories = threads.memories.filter { $0.profileID == nil || $0.profileID == profile?.id }
        if let memoryPrompt = ChatContextBuilder().build(messages: [], memories: scopedMemories).memoryPrompt {
            parts.append(memoryPrompt)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Source bar

    /// "This iPhone" (on-device, unchanged) vs a Mac already found on the
    /// network or previously saved — one tap from a discovered model
    /// straight into use, the same frictionless flow the Mac tab already
    /// had, just relocated here instead of living behind a second chat
    /// screen. Picking a Mac also switches Profiles/Memory to its data —
    /// see `ChatThreadsViewModel.selectSource`.
    private var sourceBar: some View {
        HStack {
            Menu {
                Button {
                    Task { await threads.selectSource(.local, profilesViewModel: profilesViewModel) }
                } label: {
                    Label("This iPhone", systemImage: "iphone")
                }
                if !connectionsModel.textConnections.isEmpty {
                    Divider()
                    ForEach(connectionsModel.textConnections) { connection in
                        Button {
                            Task { await threads.selectSource(.mac(connection), profilesViewModel: profilesViewModel) }
                        } label: {
                            Label(connection.displayName, systemImage: "network")
                        }
                    }
                }
                if !connectionsModel.discoveredModels.filter({ $0.kind == .text }).isEmpty {
                    Divider()
                    ForEach(connectionsModel.discoveredModels.filter { $0.kind == .text }) { discovered in
                        Button {
                            let connection = connectionsModel.connect(to: discovered)
                            Task { await threads.selectSource(.mac(connection), profilesViewModel: profilesViewModel) }
                        } label: {
                            Label("Remote: \(discovered.displayName)", systemImage: "bolt.horizontal")
                        }
                    }
                }
                Divider()
                Button {
                    isConnectionsSheetPresented = true
                } label: {
                    Label("Manage Mac Connections…", systemImage: "gearshape")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: sourceIcon)
                    Text(sourceLabel).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                }
                .font(.caption)
            }
            .disabled(isGenerating)

            Spacer()

            switch source {
            case .local:
                localModelControls
            case .mac:
                remoteSourceControls
            }
        }
        .padding(8)
    }

    private var sourceIcon: String {
        switch source {
        case .local: return "iphone"
        case .mac: return "network"
        }
    }

    private var sourceLabel: String {
        switch source {
        case .local: return engine.loadedModelID ?? "This iPhone"
        case .mac(let connection): return connection.displayName
        }
    }

    private var localModelControls: some View {
        HStack {
            TextField("mlx-community/…", text: $modelID)
                .textFieldStyle(.roundedBorder)
                .disabled(engine.isLoading || engine.isLoaded)
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .frame(maxWidth: 160)

            if !engine.isLoaded && !engine.isLoading {
                Menu {
                    let textModels = modelsViewModel.registeredModels.filter { $0.kind == .text }
                    if textModels.isEmpty {
                        Text("None registered yet — download one in Models.")
                    } else {
                        ForEach(textModels) { entry in
                            Button(entry.displayName) { modelID = entry.id }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
            }

            if engine.isLoaded {
                Button("Unload") { engine.unload() }
            } else if engine.isLoading {
                if let progress = engine.loadProgress {
                    ProgressView(value: progress).frame(width: 80)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Button("Load") { Task { await load() } }
            }
        }
    }

    /// A remote source has nothing to "load" — it's either reachable or
    /// it isn't — so this just shows that, plus an optional pick for
    /// which remote **image** connection (if any) `generate_image` tool
    /// calls should go to.
    private var remoteSourceControls: some View {
        HStack(spacing: 6) {
            if case .mac(let connection) = source {
                Circle()
                    .fill(connectionsModel.reachableConnectionIDs.contains(connection.id) ? .green : .secondary)
                    .frame(width: 6, height: 6)
            }
            Menu {
                Button("None") { selectedImageConnectionID = nil }
                ForEach(connectionsModel.imageConnections) { connection in
                    Button(connection.displayName) { selectedImageConnectionID = connection.id }
                }
            } label: {
                Text("Image: \(selectedImageConnection?.displayName ?? "None")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionsSheet: some View {
        NavigationStack {
            RemoteConnectionsListView(connectionsModel: connectionsModel, preferredKind: .text) { connection in
                Task { await threads.selectSource(.mac(connection), profilesViewModel: profilesViewModel) }
                isConnectionsSheetPresented = false
            }
            .navigationTitle("Mac Connections")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isConnectionsSheetPresented = false }
                }
            }
        }
    }

    private var remoteGeneratingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            if let label = remoteEngine.generationPhase.label {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 8)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                if let path = message.generatedImagePath, let uiImage = UIImage(contentsOfFile: path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contextMenu {
                            ShareLink(item: URL(fileURLWithPath: path))
                        }
                }
                if !message.content.isEmpty {
                    Text(message.content)
                }
            }
            .padding(10)
            .background(isUser ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("Message…", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(!canSend)
            if case .mac = source, remoteEngine.isSending {
                Button("Stop", role: .destructive) { remoteEngine.stopGeneration() }
            } else {
                Button("Send") { send() }
                    .disabled(!canSend || isGenerating || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(8)
    }

    /// Loads (or reuses, if already resident) `modelID`'s weights, then
    /// starts a session rehydrated from the current thread's saved
    /// messages — resuming a past conversation exactly where it left
    /// off, or starting clean for an empty one. Only meaningful for the
    /// local source.
    private func load() async {
        await applyCurrentProfileChoice(startFreshSessionIfLoaded: false)
        await engine.load(
            modelID: modelID, instructions: composedLocalInstructions(profile: activeProfile),
            history: threads.currentThread.messages)
    }

    private func send() {
        switch source {
        case .local:
            sendLocal()
        case .mac(let connection):
            remoteEngine.send(
                text: inputText,
                threads: threads,
                connection: connection,
                imageConnection: selectedImageConnection,
                profile: activeProfile,
                memories: threads.memories,
                settings: engine.settings
            )
            inputText = ""
        }
    }

    private func sendLocal() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, engine.isLoaded, !isLocalGenerating else { return }
        inputText = ""
        isLocalGenerating = true

        threads.currentThread.messages.append(ChatMessage(role: .user, content: text))
        if threads.currentThread.title == "New Chat", threads.currentThread.messages.count == 1 {
            threads.currentThread.title = String(text.prefix(48))
        }
        // Saved right away — not just after the full round trip
        // completes — so the message survives even if something else
        // interrupts before the assistant answers.
        threads.persistCurrentThreadForDurability()

        let modelDisplayName = engine.loadedModelID ?? modelID

        Task {
            defer { isLocalGenerating = false }
            do {
                threads.currentThread.messages.append(
                    ChatMessage(role: .assistant, content: "", modelDisplayName: modelDisplayName))
                let replyIndex = threads.currentThread.messages.count - 1
                let stream = try engine.streamSend(text)
                for try await chunk in stream {
                    threads.currentThread.messages[replyIndex].content += chunk
                }
                // Set only if a generate_image tool call actually ran
                // as part of that stream (see NativeChatEngine.refreshTools).
                if let imagePath = engine.consumeLastGeneratedImagePath() {
                    threads.currentThread.messages[replyIndex].generatedImagePath = imagePath
                }
                if let tokensPerSecond = engine.consumeLastTokensPerSecond() {
                    threads.currentThread.messages[replyIndex].tokensPerSecond = tokensPerSecond
                    lastTokensPerSecond = tokensPerSecond
                }
            } catch {
                threads.currentThread.messages.append(
                    ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
            }
            await threads.persistCurrentThread()
        }
    }
}
