import SwiftUI
import AnvilCore

/// Top-level switcher: shows the bootstrap screen until the bare
/// minimum needed to browse models is installed (Phase 1 rule), then
/// the model manager (Phase 2), then a real chat window once a model
/// is picked to load (Phase 3) — pick a model, start talking to it,
/// same as the brief's own "wait, that's it?" bar.
struct RootView: View {
    @EnvironmentObject private var requirements: RequirementsManager
    @StateObject private var router = AppRouter()

    var body: some View {
        Group {
            switch router.screen {
            case .bootstrap:
                BootstrapProgressView(
                    statusMessage: requirements.statusMessage,
                    isInstalling: requirements.isInstalling,
                    errorMessage: requirements.lastError
                )
            case .modelManager:
                ModelManagerView(requirements: requirements, router: router)
            case .chat(let model):
                ChatView(model: model, requirements: requirements, router: router)
            }
        }
        .task {
            let ready = await requirements.ensure(HuggingFaceClientDependency())
            if ready {
                router.screen = .modelManager
            }
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
