import SwiftUI
import AppKit
import AnvilCore

/// The system menu bar item's dropdown — server control and quit,
/// reachable whether or not the main window is open. More items land
/// here as later phases add things worth controlling from the menu bar
/// (voice chat, memory usage).
struct MenuBarContentView: View {
    @Environment(ModelSessionManager.self) private var sessions
    @Environment(ImageSessionManager.self) private var imageSessions
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if sessions.sessions.isEmpty && imageSessions.sessions.isEmpty {
            Text("No models loaded")
        } else {
            ForEach(sessions.sessions) { session in
                textSessionRow(session)
            }
            ForEach(imageSessions.sessions) { session in
                imageSessionRow(session)
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

    /// Plain text label (not a tappable row) plus an explicit "Unload"
    /// button — an earlier version made the whole row the unload
    /// action, which wasn't discoverable as clickable inside a menu.
    private func textSessionRow(_ session: ModelSessionManager.Session) -> some View {
        HStack {
            statusSymbol(for: session.status)
            Text(session.model.displayName)
            Spacer()
            if session.status == .ready {
                Button("Unload") {
                    Task { await sessions.unload(modelID: session.id) }
                }
            }
        }
    }

    private func imageSessionRow(_ session: ImageSessionManager.Session) -> some View {
        HStack {
            statusSymbol(for: session.status)
            Text("\(session.model.displayName) (image)")
            Spacer()
            if session.status == .ready {
                Button("Unload") {
                    Task { await imageSessions.unload(modelID: session.id) }
                }
            }
        }
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

    private func statusSymbol(for status: ImageSessionManager.Status) -> some View {
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
