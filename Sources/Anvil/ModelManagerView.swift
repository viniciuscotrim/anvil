import SwiftUI
import AnvilCore
import UniformTypeIdentifiers

/// Phase 2: browse/search/download against Hugging Face directly, plus
/// importing an already-downloaded model folder without re-fetching it.
struct ModelManagerView: View {
    @StateObject private var viewModel: ModelManagerViewModel
    @EnvironmentObject private var sessions: ModelSessionManager
    private let requirements: RequirementsManager

    init(requirements: RequirementsManager) {
        _viewModel = StateObject(wrappedValue: ModelManagerViewModel(requirements: requirements))
        self.requirements = requirements
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchBar

            if !viewModel.searchResults.isEmpty {
                searchResultsList
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if viewModel.isBusy {
                ProgressView(viewModel.statusMessage.isEmpty ? "Working…" : viewModel.statusMessage)
                    .progressViewStyle(.linear)
            }

            Divider()

            registeredModelsSection
        }
        .padding()
        .frame(minWidth: 560, minHeight: 420)
        .task {
            await viewModel.loadRegistry()
        }
    }

    private var searchBar: some View {
        HStack {
            TextField("Search Hugging Face models…", text: $viewModel.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await viewModel.search() } }

            Button("Search") { Task { await viewModel.search() } }
                .disabled(viewModel.isBusy)

            Button("Import Local Model…") { viewModel.isImportPanelPresented = true }
                .disabled(viewModel.isBusy)
                .fileImporter(
                    isPresented: Binding(
                        get: { viewModel.isImportPanelPresented },
                        set: { viewModel.isImportPanelPresented = $0 }
                    ),
                    allowedContentTypes: [.folder]
                ) { result in
                    switch result {
                    case .success(let url):
                        Task { await viewModel.importModel(at: url) }
                    case .failure(let error):
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
        }
    }

    private var searchResultsList: some View {
        List(viewModel.searchResults) { summary in
            HStack {
                VStack(alignment: .leading) {
                    Text(summary.modelID)
                        .font(.headline)
                    if let downloads = summary.downloads {
                        Text("\(downloads) downloads")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Download") { Task { await viewModel.download(summary) } }
                    .disabled(viewModel.isBusy)
            }
        }
        .frame(minHeight: 160, maxHeight: 220)
    }

    private var registeredModelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Registered models")
                .font(.headline)

            if viewModel.registeredModels.isEmpty {
                Text("None yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(viewModel.registeredModels) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.displayName)
                                Spacer()
                                if let size = entry.sizeBytes {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(entry.localPath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        loadControl(for: entry)
                    }
                }
                .frame(minHeight: 140)
            }
        }
    }

    @ViewBuilder
    private func loadControl(for entry: ModelEntry) -> some View {
        let session = sessions.sessions.first { $0.id == entry.id }

        switch session?.status {
        case .none:
            Button("Load") { Task { await sessions.load(entry, requirements: requirements) } }

        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }

        case .ready:
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Loaded · :\(session?.port ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Unload") { Task { await sessions.unload(modelID: entry.id) } }
            }

        case .failed(let reason):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(reason)
                Button("Retry") { Task { await sessions.load(entry, requirements: requirements) } }
            }
        }
    }
}
