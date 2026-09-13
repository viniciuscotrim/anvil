import SwiftUI
import AnvilCore

/// Auditable local memory: facts and impressions are deliberately shown
/// with their source, confidence, and Profile scope so inference never
/// masquerades as something the user explicitly told Anvil.
///
/// A real `List`, not a plain `VStack` — a `VStack` doesn't scroll on
/// its own, and a real digest (`suggestMemoriesFromCurrentThread`) or
/// a long-lived Memory store can both genuinely overflow this window's
/// fixed size. Reported live: "preciso de uma barra de rolagem pois
/// são muitas" (need a scrollbar, there are too many) once a real
/// multi-batch digest started surfacing dozens of suggestions at once.
struct MemoryView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @State private var draftText = ""
    @State private var draftKind: ChatMemoryKind = .fact
    @State private var draftSource: ChatMemorySource = .explicit
    @State private var draftProfileID: UUID?
    @State private var draftConfidence = 0.8

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Memory").font(.headline)
                        Text("Everything here is local, editable, and removable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await chat.suggestMemoriesFromCurrentThread() }
                    } label: {
                        Label(suggestButtonLabel, systemImage: "wand.and.stars")
                    }
                    .disabled(chat.isSuggestingMemories || chat.messages.isEmpty)
                }

                HStack {
                    Text("Model for suggestions")
                    Spacer()
                    // Every registered text model, not just a loaded
                    // one — requested live: picking one here doesn't
                    // load it yet, only pressing "Suggest" does (and,
                    // if there isn't room, asks before unloading
                    // anything else). Matches Mac's own `ModelManager`
                    // list ordering (by family) so the picker isn't a
                    // flat unsorted dump of every quant/size variant.
                    Picker("", selection: Binding(
                        get: { chat.memorySuggestionModelID },
                        set: { chat.setMemorySuggestionModelID($0) }
                    )) {
                        Text("Current chat model").tag(Optional<String>.none)
                        ForEach(chat.availableTextModels) { model in
                            Text(model.displayName).tag(Optional(model.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(chat.isSuggestingMemories)
                }

                if let errorMessage = chat.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(errorMessage)
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
                }
            }

            if !chat.memorySuggestions.isEmpty {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Suggestions to review (\(chat.memorySuggestions.count))").font(.headline)
                            Text("Nothing is saved until you accept it — global, usable from any new thread.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Accept All") {
                            Task { await chat.acceptAllMemorySuggestions() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    ForEach(chat.memorySuggestions) { suggestion in
                        suggestionRow(suggestion)
                    }
                }
            }

            Section("Add a Memory") {
                TextField("A fact, preference, date, number, or impression…", text: $draftText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                Button("Remember") {
                    let text = draftText
                    draftText = ""
                    Task {
                        await chat.addMemory(
                            text,
                            kind: draftKind,
                            source: draftSource,
                            confidence: draftSource == .inferred ? draftConfidence : nil,
                            profileID: draftProfileID
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                HStack {
                    Picker("Type", selection: $draftKind) {
                        ForEach(ChatMemoryKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    Picker("Source", selection: $draftSource) {
                        ForEach(ChatMemorySource.allCases, id: \.self) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    Picker("Profile", selection: $draftProfileID) {
                        Text("Global").tag(Optional<UUID>.none)
                        ForEach(chat.availableProfiles) { profile in
                            Text(profile.name).tag(Optional(profile.id))
                        }
                    }
                    if draftSource == .inferred {
                        Text("Confidence")
                        Slider(value: $draftConfidence, in: 0...1)
                            .frame(width: 100)
                        Text(String(format: "%.0f%%", draftConfidence * 100))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Saved (\(chat.memories.count))") {
                if chat.memories.isEmpty {
                    Text("No memories recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(chat.memories) { memory in
                        memoryRow(memory)
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await chat.loadInitialState() }
        .confirmationDialog(
            "Unload \((chat.pendingModelUnloadConfirmation?.modelsToUnloadNames ?? []).joined(separator: ", ")) to load "
                + "\(chat.pendingModelUnloadConfirmation?.modelToLoadName ?? "")?",
            isPresented: Binding(
                get: { chat.pendingModelUnloadConfirmation != nil },
                set: { if !$0 { chat.resolveModelUnloadConfirmation(unload: false) } }
            )
        ) {
            Button("Unload and Continue", role: .destructive) {
                chat.resolveModelUnloadConfirmation(unload: true)
            }
            Button("Cancel", role: .cancel) {
                chat.resolveModelUnloadConfirmation(unload: false)
            }
        } message: {
            Text("There isn't enough unified memory to load "
                + "\(chat.pendingModelUnloadConfirmation?.modelToLoadName ?? "this model") alongside what's "
                + "already loaded. It'll be unloaded first, then Suggest from Thread will continue.")
        }
    }

    /// Shows which batch is in flight while digesting a whole thread —
    /// a real digest now makes several sequential model calls, one per
    /// excerpt (`ChatContextBuilder.batches`), and a plain "Analyzing…"
    /// with no further detail through several minutes of that looked
    /// exactly like it had silently failed (reported live).
    private var suggestButtonLabel: String {
        guard chat.isSuggestingMemories else { return "Suggest from thread" }
        guard let progress = chat.memorySuggestionProgress, progress.total > 1 else { return "Analyzing…" }
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
                Task { await chat.acceptMemorySuggestion(suggestion) }
            } label: {
                Image(systemName: "checkmark.circle.fill")
            }
            .buttonStyle(.borderless)
            Button {
                chat.dismissMemorySuggestion(suggestion)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.purple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func memoryRow(_ memory: ChatMemory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: memory.source == .inferred ? "sparkles" : "person.fill")
                .foregroundStyle(memory.source == .inferred ? .purple : .accentColor)
            VStack(alignment: .leading, spacing: 5) {
                Text(memory.content)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(memory.kind.label)
                    Text(memory.source.label)
                    if let profileID = memory.profileID,
                       let profile = chat.availableProfiles.first(where: { $0.id == profileID }) {
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
                    Text(memory.updatedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await chat.deleteMemory(memory) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this memory")
        }
        .padding(.vertical, 4)
    }
}
