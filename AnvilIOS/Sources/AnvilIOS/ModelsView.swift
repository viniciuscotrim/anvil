import SwiftUI
import AnvilCore

/// Search, download, and manage models — real feature parity with the
/// Mac app's Model Manager (a source picker between Hugging Face and
/// CivitAI, same as the Mac's, minus the folder-mapping UI, not yet
/// ported), sharing the exact same `AnvilCore` catalog/registry code.
///
/// Both sources share one `.searchable` bar and one filter row — HF and
/// CivitAI used to each own a structurally different search control (a
/// native `.searchable` field for one, an inline `TextField`+`Button`
/// row for the other), so switching sources visibly reshuffled the
/// whole screen. Routing both through the same `.searchable` field via
/// `viewModel.performSearch()` fixes that.
struct ModelsView: View {
    @Environment(ModelsViewModel.self) private var viewModel
    @EnvironmentObject private var chatEngine: NativeChatEngine

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            List {
                Picker("Source", selection: $viewModel.source) {
                    ForEach(ModelsViewModel.Source.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                filterRow

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }

                if viewModel.source == .huggingFace {
                    if !viewModel.filteredSearchResults.isEmpty {
                        Section("Search Results") {
                            ForEach(viewModel.filteredSearchResults) { summary in
                                searchResultRow(summary)
                            }
                        }
                    } else if !viewModel.searchResults.isEmpty {
                        Text("No results match the current filters.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    if !viewModel.filteredCivitAIResults.isEmpty {
                        Section("Search Results") {
                            ForEach(viewModel.filteredCivitAIResults) { summary in
                                civitaiResultRow(summary)
                            }
                        }
                    } else if !viewModel.civitaiResults.isEmpty {
                        Text("No results match the current filters.")
                            .foregroundStyle(.secondary)
                    }
                    Text("CivitAI checkpoints download and register, but only the built-in "
                        + "SDXL Turbo can be used for generation today — see the Images tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Registered Models") {
                    if viewModel.registeredModels.isEmpty {
                        Text("None yet — search above and download one.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.registeredModels) { entry in
                            registeredModelRow(entry)
                        }
                    }
                }
            }
            .searchable(text: $viewModel.query, prompt: searchPrompt)
            .onSubmit(of: .search) { Task { await viewModel.performSearch() } }
            .navigationTitle("Models")
            .overlay {
                if viewModel.isSearching { ProgressView() }
            }
            .task { await viewModel.loadRegistry() }
            .onAppear { Task { await viewModel.loadRegistry() } }
            .dismissKeyboardOnTap()
        }
    }

    private var searchPrompt: String {
        viewModel.source == .huggingFace ? "Search Hugging Face models…" : "Search CivitAI checkpoints…"
    }

    /// One consistent filter row for both sources — "Compatible only"
    /// only makes sense for HF (see `ModelsViewModel.filteredCivitAIResults`),
    /// the size limit applies to either. `viewModel` is a class, so every
    /// mutation here (`viewModel.maxSizeClass = …`) writes straight
    /// through to the `@Environment`-provided instance directly; only
    /// `Toggle` needs an actual `Binding`, built explicitly rather than
    /// relying on `$viewModel` sugar (which only exists inside `body`'s
    /// own `@Bindable` shadow).
    private var filterRow: some View {
        HStack {
            if viewModel.source == .huggingFace {
                Toggle("Compatible only", isOn: Binding(
                    get: { viewModel.compatibleOnlyHF },
                    set: { viewModel.compatibleOnlyHF = $0 }
                ))
                .toggleStyle(.button)
                .font(.caption)
                Spacer()
            }
            Menu {
                Button("Any size") { viewModel.maxSizeClass = nil }
                ForEach(ModelSizeClass.allCases) { sizeClass in
                    Button("Up to \(sizeClass.label)") { viewModel.maxSizeClass = sizeClass }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(sizeFilterLabel)
                }
                .font(.caption)
            }
            if viewModel.source != .huggingFace { Spacer() }
        }
        .listRowSeparator(.hidden)
    }

    private var sizeFilterLabel: String {
        guard let maxSizeClass = viewModel.maxSizeClass else { return "Any size" }
        return "Up to \(maxSizeClass.label)"
    }

    private func searchResultRow(_ summary: HFModelSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.modelID).font(.headline)
                HStack(spacing: 6) {
                    if let bytes = summary.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        Text("· \(ModelSizeClass.classify(sizeBytes: bytes).label)")
                    }
                    switch summary.compatibility {
                    case .compatible:
                        Text("· compatible").foregroundStyle(.green)
                    case .incompatible:
                        Text("· raw checkpoint, likely won't load").foregroundStyle(.orange)
                    case .unknown:
                        EmptyView()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            downloadControl(id: "hf:\(summary.modelID)") { Task { await viewModel.download(summary) } }
        }
    }

    private func civitaiResultRow(_ summary: CivitAIModelSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.name).font(.headline)
                HStack(spacing: 6) {
                    Text(summary.type)
                    if let baseModel = summary.baseModel {
                        Text("· \(baseModel)")
                    }
                    if let bytes = summary.primaryFile?.sizeBytes {
                        Text("· \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        Text("· \(ModelSizeClass.classify(sizeBytes: bytes).label)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            downloadControl(id: "civitai:\(summary.id)", disabled: summary.primaryFile == nil) {
                Task { await viewModel.download(summary) }
            }
        }
    }

    /// A real fillable bar + percentage while a download is active — the
    /// same "clara" progress the Mac app's Model Manager gives, not just
    /// a spinner with no sense of how far along it is.
    @ViewBuilder
    private func downloadControl(id: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        if viewModel.activeDownloadID == id {
            VStack(alignment: .trailing, spacing: 2) {
                if let progress = viewModel.downloadProgress {
                    ProgressView(value: progress).frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        } else {
            Button("Download", action: action)
                .disabled(viewModel.isDownloading || disabled)
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func registeredModelRow(_ entry: ModelEntry) -> some View {
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
            if entry.kind == .text {
                loadControl(for: entry)
            }
        }
        .swipeActions {
            if chatEngine.loadedModelID != entry.id {
                Button("Delete", role: .destructive) { Task { await viewModel.delete(entry) } }
            }
        }
    }

    /// Load/Unload straight from the Models tab — the actual management
    /// the source list/downloads alone didn't give: a downloaded text
    /// model previously had no way to be loaded, freed, or even shown as
    /// "in use" anywhere outside Chat's own picker.
    private func loadControl(for entry: ModelEntry) -> some View {
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
}
