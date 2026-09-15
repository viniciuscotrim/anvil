import SwiftUI
import AppKit
import AnvilCore

/// An app-level chat window. The threads column (left) navigates
/// between conversations; the header carries the editable title, the
/// active model (switchable), and performance metrics; Temporary Chat
/// lives in the composer, since it only matters at the start of a
/// thread; display options, generation settings, and export live in
/// the collapsible side panel. iPhone/iCloud sync are app-wide, not
/// per-conversation — see `RootView`'s top bar instead.
struct ChatView: View {
    @Environment(ModelSessionManager.self) private var sessions
    @Environment(ChatViewModel.self) private var chat
    @Environment(\.openWindow) private var openWindow
    @State private var newMemoryText = ""
    @State private var memoryMessageID: UUID?
    @State private var shiftReturnMonitor: Any?
    @FocusState private var isTitleFieldFocused: Bool
    /// True only for the detached window opened via the "pop out"
    /// button (`WindowGroup(id: "chat-popout")` in `AnvilApp`) — same
    /// `ChatViewModel`, but a different layout: no threads column (that
    /// stays in the main window) and the right-hand settings panel is
    /// always shown here instead of being optional.
    var isPopout: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if !isPopout, chat.isThreadsSidebarOpen || chat.isPoppedOut {
                threadsSidebar
                    .frame(width: 240)
                Divider()
            }

            if !isPopout, chat.isPoppedOut {
                poppedOutPlaceholder
                    .frame(minWidth: 480, minHeight: 480)
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()

                    if !chat.visibleMessages.isEmpty {
                        // Reading and navigating a past conversation
                        // never needed a model loaded on disk — only
                        // sending a *new* message does (the input bar
                        // below already gates that on its own). Now
                        // that history syncs through iCloud too,
                        // requiring the last-used model to still be
                        // loaded just to look at it stopped making
                        // sense: reported live — "hoje sou obrigado,
                        // mas com o histórico na núvem não faz
                        // sentido" (today I'm forced to, but with
                        // history in the cloud it doesn't make sense).
                        messageList
                    } else if chat.selectedModelID == nil {
                        emptyState
                    } else {
                        // Doesn't require the model to actually be
                        // loaded right now — picking one no longer
                        // means picking a *loaded* one; `send()` loads
                        // it on demand the moment there's something to
                        // send.
                        Spacer()
                        Text("Say something to \(activeModelName).")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    if let status = chat.contextShiftStatus, status.isPaused {
                        contextShiftBanner(status)
                    }

                    if let error = chat.errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(error)
                            Spacer()
                            Button {
                                chat.errorMessage = nil
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.top, 4)
                    }

                    if !chat.isSending,
                       let phase = chat.generationPhase.label,
                       chat.generationPhase == .cancelled {
                        Text(phase)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.top, 4)
                    }

