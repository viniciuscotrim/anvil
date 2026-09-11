import SwiftUI
import AnvilCore

/// Phase 3's other half: not just a server for the persona proxies, but
/// an actual place to talk to a loaded model yourself — pick a model,
/// start talking to it, same as the brief's own zero-friction bar.
struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @ObservedObject private var router: AppRouter

    init(model: ModelEntry, requirements: RequirementsManager, router: AppRouter) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(model: model, requirements: requirements))
        self.router = router
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }
            Divider()
            inputBar
        }
        .frame(minWidth: 560, minHeight: 420)
        .task { await viewModel.start() }
    }

    private var header: some View {
        HStack {
            Button("← Models") {
                Task { await viewModel.stop() }
                router.screen = .modelManager
            }

            Spacer()

            Text(viewModel.model.displayName)
                .font(.headline)

            Spacer()

            if viewModel.isLoadingModel {
                ProgressView()
                    .controlSize(.small)
            } else if viewModel.isServerReady {
                Label("Ready", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding()
    }

    private var messageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(viewModel.messages) { message in
                    bubble(for: message)
                }
                if viewModel.isSending {
                    ProgressView()
                        .padding(.leading, 4)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bubble(for message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(message.content)
            }
            .padding(10)
            .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("Message…", text: $viewModel.inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit { Task { await viewModel.send() } }

            Button("Send") { Task { await viewModel.send() } }
                .disabled(
                    !viewModel.isServerReady
                    || viewModel.isSending
                    || viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        }
        .padding()
    }
}
