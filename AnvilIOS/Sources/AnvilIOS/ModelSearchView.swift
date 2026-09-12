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

                if viewModel.source == .huggingFace {
                    resultsSection(
                        results: viewModel.filteredSearchResults,
                        rawCount: viewModel.searchResults.count,
                        row: searchResultRow
                    )
                } else {
                    resultsSection(
                        results: viewModel.filteredCivitAIResults,
                        rawCount: viewModel.civitaiResults.count,
                        row: civitaiResultRow
                    )
                    Text("CivitAI checkpoints download and register, but only the built-in "
                        + "SDXL Turbo can be used for generation today — see the Images tab.")
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
        viewModel.source == .huggingFace ? "Search Hugging Face models…" : "Search CivitAI checkpoints…"
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
                    if let downloads = summary.downloads {
                        Text("\(downloads) downloads")
                    }
                    if let bytes = summary.sizeBytes {
                        Text("· \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
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
}
