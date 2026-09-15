import SwiftUI
import AnvilCore

// No `@main` here — see main.swift. A plain `main.swift` lets us run
// headless gate checks (`--phase2-gate`, `--phase3-gate`, `--phase4-gate`)
// before SwiftUI ever creates a window; `@main` on this type would take
// over the process entirely.
struct AnvilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("Anvil", id: "main") {
            RootView()
                .environment(appState.requirements)
                .environment(appState.sessions)
                .environment(appState.imageSessions)
                .environment(appState.chat)
                .environment(appState.imageGeneration)
                .environment(appState.profiles)
                .environment(appState.promptToModel)
                .environment(appState.modelManager)
                .environment(appState.codeAgent)
                .onAppear {
                    appDelegate.sessions = appState.sessions
                    appDelegate.imageSessions = appState.imageSessions
                    appDelegate.gateway = appState.gateway
                }
        }
        .windowResizability(.contentSize)

        WindowGroup("Code History", id: "code-threads") {
            CodeThreadsListView()
                .environment(appState.codeAgent)
        }

        WindowGroup("Memory", id: "memory") {
            MemoryView()
                .environment(appState.chat)
        }

        // A detached copy of the same live chat — same `ChatViewModel`
        // instance, so it's the identical conversation, not a fork —
        // opened via the "pop out" button in Chat's header so the user
        // can keep it visible while using the rest of the app.
        // `isPopout: true` gives it a different layout (no threads
        // column, settings panel always shown) and marks
        // `chat.isPoppedOut` for as long as this window stays open —
        // see `ChatView`'s own header comment.
        WindowGroup("Chat", id: "chat-popout") {
            ChatView(isPopout: true)
                .environment(appState.sessions)
                .environment(appState.imageSessions)
                .environment(appState.chat)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Anvil", systemImage: "hammer.fill") {
            MenuBarContentView()
                .environment(appState.sessions)
                .environment(appState.imageSessions)
        }
        .menuBarExtraStyle(.menu)
    }
}
