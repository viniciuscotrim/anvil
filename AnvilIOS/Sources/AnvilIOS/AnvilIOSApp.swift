import MLX
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
    /// Owned here (not by `NativeChatView`) so the Memory tab can see
    /// the exact same in-memory `currentThread` Chat is actively having
    /// — not just whatever was last saved to disk — for "Suggest from
    /// current Chat thread".
    @State private var chatThreads = ChatThreadsViewModel()
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
        // Real, documented MLX guidance for iOS (mlx-swift's own
        // "Running on iOS" article): left at its defaults, MLX's
        // buffer-reuse cache and allocator can both grow well past what
        // jetsam allows one process — confirmed directly against this
        // device's own JetsamEvent reports (reason: "per-process-limit"),
        // during image *generation* specifically, not just loading the
        // weights. A small cache limit makes MLX release scratch buffers
        // instead of hoarding them for reuse; a lower, explicit memory
        // limit makes further allocation *wait* on in-flight work instead
        // of piling up until the OS kills the whole process. Set once,
        // globally, before either engine ever loads a model.
        MLX.Memory.cacheLimit = 16 * 1024 * 1024
        MLX.Memory.memoryLimit = 4_500_000_000

        let imageEngine = NativeImageEngine()
        _imageEngine = StateObject(wrappedValue: imageEngine)
        _chatEngine = StateObject(wrappedValue: NativeChatEngine(imageEngine: imageEngine))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(modelsViewModel)
                .environment(profilesViewModel)
                .environment(chatThreads)
                .environmentObject(chatEngine)
                .environmentObject(imageEngine)
        }
    }
}
