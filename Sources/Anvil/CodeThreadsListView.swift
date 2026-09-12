import SwiftUI
import AnvilCore

/// Code's own conversation history — same idea and layout as `ThreadsListView`
/// (Chat's), backed by its own `ChatThreadStore` file (`code/threads.json`)
/// so a Code conversation's tool-call/result messages never mix into
/// Chat's own list or vice versa. Every Code conversation is saved here
/// permanently the same way Chat's are — there's no temporary/incognito
/// mode for Code (unlike Chat, which has an explicit toggle for that).
struct CodeThreadsListView: View {
    @EnvironmentObject private var codeAgent: CodeAgentViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Code History")
                    .font(.headline)
                Spacer()
                Button("New Thread") { codeAgent.newThread() }
            }
            .padding()

            Divider()

            if codeAgent.allThreads.isEmpty {
                Spacer()
                Text("No saved Code conversations yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(codeAgent.allThreads) { thread in
                    threadRow(thread)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
    }

    private func threadRow(_ thread: ChatThread) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.title)
                        .font(.headline)
                        .lineLimit(1)
                    if thread.id == codeAgent.currentThread.id {
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
            .onTapGesture { codeAgent.selectThread(thread) }

            Spacer()

            Button {
                Task { await codeAgent.deleteThread(thread) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}
