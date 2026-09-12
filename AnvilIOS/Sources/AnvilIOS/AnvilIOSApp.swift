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
    /// Owned here (not by `NativeChatView`/`NativeImageView` themselves)
    /// so Prompt to Model can drive the very same loaded text/image
    /// models Chat and Images already hold — one resident model per
    /// kind, shared across tabs, matching `AppState`'s
    /// `ModelSessionManager`/`ImageSessionManager` singletons on macOS.
    /// `chatEngine` also needs a direct reference to `imageEngine` for
    /// its `generate_image` tool-call dispatch, hence the explicit
    /// `init()` below instead of two independent property initializers.
    @StateObject private var chatEngine: NativeChatEngine
    @StateObject private var imageEngine: NativeImageEngine

    init() {
        let imageEngine = NativeImageEngine()
        _imageEngine = StateObject(wrappedValue: imageEngine)
        _chatEngine = StateObject(wrappedValue: NativeChatEngine(imageEngine: imageEngine))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(modelsViewModel)
                .environment(profilesViewModel)
                .environmentObject(chatEngine)
                .environmentObject(imageEngine)
        }
    }
}
