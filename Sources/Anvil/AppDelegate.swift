import AppKit
import AnvilCore

/// Makes sure quitting the app — by any path (Cmd+Q, Dock menu, the
/// menu bar item's Quit) — actually stops every `mlx_lm.server`
/// subprocess first. Without this, a loaded model's server survives the
/// app quitting and keeps holding its port and memory: exactly the
/// "background process I can't get rid of" bug this whole menu bar
/// exists to fix.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var sessions: ModelSessionManager?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let sessions, !sessions.sessions.isEmpty else { return .terminateNow }

        Task { @MainActor in
            await sessions.unloadAll()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
