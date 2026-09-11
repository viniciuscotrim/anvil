import SwiftUI
import AppKit
import AnvilCore

/// An app-level chat window: pick which loaded model you're talking to,
/// switch freely between them without losing history, select/copy any
/// message, and export the whole thread as Markdown.
struct ChatView: View {
    @EnvironmentObject private var sessions: ModelSessionManager
    @StateObject private var viewModel: ChatViewModel

    init(sessions: ModelSessionManager) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(sessions: sessions))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if sessions.readySessions.isEmpty {
                emptyState
            } else if viewModel.messages.isEmpty {
                Spacer()
                Text("Say something to \(viewModel.selectedModelDisplayName ?? "the model").")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                messageList
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            Divider()
            inputBar
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { viewModel.syncSelection() }
        .onChange(of: sessions.sessions) { _, _ in viewModel.syncSelection() }
        .fileExporter(
            isPresented: Binding(
                get: { viewModel.isExportPresented },
                set: { viewModel.isExportPresented = $0 }
            ),
            document: TranscriptDocument(text: viewModel.exportMarkdown()),
            contentType: .markdownTranscript,
            defaultFilename: (viewModel.selectedModelDisplayName ?? "conversation") + ".md"
        ) { _ in }
    }

    private var header: some View {
        HStack {
            if sessions.readySessions.isEmpty {
                Text("Chat").font(.headline)
            } else {
                Picker("", selection: Binding(
                    get: { viewModel.selectedModelID },
                    set: { viewModel.selectedModelID = $0 }
                )) {
                    ForEach(sessions.readySessions) { session in
                        Text(session.model.displayName).tag(Optional(session.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }

            Spacer()

            Button {
                copyAllToPasteboard()
            } label: {
                Label("Copy All", systemImage: "doc.on.doc")
            }
            .disabled(viewModel.messages.isEmpty)

            Button {
                viewModel.isExportPresented = true
            } label: {
                Label("Export…", systemImage: "square.and.arrow.up")
            }
            .disabled(viewModel.messages.isEmpty)
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

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }
                    if viewModel.isSending {
                        ProgressView()
                            .padding(.leading, 4)
                            .id("sending-indicator")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.messages) { _, _ in
                let target: AnyHashable = viewModel.messages.last.map { AnyHashable($0.id) }
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
            VStack(alignment: .leading, spacing: 2) {
                Text(message.role == .user ? "You" : "Assistant")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(message.content)
                    .textSelection(.enabled)
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
                .disabled(sessions.readySessions.isEmpty)

            Button("Send") { Task { await viewModel.send() } }
                .disabled(
                    sessions.readySessions.isEmpty
                    || viewModel.isSending
                    || viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
        }
        .padding()
    }

    private func copyAllToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.exportMarkdown(), forType: .string)
    }
}
