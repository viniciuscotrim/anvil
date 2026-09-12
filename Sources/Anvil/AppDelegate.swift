import AppKit
import AnvilCore

/// Makes sure quitting the app — by any path (Cmd+Q, Dock menu, the
/// menu bar item's Quit) — actually stops every loaded model's
/// subprocess first (`mlx_lm.server` and `mflux`-backed image servers
/// alike). Without this, a loaded model's server survives the app
/// quitting and keeps holding its port and memory: exactly the
/// "background process I can't get rid of" bug this whole menu bar
/// exists to fix.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var sessions: ModelSessionManager?
    var imageSessions: ImageSessionManager?
    var gateway: OpenAIGateway?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasLoadedSessions = !(sessions?.sessions.isEmpty ?? true) || !(imageSessions?.sessions.isEmpty ?? true)
        guard hasLoadedSessions else { return .terminateNow }

        Task { @MainActor in
            await sessions?.unloadAll()
            await imageSessions?.unloadAll()
            if let gateway { await gateway.stop() }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
