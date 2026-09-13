import SwiftUI
import AnvilCore

// No `@main` here — see main.swift. A plain `main.swift` lets us run
// headless gate checks (`--phase2-gate`, `--phase3-gate`, `--phase4-gate`)
// before SwiftUI ever creates a window; `@main` on this type would take
// over the process entirely.
struct AnvilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Anvil", id: "main") {
            RootView()
                .environmentObject(appState.requirements)
                .environmentObject(appState.sessions)
                .environmentObject(appState.imageSessions)
                .environmentObject(appState.chat)
                .environmentObject(appState.imageGeneration)
                .environmentObject(appState.profiles)
                .environmentObject(appState.promptToModel)
                .environmentObject(appState.modelManager)
                .environmentObject(appState.codeAgent)
                .onAppear {
                    appDelegate.sessions = appState.sessions
                    appDelegate.imageSessions = appState.imageSessions
                    appDelegate.gateway = appState.gateway
                }
        }
        .windowResizability(.contentSize)

        WindowGroup("Code History", id: "code-threads") {
            CodeThreadsListView()
                .environmentObject(appState.codeAgent)
        }

        WindowGroup("Memory", id: "memory") {
            MemoryView()
                .environmentObject(appState.chat)
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
                .environmentObject(appState.sessions)
                .environmentObject(appState.imageSessions)
                .environmentObject(appState.chat)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Anvil", systemImage: "hammer.fill") {
            MenuBarContentView()
                .environmentObject(appState.sessions)
                .environmentObject(appState.imageSessions)
        }
        .menuBarExtraStyle(.menu)
    }
}
