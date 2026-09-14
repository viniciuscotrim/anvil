import AnvilCore
import SwiftUI

/// Auditable local memory: facts and impressions are deliberately shown
/// with their source, confidence, and Profile scope so inference never
/// masquerades as something the user explicitly told Anvil. Adapted from
/// the Mac app's own `MemoryView` (a `NavigationStack`/`List` here
/// instead of a fixed-size panel — iOS has no sidebar), backed by the
/// exact same cross-platform `ChatMemoryStore` via `ChatThreadsViewModel`
/// (shared with the Chat tab so "Suggest from thread" sees the same
/// conversation Chat is actually having).
struct MemoryView: View {
    @Environment(ProfilesViewModel.self) private var profilesViewModel
    @Environment(ChatThreadsViewModel.self) private var threads
    @EnvironmentObject private var engine: NativeChatEngine
    @State private var draftText = ""
    @State private var draftKind: ChatMemoryKind = .fact
    @State private var draftSource: ChatMemorySource = .explicit
    @State private var draftProfileID: UUID?
    @State private var draftConfidence = 0.8
    /// Set when Suggest needs to swap the engine to a different model
    /// than whatever it currently has loaded — asked first since, on
    /// iOS, that also changes what Chat itself would use next (there's
    /// only ever one model resident at a time here, unlike Mac's
    /// several-at-once server processes).
    @State private var pendingModelSwap: PendingModelSwap?
    /// Which memory is being rewritten in a sheet right now, if any —
    /// requested live: "também poder editar/reescrever uma memoria
    /// capturada."
    @State private var editingMemory: ChatMemory?

    private struct PendingModelSwap: Identifiable {
        let id: String
        let displayName: String
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Everything here is local, editable, and removable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        beginSuggesting()
                    } label: {
                        Label(suggestButtonLabel, systemImage: "wand.and.stars")
                    }
                    .disabled(threads.isSuggestingMemories || threads.currentThread.messages.isEmpty)

