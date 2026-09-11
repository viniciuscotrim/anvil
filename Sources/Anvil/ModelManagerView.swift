import SwiftUI
import AnvilCore
import UniformTypeIdentifiers

/// Phase 2: browse/search/download against Hugging Face directly, plus
/// importing an already-downloaded model folder without re-fetching it.
/// A model's `kind` (auto-detected at download/import time) decides
/// which session manager — text or image — its Load/Unload/server
/// controls talk to.
struct ModelManagerView: View {
    @StateObject private var viewModel: ModelManagerViewModel
    @EnvironmentObject private var sessions: ModelSessionManager
    @EnvironmentObject private var imageSessions: ImageSessionManager
    private let requirements: RequirementsManager

    init(requirements: RequirementsManager) {
        _viewModel = StateObject(wrappedValue: ModelManagerViewModel(requirements: requirements))
        self.requirements = requirements
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchBar
            searchOptionsBar
            modelsFolderBar
            hfTokenBar

            if !viewModel.searchResults.isEmpty {
                searchResultsList
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if viewModel.isBusy {
                if let progress = viewModel.downloadProgress {
                    ProgressView(
                        value: progress,
                        label: { Text(viewModel.statusMessage.isEmpty ? "Working…" : viewModel.statusMessage) },
                        currentValueLabel: { Text("\(Int(progress * 100))%") }
                    )
                } else {
                    ProgressView(viewModel.statusMessage.isEmpty ? "Working…" : viewModel.statusMessage)
                        .progressViewStyle(.linear)
                }
                if !viewModel.downloadQueue.isEmpty {
                    Text("\(viewModel.downloadQueue.count) more queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                .onChange(of: viewModel.query) { _, _ in viewModel.queryDidChange() }

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
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.activeDownloadRepoID == summary.modelID {
                    downloadProgressControl
                } else if let queuePosition = viewModel.downloadQueue.firstIndex(where: { $0.modelID == summary.modelID }) {
                    Text("Queued (#\(queuePosition + 1))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove") { viewModel.removeFromQueue(summary) }
                } else {
                    // Not disabled while something else is downloading
                    // — clicking then enqueues instead of starting a
                    // second, simultaneous download.
                    Button(viewModel.isBusy ? "Queue" : "Download") { viewModel.download(summary) }
                }
            }
        }
        .frame(minHeight: 160, maxHeight: 220)
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
