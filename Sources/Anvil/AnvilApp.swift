import SwiftUI
import AnvilCore

@main
struct AnvilApp: App {
    @StateObject private var requirements = RequirementsManager()

    var body: some Scene {
        WindowGroup {
            BootstrapView()
                .environmentObject(requirements)
                .frame(minWidth: 480, minHeight: 320)
        }
        .windowResizability(.contentSize)
    }
}
