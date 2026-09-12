import SwiftUI
import AnvilCore

struct ProfilesView: View {
    @Environment(ProfilesViewModel.self) private var viewModel
    @Environment(ModelsViewModel.self) private var modelsViewModel
    @State private var editingProfile: ChatProfile?
    @State private var isPresentingNew = false

    var body: some View {
        NavigationStack {
            List {
                if viewModel.profiles.isEmpty {
                    Text("No profiles yet — create one to shape how a model responds.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.profiles) { profile in
                    Button {
                        editingProfile = profile
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).foregroundStyle(.primary)
                            if let modelID = profile.defaultForModelID,
                               let entry = modelsViewModel.registeredModels.first(where: { $0.id == modelID }) {
                                Text("Default for \(entry.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let origin = profile.originDeviceName {
                                Text("From \(origin)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { Task { await viewModel.delete(profile) } }
                    }
                }
            }
            .navigationTitle("Profiles")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingNew) {
                ProfileEditView(profile: nil)
            }
            .sheet(item: $editingProfile) { profile in
                ProfileEditView(profile: profile)
            }
            .task { await viewModel.load() }
        }
    }
}

private struct ProfileEditView: View {
    @Environment(ProfilesViewModel.self) private var viewModel
    @Environment(ModelsViewModel.self) private var modelsViewModel
    @Environment(\.dismiss) private var dismiss

    let profile: ChatProfile?
    @State private var name: String
    @State private var prompt: String
    @State private var defaultForModelID: String?

    init(profile: ChatProfile?) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _prompt = State(initialValue: profile?.prompt ?? "")
        _defaultForModelID = State(initialValue: profile?.defaultForModelID)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Concise Assistant", text: $name)
                }
                Section("Prompt") {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 120)
                }
                Section("Default model") {
                    Picker("Model", selection: $defaultForModelID) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(modelsViewModel.registeredModels.filter { $0.kind == .text }) { entry in
                            Text(entry.displayName).tag(Optional(entry.id))
                        }
                    }
                }
            }
            .navigationTitle(profile == nil ? "New Profile" : "Edit Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let saved = ChatProfile(
                                id: profile?.id ?? UUID(),
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                prompt: prompt,
                                defaultForModelID: defaultForModelID,
                                createdAt: profile?.createdAt ?? Date(),
                                originDeviceName: profile?.originDeviceName ?? DeviceIdentity.currentName
                            )
                            await viewModel.save(saved)
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .dismissKeyboardOnTap()
        }
    }
}
