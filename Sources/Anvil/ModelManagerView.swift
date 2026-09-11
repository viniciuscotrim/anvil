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

        HStack(spacing: 6) {
            switch session?.status {
            case .none:
                Button("Load") { Task { await sessions.load(entry, requirements: requirements) } }

            case .loading:
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)

            case .ready:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("\(session?.access.host ?? ""):\(session?.port ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Unload") { Task { await sessions.unload(modelID: entry.id) } }

            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(reason)
                Button("Retry") { Task { await sessions.load(entry, requirements: requirements) } }
            }

            serverSettingsButton(for: entry)
        }
    }

    /// Opt-in, per-model control for the two things a server the user
    /// opens must let them decide: which port, and whether it's
    /// reachable only from this Mac or over the network.
    private func serverSettingsButton(for entry: ModelEntry) -> some View {
        Button {
            viewModel.openServerSettingsFor = entry.id
        } label: {
            Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
        .popover(isPresented: Binding(
            get: { viewModel.openServerSettingsFor == entry.id },
            set: { isPresented in
                if !isPresented, viewModel.openServerSettingsFor == entry.id {
                    viewModel.openServerSettingsFor = nil
                }
            }
        )) {
            serverSettingsPopover(for: entry)
        }
    }

    private func serverSettingsPopover(for entry: ModelEntry) -> some View {
        let isLoaded = sessions.isLoaded(modelID: entry.id)
        let currentAccess = viewModel.access(for: entry.id, sessions: sessions)

        return VStack(alignment: .leading, spacing: 10) {
            Text("Server Settings").font(.headline)

            Picker("Access", selection: Binding(
                get: { currentAccess },
                set: { viewModel.setAccess($0, for: entry.id, sessions: sessions) }
            )) {
                ForEach(ServerAccess.allCases) { access in
                    Text(access.label).tag(access)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(currentAccess.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Port") {
                TextField("8000", text: Binding(
                    get: { viewModel.portText(for: entry.id, sessions: sessions) },
                    set: { viewModel.setPortText($0, for: entry.id, sessions: sessions) }
                ))
                .frame(width: 80)
            }

            HStack {
                Spacer()
                Button(isLoaded ? "Apply & Restart" : "Load") {
                    Task {
                        await viewModel.applyServerSettings(for: entry, sessions: sessions, requirements: requirements)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 260)
    }
}
