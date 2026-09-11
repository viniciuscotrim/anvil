import SwiftUI
import AnvilCore

// No `@main` here — see main.swift. A plain `main.swift` lets us run
// headless gate checks (`--phase2-gate`) before SwiftUI ever creates a
// window; `@main` on this type would take over the process entirely.
struct AnvilApp: App {
    @StateObject private var requirements = RequirementsManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(requirements)
        }
        .windowResizability(.contentSize)
    }
}
