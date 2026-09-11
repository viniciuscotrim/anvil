import SwiftUI
import AnvilCore

/// Holds this view's own transient state via `@StateObject` instead of
/// `@State`. On this toolchain (Command Line Tools only, no Xcode.app),
/// `@State`'s macro implementation lives in a plugin that ships inside
/// Xcode.app and isn't available — `@StateObject`/`ObservableObject`
/// are plain Combine-based property wrappers and build fine. Keep this
/// pattern for any future view-local state rather than reaching for
/// `@State`.
private final class BootstrapViewState: ObservableObject {
    @Published var isReady = false
}

/// First-launch screen. Triggers only the bare minimum needed to browse
/// and pick a model (Phase 1 rule) — the model picker itself lands in
/// Phase 2, at which point this view becomes the "installing…" state
/// that picker pushes into, rather than the whole app.
struct BootstrapView: View {
    @EnvironmentObject private var requirements: RequirementsManager
    @StateObject private var viewState = BootstrapViewState()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Anvil")
                .font(.title)
                .bold()

            if requirements.isInstalling {
                ProgressView(requirements.statusMessage.isEmpty ? "Setting up…" : requirements.statusMessage)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
            } else if let error = requirements.lastError {
                VStack(spacing: 8) {
                    Text("Setup couldn't finish")
                        .font(.headline)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if viewState.isReady {
                Text("Ready to pick a model.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .task {
            viewState.isReady = await requirements.ensure(HuggingFaceClientDependency())
        }
    }
}
