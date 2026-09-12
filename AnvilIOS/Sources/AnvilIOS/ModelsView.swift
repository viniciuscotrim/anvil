import SwiftUI
import AnvilCore

/// Search, download, and manage models — real feature parity with the
/// Mac app's Model Manager (a source picker between Hugging Face and
/// CivitAI, same as the Mac's, minus the folder-mapping UI, not yet
/// ported), sharing the exact same `AnvilCore` catalog/registry code.
struct ModelsView: View {
    @Environment(ModelsViewModel.self) private var viewModel

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

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }

                if viewModel.source == .huggingFace {
                    if !viewModel.searchResults.isEmpty {
                        Section("Search Results") {
                            ForEach(viewModel.searchResults) { summary in
                                searchResultRow(summary)
                            }
                        }
                    }
                } else {
                    HStack {
                        TextField("Search CivitAI checkpoints…", text: $viewModel.civitaiQuery)
                            .textFieldStyle(.roundedBorder)
                        Button("Search") { Task { await viewModel.searchCivitAI() } }
                    }
                    if !viewModel.civitaiResults.isEmpty {
                        Section("Search Results") {
                            ForEach(viewModel.civitaiResults) { summary in
                                civitaiResultRow(summary)
                            }
                        }
                    }
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
            .conditionallySearchable(isEnabled: viewModel.source == .huggingFace, text: $viewModel.query)
            .onSubmit(of: .search) { Task { await viewModel.search() } }
            .navigationTitle("Models")
            .overlay {
                if viewModel.isSearching { ProgressView() }
            }
            .task { await viewModel.loadRegistry() }
            .dismissKeyboardOnTap()
        }
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

    @ViewBuilder
    private func downloadControl(id: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        if viewModel.activeDownloadID == id {
            if let progress = viewModel.downloadProgress {
                ProgressView(value: progress).frame(width: 60)
            } else {
                ProgressView().controlSize(.small)
            }
        } else {
            Button("Download", action: action)
                .disabled(viewModel.isDownloading || disabled)
                .buttonStyle(.bordered)
        }
    }

    private func registeredModelRow(_ entry: ModelEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
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
        }
        .swipeActions {
            Button("Delete", role: .destructive) { Task { await viewModel.delete(entry) } }
        }
    }
}

private extension View {
    /// `.searchable` always shows a search field even when it's meant
    /// for a different source (CivitAI has its own inline field
    /// instead, since binding `.searchable` conditionally isn't
    /// directly supported) — toggling it off avoids two search fields
    /// showing at once.
    @ViewBuilder
    func conditionallySearchable(isEnabled: Bool, text: Binding<String>) -> some View {
        if isEnabled {
            self.searchable(text: text, prompt: "Search Hugging Face models…")
        } else {
            self
        }
    }
}
