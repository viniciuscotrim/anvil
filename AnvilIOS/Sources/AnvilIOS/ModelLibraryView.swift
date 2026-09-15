import SwiftUI
import AnvilCore

/// Registered models — grouped by family (every "Qwen3.5" size/quant
/// variant together, "FLUX.2-klein" its own, …) the same way the Mac
/// app's Model Manager groups its own registered-models list, with
/// Load/Unload wired to the shared `NativeChatEngine` and Delete
/// blocked while a model is loaded. Its own screen, separate from
/// `ModelSearchView` — see `ModelsViewModel`'s header comment for why.
struct ModelLibraryView: View {
    @Environment(ModelsViewModel.self) private var viewModel
    @Environment(NativeChatEngine.self) private var chatEngine
    @Environment(NativeImageEngine.self) private var imageEngine

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.registeredModels.isEmpty {
                    ContentUnavailableView(
                        "No Models Yet",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Search and download one in the Search tab.")
                    )
                } else {
                    List {
                        ForEach(orderedFamilies) { family in
                            Section(family.name) {
                                ForEach(sortedModels(in: family)) { entry in
                                    modelRow(entry)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Model Library")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await viewModel.loadRegistry() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await viewModel.loadRegistry() }
            .onAppear { Task { await viewModel.loadRegistry() } }
        }
    }

    /// `registeredModelFamilies`, reordered so the family containing the
    /// one model this iPhone actually has loaded always sorts first —
    /// requested live (matching the Mac app): "organizar por Ativo
    /// sempre no topo".
    private var orderedFamilies: [ModelFamilyGrouping.Family] {
        viewModel.registeredModelFamilies.sorted { lhs, rhs in
            lhs.models.contains(where: isLoaded) && !rhs.models.contains(where: isLoaded)
        }
    }

    private func sortedModels(in family: ModelFamilyGrouping.Family) -> [ModelEntry] {
        family.models.sorted { isLoaded($0) && !isLoaded($1) }
    }

    private func isLoaded(_ entry: ModelEntry) -> Bool {
        chatEngine.loadedModelID == entry.id || imageEngine.loadedModelID == entry.id
    }

    @ViewBuilder
    private func modelRow(_ entry: ModelEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.displayName)
                Text(entry.kind == .image ? "· image" : "· text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let size = entry.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            switch entry.kind {
            case .text:
                textLoadControl(for: entry)
            case .image:
                imageLoadControl(for: entry)
            }
        }
        .swipeActions {
            if chatEngine.loadedModelID != entry.id, imageEngine.loadedModelID != entry.id {
                Button("Delete", role: .destructive) { Task { await viewModel.delete(entry) } }
            }
        }
    }

    /// Load/Unload straight from the Library — the actual management
    /// the source list/downloads alone didn't give: a downloaded model
    /// previously had no way to be loaded, freed, or even shown as
    /// "in use" anywhere outside Chat's/Images' own pickers.
    private func textLoadControl(for entry: ModelEntry) -> some View {
        HStack(spacing: 8) {
            if chatEngine.loadedModelID == entry.id {
                Label("Loaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button("Unload") { chatEngine.unload() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            } else if chatEngine.isLoading {
                if let progress = chatEngine.loadProgress {
                    ProgressView(value: progress).frame(width: 80)
                    Text("\(Int(progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            } else {
                Spacer()
                Button("Load") { Task { await chatEngine.load(modelID: entry.id) } }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(chatEngine.isLoading)
            }
        }
    }

    /// Same idea for image models — real now that `NativeImageEngine`
    /// can load an arbitrary registered checkpoint (see
    /// `StableDiffusionModelLoader`), not just its one built-in preset.
    private func imageLoadControl(for entry: ModelEntry) -> some View {
        HStack(spacing: 8) {
            if imageEngine.loadedModelID == entry.id {
                Label("Loaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button("Unload") { imageEngine.unload() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            } else if imageEngine.isLoading {
                if let progress = imageEngine.loadProgress {
                    ProgressView(value: progress).frame(width: 80)
                    Text("\(Int(progress * 100))%").font(.caption2).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            } else {
                Spacer()
                Button("Load") { Task { await imageEngine.load(entry: entry) } }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .disabled(imageEngine.isLoading || imageEngine.isLoaded)
                    .help(imageEngine.isLoaded ? "Unload the current image model first." : "")
            }
        }
    }
}
