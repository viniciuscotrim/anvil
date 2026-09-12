import SwiftUI
import AnvilCore
import UniformTypeIdentifiers

/// Phase 2: browse/search/download against Hugging Face directly, plus
/// importing an already-downloaded model folder without re-fetching it.
/// A model's `kind` (auto-detected at download/import time) decides
/// which session manager — text or image — its Load/Unload/server
/// controls talk to.
struct ModelManagerView: View {
    // Owned once by `AppState` (like `chat`/`imageGeneration`/`profiles`),
    // not a view-local `@StateObject` — that was a real, reported bug:
    // switching away from Models and back tore this down and rebuilt
    // it from scratch, so an in-flight download's Task, still running
    // in the background, was orphaned from any UI that could show it —
    // it kept downloading, just invisibly. Same root cause, same fix,
    // as the earlier Chat/conversation-loss bug.
    @EnvironmentObject private var viewModel: ModelManagerViewModel
    @EnvironmentObject private var sessions: ModelSessionManager
    @EnvironmentObject private var imageSessions: ImageSessionManager
    @EnvironmentObject private var requirements: RequirementsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourcePicker

            switch viewModel.searchSource {
            case .huggingFace:
                searchBar
                searchOptionsBar
                hfTokenBar
            case .civitai:
                civitaiSearchBar
                Text("Search and download work today — loading a downloaded CivitAI checkpoint doesn't yet (mflux needs a single-file loading path this hasn't been wired up to). It'll register and show up below either way.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                civitaiTokenBar
            case .drawThings:
                drawThingsSearchBar
                Text("Official quantized community models from the Draw Things ecosystem (Flux, SDXL, SD 1.5 in 8-bit, 4-bit, 3-bit).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            downloadsInProgressSection

            switch viewModel.searchSource {
            case .huggingFace:
                if !viewModel.searchResults.isEmpty {
                    searchResultsList
                }
            case .civitai:
                if !viewModel.civitaiResults.isEmpty {
                    civitaiResultsList
                }
            case .drawThings:
                if !viewModel.drawThingsResults.isEmpty {
                    drawThingsResultsList
                }
            }

            modelsFolderBar

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
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
    /// shown below: a model registered from somewhere else stays
    /// registered (and usable) no matter what this is set to. Move a
    /// model into the current folder, or delete it, with the icons
    /// next to it in the list.
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
            Text("Controls new downloads and Rescan only — doesn't hide models registered from elsewhere. Move/delete those below.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    /// Authenticates search and downloads against Hugging Face — needed
    /// for private repos and gated ones you've been granted access to,
    /// and gets the authenticated (higher) rate limit either way. Held
    /// in the macOS keychain, not a plain settings file — see
    /// `HFTokenStore`.
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

    private var civitaiResultsList: some View {
        List(viewModel.rankedCivitAIResults) { summary in
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
        .frame(minHeight: 160, maxHeight: 220)
    }

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

    private var drawThingsResultsList: some View {
        List(viewModel.drawThingsResults) { summary in
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
        .frame(minHeight: 160, maxHeight: 220)
    }

    private var searchResultsList: some View {
        List(viewModel.filteredSearchResults) { summary in
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
        .frame(minHeight: 160, maxHeight: 220)
    }

    /// A result row's own download control — deliberately just a button
    /// (Download / Queue / a plain "Downloading…"/"Queued" label), no
    /// progress bar or Pause/Stop here anymore. Those actions moved into
    /// `downloadsInProgressSection`, a dedicated area below the search
    /// bar: mixing live download state into every row of a scrollable
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

    /// Every active/queued download, separate from search results —
    /// the active one gets a real fillable bar + percentage (falling
    /// back to an indeterminate spinner for stretches with no percentage
    /// in `huggingface_hub`'s own progress lines, e.g. between files)
    /// plus Pause/Stop; queued ones just get a Remove.
    @ViewBuilder
    private var downloadsInProgressSection: some View {
        if viewModel.isBusy || !viewModel.downloadQueue.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloads in Progress").font(.headline)
                if viewModel.isBusy, let activeJob = viewModel.activeJob {
                    activeDownloadRow(activeJob)
                }
                ForEach(viewModel.downloadQueue) { job in
                    queuedDownloadRow(job)
                }
            }
            .padding(10)
            .background(Color.gray.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private var registeredModelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Registered models")
                .font(.headline)

            if viewModel.registeredModels.isEmpty {
                Text("None yet.")
                    .foregroundStyle(.secondary)
            } else {
                // Grouped by family (e.g. every "Qwen3.5" size/quant
                // variant together, "FLUX.2-klein" its own) rather than
                // one flat list — see `ModelManagerViewModel.familyName`.
                List {
                    ForEach(viewModel.registeredModelFamilies) { family in
                        Section(family.name) {
                            ForEach(family.models) { entry in
                                modelRow(entry)
                            }
                        }
                    }
                }
                .frame(minHeight: 220)
            }
        }
        .confirmationDialog(
            "Move \"\(viewModel.modelPendingDeletion?.displayName ?? "")\" to the Trash?",
            isPresented: Binding(
                get: { viewModel.modelPendingDeletion != nil },
                set: { if !$0 { viewModel.modelPendingDeletion = nil } }
            ),
            presenting: viewModel.modelPendingDeletion
        ) { entry in
            Button("Move to Trash", role: .destructive) {
                Task { await viewModel.deleteModel(entry) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("This moves the model's files to the Trash and removes it from Anvil — not a permanent delete, but it does free up \(ByteCountFormatter.string(fromByteCount: entry.sizeBytes ?? 0, countStyle: .file)) once emptied.")
        }
    }

    private func modelRow(_ entry: ModelEntry) -> some View {
        let isLoaded = entry.kind == .image ? imageSessions.isLoaded(modelID: entry.id) : sessions.isLoaded(modelID: entry.id)

        return HStack {
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
                Text(entry.localPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()

            if !viewModel.isUnderCurrentModelsFolder(entry) {
                Button {
                    Task { await viewModel.moveToCurrentFolder(entry) }
                } label: {
                    if viewModel.movingModelID == entry.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "tray.and.arrow.down")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isLoaded || viewModel.movingModelID != nil)
                .help(isLoaded ? "Unload the model first." : "Move into the current models folder.")
            }

            Button {
                viewModel.modelPendingDeletion = entry
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isLoaded)
            .help(isLoaded ? "Unload the model first." : "Move this model's files to the Trash.")

            loadControl(for: entry)
        }
    }

    @ViewBuilder
    private func loadControl(for entry: ModelEntry) -> some View {
        switch entry.kind {
        case .text:
            textLoadControl(for: entry)
        case .image:
            imageLoadControl(for: entry)
        }
    }

    @ViewBuilder
    private func textLoadControl(for entry: ModelEntry) -> some View {
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
                failureIndicator(reason: reason, modelID: entry.id)
                Button("Retry") { Task { await sessions.load(entry, requirements: requirements) } }
            }

            serverSettingsButton(
                for: entry,
                currentPort: session?.port ?? sessions.suggestedPort(),
                currentAccess: session?.access ?? .localOnly,
                isLoaded: sessions.isLoaded(modelID: entry.id)
            ) { access, port in
                if sessions.isLoaded(modelID: entry.id) {
                    await sessions.updateServerSettings(modelID: entry.id, requirements: requirements, access: access, port: port)
                } else {
                    await sessions.load(entry, requirements: requirements, access: access, port: port)
                }
            }
        }
    }

    /// A tappable warning icon — not hover-only, which a real report
    /// showed users don't reliably discover — opening a popover with
    /// the full, selectable failure reason. That reason itself now
    /// includes the server process's own captured output (a real
    /// traceback, when there is one), not just a generic wrapper
    /// message — see `LLMServer`/`ImageServer`'s `failureDetail`.
    private func failureIndicator(reason: String, modelID: String) -> some View {
        Button {
            viewModel.failureDetailFor = modelID
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .buttonStyle(.borderless)
        .help(reason)
        .popover(isPresented: Binding(
            get: { viewModel.failureDetailFor == modelID },
            set: { if !$0 { viewModel.failureDetailFor = nil } }
        )) {
            ScrollView {
                Text(reason)
                    .textSelection(.enabled)
                    .font(.system(.callout, design: .monospaced))
                    .padding()
            }
            .frame(width: 420, height: 260)
        }
    }

    @ViewBuilder
    private func imageLoadControl(for entry: ModelEntry) -> some View {
        let session = imageSessions.sessions.first { $0.id == entry.id }

        HStack(spacing: 6) {
            switch session?.status {
            case .none:
                Button("Load") { Task { await imageSessions.load(entry, requirements: requirements) } }

            case .loading:
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)

            case .ready:
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("\(session?.access.host ?? ""):\(session?.port ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Unload") { Task { await imageSessions.unload(modelID: entry.id) } }

            case .failed(let reason):
                failureIndicator(reason: reason, modelID: entry.id)
                Button("Retry") { Task { await imageSessions.load(entry, requirements: requirements) } }
            }

            serverSettingsButton(
                for: entry,
                currentPort: session?.port ?? imageSessions.suggestedPort(),
                currentAccess: session?.access ?? .localOnly,
                isLoaded: imageSessions.isLoaded(modelID: entry.id)
            ) { access, port in
                if imageSessions.isLoaded(modelID: entry.id) {
                    await imageSessions.updateServerSettings(modelID: entry.id, requirements: requirements, access: access, port: port)
                } else {
                    await imageSessions.load(entry, requirements: requirements, access: access, port: port)
                }
            }
        }
    }

    /// Opt-in, per-model control for the two things a server the user
    /// opens must let them decide: which port, and whether it's
    /// reachable only from this Mac or over the network. Works for
    /// either session manager — the caller supplies the current
    /// port/access and how to actually apply a new choice.
    private func serverSettingsButton(
        for entry: ModelEntry,
        currentPort: Int,
        currentAccess: ServerAccess,
        isLoaded: Bool,
        apply: @escaping (ServerAccess, Int) async -> Void
    ) -> some View {
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
            serverSettingsPopover(
                for: entry,
                currentPort: currentPort,
                currentAccess: currentAccess,
                isLoaded: isLoaded,
                apply: apply
            )
        }
    }

    private func serverSettingsPopover(
        for entry: ModelEntry,
        currentPort: Int,
        currentAccess: ServerAccess,
        isLoaded: Bool,
        apply: @escaping (ServerAccess, Int) async -> Void
    ) -> some View {
        let resolvedAccess = viewModel.access(for: entry.id, currentAccess: currentAccess)

        return VStack(alignment: .leading, spacing: 10) {
            Text("Server Settings").font(.headline)

            Picker("Access", selection: Binding(
                get: { resolvedAccess },
                set: { viewModel.setAccess($0, for: entry.id, currentPort: currentPort, currentAccess: currentAccess) }
            )) {
                ForEach(ServerAccess.allCases) { access in
                    Text(access.label).tag(access)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(resolvedAccess.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Port") {
                TextField("8000", text: Binding(
                    get: { viewModel.portText(for: entry.id, currentPort: currentPort) },
                    set: { viewModel.setPortText($0, for: entry.id, currentPort: currentPort, currentAccess: currentAccess) }
                ))
                .frame(width: 80)
            }

            if entry.kind == .text {
                Divider()
                Text("Inference Engine").font(.headline)
                Picker("Engine", selection: Binding(
                    get: { entry.engineOverride },
                    set: { newEngine in
                        Task { await viewModel.updateEngineOverride(for: entry.id, engine: newEngine) }
                    }
                )) {
                    Text("Auto (\(entry.effectiveEngine.shortLabel))").tag(Optional<InferenceEngine>.none)
                    Text("MLX (Apple Silicon)").tag(Optional(InferenceEngine.mlx))
                    Text("llama.cpp (GGUF)").tag(Optional(InferenceEngine.llamaCpp))
                }
                .labelsHidden()
                Text("Default is auto-detected from files (GGUF uses llama.cpp, Safetensors uses MLX).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if entry.kind == .image {
                Divider()
                Text("Inference Engine").font(.headline)
                Picker("Engine", selection: Binding(
                    get: { entry.engineOverride },
                    set: { newEngine in
                        Task { await viewModel.updateEngineOverride(for: entry.id, engine: newEngine) }
                    }
                )) {
                    Text("Auto (\(entry.effectiveEngine.shortLabel))").tag(Optional<InferenceEngine>.none)
                    Text("mflux (Flux Image)").tag(Optional(InferenceEngine.mflux))
                    Text("Draw Things (libnnc)").tag(Optional(InferenceEngine.drawThings))
                }
                .labelsHidden()
                Text("Default is auto-detected (Draw Things .ckpt uses libnnc, Diffusers uses mflux).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if entry.kind == .image {
                Divider()
                imageModelChatDefaults(for: entry)
            }

            HStack {
                Spacer()
                Button(isLoaded ? "Apply & Restart" : "Load") {
                    Task {
                        await viewModel.applyServerSettings(
                            for: entry.id,
                            currentPort: currentPort,
                            currentAccess: currentAccess,
                            apply: apply
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: entry.kind == .image ? 280 : 260)
    }

    /// Chat-only behavior for an image model: whether it stays resident
    /// after delivering a `generate_image` result, and the resolution
    /// used when that tool call doesn't specify one. Applied
    /// immediately — no separate "Apply" step, unlike access/port which
    /// need a server restart to take effect.
    private func imageModelChatDefaults(for entry: ModelEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chat Behavior").font(.headline)

            Toggle("Default image model for chat", isOn: Binding(
                get: { viewModel.defaultChatImageModelID == entry.id },
                set: { isOn in
                    viewModel.setDefaultChatImageModel(isOn ? entry.id : nil)
                }
            ))
            .help(
                "With more than one image model registered, this is the one generate_image "
                + "in chat prefers — loading it on demand if it isn't already resident. "
                + "Only one model can be the default at a time."
            )

            Toggle("Keep loaded after generating in chat", isOn: Binding(
                get: { entry.keepImageModelLoadedInChat },
                set: { newValue in
                    Task {
                        await viewModel.updateImageDefaults(
                            for: entry.id,
                            keepLoadedInChat: newValue,
                            width: entry.defaultImageWidth,
                            height: entry.defaultImageHeight
                        )
                    }
                }
            ))
            .help(
                "On: stays in memory between images, faster. "
                + "Off: unloads right after each image to free memory, and reloads automatically the next time one's requested."
            )

            LabeledContent("Width") {
                TextField("512", text: Binding(
                    get: { entry.defaultImageWidth.map(String.init) ?? "" },
                    set: { text in
                        Task {
                            await viewModel.updateImageDefaults(
                                for: entry.id,
                                keepLoadedInChat: entry.keepImageModelLoadedInChat,
                                width: Int(text.trimmingCharacters(in: .whitespaces)),
                                height: entry.defaultImageHeight
                            )
                        }
                    }
                ))
                .frame(width: 80)
            }
            LabeledContent("Height") {
                TextField("512", text: Binding(
                    get: { entry.defaultImageHeight.map(String.init) ?? "" },
                    set: { text in
                        Task {
                            await viewModel.updateImageDefaults(
                                for: entry.id,
                                keepLoadedInChat: entry.keepImageModelLoadedInChat,
                                width: entry.defaultImageWidth,
                                height: Int(text.trimmingCharacters(in: .whitespaces))
                            )
                        }
                    }
                ))
                .frame(width: 80)
            }
        }
    }
}
