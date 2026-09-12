import SwiftUI

/// The iOS scaffold's entry point — Phase iOS-1's whole job is proving
/// this builds, signs with the real team, and installs+launches on a
/// real iPhone. Nothing here shares code with the macOS app's
/// `AnvilCore` yet: that library's Requirements/Serving layers are
/// built entirely around `Foundation.Process` (a private Python venv,
/// `mlx_lm.server`, `mflux` as subprocesses) — an API that doesn't
/// exist on iOS at all. The real iOS port needs a native Swift
/// inference engine (`mlx-swift`) instead, which is a separate,
/// substantial piece of work this scaffold intentionally doesn't
/// attempt — see the macOS app's README for the phased plan.
@main
struct AnvilIOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
