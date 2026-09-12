import SwiftUI
import AppKit
import AnvilCore

/// An app-level chat window. Header carries only the active model
/// (switchable) and performance metrics; everything else about the
/// conversation — threads, temporary mode, display options, generation
/// settings, export — lives in the collapsible side panel.
struct ChatView: View {
    @EnvironmentObject private var sessions: ModelSessionManager
    @EnvironmentObject private var chat: ChatViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
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

            if chat.isSidebarOpen {
                Divider()
                sidebar
                    .frame(width: 280)
            }
        }
        .task {
            await chat.loadInitialState()
        }
        .onChange(of: sessions.sessions) { _, _ in chat.syncSelectedModel() }
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
            if sessions.readySessions.isEmpty {
                Text("Chat").font(.headline)
            } else {
                Picker("", selection: Binding(
                    get: { chat.selectedModelID },
                    set: { chat.selectModel($0) }
                )) {
                    ForEach(sessions.readySessions) { session in
                        Text(session.model.displayName).tag(Optional(session.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
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

            Button {
                openWindow(id: "chat-popout")
            } label: {
                Image(systemName: "macwindow.badge.plus")
            }
            .help("Open this conversation in its own window.")

            Button {
                chat.isSidebarOpen.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
        }
        .padding()
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
            if message.role != .user { Spacer(minLength: 40) }
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

    // MARK: - Sidebar (everything about the conversation lives here)

    private var sidebar: some View {
        Form {
            Section("Conversation") {
                Button("New Thread") { chat.newThread() }
                    .disabled(chat.isTemporaryModeActive)
                Button("Chat History…") {
                    openWindow(id: "threads")
                }
                Button("Clear Conversation") { chat.clearCurrentConversation() }
                    .disabled(chat.messages.isEmpty)
                Toggle("Temporary Chat", isOn: Binding(
                    get: { chat.isTemporaryModeActive },
                    set: { _ in chat.toggleTemporaryMode() }
                ))
                .help("While on, this conversation is never saved to disk.")
            }

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
