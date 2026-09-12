import SwiftUI

/// Credentials for search/download — needed for gated/private Hugging
/// Face repos and some CivitAI content, and to get each site's
/// authenticated (higher) rate limit either way. No account-level
/// settings live here; this is the one thing the Search tab actually
/// needed a home for.
struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
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
}
