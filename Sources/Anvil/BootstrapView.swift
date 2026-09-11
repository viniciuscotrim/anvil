import SwiftUI
import AnvilCore

/// Top-level switcher: bootstrap screen until the bare minimum needed
/// to browse models is installed (Phase 1 rule), then a persistent
/// Models / Chat tab bar — Chat is its own app-level section, not tied
/// to whichever model you clicked into, so it stays put no matter which
/// loaded model you're talking to.
struct RootView: View {
    @EnvironmentObject private var requirements: RequirementsManager
    @StateObject private var router = AppRouter()

    var body: some View {
        VStack(spacing: 0) {
            switch router.screen {
            case .bootstrap:
                BootstrapProgressView(
                    statusMessage: requirements.statusMessage,
                    isInstalling: requirements.isInstalling,
                    errorMessage: requirements.lastError
                )
            case .modelManager, .chat, .images, .profiles, .promptToModel:
                tabBar
                Divider()
                switch router.screen {
                case .modelManager:
                    ModelManagerView()
                case .chat:
                    ChatView()
                case .images:
                    ImageGenerationView()
                case .profiles:
                    ProfilesView()
                case .promptToModel:
                    PromptToModelView()
                case .bootstrap:
                    EmptyView()
                }
            }
        }
        .task {
            let ready = await requirements.ensure(HuggingFaceClientDependency())
            if ready {
                router.screen = .modelManager
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            tabButton("Models", screen: .modelManager)
            tabButton("Chat", screen: .chat)
            tabButton("Images", screen: .images)
            tabButton("Profiles", screen: .profiles)
            tabButton("Prompt to Model", screen: .promptToModel)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func tabButton(_ title: String, screen: AppRouter.Screen) -> some View {
        Button(title) { router.screen = screen }
            .buttonStyle(.borderedProminent)
            .tint(router.screen == screen ? .accentColor : .secondary)
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
