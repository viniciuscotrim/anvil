import SwiftUI
import AnvilCore

/// Every registered model — search and download live in their own
/// `ModelSearchView` tab now (split out, requested live: "vamos
/// separar a busca e download de modelos em uma nova aba/menu chamado
/// Search, e os modelos Registrados ficam onde estão agora. Igual já
/// temos no iPhone" — see that type's own header comment for the real
/// layout bug this split also fixes). This tab keeps the "Models" name
/// and its place in the tab bar; only its content narrowed to what the
/// name always meant: what's actually registered, loadable, and
/// removable.
struct ModelLibraryView: View {
    // Owned once by `AppState` (like `ModelSearchView`'s own copy of
    // the same instance), not a view-local `@StateObject` — a real,
    // reported bug: switching away from Models and back tore a
    // view-local one down and rebuilt it from scratch, orphaning an
    // in-flight download's `Task` (still running, just invisible) from
    // any UI that could show it. Same root cause, same fix, as the
    // earlier Chat/conversation-loss bug.
    @Environment(ModelManagerViewModel.self) private var viewModel
    @Environment(ModelSessionManager.self) private var sessions
    @Environment(ImageSessionManager.self) private var imageSessions
    @Environment(RequirementsManager.self) private var requirements

    var body: some View {
        List {
            if viewModel.registeredModels.isEmpty {
                Section {
                    Text("None yet — search and download one in the Search tab, or import a folder from there.")
                        .foregroundStyle(.secondary)
                }
            } else {
                // Grouped by family (e.g. every "Qwen3.5" size/quant
                // variant together, "FLUX.2-klein" its own) rather than
                // one flat list — see `ModelManagerViewModel.familyName`.
                // Requested live: "organizar por Ativo sempre no topo" —
                // whichever family has a currently-loaded model in it
                // sorts to the very top of the list, and within that
                // family the loaded model itself sorts first too, so
                // it's never buried in a scrolled-away section.
                // Alphabetical order (already `group()`'s own tiebreak)
                // still decides everything else, both between families
                // and within one, so nothing else visually reshuffles
                // just because a model got loaded or unloaded.
                ForEach(orderedFamilies) { family in
                    Section(family.name) {
                        ForEach(sortedModels(in: family)) { entry in
                            modelRow(entry)
                        }
                    }
                }
            }
        }
        .task {
            await viewModel.loadRegistry()
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

    /// `registeredModelFamilies`, reordered so a family containing the
    /// currently-loaded model always sorts first — requested live:
    /// "organizar por Ativo sempre no topo". Alphabetical order (the
    /// grouping's own existing tiebreak) still decides everything else,
    /// so nothing else visually reshuffles just because a model got
    /// loaded or unloaded.
    private var orderedFamilies: [ModelFamilyGrouping.Family] {
        viewModel.registeredModelFamilies.sorted { lhs, rhs in
            lhs.models.contains(where: isLoaded) && !rhs.models.contains(where: isLoaded)
        }
    }

    /// A family's own models, with the loaded one (if any) sorted first
    /// too — same request, applied within a section as well as across
    /// them.
    private func sortedModels(in family: ModelFamilyGrouping.Family) -> [ModelEntry] {
        family.models.sorted { isLoaded($0) && !isLoaded($1) }
    }

    private func isLoaded(_ entry: ModelEntry) -> Bool {
        entry.kind == .image ? imageSessions.isLoaded(modelID: entry.id) : sessions.isLoaded(modelID: entry.id)
    }

    private func modelRow(_ entry: ModelEntry) -> some View {
        let active = isLoaded(entry)

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
                .disabled(active || viewModel.movingModelID != nil)
                .help(active ? "Unload the model first." : "Move into the current models folder.")
            }

            Button {
                viewModel.modelPendingDeletion = entry
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(active)
            .help(active ? "Unload the model first." : "Move this model's files to the Trash.")

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
