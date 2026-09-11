import SwiftUI
import AnvilCore

// No `@main` here — see main.swift. A plain `main.swift` lets us run
// headless gate checks (`--phase2-gate`, `--phase3-gate`) before
// SwiftUI ever creates a window; `@main` on this type would take over
// the process entirely.
struct AnvilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Anvil", id: "main") {
            RootView()
                .environmentObject(appState.requirements)
                .environmentObject(appState.sessions)
                .environmentObject(appState.chat)
                .onAppear { appDelegate.sessions = appState.sessions }
        }
        .windowResizability(.contentSize)

        WindowGroup("Chat History", id: "threads") {
            ThreadsListView()
                .environmentObject(appState.chat)
        }

        MenuBarExtra("Anvil", systemImage: "hammer.fill") {
            MenuBarContentView()
                .environmentObject(appState.sessions)
        }
        .menuBarExtraStyle(.menu)
    }
}
