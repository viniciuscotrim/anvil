import SwiftUI
import AnvilCore

/// Search, download, and manage models — real feature parity with the
/// Mac app's Model Manager (minus CivitAI and the folder-mapping UI,
/// not yet ported), sharing the exact same `AnvilCore` catalog/registry
/// code.
struct ModelsView: View {
    @Environment(ModelsViewModel.self) private var viewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            List {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }

                if !viewModel.searchResults.isEmpty {
                    Section("Search Results") {
                        ForEach(viewModel.searchResults) { summary in
                            searchResultRow(summary)
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
            .searchable(text: $viewModel.query, prompt: "Search Hugging Face models…")
            .onSubmit(of: .search) { Task { await viewModel.search() } }
            .navigationTitle("Models")
            .overlay {
                if viewModel.isSearching { ProgressView() }
            }
            .task { await viewModel.loadRegistry() }
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
            if viewModel.activeDownloadRepoID == summary.modelID {
                if let progress = viewModel.downloadProgress {
                    ProgressView(value: progress).frame(width: 60)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Button("Download") { Task { await viewModel.download(summary) } }
                    .disabled(viewModel.isDownloading)
                    .buttonStyle(.bordered)
            }
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
