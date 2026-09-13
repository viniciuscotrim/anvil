import SwiftUI
import AnvilCore

/// Search and download — Hugging Face or CivitAI, one consistent
/// `.searchable` bar for both (switching sources used to reshuffle the
/// whole screen: HF had a native search field, CivitAI an inline
/// `TextField`+`Button` row instead), with a filter row and a real
/// fillable-bar-plus-percentage download control. Registered models
/// live on their own screen (`ModelLibraryView`) — see
/// `ModelsViewModel`'s header comment for why this used to be one
/// crowded tab and isn't anymore.
struct ModelSearchView: View {
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

                filterRow

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }

                downloadsInProgressSection

                switch viewModel.source {
                case .huggingFace:
                    resultsSection(
                        results: viewModel.filteredSearchResults,
                        rawCount: viewModel.searchResults.count,
                        row: searchResultRow
                    )
                case .civitai:
                    resultsSection(
                        results: viewModel.filteredCivitAIResults,
                        rawCount: viewModel.civitaiResults.count,
                        row: civitaiResultRow
                    )
                    Text("CivitAI checkpoints download and register, but only the built-in "
                        + "SDXL Turbo can be used for generation today — see the Images tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .drawThings:
                    resultsSection(
                        results: viewModel.filteredDrawThingsResults,
                        rawCount: viewModel.drawThingsResults.count,
                        row: drawThingsResultRow
                    )
                    Text("Draw Things checkpoints download and register, but iOS has no libnnc "
                        + "runtime — nothing here can be loaded on-device yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $viewModel.query, prompt: searchPrompt)
            .onSubmit(of: .search) { Task { await viewModel.performSearch() } }
            .navigationTitle("Search Models")
            .overlay {
                if viewModel.isSearching { ProgressView() }
            }
            .dismissKeyboardOnTap()
            // `item:` needs a stable identity to know a sheet is
            // showing at all, but the sheet's own content (`files`/
            // `isLoading` filling in once `beginDownload`'s fetch
            // finishes) reads live from `viewModel.ggufFilePicker`
            // itself, not this closure's `_` snapshot — a `@Observable`
            // model, so that keeps updating the sheet even though this
            // closure only ever runs once per presentation.
            .sheet(item: $viewModel.ggufFilePicker) { _ in
                GGUFFilePickerSheet()
            }
        }
    }

    @ViewBuilder
    private func resultsSection<Result: Identifiable, Row: View>(
        results: [Result], rawCount: Int, @ViewBuilder row: @escaping (Result) -> Row
    ) -> some View {
        if !results.isEmpty {
            Section("Search Results") {
                ForEach(results) { row($0) }
            }
        } else if rawCount > 0 {
            Text("No results match the current filters.")
                .foregroundStyle(.secondary)
        }
    }

    private var searchPrompt: String {
        switch viewModel.source {
        case .huggingFace: return "Search Hugging Face models…"
        case .civitai: return "Search CivitAI checkpoints…"
        case .drawThings: return "Search Draw Things models…"
        }
    }

    /// `viewModel` is a class, so every mutation here writes straight
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
            }
            Toggle(isOn: Binding(
                get: { viewModel.isLiveSearchEnabled },
                set: { viewModel.isLiveSearchEnabled = $0 }
            )) {
                Image(systemName: "bolt.fill")
            }
            .toggleStyle(.button)
            .font(.caption)
            .help("Search as I type (3+ characters, after a short pause).")
            Spacer()
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
                    if let downloads = summary.downloads {
                        Text("\(downloads) downloads")
                    }
                    if let bytes = summary.sizeBytes {
                        Text("· \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        Text("· \(ModelSizeClass.classify(sizeBytes: bytes).label)")
                    }
                    switch summary.compatibility {
                    case .supported(.mlx), .supported(.mflux):
                        Text("· compatible").foregroundStyle(.green)
                    case .supported(.llamaCpp):
                        Text("· GGUF (llama.cpp)").foregroundStyle(.green)
                    case .supported(.drawThings):
                        Text("· Draw Things format, can't load on-device here").foregroundStyle(.red)
                    case .incompatible(let reason):
                        Text("· \(reason)").foregroundStyle(.orange)
                    case .unknown:
                        EmptyView()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            resultDownloadButton(for: .huggingFace(summary), disabled: !summary.isLoadableOnIOS) {
                viewModel.beginDownload(summary)
            }
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
                    if let downloads = summary.downloadCount {
                        Text("· \(downloads) downloads")
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
            resultDownloadButton(for: .civitai(summary), disabled: summary.primaryFile == nil) {
                viewModel.download(summary)
            }
        }
    }

    private func drawThingsResultRow(_ summary: DrawThingsModelSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.name).font(.headline)
                HStack(spacing: 6) {
                    if let baseModel = summary.baseModel {
                        Text(baseModel)
                    }
                    if let quantization = summary.quantization {
                        Text("· \(quantization)")
                    }
                    if let downloads = summary.downloads {
                        Text("· \(downloads) downloads")
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
            resultDownloadButton(for: .drawThings(summary), disabled: false) {
                viewModel.download(summary)
            }
        }
    }

    /// A result row's own download control — deliberately just a button
    /// (Download / Queue / a plain "Downloading…"/"Queued" label), no
    /// progress bar or Pause/Stop here. Those live in
    /// `downloadsInProgressSection` instead, separate from the results
    /// list — mixing live download state into every row was real,
    /// reported clutter ("Downloads contaminando a tela"), not just
    /// untidy.
    private func resultDownloadButton(for job: DownloadJob, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Group {
            if viewModel.activeDownloadID == job.id {
                Text("Downloading…").font(.caption).foregroundStyle(.secondary)
            } else if viewModel.downloadQueue.contains(where: { $0.id == job.id }) {
                Text("Queued").font(.caption).foregroundStyle(.secondary)
            } else {
                // Not disabled while something else is downloading —
                // tapping then enqueues instead of starting a second,
                // simultaneous download.
                Button("Download", action: action)
                    .buttonStyle(.bordered)
                    .disabled(disabled)
            }
        }
    }

    /// Every active/queued download, in its own section right below the
    /// search bar and filters — separate from the results list, unlike
    /// before. The active one gets a real fillable bar + percentage plus
    /// Pause/Stop; queued ones just get a Remove.
    @ViewBuilder
    private var downloadsInProgressSection: some View {
        if viewModel.isDownloading || !viewModel.downloadQueue.isEmpty {
            Section("Downloads in Progress") {
                if let activeJob = viewModel.activeJob {
                    activeDownloadRow(activeJob)
                }
                ForEach(viewModel.downloadQueue) { job in
                    queuedDownloadRow(job)
                }
            }
        }
    }

    private func activeDownloadRow(_ job: DownloadJob) -> some View {
        HStack {
            Text(job.displayName).font(.callout).lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let progress = viewModel.downloadProgress {
                    ProgressView(value: progress).frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                HStack(spacing: 12) {
                    Button("Pause") { viewModel.pauseDownload() }
                        .font(.caption)
                    Button("Stop", role: .destructive) { viewModel.stopDownload() }
                        .font(.caption)
                }
            }
        }
    }

    private func queuedDownloadRow(_ job: DownloadJob) -> some View {
        HStack {
            Text(job.displayName).font(.callout).lineLimit(1)
            Spacer()
            Text("Queued").font(.caption).foregroundStyle(.secondary)
            Button("Remove") { viewModel.removeFromQueue(job) }
                .font(.caption)
        }
    }
}

