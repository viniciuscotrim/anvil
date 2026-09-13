import AnvilCore
import UIKit

/// Wired in via `@UIApplicationDelegateAdaptor` in `AnvilIOSApp` purely
/// to receive one UIKit-only callback SwiftUI's own `App`/`Scene`
/// lifecycle has no equivalent for: iOS waking this app briefly in the
/// background specifically to hand back events from a background
/// `URLSession` — see `BackgroundDownloadCoordinator`'s own header
/// comment for why a model download needs one at all (continuing
/// through a locked screen or a switched-away app).
final class AnvilIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloadCoordinator.sessionIdentifier else {
            completionHandler()
            return
        }
        Task {
            await BackgroundDownloadCoordinator.shared.setBackgroundCompletionHandler(completionHandler)
            await BackgroundDownloadCoordinator.shared.reconnectIfNeeded()
        }
    }
}
