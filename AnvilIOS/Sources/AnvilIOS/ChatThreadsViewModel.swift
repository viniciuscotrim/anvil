import AnvilCore
import Foundation

/// Chat's thread list + persistence, mirroring the threading half of
/// the Mac app's `ChatViewModel` (the model-serving half stays in
/// `NativeChatEngine` here since iOS talks to an in-process
/// `ChatSession` instead of an HTTP `ChatClient`). Owned by
/// `NativeChatView` via `@State` so it survives tab switches the same
/// way `engine` does.
@Observable @MainActor
final class ChatThreadsViewModel {
    var currentThread = ChatThread()
    private(set) var allThreads: [ChatThread] = []
    /// While on, the active conversation is never saved to disk — same
    /// restriction and behavior as the Mac app's own temporary mode:
    /// blocks `newThread`/`selectThread` (turn it off first) and every
    /// persist call becomes a no-op until it's off again.
    private(set) var isTemporaryModeActive = false
    private var threadBeforeTemporaryMode: ChatThread?

    private let store = ChatThreadStore()
    /// `.task` on the view reruns every time it re-enters the hierarchy
    /// (switching tabs and back) — only the first call should pick the
    /// initial thread; later calls just refresh `allThreads`, the same
    /// distinction `ChatViewModel.loadInitialState` draws and for the
    /// same reason (don't silently discard the active conversation).
    private var hasLoadedInitialState = false

    func loadInitialState() async {
        allThreads = await store.all()
        if !hasLoadedInitialState {
            currentThread = allThreads.first ?? ChatThread()
            hasLoadedInitialState = true
        }
    }

    func newThread() {
        guard !isTemporaryModeActive else { return }
        currentThread = ChatThread()
    }

    func selectThread(_ thread: ChatThread) {
        guard !isTemporaryModeActive else { return }
        currentThread = thread
    }

    func deleteThread(_ thread: ChatThread) async {
        try? await store.delete(id: thread.id)
        allThreads.removeAll { $0.id == thread.id }
        if currentThread.id == thread.id {
            currentThread = allThreads.first ?? ChatThread()
        }
    }

    /// Only the caller flips this — nothing else enters or exits
    /// temporary mode on its own. Turning it back off restores whatever
    /// thread was active before, exactly where it was left.
    func toggleTemporaryMode() {
        if isTemporaryModeActive {
            isTemporaryModeActive = false
            currentThread = threadBeforeTemporaryMode ?? allThreads.first ?? ChatThread()
            threadBeforeTemporaryMode = nil
        } else {
            threadBeforeTemporaryMode = currentThread
            currentThread = ChatThread(title: "Temporary Chat")
            isTemporaryModeActive = true
        }
    }

    /// Saves and reassigns `currentThread` to the persisted copy (its
    /// `updatedAt` included) — use once a turn is fully done. A no-op
    /// while temporary mode is active.
    func persistCurrentThread() async {
        guard !isTemporaryModeActive else { return }
        guard let saved = try? await store.upsert(currentThread) else { return }
        if currentThread.id == saved.id {
            currentThread = saved
        }
        allThreads = await store.all()
    }

    /// Write-only: saves to disk without reassigning `currentThread`, so
    /// a save that resolves after later mutations in the same turn (the
    /// assistant's reply streaming in) can't clobber them. Used right
    /// after appending the user's own message, so it survives even if
    /// something interrupts before the assistant replies. A no-op while
    /// temporary mode is active.
    func persistCurrentThreadForDurability() {
        guard !isTemporaryModeActive else { return }
        let threadToSave = currentThread
        Task {
            _ = try? await store.upsert(threadToSave)
        }
    }
}
