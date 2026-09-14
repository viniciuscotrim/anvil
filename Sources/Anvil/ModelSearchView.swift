import SwiftUI
import AnvilCore
import UniformTypeIdentifiers

/// Search and download models — Hugging Face, CivitAI, or Draw Things
/// — as its own tab, separate from the registered-model library
/// (`ModelLibraryView`). Split out of what used to be one combined
/// "Models" screen: requested live — "vamos separar a busca e download
/// de modelos em uma nova aba/menu chamado Search, e os modelos
/// Registrados ficam onde estão agora. Igual já temos no iPhone" (iOS
/// already draws this same line between its own `ModelSearchView` and
/// `ModelLibraryView`, both backed by the same `ModelsViewModel` the
/// way this file and `ModelLibraryView` here both share one
/// `ModelManagerViewModel`). Stacking search controls, live downloads,
/// results, *and* the whole registered library in one unscrollable
/// `VStack` — what the combined screen used to do — was the real,
/// reported layout bug this also fixes: at this window's old minimum
/// size, that stack didn't fit, so rows visually crowded and
/// overlapped the app's own top-level tab bar above it. A `List` with
/// defined `Section`s gives every part of this a fixed place and
/// scrolls internally on its own, the same fix `MemoryView` got for
/// an identical complaint.
struct ModelSearchView: View {
    // Owned once by `AppState` (like `ModelLibraryView`'s own copy of
    // the same instance) — see that type's header comment for why this
    // is never a view-local `@StateObject`.
    @EnvironmentObject private var viewModel: ModelManagerViewModel

