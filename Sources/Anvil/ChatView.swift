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
    @EnvironmentObject private var sessions: ModelSessionManager
    @EnvironmentObject private var chat: ChatViewModel
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

                    if sessions.readySessions.isEmpty {
                        emptyState
                    } else if chat.visibleMessages.isEmpty {
                        Spacer()
                        Text("Say something to \(activeModelName).")
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        messageList
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
        sessions.sessions.first { $0.id == chat.selectedModelID }?.model.displayName ?? "the model"
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

            if !sessions.readySessions.isEmpty {
                Picker("", selection: Binding(
                    get: { chat.selectedModelID },
                    set: { chat.selectModel($0) }
                )) {
                    ForEach(sessions.readySessions) { session in
                        Text(session.model.displayName).tag(Optional(session.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
            }

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
            Text("No models loaded")
                .font(.headline)
            Text("Load a model from the Models tab first.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.visibleMessages) { message in
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
                    .disabled(sessions.readySessions.isEmpty)

                if chat.isSending {
                    Button("Stop", role: .destructive) { chat.stopGeneration() }
                } else {
                    Button("Send") { Task { await chat.send() } }
                        .disabled(
                            sessions.readySessions.isEmpty
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
            Section("Profile") {
                Picker("Profile", selection: Binding(
                    get: { chat.activeProfile?.id },
                    set: { id in chat.setProfile(chat.availableProfiles.first { $0.id == id }) }
                )) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(chat.availableProfiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .disabled(!chat.canChangeProfile)
                .labelsHidden()

                if !chat.canChangeProfile {
                    Text("Locked after the first message — start a new thread to use a different profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if chat.availableProfiles.isEmpty {
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
