import SwiftUI
import AnvilCore

/// Auditable local memory: facts and impressions are deliberately shown
/// with their source, confidence, and Profile scope so inference never
/// masquerades as something the user explicitly told Anvil.
struct MemoryView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @State private var draftText = ""
    @State private var draftKind: ChatMemoryKind = .fact
    @State private var draftSource: ChatMemorySource = .explicit
    @State private var draftProfileID: UUID?
    @State private var draftConfidence = 0.8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Memory").font(.headline)
                    Text("Everything here is local, editable, and removable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: 8) {
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
            }

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

            Divider()

            if chat.memories.isEmpty {
                Text("No memories recorded yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(chat.memories) { memory in
                    memoryRow(memory)
                }
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 520)
        .task { await chat.loadInitialState() }
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
