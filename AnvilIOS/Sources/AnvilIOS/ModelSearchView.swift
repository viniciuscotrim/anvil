import SwiftUI
import AnvilCore

/// The real proof this scaffold is more than a device-info screen: a
/// live Hugging Face search running the *exact same* `AnvilCore` code
/// the Mac app's Model Manager uses — `HuggingFaceCatalog`,
/// `ModelCompatibility`, `ModelSizeClass` — compiled straight into this
/// iOS target with zero duplication. Search only for now; download and
/// on-device inference are the next real pieces of iOS parity (they
/// need, respectively, a native Swift downloader and an `mlx-swift`
/// inference engine — the macOS versions of both are Process-based,
/// which doesn't exist on iOS).
struct ModelSearchView: View {
    @State private var query = ""
    @State private var results: [HFModelSummary] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    private let catalog = HuggingFaceCatalog()

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(results) { summary in
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
                }
            }
            .searchable(text: $query, prompt: "Search Hugging Face models…")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationTitle("Models")
            .overlay {
                if isSearching { ProgressView() }
            }
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await catalog.search(query: trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
