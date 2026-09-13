import SwiftUI
import CloudKit
import AnvilCore

/// Top-level switcher: bootstrap screen until the bare minimum needed
/// to browse models is installed (Phase 1 rule), then a persistent
/// Models / Chat tab bar — Chat is its own app-level section, not tied
/// to whichever model you clicked into, so it stays put no matter which
/// loaded model you're talking to.
struct RootView: View {
    @EnvironmentObject private var requirements: RequirementsManager
    @EnvironmentObject private var chat: ChatViewModel
    @StateObject private var router = AppRouter()
    @State private var isIPhoneSyncPopoverPresented = false
    @State private var isCloudSyncPopoverPresented = false

    var body: some View {
        VStack(spacing: 0) {
            switch router.screen {
            case .bootstrap:
                BootstrapProgressView(
                    statusMessage: requirements.statusMessage,
                    isInstalling: requirements.isInstalling,
                    errorMessage: requirements.lastError
                )
            case .modelManager, .chat, .images, .profiles, .promptToModel, .code:
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
                case .code:
                    CodeAgentView()
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
        .task {
            // Runs here, not in `ChatView`'s own `.task` — iPhone/iCloud
            // sync are app-wide (their buttons now live in this bar, not
            // Chat's sidebar), so they need to be live and their status
            // known even if the user never opens the Chat tab this
            // session.
            await chat.applyMacSyncSettingsIfNeeded()
            await chat.applyCloudSyncSettingsIfNeeded()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            tabButton("Models", screen: .modelManager)
            tabButton("Chat", screen: .chat)
            tabButton("Images", screen: .images)
            tabButton("Profiles", screen: .profiles)
            tabButton("Prompt to Model", screen: .promptToModel)
            tabButton("Code", screen: .code)
            Spacer()

            // App-wide, not per-conversation — Chat's own sidebar used
            // to carry both, but iPhone/iCloud sync apply no matter
            // which tab (or thread) is open, so they live in the global
            // bar instead. iPhone sits to the left of iCloud, both to
            // the left of the version block.
            iPhoneSyncButton
            iCloudSyncButton

            VStack(alignment: .trailing, spacing: 1) {
                Text("v\(appVersion) (build \(buildNumber))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Created by Vinicius Cotrim")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var iPhoneSyncButton: some View {
        Button {
            isIPhoneSyncPopoverPresented = true
        } label: {
            Image(systemName: chat.isMacSyncEnabled ? "iphone.gen3" : "iphone.slash")
        }
        .foregroundStyle(chat.isMacSyncEnabled ? Color.accentColor : .secondary)
        .help("iPhone sync — let Anvil for iOS use this Mac's threads.")
        .popover(isPresented: $isIPhoneSyncPopoverPresented) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Let iPhone Use This Mac's Threads", isOn: Binding(
                    get: { chat.isMacSyncEnabled },
                    set: { chat.setMacSyncEnabled($0) }
                ))
                if chat.isMacSyncEnabled {
                    Picker("Access", selection: Binding(
                        get: { chat.macSyncAccess },
                        set: { chat.setMacSyncAccess($0) }
                    )) {
                        ForEach(ServerAccess.allCases) { access in
                            Text(access.label).tag(access)
                        }
                    }
                }
                Text("Off by default. When on, the Chat tab in Anvil for iOS can pick this Mac as its source — same threads, profiles, and memories, kept in sync on this Mac even when the iPhone sends the message.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(width: 340)
        }
    }

    private var iCloudSyncButton: some View {
        Button {
            isCloudSyncPopoverPresented = true
        } label: {
            Image(systemName: chat.isCloudSyncEnabled ? "icloud.fill" : "icloud.slash")
        }
        .foregroundStyle(chat.isCloudSyncEnabled ? Color.accentColor : .secondary)
        .help("iCloud sync — sync threads, profiles & memories across your devices.")
        .popover(isPresented: $isCloudSyncPopoverPresented) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Sync Threads, Profiles & Memories via iCloud", isOn: Binding(
                    get: { chat.isCloudSyncEnabled },
                    set: { chat.setCloudSyncEnabled($0) }
                ))
                if chat.isCloudSyncEnabled, let status = chat.cloudAccountStatus, status != .available {
                    Text(cloudAccountStatusText(status))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding()
            .frame(width: 340)
        }
    }

    private func cloudAccountStatusText(_ status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: return "Not signed into iCloud — sign in via System Settings to use this."
        case .restricted: return "iCloud is restricted on this Mac (e.g. parental controls)."
        case .couldNotDetermine: return "Couldn't check iCloud account status — try again shortly."
        case .temporarilyUnavailable: return "iCloud is temporarily unavailable — try again shortly."
        case .available: return ""
        @unknown default: return "iCloud isn't available right now."
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
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
