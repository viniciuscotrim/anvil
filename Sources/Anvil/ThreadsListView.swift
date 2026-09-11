import SwiftUI
import AnvilCore

/// Chat history — every persisted thread, newest first. Picking one
/// makes it the active conversation in the Chat tab; each can be
/// deleted independently. Disabled while temporary mode is active,
/// since switching threads is one of the things that mode blocks.
struct ThreadsListView: View {
    @EnvironmentObject private var chat: ChatViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat History")
                    .font(.headline)
                Spacer()
                Button("New Thread") { chat.newThread() }
                    .disabled(chat.isTemporaryModeActive)
            }
            .padding()

            if chat.isTemporaryModeActive {
                Text("Temporary chat is active — turn it off to switch threads.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            Divider()

            if chat.allThreads.isEmpty {
                Spacer()
                Text("No saved conversations yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(chat.allThreads) { thread in
                    threadRow(thread)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .disabled(chat.isTemporaryModeActive)
    }

    private func threadRow(_ thread: ChatThread) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.title)
                        .font(.headline)
                        .lineLimit(1)
                    if thread.id == chat.currentThread.id {
                        Text("· active")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(thread.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(thread.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { chat.selectThread(thread) }

            Spacer()

            Button {
                Task { await chat.deleteThread(thread) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}
