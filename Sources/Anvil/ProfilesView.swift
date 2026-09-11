import SwiftUI
import AnvilCore

/// "Perfis" — reusable system prompts (oMLX's "personas"), each
/// optionally bound as the default for one registered model.
struct ProfilesView: View {
    @EnvironmentObject private var viewModel: ProfilesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Button("New Profile") { viewModel.startCreating() }
            }

            if let error = viewModel.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            if viewModel.profiles.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No profiles yet").font(.headline)
                    Text("A profile is a system prompt that shapes how a model responds — create one and optionally set it as a model's default.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(viewModel.profiles) { profile in
                    profileRow(profile)
                }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 420)
        .task { await viewModel.load() }
        .sheet(item: Binding(
            get: { viewModel.editingDraft },
            set: { viewModel.editingDraft = $0 }
        )) { _ in
            editSheet
        }
    }

    private func profileRow(_ profile: ChatProfile) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(profile.name).font(.headline)
                    if let modelName = viewModel.modelDisplayName(for: profile.defaultForModelID) {
                        Text("· default for \(modelName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(profile.prompt.isEmpty ? "(no prompt)" : profile.prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
            Button("Edit") { viewModel.startEditing(profile) }
            Button("Delete", role: .destructive) { Task { await viewModel.delete(profile) } }
        }
        .padding(.vertical, 4)
    }

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.editingDraft?.id == nil ? "New Profile" : "Edit Profile")
                .font(.headline)

            TextField("Name", text: Binding(
                get: { viewModel.editingDraft?.name ?? "" },
                set: { viewModel.editingDraft?.name = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            Text("Prompt").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { viewModel.editingDraft?.prompt ?? "" },
                set: { viewModel.editingDraft?.prompt = $0 }
            ))
            .frame(minHeight: 140)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            Picker("Default for model", selection: Binding(
                get: { viewModel.editingDraft?.defaultForModelID },
                set: { viewModel.editingDraft?.defaultForModelID = $0 }
            )) {
                Text("None").tag(Optional<String>.none)
                ForEach(viewModel.registeredModels) { model in
                    Text(model.displayName).tag(Optional(model.id))
                }
            }

            if let modelID = viewModel.editingDraft?.defaultForModelID,
               let holder = viewModel.currentDefaultHolder(for: modelID, excluding: viewModel.editingDraft?.id) {
                Text("Currently the default for \(holder.name) — saving will move it to this profile.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { viewModel.editingDraft = nil }
                Button("Save") { Task { await viewModel.saveDraft() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
