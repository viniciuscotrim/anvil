import CloudKit
import SwiftUI

/// Credentials for search/download — needed for gated/private Hugging
/// Face repos and some CivitAI content, and to get each site's
/// authenticated (higher) rate limit either way. No account-level
/// settings live here; this is the one thing the Search tab actually
/// needed a home for.
struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @Environment(ChatThreadsViewModel.self) private var threads

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Sync Threads, Profiles & Memories", isOn: Binding(
                        get: { threads.isCloudSyncEnabled },
                        set: { threads.setCloudSyncEnabled($0) }
                    ))
                    if threads.isCloudSyncEnabled, let status = threads.cloudAccountStatus, status != .available {
                        Text(cloudAccountStatusText(status))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("iCloud Sync")
                } footer: {
                    Text("Off by default. Works from anywhere — no Mac reachability needed at all, unlike picking a Mac as Chat's source. Encrypted in your own private iCloud account.")
                }

                Section {
                    if viewModel.hasStoredHFToken {
                        LabeledContent("Status") {
                            Text("Set").foregroundStyle(.green)
                        }
                        Button("Remove", role: .destructive) { viewModel.clearHFToken() }
                    } else {
                        SecureField("hf_…", text: $viewModel.hfTokenDraft)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button("Save") { viewModel.saveHFToken() }
                            .disabled(viewModel.hfTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Hugging Face Token")
                } footer: {
                    Text("Needed for gated/private repos you have access to, and gets the authenticated (higher) search rate limit either way.")
                }

                Section {
                    if viewModel.hasStoredCivitAIToken {
                        LabeledContent("Status") {
                            Text("Set").foregroundStyle(.green)
                        }
                        Button("Remove", role: .destructive) { viewModel.clearCivitAIToken() }
                    } else {
                        SecureField("Optional — needed for some gated content", text: $viewModel.civitaiTokenDraft)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        Button("Save") { viewModel.saveCivitAIToken() }
                            .disabled(viewModel.civitaiTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("CivitAI API Key")
                }
            }
            .navigationTitle("Settings")
            .task { viewModel.load() }
            .dismissKeyboardOnTap()
        }
    }

    private func cloudAccountStatusText(_ status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: return "Not signed into iCloud — sign in via Settings to use this."
        case .restricted: return "iCloud is restricted on this device."
        case .couldNotDetermine: return "Couldn't check iCloud account status — try again shortly."
        case .temporarilyUnavailable: return "iCloud is temporarily unavailable — try again shortly."
        case .available: return ""
        @unknown default: return "iCloud isn't available right now."
        }
    }
}