/// Shown instead of downloading immediately whenever a GGUF repo has
/// more than one `.gguf` file (`ModelsViewModel.beginDownload`'s own
/// doc comment has the real bug this exists to prevent — grabbing
/// every quantization at once, not just the one the user wants).
/// Reads `viewModel.ggufFilePicker` live rather than a value captured
/// at presentation time, since it starts out `isLoading` and fills in
/// once `HuggingFaceCatalog.fileTree`'s request finishes.
private struct GGUFFilePickerSheet: View {
    @Environment(ModelsViewModel.self) private var viewModel

    var body: some View {
        NavigationStack {
            Group {
                if let picker = viewModel.ggufFilePicker {
                    List {
                        if picker.isLoading {
                            HStack {
                                Spacer()
                                ProgressView("Loading file sizes…")
                                Spacer()
                            }
                        } else if let errorMessage = picker.errorMessage {
                            Text(errorMessage).foregroundStyle(.red)
                        } else {
                            ForEach(picker.files) { file in
                                fileRow(file, label: Self.label(for: file, among: picker.files))
                            }
                        }
                    }
                } else {
                    // Only reachable for the instant between the sheet
                    // being dismissed and SwiftUI tearing this view
                    // down — `.sheet(item:)` keeps content alive briefly
                    // through its dismiss animation.
                    EmptyView()
                }
            }
            .navigationTitle("Choose a File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel.cancelGGUFFilePicker() }
                }
            }
        }
    }

    private func fileRow(_ file: HFRepoFile, label: String) -> some View {
        Button {
            viewModel.downloadSelectedGGUFFile(file)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.headline)
                    Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let bytes = file.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// The part of `file`'s name that actually distinguishes it from
    /// its siblings in this same repo (the longest common prefix
    /// across all of them, trimmed off) — most quantization filenames
    /// share one long common stem and differ only in a trailing tag
    /// (`Q4_K_M`, `IQ2_M`, …); showing just that instead of the full
    /// name makes the real choice ("which quant/size") legible without
    /// guessing at any particular naming convention.
    private static func label(for file: HFRepoFile, among files: [HFRepoFile]) -> String {
        let names = files.map { ($0.path as NSString).deletingPathExtension }
        guard names.count > 1, var prefix = names.first else {
            return (file.path as NSString).deletingPathExtension
        }
        for name in names.dropFirst() {
            while !name.hasPrefix(prefix), !prefix.isEmpty {
                prefix = String(prefix.dropLast())
            }
        }
        let name = (file.path as NSString).deletingPathExtension
        let suffix = String(name.dropFirst(prefix.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
        return suffix.isEmpty ? name : suffix
    }
}
