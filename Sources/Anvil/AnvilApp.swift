import SwiftUI
import AnvilCore

// No `@main` here — see main.swift. A plain `main.swift` lets us run
// headless gate checks (`--phase2-gate`, `--phase3-gate`) before
// SwiftUI ever creates a window; `@main` on this type would take over
// the process entirely.
struct AnvilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var requirements = RequirementsManager()
    @StateObject private var sessions = ModelSessionManager()

    var body: some Scene {
        WindowGroup("Anvil", id: "main") {
            RootView()
                .environmentObject(requirements)
                .environmentObject(sessions)
                .onAppear { appDelegate.sessions = sessions }
        }
        .windowResizability(.contentSize)

        MenuBarExtra("Anvil", systemImage: "hammer.fill") {
            MenuBarContentView()
                .environmentObject(sessions)
        }
        .menuBarExtraStyle(.menu)
    }
}
