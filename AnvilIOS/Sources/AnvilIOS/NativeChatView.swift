import SwiftUI
import MLXLMCommon
import AnvilCore

/// A real chat screen — on-device inference via `NativeChatEngine`, no
/// server, no network round trip once the model is loaded — with
/// conversations persisted via `ChatThreadsViewModel`/`ChatThreadStore`,
/// the same cross-platform store the Mac app's Chat uses. The model ID
/// field takes any Hugging Face MLX-format repo (e.g.
/// `mlx-community/Qwen3-0.6B-4bit`), or pick one already downloaded in
/// the Models tab from the menu next to it.
struct NativeChatView: View {
    @Environment(ModelsViewModel.self) private var modelsViewModel
    @Environment(ProfilesViewModel.self) private var profilesViewModel
    @EnvironmentObject private var engine: NativeChatEngine
    @State private var threads = ChatThreadsViewModel()
    @State private var modelID = "mlx-community/Qwen3-0.6B-4bit"
    @State private var inputText = ""
    @State private var isGenerating = false
    @State private var isThreadListPresented = false
    /// The user's own explicit pick, made before hitting Load — takes
    /// priority over the model's bound default. `nil` means "haven't
    /// touched the picker", which falls back to that model's default
    /// profile (if any) the same way it always did; `.some(nil)` isn't
    /// representable here, so an explicit "no profile" pick is tracked
    /// separately via `manualProfileChoiceMade`.
    @State private var selectedProfile: ChatProfile?
    @State private var manualProfileChoiceMade = false

    /// Only true before the first message — same restriction
    /// `ChatViewModel.canChangeProfile` documents: once a reply exists
    /// under a given profile, switching it would mix instructions with
    /// history that never saw them.
    private var canChangeProfile: Bool { threads.currentThread.messages.isEmpty }

    private var activeProfile: ChatProfile? {
        guard let id = threads.currentThread.profileID else { return nil }
        return profilesViewModel.profiles.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modelBar
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

                if let errorMessage = engine.errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption).padding(8)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(threads.currentThread.messages) { message in
                                bubble(message).id(message.id)
                            }
                            if isGenerating {
                                ProgressView().padding(.leading, 8)
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
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { newChat() } label: { Image(systemName: "square.and.pencil") }
                        .disabled(isGenerating)
                }
            }
            .sheet(isPresented: $isThreadListPresented) { threadListSheet }
            .task { await profilesViewModel.load() }
            .task { await threads.loadInitialState() }
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

    private func newChat() {
        guard !isGenerating else { return }
        threads.newThread()
        manualProfileChoiceMade = false
        selectedProfile = nil
        if engine.isLoaded {
            Task { await applyCurrentProfileChoice(startFreshSessionIfLoaded: true) }
        }
    }

    /// Switches the visible conversation and, if a model is already
    /// loaded, immediately rehydrates the session with this thread's
    /// history — no re-download, no reload, just a fresh `ChatSession`
    /// built from the saved turns (see `NativeChatEngine.startSession`).
    private func selectThread(_ thread: ChatThread) {
        guard !isGenerating else { return }
        threads.selectThread(thread)
        manualProfileChoiceMade = thread.profileID != nil
        selectedProfile = activeProfile
        if engine.isLoaded {
            engine.startSession(instructions: activeProfile?.prompt, history: thread.messages)
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

    /// Records the pick and, if a model is already loaded, applies it
    /// right away by rebuilding the session — so choosing a profile for
    /// a brand-new thread doesn't require pressing Load again when one
    /// is already resident.
    private func choose(profile: ChatProfile?, manual: Bool) async {
        manualProfileChoiceMade = manual
        selectedProfile = profile
        await applyCurrentProfileChoice(startFreshSessionIfLoaded: true)
    }

    /// Resolves the picker's current choice into `currentThread.profileID`
    /// — a no-op once the thread already has messages, since the profile
    /// is fixed at that point (`canChangeProfile`). Optionally rebuilds
    /// the live session immediately so a loaded model picks it up.
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
        if startFreshSessionIfLoaded, engine.isLoaded {
            engine.startSession(instructions: profile?.prompt, history: threads.currentThread.messages)
        }
    }

    // MARK: - Model bar

    private var modelBar: some View {
        HStack {
            TextField("mlx-community/…", text: $modelID)
                .textFieldStyle(.roundedBorder)
                .disabled(engine.isLoading || engine.isLoaded)
                .autocapitalization(.none)
                .disableAutocorrection(true)

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
        .padding(8)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 40) }
            Text(message.content)
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
                .disabled(!engine.isLoaded)
            Button("Send") { send() }
                .disabled(!engine.isLoaded || isGenerating || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(8)
    }

    /// Loads (or reuses, if already resident) `modelID`'s weights, then
    /// starts a session rehydrated from the current thread's saved
    /// messages — resuming a past conversation exactly where it left
    /// off, or starting clean for an empty one.
    private func load() async {
        await applyCurrentProfileChoice(startFreshSessionIfLoaded: false)
        await engine.load(
            modelID: modelID, instructions: activeProfile?.prompt,
            history: threads.currentThread.messages)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, engine.isLoaded, !isGenerating else { return }
        inputText = ""
        isGenerating = true

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
            defer { isGenerating = false }
            do {
                threads.currentThread.messages.append(
                    ChatMessage(role: .assistant, content: "", modelDisplayName: modelDisplayName))
                let replyIndex = threads.currentThread.messages.count - 1
                let stream = try engine.streamSend(text)
                for try await chunk in stream {
                    threads.currentThread.messages[replyIndex].content += chunk
                }
            } catch {
                threads.currentThread.messages.append(
                    ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
            }
            await threads.persistCurrentThread()
        }
    }
}
