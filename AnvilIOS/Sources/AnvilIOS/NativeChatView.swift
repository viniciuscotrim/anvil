import SwiftUI
import MLXLMCommon
import AnvilCore

/// A minimal but real chat screen — on-device inference via
/// `NativeChatEngine`, no server, no network round trip once the model
/// is loaded. The model ID field takes any Hugging Face MLX-format
/// repo (e.g. `mlx-community/Qwen3-0.6B-4bit`), or pick one already
/// downloaded in the Models tab from the menu next to it.
struct NativeChatView: View {
    @Environment(ModelsViewModel.self) private var modelsViewModel
    @Environment(ProfilesViewModel.self) private var profilesViewModel
    @StateObject private var engine = NativeChatEngine()
    @State private var modelID = "mlx-community/Qwen3-0.6B-4bit"
    @State private var messages: [(isUser: Bool, text: String)] = []
    @State private var inputText = ""
    @State private var isGenerating = false
    /// Which profile is actually shaping the current, already-loaded
    /// session — shown, not editable, once loaded: changing profiles
    /// mid-conversation would mix its instructions with history that
    /// never saw them. Unload (starting fresh) to pick a different one.
    @State private var activeProfileName: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modelBar
                Divider()

                if let errorMessage = engine.errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption).padding(8)
                }
                if let activeProfileName {
                    Text("Profile: \(activeProfileName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                                bubble(message).id(index)
                            }
                            if isGenerating {
                                ProgressView().padding(.leading, 8)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, _ in
                        withAnimation { proxy.scrollTo(messages.count - 1, anchor: .bottom) }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .dismissKeyboardOnTap()
                }

                Divider()
                inputBar
            }
            .navigationTitle("Chat (on-device)")
        }
    }

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
                Button("Unload") {
                    engine.unload()
                    activeProfileName = nil
                    messages.removeAll()
                }
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

    private func bubble(_ message: (isUser: Bool, text: String)) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }
            Text(message.text)
                .padding(10)
                .background(message.isUser ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if !message.isUser { Spacer(minLength: 40) }
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

    /// Looks up this model's bound default profile (if any) — the same
    /// "loading this model applies its profile automatically" behavior
    /// the Mac app's Chat gives — and loads with its prompt as the
    /// session's system instructions.
    private func load() async {
        let profile = await profilesViewModel.defaultProfile(forModelID: modelID)
        activeProfileName = profile?.name
        await engine.load(modelID: modelID, instructions: profile?.prompt)
    }

    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        messages.append((isUser: true, text: text))
        isGenerating = true

        Task {
            defer { isGenerating = false }
            do {
                messages.append((isUser: false, text: ""))
                let replyIndex = messages.count - 1
                let stream = try engine.streamSend(text)
                for try await chunk in stream {
                    messages[replyIndex].text += chunk
                }
            } catch {
                messages.append((isUser: false, text: "Error: \(error.localizedDescription)"))
            }
        }
    }
}