                    Divider()
                    inputBar
                }
                .frame(minWidth: 480, minHeight: 480)
            }

            // In the popout, the settings panel is the whole reason the
            // window exists, so it's always visible there — no toggle.
            // In the main window it stays optional, and disappears
            // entirely once popped out (it now lives in that window).
            if isPopout {
                Divider()
                sidebar
                    .frame(width: 280)
            } else if chat.isSidebarOpen && !chat.isPoppedOut {
                Divider()
                sidebar
                    .frame(width: 280)
            }
        }
        .task {
            // iPhone/iCloud sync startup lives in `RootView`'s own
            // `.task` now — those controls are app-wide (see the top
            // bar), not specific to whether Chat has ever been opened.
            await chat.loadInitialState()
        }
        .task {
            await chat.pollForExternalThreadUpdates()
        }
        .onChange(of: sessions.sessions) { _, _ in chat.syncSelectedModel() }
        .onAppear {
            if isPopout { chat.isPoppedOut = true }
            // Shift+Return -> insert a newline in the composer instead
            // of submitting. Not `.onKeyPress(.return)` on the
            // TextField itself — that reliably caused a real, reported
            // regression (Shift+Return selecting the entire field's
            // text instead of adding a line, a known SwiftUI quirk
            // around returning `.ignored` from a Return-scoped
            // `onKeyPress` and having the event redelivered through the
            // responder chain). A local `NSEvent` monitor sidesteps
            // that entirely: it never touches SwiftUI's own key-press
            // handling, just appends the newline directly and consumes
            // the event so `.onSubmit` never also fires for the same
            // keystroke.
            guard shiftReturnMonitor == nil else { return }
            shiftReturnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 36, event.modifierFlags.contains(.shift) else { return event }
                chat.inputText += "\n"
                return nil
            }
        }
        .onDisappear {
            // The only way `isPoppedOut` clears — closing this window
            // is what brings the main window's conversation pane back.
            if isPopout { chat.isPoppedOut = false }
            if let monitor = shiftReturnMonitor {
                NSEvent.removeMonitor(monitor)
                shiftReturnMonitor = nil
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { chat.isExportPresented },
                set: { chat.isExportPresented = $0 }
            ),
            document: TranscriptDocument(text: chat.exportMarkdown()),
            contentType: .markdownTranscript,
            defaultFilename: chat.currentThread.title + ".md"
        ) { _ in }
    }

    private var activeModelName: String {
        // Looked up against every *registered* model, not just a
        // loaded one (`sessions.sessions` only ever holds
        // loading/ready/failed sessions) — the selected model is now
        // routinely one that isn't resident yet.
        chat.availableTextModels.first { $0.id == chat.selectedModelID }?.displayName ?? "the model"
    }

    // MARK: - Header (stays outside the sidebar, always visible)

    private var header: some View {
        HStack {
            if !isPopout {
                Button {
                    chat.isThreadsSidebarOpen.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Show or hide the threads list.")
            }

            titleField

            modelPicker
            profilePicker

            if chat.isTemporaryModeActive {
                Label("Temporary", systemImage: "eyeglasses")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            if let tps = chat.lastTokensPerSecond {
                Text(String(format: "%.1f tok/s", tps))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let cached = chat.lastCachedPromptTokens, cached > 0 {
                Text("cache \(cached)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if chat.lastEstimatedContextTokens > 0 {
                Text("context ~\(chat.lastEstimatedContextTokens) tok")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !isPopout {
                Button {
                    openWindow(id: "chat-popout")
                } label: {
                    Image(systemName: "macwindow.badge.plus")
                }
                .help("Open this conversation in its own window.")
                .disabled(chat.isPoppedOut)

                Button {
                    chat.isSidebarOpen.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
            }
        }
        .padding()
    }

    /// Every registered text model, loaded or not — requested live:
    /// this used to only list `sessions.readySessions` (already-loaded
    /// models), which meant there was no way to even see, let alone
    /// pick, a model at all once nothing happened to be loaded. Stays
    /// visible and changeable for the whole life of the conversation
    /// (unlike `profilePicker`, which locks after the first message) —
    /// switching mid-conversation is exactly what's requested;
    /// `send()` loads whichever one is selected on demand.
    private var modelPicker: some View {
        Group {
            if !chat.availableTextModels.isEmpty {
                Picker("", selection: Binding(
                    get: { chat.selectedModelID },
                    set: { chat.selectModel($0) }
                )) {
                    ForEach(chat.availableTextModels) { model in
                        Label(model.displayName, systemImage: sessions.isLoaded(modelID: model.id) ? "circle.fill" : "circle")
                            .tag(Optional(model.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .help("Model used for this conversation — a filled dot means it's already loaded.")
            }
        }
    }

    /// Moved here from the settings sidebar — requested live, the same
    /// footing as `modelPicker`: a conversation's Profile is decided
    /// per-thread (`ChatThread.profileID`) already, but tucked away in
    /// a collapsible panel most people never open, it behaved like an
    /// invisible, system-wide default instead of something chosen for
    /// *this* chat. Locked after the first message (`canChangeProfile`)
    /// since it shapes the system prompt from the very first turn —
    /// unlike the model, there's no sensible "swap mid-conversation"
    /// for this one.
    private var profilePicker: some View {
        Picker("", selection: Binding(
            get: { chat.activeProfile?.id },
            set: { id in chat.setProfile(chat.availableProfiles.first { $0.id == id }) }
        )) {
            Text("No Profile").tag(Optional<UUID>.none)
            ForEach(chat.availableProfiles) { profile in
                Text(profile.name).tag(Optional(profile.id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 160)
        .disabled(!chat.canChangeProfile)
        .help(
            chat.canChangeProfile
                ? "Profile used for this conversation."
                : "Locked after the first message — start a new thread to use a different profile."
        )
    }

    /// Editable conversation title — defaults to "Profile · created
    /// date" (see `ChatViewModel.autoTitle`) and stays in sync with the
    /// profile until the user types something here, which locks it in
    /// (`ChatThread.isTitleCustom`) for good.
    private var titleField: some View {
        TextField("Title", text: Binding(
            get: { chat.currentThread.title },
            set: { chat.updateThreadTitleDraft($0) }
        ))
        .textFieldStyle(.plain)
        .font(.headline)
        .lineLimit(1)
        .frame(minWidth: 100, idealWidth: 200, maxWidth: 280)
        .focused($isTitleFieldFocused)
        .onSubmit { chat.commitThreadTitle() }
        .onChange(of: isTitleFieldFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused { chat.commitThreadTitle() }
        }
        .help("Conversation title — click to rename.")
    }

    /// Shown in the main window's conversation pane in place of the
    /// normal header/messages/input once the conversation is open in
    /// its own popped-out window — the threads column next to this
    /// stays fully usable, only the conversation itself moved.
    private var poppedOutPlaceholder: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "macwindow")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("This conversation is open in a separate window.")
                .foregroundStyle(.secondary)
            Text("Close that window to bring it back here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("No models registered")
                .font(.headline)
            Text("Download or import a model in the Models tab first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// Live hot-swap status while `ContextShiftCoordinator`'s
    /// background pipeline is compacting this conversation — distinct
    /// from `chat.errorMessage`'s red banner since this isn't a
    /// failure, just something happening. Shows the current phase and
    /// real memory numbers (from the Python side's own `psutil`
    /// readings) as they arrive, so the wait doesn't look stalled the
    /// way a multi-minute "Suggest from Thread" run once did before it
    /// got the same treatment.
    private func contextShiftBanner(_ status: ContextShiftCoordinator.Status) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(contextShiftPhaseLabel(status.phase))
            if let rss = status.processRSSBytes {
                Text("· \(ByteCountFormatter.string(fromByteCount: rss, countStyle: .memory))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func contextShiftPhaseLabel(_ phase: String?) -> String {
        switch phase {
        case "rag_text": return "Compacting conversation — indexing text…"
        case "rag_code": return "Compacting conversation — indexing code…"
        case "summarize": return "Compacting conversation — summarizing…"
        default: return "Compacting conversation to free up memory…"
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Requested live: "Ele pode ir carregando a cada X
                    // mensagens pra não sobrecarregar o app." The full
                    // thread is always intact underneath
                    // (`chat.visibleMessages`) — this just controls how
                    // much of it is actually mounted at once. A plain
                    // button rather than an auto-load-on-scroll trigger:
                    // this row sits at the very top of a long thread's
                    // initial view (which opens scrolled to the
                    // *bottom*, the `.onChange` below), so it's never
                    // actually on-screen until the user deliberately
                    // scrolls all the way up to it.
                    if chat.hasEarlierMessagesToLoad {
                        HStack {
                            Spacer()
                            Button("Load Earlier Messages") { chat.loadEarlierMessages() }
                            Spacer()
                        }
                        .id("load-earlier")
                    }
                    ForEach(chat.displayedMessages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }
                    if chat.isSending {
                        HStack(spacing: 6) {
                            CircularProgressView(fraction: chat.imageToolProgress)
                                .frame(width: 16, height: 16)
                            if let phase = chat.generationPhase.label {
                                Text(phase)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.leading, 4)
                        .id("sending-indicator")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: chat.visibleMessages) { _, _ in
                let target: AnyHashable = chat.visibleMessages.last.map { AnyHashable($0.id) }
                    ?? AnyHashable("sending-indicator")
                withAnimation {
                    proxy.scrollTo(target, anchor: .bottom)
                }
            }
        }
    }

    private func bubble(for message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(heading(for: message))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if message.role == .assistant,
                   !(message.memoryIDsUsed ?? []).isEmpty || !(message.memoryIDsCreated ?? []).isEmpty {
                    Button {
                        memoryMessageID = message.id
                    } label: {
                        Label("Memory context", systemImage: "brain.head.profile")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .popover(isPresented: Binding(
                        get: { memoryMessageID == message.id },
                        set: { if !$0 { memoryMessageID = nil } }
                    )) {
                        memoryInspector(for: message)
                    }
                }

                if !chat.hideReasoning, let reasoning = message.reasoning, !reasoning.isEmpty {
                    Text(reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                if message.content.isEmpty && message.reasoning != nil && !chat.isSending {
                    Text("_(cut off before an answer — try again, or raise Max Tokens)_")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .italic()
                } else if !message.content.isEmpty {
                    Text(message.content)
                        .textSelection(.enabled)
                }

                if let path = message.generatedImagePath {
                    InteractiveImageView(path: path)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(10)
            .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contextMenu {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(message.content, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                if message.role == .user {
                    Button {
                        guard !chat.isSending else { return }
                        Task {
                            guard let content = await chat.beginEditingMessage(message) else { return }
                            chat.inputText = content
                        }
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .disabled(chat.isSending)
                }
                Button(role: .destructive) {
                    guard !chat.isSending else { return }
                    Task { await chat.deleteMessage(message) }
                } label: {
                    Label(
                        message.id == chat.currentThread.messages.last?.id ? "Delete" : "Delete (and everything after)",
                        systemImage: "trash")
                }
                .disabled(chat.isSending)
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private func memoryInspector(for message: ChatMessage) -> some View {
        let used = Set(message.memoryIDsUsed ?? [])
        let created = Set(message.memoryIDsCreated ?? [])
        let usedMemories = chat.memories.filter { used.contains($0.id) }
        let createdMemories = chat.memories.filter { created.contains($0.id) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Memory for this response").font(.headline)
            memorySection("Used", memories: usedMemories, empty: "No durable memories were injected.")
            memorySection("Created", memories: createdMemories, empty: "No memory was created by this response.")
        }
        .padding()
        .frame(width: 380)
    }

    @ViewBuilder
    private func memorySection(_ title: String, memories: [ChatMemory], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).bold()
            if memories.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(memories) { memory in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(memory.content).font(.caption)
                        Text("\(memory.kind.label) · \(memory.source.label)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func heading(for message: ChatMessage) -> String {
        switch message.role {
        case .user: return "You"
        case .system: return "System"
        case .assistant:
            if let responderName = message.responderName, !responderName.isEmpty {
                return responderName
            }
            return message.modelDisplayName.map { "Assistant · \($0)" } ?? "Assistant"
        case .tool: return "Tool" // never actually shown — visibleMessages filters these out
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(
                    get: { chat.isTemporaryModeActive },
                    set: { _ in chat.toggleTemporaryMode() }
                )) {
                    Image(systemName: "eyeglasses")
                }
                .toggleStyle(.button)
                .disabled(!chat.canChangeProfile)
                .help(
                    chat.canChangeProfile
                        ? "Temporary chat — this conversation is never saved to disk."
                        : "Locked after the first message — start a new thread to go temporary."
                )

                TextField("Message…", text: Binding(
                    get: { chat.inputText },
                    set: { chat.inputText = $0 }
                ), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { chat.handleSubmit() }
                    .onChange(of: chat.inputText) { _, _ in
                        if chat.chatMessageWaitSeconds > 0 && !chat.isSending {
                            chat.scheduleBufferedSend()
                        }
                    }
                    // Only requires a model to be *selected*, not
                    // loaded — `send()` loads whichever one is picked
                    // on demand, unloading whatever's currently
                    // running first if that's what it takes to fit.
                    .disabled(chat.selectedModelID == nil)

                if chat.isSending {
                    Button("Stop", role: .destructive) { chat.stopGeneration() }
                } else {
                    Button("Send") { Task { await chat.send() } }
                        .disabled(
                            chat.selectedModelID == nil
                            || chat.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }

            if chat.isWaitingToSend {
                Text("Waiting for more text…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Threads column (every open conversation, for navigation —
    // saved threads and in-memory temporary ones alike, the latter
    // disappearing once the app quits since they're never written to
    // disk)

    private var threadsSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Threads")
                    .font(.headline)
                Spacer()
                Button {
                    chat.newThread()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .disabled(chat.isTemporaryModeActive)
                .help("New Thread")
            }
            .padding()

            Divider()

            if chat.allThreads.isEmpty {
                Spacer()
                Text("No conversations yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(chat.allThreads) { thread in
                    threadRow(thread)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func threadRow(_ thread: ChatThread) -> some View {
        let isActive = thread.id == chat.currentThread.id
        return HStack(spacing: 4) {
            Button {
                chat.selectThread(thread)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title)
                        .font(.subheadline)
                        .fontWeight(isActive ? .semibold : .regular)
                        .lineLimit(1)
                    Text(thread.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                Task { await chat.deleteThread(thread) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .opacity(0.6)
        }
        .padding(.vertical, 2)
        .listRowBackground(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    // MARK: - Sidebar (everything about the conversation lives here)

    private var sidebar: some View {
        Form {
            // Profile moved to the header (`profilePicker`), right next
            // to the model — requested live: tucked away in here, a
            // per-conversation choice behaved like an invisible,
            // system-wide default instead of something picked for
            // *this* chat before the first message.
            if chat.availableProfiles.isEmpty {
                Section("Profile") {
                    Text("No profiles yet — create one in the Profiles tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Display") {
                Toggle("Hide Model Thinking", isOn: Binding(
                    get: { chat.hideReasoning },
                    set: { chat.hideReasoning = $0 }
                ))
            }

            Section("Memory") {
                Button {
                    openWindow(id: "memory")
                } label: {
                    Label("Open Memory…", systemImage: "brain.head.profile")
                }
                TextField("Add a durable fact or preference…", text: $newMemoryText, axis: .vertical)
                    .lineLimit(2...4)
                Button {
                    let text = newMemoryText
                    newMemoryText = ""
                    Task { await chat.addMemory(text) }
                } label: {
                    Label("Remember", systemImage: "plus.circle")
                }
                .disabled(newMemoryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                ForEach(chat.memories) { memory in
                    HStack(alignment: .top, spacing: 6) {
                        Text(memory.content)
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            Task { await chat.deleteMemory(memory) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section("Composer") {
                LabeledContent("Wait after typing") {
                    TextField("0", value: Binding(
                        get: { chat.chatMessageWaitSeconds },
                        set: { chat.chatMessageWaitSeconds = $0 }
                    ), format: .number)
                    .frame(width: 70)
                    .onSubmit { chat.saveChatMessageWaitSeconds() }
                }
                Text("Seconds of silence before sending. Enter adds a block; 0 sends immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Generation") {
                LabeledContent("Max Tokens") {
                    TextField(String(GenerationSettings.effectivelyUnlimited), text: Binding(
                        get: { chat.settings.maxTokens.map(String.init) ?? "" },
                        set: { chat.settings.maxTokens = Int($0.trimmingCharacters(in: .whitespaces)) }
                    ))
                        .frame(width: 80)
                        .help(
                            "Empty uses \(GenerationSettings.effectivelyUnlimited) tokens, including reasoning. "
                            + "Set a lower value for faster bounded replies."
                        )
                Text("Effective budget: \(chat.settings.wireMaxTokens) tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                LabeledContent("Temperature") {
                    TextField("", value: Binding(
                        get: { chat.settings.temperature },
                        set: { chat.settings.temperature = $0 }
                    ), format: .number)
                        .frame(width: 80)
                }
                LabeledContent("Top P") {
                    TextField("", value: Binding(
                        get: { chat.settings.topP },
                        set: { chat.settings.topP = $0 }
                    ), format: .number)
                        .frame(width: 80)
                }
                LabeledContent("Top K") {
                    TextField("", value: Binding(
                        get: { chat.settings.topK },
                        set: { chat.settings.topK = $0 }
                    ), format: .number)
                        .frame(width: 80)
                }
                LabeledContent("Min P") {
                    TextField("", value: Binding(
                        get: { chat.settings.minP },
                        set: { chat.settings.minP = $0 }
                    ), format: .number)
                        .frame(width: 80)
                }
            }

            Section("Long conversations") {
                LabeledContent("Context budget") {
                    TextField("24000", value: Binding(
                        get: { chat.maxEstimatedContextTokens },
                        set: { chat.maxEstimatedContextTokens = $0 }
                    ), format: .number)
                    .frame(width: 90)
                    .onSubmit { chat.saveContextSettings() }
                }
                LabeledContent("Recent turns") {
                    TextField("12", value: Binding(
                        get: { chat.recentMessageCount },
                        set: { chat.recentMessageCount = $0 }
                    ), format: .number)
                    .frame(width: 70)
                    .onSubmit { chat.saveContextSettings() }
                }
                Text("Anvil preserves the first user turn and recent turns, then fills older context only when the budget allows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Export") {
                Button {
                    copyAllToPasteboard()
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .disabled(chat.messages.isEmpty)

                Button {
                    chat.isExportPresented = true
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(chat.messages.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func copyAllToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(chat.exportMarkdown(), forType: .string)
    }
}