                    Picker("Model for suggestions", selection: Binding(
                        get: { threads.memorySuggestionModelID },
                        set: { threads.setMemorySuggestionModelID($0) }
                    )) {
                        Text("Current chat model").tag(Optional<String>.none)
                        ForEach(threads.availableTextModels) { model in
                            Text(model.displayName).tag(Optional(model.id))
                        }
                    }
                    .disabled(threads.isSuggestingMemories)
                }

                if let errorMessage = threads.errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption)
                }

                if !threads.memorySuggestions.isEmpty {
                    Section("Suggestions to review (\(threads.memorySuggestions.count))") {
                        Text("Nothing is saved until you accept it — global, usable from any new thread.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Accept All") {
                            Task { await threads.acceptAllMemorySuggestions() }
                        }
                        ForEach(threads.memorySuggestions) { suggestion in
                            suggestionRow(suggestion)
                        }
                    }
                }

                Section("Add a Memory") {
                    TextField("A fact, preference, date, number, or impression…", text: $draftText, axis: .vertical)
                        .lineLimit(2...4)
                    Picker("Type", selection: $draftKind) {
                        ForEach(ChatMemoryKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    Picker("Profile", selection: $draftProfileID) {
                        Text("Global").tag(Optional<UUID>.none)
                        ForEach(profilesViewModel.profiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    Button("Remember") {
                        let text = draftText
                        draftText = ""
                        Task {
                            await threads.addMemory(text, kind: draftKind, source: .explicit, profileID: draftProfileID)
                        }
                    }
                    .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Saved") {
                    if threads.memories.isEmpty {
                        Text("No memories recorded yet.").foregroundStyle(.secondary)
                    }
                    ForEach(threads.memories) { memory in
                        memoryRow(memory)
                    }
                }
            }
            .navigationTitle("Memory")
            .task { await threads.loadInitialState() }
            .task { await profilesViewModel.load() }
            .dismissKeyboardOnTap()
            .confirmationDialog(
                "Switch to \(pendingModelSwap?.displayName ?? "") for this?",
                isPresented: Binding(
                    get: { pendingModelSwap != nil },
                    set: { if !$0 { pendingModelSwap = nil } }
                ),
                presenting: pendingModelSwap
            ) { swap in
                Button("Switch and Continue") {
                    Task { await loadThenSuggest(modelID: swap.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { swap in
                Text("Chat only keeps one model loaded at a time on this iPhone, so this also switches what "
                    + "Chat itself uses next, until you load something else.")
            }
            .sheet(item: $editingMemory) { memory in
                EditMemorySheet(memory: memory) { newText in
                    Task { await threads.editMemoryContent(memory, to: newText) }
                }
            }
        }
    }

    /// Starts a digest against whichever model was picked — loading it
    /// first (after confirming, since that also replaces whatever Chat
    /// itself is currently using) if it isn't already the one
    /// `NativeChatEngine` has resident.
    private func beginSuggesting() {
        guard let targetModelID = threads.memorySuggestionModelID, targetModelID != engine.loadedModelID else {
            Task { await runSuggestMemories() }
            return
        }
        let name = threads.availableTextModels.first { $0.id == targetModelID }?.displayName ?? targetModelID
        pendingModelSwap = PendingModelSwap(id: targetModelID, displayName: name)
    }

    private func loadThenSuggest(modelID: String) async {
        await engine.load(modelID: modelID)
        guard engine.loadedModelID == modelID else {
            threads.errorMessage = engine.errorMessage ?? "Could not load that model."
            return
        }
        await runSuggestMemories()
    }

    private func runSuggestMemories() async {
        await threads.suggestMemoriesFromCurrentThread { instruction, context in
            guard engine.isLoaded else {
                throw NativeChatEngineError.notLoaded
            }
            let transcript = context.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
            // The default output budget is sized for an ordinary chat
            // reply, not a JSON array that can legitimately list many
            // facts — matches the Mac app's own 4000-token override
            // for the same call.
            return try await engine.respondOnce(
                to: "\(instruction)\n\nConversation:\n\(transcript)", maxTokens: 4000)
        }
    }

    /// Shows which batch is in flight — see Mac's own
    /// `MemoryView.suggestButtonLabel` doc comment for the real
    /// reported problem this fixes.
    private var suggestButtonLabel: String {
        guard threads.isSuggestingMemories else { return "Suggest from current Chat thread" }
        guard let progress = threads.memorySuggestionProgress, progress.total > 1 else { return "Analyzing…" }
        return "Analyzing (\(progress.completed) of \(progress.total))…"
    }

    private func suggestionRow(_ suggestion: ChatMemorySuggestion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.content)
                Text("\(suggestion.kind.label) · \(Int(suggestion.confidence * 100))% · \(suggestion.rationale)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await threads.acceptMemorySuggestion(suggestion) }
            } label: {
                Image(systemName: "checkmark.circle.fill")
            }
            .buttonStyle(.borderless)
            Button {
                threads.dismissMemorySuggestion(suggestion)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func memoryRow(_ memory: ChatMemory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: memory.source == .inferred ? "sparkles" : "person.fill")
                .foregroundStyle(memory.source == .inferred ? .purple : .accentColor)
            VStack(alignment: .leading, spacing: 5) {
                Text(memory.content).textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(memory.kind.label)
                    Text(memory.source.label)
                    if let profileID = memory.profileID,
                        let profile = profilesViewModel.profiles.first(where: { $0.id == profileID }) {
                        Text("Profile: \(profile.name)")
                    } else {
                        Text("Global")
                    }
                    if let confidence = memory.confidence {
                        Text(String(format: "%.0f%% confidence", confidence * 100))
                    }
                    if let origin = memory.originDeviceName {
                        Text("· \(origin)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(threadScopeLabel(for: memory))
                    .font(.caption2)
                    .foregroundStyle(memory.isGlobal ? Color.secondary : Color.accentColor)
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                Task { await threads.deleteMemory(memory) }
            }
            // Requested live: "criar um botão pra cada memória no menu
            // Memórias que pode transformar ela em Global ou voltar
            // apenas pra conversa onde foi gerada." Hidden for a
            // memory with no recorded origin at all — see
            // `ChatMemory.appliesTo`'s own doc comment.
            if memory.originThreadID != nil {
                Button {
                    Task { await threads.toggleMemoryGlobal(memory) }
                } label: {
                    Label(memory.isGlobal ? "Restrict" : "Make Global", systemImage: memory.isGlobal ? "bubble.left" : "globe")
                }
                .tint(.blue)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                editingMemory = memory
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.orange)
        }
    }

    private func threadScopeLabel(for memory: ChatMemory) -> String {
        guard !memory.isGlobal, let originThreadID = memory.originThreadID else {
            return "All conversations"
        }
        let threadTitle = threads.allThreads.first(where: { $0.id == originThreadID })?.title
        return "Only in: \(threadTitle ?? "a deleted conversation")"
    }
}

/// A memory's own text, rewritten in place — requested live: "também
/// poder editar/reescrever uma memoria capturada." `onSave` is handed
/// the trimmed replacement text; `ChatThreadsViewModel
/// .editMemoryContent` itself no-ops if it's empty or unchanged, so
/// this doesn't need to duplicate that check to behave correctly.
private struct EditMemorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let memory: ChatMemory
    let onSave: (String) -> Void
    @State private var text: String

    init(memory: ChatMemory, onSave: @escaping (String) -> Void) {
        self.memory = memory
        self.onSave = onSave
        _text = State(initialValue: memory.content)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Memory", text: $text, axis: .vertical)
                    .lineLimit(4...12)
            }
            .navigationTitle("Edit Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(text)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
