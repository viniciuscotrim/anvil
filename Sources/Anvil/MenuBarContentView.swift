import SwiftUI
import AppKit
import AnvilCore

/// The system menu bar item's dropdown — server control and quit,
/// reachable whether or not the main window is open. More items land
/// here as later phases add things worth controlling from the menu bar
/// (image generation, voice chat, memory usage).
struct MenuBarContentView: View {
    @EnvironmentObject private var sessions: ModelSessionManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if sessions.sessions.isEmpty {
            Text("No models loaded")
        } else {
            ForEach(sessions.sessions) { session in
                Button {
                    Task { await sessions.unload(modelID: session.id) }
                } label: {
                    HStack {
                        statusSymbol(for: session.status)
                        Text(session.model.displayName)
                    }
                }
            }
        }

        Divider()

        Button("Open Anvil") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Divider()

        Button("Quit Anvil") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func statusSymbol(for status: ModelSessionManager.Status) -> some View {
        switch status {
        case .loading:
            return Image(systemName: "hourglass")
        case .ready:
            return Image(systemName: "circle.fill")
        case .failed:
            return Image(systemName: "exclamationmark.triangle.fill")
        }
    }
}
