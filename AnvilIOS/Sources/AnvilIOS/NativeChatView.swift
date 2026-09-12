import SwiftUI
import MLXLMCommon

/// A minimal but real chat screen — on-device inference via
/// `NativeChatEngine`, no server, no network round trip once the model
/// is loaded. The model ID field takes any Hugging Face MLX-format
/// repo (e.g. `mlx-community/Qwen3-0.6B-4bit`); this is deliberately
/// small-model-first since it's the first real on-device generation
/// this app has ever run — a good one to validate the whole pipeline
/// with before trying anything large.
struct NativeChatView: View {
    @StateObject private var engine = NativeChatEngine()
    @State private var modelID = "mlx-community/Qwen3-0.6B-4bit"
    @State private var messages: [(isUser: Bool, text: String)] = []
    @State private var inputText = ""
    @State private var isGenerating = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                modelBar
                Divider()

                if let errorMessage = engine.errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption).padding(8)
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

            if engine.isLoaded {
                Button("Unload") { engine.unload() }
            } else if engine.isLoading {
                if let progress = engine.loadProgress {
                    ProgressView(value: progress).frame(width: 80)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Button("Load") { Task { await engine.load(modelID: modelID) } }
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
