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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Everything here is local, editable, and removable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        Task {
                            await threads.suggestMemoriesFromCurrentThread { instruction, context in
                                guard engine.isLoaded else {
                                    throw NativeChatEngineError.notLoaded
                                }
                                let transcript = context.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
                                return try await engine.respondOnce(to: "\(instruction)\n\nConversation:\n\(transcript)")
                            }
                        }
                    } label: {
                        Label(
                            threads.isSuggestingMemories ? "Analyzing…" : "Suggest from current Chat thread",
                            systemImage: "wand.and.stars")
                    }
                    .disabled(threads.isSuggestingMemories || threads.currentThread.messages.isEmpty)
                }

                if let errorMessage = threads.errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption)
                }

                if !threads.memorySuggestions.isEmpty {
                    Section("Suggestions to review") {
                        Text("Nothing is saved until you accept it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        }
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
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                Task { await threads.deleteMemory(memory) }
            }
        }
    }
}
