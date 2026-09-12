import SwiftUI
import AnvilCore

/// Chat history — every persisted thread, newest first. Picking one
/// makes it the active conversation in the Chat tab; each can be
/// deleted independently. Temporary threads stay in memory for the app
/// session and can be selected alongside persisted threads.
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
    }

    private func threadRow(_ thread: ChatThread) -> some View {
        HStack {
            Button {
                chat.selectThread(thread)
            } label: {
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
                HStack(spacing: 4) {
                    Text(thread.updatedAt, style: .relative)
                    if let origin = thread.originDeviceName {
                        Text("· \(origin)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

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
