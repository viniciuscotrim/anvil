import SwiftUI
import AnvilCore

/// Holds this view's own transient state via `@StateObject` instead of
/// `@State`. On this toolchain (Command Line Tools only, no Xcode.app),
/// `@State`'s macro implementation lives in a plugin that ships inside
/// Xcode.app and isn't available — `@StateObject`/`ObservableObject`
/// are plain Combine-based property wrappers and build fine. Keep this
/// pattern for any future view-local state rather than reaching for
/// `@State`.
final class BootstrapViewState: ObservableObject {
    @Published var isReady = false
}

/// Top-level switcher: shows the bootstrap screen until the bare
/// minimum needed to browse models is installed (Phase 1 rule), then
/// hands off to the model manager (Phase 2).
struct RootView: View {
    @EnvironmentObject private var requirements: RequirementsManager
    @StateObject private var bootstrapState = BootstrapViewState()

    var body: some View {
        Group {
            if bootstrapState.isReady {
                ModelManagerView(requirements: requirements)
            } else {
                BootstrapProgressView(
                    statusMessage: requirements.statusMessage,
                    isInstalling: requirements.isInstalling,
                    errorMessage: requirements.lastError
                )
            }
        }
        .task {
            bootstrapState.isReady = await requirements.ensure(HuggingFaceClientDependency())
        }
    }
}

/// First-launch screen — pure display, all state comes from its parent.
struct BootstrapProgressView: View {
    let statusMessage: String
    let isInstalling: Bool
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Anvil")
                .font(.title)
                .bold()

            if isInstalling {
                ProgressView(statusMessage.isEmpty ? "Setting up…" : statusMessage)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
            } else if let errorMessage {
                VStack(spacing: 8) {
                    Text("Setup couldn't finish")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 320)
    }
}