    var body: some View {
        List {
            Section {
                sourcePicker
                sortPicker
            }

            switch viewModel.searchSource {
            case .huggingFace:
                Section {
                    searchBar
                    searchOptionsBar
                    hfTokenBar
                }
            case .civitai:
                Section {
                    civitaiSearchBar
                    Text("Search and download work today — loading a downloaded CivitAI checkpoint doesn't yet (mflux needs a single-file loading path this hasn't been wired up to). It'll register and show up in the Models tab either way.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    civitaiTokenBar
                }
            case .drawThings:
                Section {
                    drawThingsSearchBar
                    Text("Official quantized community models from the Draw Things ecosystem (Flux, SDXL, SD 1.5 in 8-bit, 4-bit, 3-bit).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.isBusy || !viewModel.downloadQueue.isEmpty {
                Section("Downloads in Progress") {
                    if viewModel.isBusy, let activeJob = viewModel.activeJob {
                        activeDownloadRow(activeJob)
                    }
                    ForEach(viewModel.downloadQueue) { job in
                        queuedDownloadRow(job)
                    }
                }
            }

            switch viewModel.searchSource {
            case .huggingFace:
                if !viewModel.filteredSearchResults.isEmpty {
                    Section("Results") {
                        ForEach(viewModel.filteredSearchResults) { summary in
                            searchResultRow(summary)
                        }
                    }
                }
            case .civitai:
                if !viewModel.rankedCivitAIResults.isEmpty {
                    Section("Results") {
                        ForEach(viewModel.rankedCivitAIResults) { summary in
                            civitaiResultRow(summary)
                        }
                    }
                }
            case .drawThings:
                if !viewModel.drawThingsResults.isEmpty {
                    Section("Results") {
                        ForEach(viewModel.sortedDrawThingsResults) { summary in
                            drawThingsResultRow(summary)
                        }
                    }
                }
            }

            Section {
                modelsFolderBar
            }

            if let error = viewModel.errorMessage {
                Section {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .task {
            await viewModel.loadRegistry()
        }
    }

    /// Which catalog Search/results below act on — a shared download
    /// queue/progress covers both, so switching sources never risks a
    /// second, simultaneous download.
    private var sourcePicker: some View {
        HStack {
            Picker("", selection: Binding(
                get: { viewModel.searchSource },
                set: { viewModel.searchSource = $0 }
            )) {
                ForEach(ModelSearchSource.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)

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
            Spacer()
        }
    }

    /// Applies to whichever source is selected above — requested live:
    /// "Na aba de busca, me dar opcões de ordenação dos resultados em
    /// todas as plataformas por tamanho, quantidade de downloads, data
    /// de atualização/pulicação."
    private var sortPicker: some View {
        HStack {
            Text("Sort by:").foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { viewModel.sortOption },
                set: { viewModel.sortOption = $0 }
            )) {
                ForEach(ModelSearchSortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            Spacer()
        }
        .font(.callout)
    }

    private var searchBar: some View {
        HStack {
            TextField("Search Hugging Face models…", text: $viewModel.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await viewModel.search() } }
                .onChange(of: viewModel.query) { _, _ in viewModel.queryDidChange() }

            Button("Search") { Task { await viewModel.search() } }
                .disabled(viewModel.isBusy)

            if !viewModel.query.isEmpty || !viewModel.searchResults.isEmpty {
                Button("Clear") { viewModel.clearSearch() }
            }
        }
    }

    private var searchOptionsBar: some View {
        HStack {
            Picker("Size", selection: Binding(
                get: { viewModel.sizeFilter },
                set: { viewModel.sizeFilter = $0 }
            )) {
                Text("Any size").tag(Optional<ModelSizeClass>.none)
                ForEach(ModelSizeClass.allCases) { sizeClass in
                    Text(sizeClass.label).tag(Optional(sizeClass))
                }
            }
            .frame(maxWidth: 160)
            .help("Relative to this Mac's RAM — Small ≤25%, Medium ≤50%, Large above that.")

            Toggle("Search as I type", isOn: Binding(
                get: { viewModel.isLiveSearchEnabled },
                set: { viewModel.isLiveSearchEnabled = $0 }
            ))
            .help("Searches automatically once you've typed 3+ characters, after a short pause.")

            Toggle("Compatible only", isOn: Binding(
                get: { viewModel.hideIncompatibleModels },
                set: { viewModel.hideIncompatibleModels = $0 }
            ))
            .help("Hides repos shaped like a raw single-file checkpoint mflux can't load as-is — a flat *.safetensors with no pipeline folders. Never hides a model this can't tell either way about, text models included.")

            Spacer()
        }
        .font(.callout)
    }

    /// Where downloads land and where "scan for existing models" looks
    /// — a folder full of models downloaded outside Anvil (an old oMLX
    /// directory, say) can be pointed at directly; its subfolders get
    /// read and registered right away. This only controls *future*
    /// downloads and what Rescan looks at — it's not a filter on what's
    /// shown in the Models tab: a model registered from somewhere else
    /// stays registered (and usable) no matter what this is set to.
    /// Move a model into the current folder, or delete it, from the
    /// Models tab's own list.
    private var modelsFolderBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("Models Folder:")
                    .foregroundStyle(.secondary)
                Text(viewModel.modelsRootPath ?? "Default (Anvil's own folder)")
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Rescan") { Task { await viewModel.rescanModelsRoot() } }
                    .disabled(viewModel.isBusy)
                Button("Change…") { viewModel.isChoosingModelsFolder = true }
                    .disabled(viewModel.isBusy)
                    .fileImporter(
                        isPresented: Binding(
                            get: { viewModel.isChoosingModelsFolder },
                            set: { viewModel.isChoosingModelsFolder = $0 }
                        ),
                        allowedContentTypes: [.folder]
                    ) { result in
                        switch result {
                        case .success(let url):
                            Task { await viewModel.changeModelsRoot(to: url) }
                        case .failure(let error):
                            viewModel.errorMessage = error.localizedDescription
                        }
                    }
                if viewModel.modelsRootPath != nil {
                    Button("Reset") { Task { await viewModel.resetModelsRootToDefault() } }
                        .disabled(viewModel.isBusy)
                }
            }
            Text("Controls new downloads and Rescan only — doesn't hide models registered from elsewhere. Move/delete those in the Models tab.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    /// Authenticates search and downloads against Hugging Face — needed
    /// for private repos and gated ones you've been granted access to,
    /// and gets the authenticated (higher) rate limit either way. Held
    /// in the keychain (synced via iCloud), not a plain settings file —
    /// see `HFTokenStore`.
    private var hfTokenBar: some View {
        HStack {
            Image(systemName: "key")
                .foregroundStyle(.secondary)
            Text("Hugging Face Token:")
                .foregroundStyle(.secondary)

            if viewModel.hasStoredHFToken {
                Text("Set").foregroundStyle(.green)
                Spacer()
                Button("Remove") { viewModel.clearHFToken() }
            } else {
                SecureField("hf_…", text: Binding(
                    get: { viewModel.hfTokenDraft },
                    set: { viewModel.hfTokenDraft = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                Button("Save") { viewModel.saveHFToken() }
                    .disabled(viewModel.hfTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
        }
        .font(.callout)
    }

    private var civitaiSearchBar: some View {
        HStack {
            TextField("Search CivitAI checkpoints…", text: Binding(
                get: { viewModel.civitaiQuery },
                set: { viewModel.civitaiQuery = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await viewModel.searchCivitAI() } }

            Button("Search") { Task { await viewModel.searchCivitAI() } }
                .disabled(viewModel.isBusy)

            if !viewModel.civitaiQuery.isEmpty || !viewModel.civitaiResults.isEmpty {
                Button("Clear") { viewModel.clearCivitAISearch() }
            }
        }
    }

    private var civitaiTokenBar: some View {
        HStack {
            Image(systemName: "key")
                .foregroundStyle(.secondary)
            Text("CivitAI API Key:")
                .foregroundStyle(.secondary)

            if viewModel.hasStoredCivitAIToken {
                Text("Set").foregroundStyle(.green)
                Spacer()
                Button("Remove") { viewModel.clearCivitAIToken() }
            } else {
                SecureField("optional — needed for some gated content", text: Binding(
                    get: { viewModel.civitaiTokenDraft },
                    set: { viewModel.civitaiTokenDraft = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                Button("Save") { viewModel.saveCivitAIToken() }
                    .disabled(viewModel.civitaiTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
        }
        .font(.callout)
    }

    private func civitaiResultRow(_ summary: CivitAIModelSummary) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(summary.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(summary.type)
                    if let baseModel = summary.baseModel {
                        Text("· \(baseModel)")
                    }
                    if let downloads = summary.downloadCount {
                        Text("· \(downloads) downloads")
                    }
                    if let bytes = summary.primaryFile?.sizeBytes {
                        Text("· \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    }
                    if let date = summary.publishedAt {
                        Text("· \(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            resultDownloadButton(for: .civitai(summary), disabled: summary.primaryFile == nil) {
                viewModel.download(summary)
            }
        }
    }

    /// Shared by every result row's own "Updated" text — requested
    /// alongside `ModelSearchSortOption`, so a "sort by update date"
    /// control isn't sorting by something invisible in the row itself.
    fileprivate static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var drawThingsSearchBar: some View {
        HStack {
            TextField("Search Draw Things official & community models…", text: Binding(
                get: { viewModel.drawThingsQuery },
                set: { viewModel.drawThingsQuery = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await viewModel.searchDrawThings() } }

            Button("Search") { Task { await viewModel.searchDrawThings() } }
                .disabled(viewModel.isBusy)

            if !viewModel.drawThingsQuery.isEmpty || viewModel.drawThingsResults != DrawThingsCatalog.curatedModels {
                Button("Clear") { viewModel.clearDrawThingsSearch() }
            }
        }
    }

    private func drawThingsResultRow(_ summary: DrawThingsModelSummary) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(summary.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    if let baseModel = summary.baseModel {
                        Text(baseModel)
                    }
                    if let quant = summary.quantization {
                        Text("· \(quant)")
                    }
                    if let downloads = summary.downloads {
                        Text("· \(downloads) downloads")
                    }
                    if let bytes = summary.sizeBytes {
                        Text("· \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    }
                    if let date = summary.lastModified {
                        Text("· \(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))")
                    }
                    HStack(spacing: 3) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("· Draw Things (libnnc)")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            resultDownloadButton(for: .drawThings(summary)) {
                viewModel.download(summary)
            }
        }
    }

    private func searchResultRow(_ summary: HFModelSummary) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(summary.modelID)
                    .font(.headline)
                HStack(spacing: 6) {
                    if let downloads = summary.downloads {
                        Text("\(downloads) downloads")
                    }
                    if let bytes = summary.sizeBytes {
                        Text("· \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        Text("· \(ModelSizeClass.classify(sizeBytes: bytes).label)")
                    }
                    if let date = summary.lastModified {
                        Text("· \(Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date()))")
                    }
                    switch summary.compatibility {
                    case .supported(let engine):
                        HStack(spacing: 3) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("· \(engine.displayName)")
                                .foregroundStyle(.green)
                        }
                    case .incompatible(let reason):
                        HStack(spacing: 3) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                            Text("· Incompatible (\(reason))")
                                .foregroundStyle(.red)
                        }
                    case .unknown:
                        EmptyView()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            let isDisabled: Bool = {
                if case .incompatible = summary.compatibility { return true }
                return false
            }()
            resultDownloadButton(for: .huggingFace(summary), disabled: isDisabled) {
                viewModel.download(summary)
            }
        }
    }

    /// A result row's own download control — deliberately just a button
    /// (Download / Queue / a plain "Downloading…"/"Queued" label), no
    /// progress bar or Pause/Stop here anymore. Those actions live in
    /// `downloadsInProgressSection`'s own rows below the search bar:
    /// mixing live download state into every row of a scrollable
    /// results list was real, reported clutter, not just untidy.
    private func resultDownloadButton(for job: DownloadJob, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Group {
            if viewModel.activeDownloadID == job.id {
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            } else if viewModel.downloadQueue.contains(where: { $0.id == job.id }) {
                Text("Queued").font(.caption).foregroundStyle(.secondary)
            } else {
                // Not disabled while something else is downloading —
                // clicking then enqueues instead of starting a second,
                // simultaneous download.
                Button(viewModel.isBusy ? "Queue" : "Download", action: action)
                    .disabled(disabled)
            }
        }
    }

    private func activeDownloadRow(_ job: DownloadJob) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName).font(.callout)
                Text(viewModel.statusMessage.isEmpty ? "Working…" : viewModel.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            downloadProgressControl
        }
    }

    private func queuedDownloadRow(_ job: DownloadJob) -> some View {
        HStack {
            Text(job.displayName).font(.callout)
            Spacer()
            Text("Queued").font(.caption).foregroundStyle(.secondary)
            Button("Remove") { viewModel.removeFromQueue(job) }
        }
    }

    /// A real fillable bar + percentage while `huggingface_hub`'s own
    /// progress lines carry one — falls back to an indeterminate spinner
    /// for the stretches that don't (between files, right at the start).
    private var downloadProgressControl: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let progress = viewModel.downloadProgress {
                ProgressView(value: progress)
                    .frame(width: 120)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 8) {
                Button("Pause") { viewModel.pauseDownload() }
                Button("Stop", role: .destructive) { viewModel.stopDownload() }
            }
        }
    }
}
