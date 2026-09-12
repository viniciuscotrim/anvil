import SwiftUI

/// The iOS app's entry point. `AnvilCore`'s shared, cross-platform
/// pieces (data models, both HTTP clients, both model catalogs,
/// `HFRepoDownloader`/`CivitAIDownloader`, `ModelRegistry`) are the
/// same code the macOS app uses — only the macOS app's Process-based
/// Requirements/Serving layer doesn't exist here, replaced by
/// `NativeChatEngine`/`NativeImageEngine` (in-process `mlx-swift`
/// inference, no subprocess).
///
/// `modelsViewModel` is owned once here and shared via `.environment`
/// so a model downloaded/registered in the Models tab shows up as a
/// pickable option in Chat and Images immediately — the same
/// single-source-of-truth registry pattern `AppState` gives the macOS
/// app's tabs.
@main
struct AnvilIOSApp: App {
    @State private var modelsViewModel = ModelsViewModel()
    @State private var profilesViewModel = ProfilesViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(modelsViewModel)
                .environment(profilesViewModel)
        }
    }
}
